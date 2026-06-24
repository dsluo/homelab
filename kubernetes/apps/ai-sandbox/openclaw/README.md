# openclaw

Self-hosted AI agent gateway that runs untrusted agent code. It lives in the
isolated `ai-sandbox` namespace, pinned to `talos1`, sandboxed by **gVisor**,
and firewalled by a default-deny egress CiliumNetworkPolicy.

## Security model

- **gVisor (`runtimeClassName: gvisor`)** is the sandbox boundary: agent code
  runs against runsc's userspace kernel, so a breakout hits gVisor, not the host
  kernel. This replaces docker-in-docker entirely — **no privileged container,
  no host Docker daemon**.
- **gVisor is scoped to openclaw only** — not forced namespace-wide. The openclaw
  pod opts in via `runtimeClassName: gvisor` (`app/runtimeclass.yaml`); VolSync
  movers and any other infra in the namespace run on the normal runtime. This is
  deliberate: the untrusted workload is sandboxed, trusted backup infra is left
  alone (and JJGadgets' reference does the same — gVisor on the app, not the
  movers).
- **Pod hardening (restricted-compliant)**: `runAsNonRoot`,
  `allowPrivilegeEscalation: false`, all caps dropped, `seccompProfile:
  RuntimeDefault`, `readOnlyRootFilesystem: true` (HOME is the only writable
  persistent path; `/tmp` is a memory emptyDir). The hardening is applied per
  workload (the openclaw pod), not via the namespace floor: the namespace
  *enforce* level is `baseline`, because VolSync's NFS-mounting backup/restore
  mover (+ an injected unhardened `jitter` initContainer) can't satisfy
  `restricted`. gVisor + the pod's own securityContext are the real isolation.
- **No kube-API access**: `automountServiceAccountToken: false`, and egress
  policy denies the API server / other namespaces anyway. (Note: JJGadgets'
  reference deliberately does the *opposite* — it grants the pod a ServiceAccount
  with `pods/exec`, `deployments` patch, and a cluster `view` ClusterRoleBinding
  so its agent can deploy/scale LLMs. That is a capability grant, not hardening;
  we keep the agent off the API entirely.)
- **SSO at the gateway (defense-in-depth)**: the HTTPRoute is wrapped by a
  Pocket-ID OIDC `SecurityPolicy` via the `components/oidc/envoy` component
  (`ks.yaml`), so reaching the Control UI requires an SSO login *before* traffic
  ever hits OpenClaw's own gateway-token auth. Two independent auth layers.
- **Pinned to `talos1`** (worker, has the gVisor extension); never the
  control-plane / GPU host `talos0`.
- **Egress is default-deny** (`app/networkpolicy.yaml`): only cluster DNS, a
  short allowlist of named in-cluster services (the Qwen model, memini, and the
  SearXNG MCP proxy — via Cilium `toServices`, which tracks each Service's own
  backends and self-heals across chart bumps, **not** the whole `ai` namespace),
  and the *public* internet (private / link-local CIDRs excluded). kube-apiserver,
  the LAN, and every other namespace/service are unreachable. (`toServices` can't
  be paired with `toPorts`, so memini's :9090 metrics port is reachable alongside
  its :8080 API — acceptable for a sandbox allowlist.) See **Egress hardening**
  below for tightening the public-internet rule to a per-domain allowlist.

## Storage

- **`config` PVC (`openclaw`, VolSync-backed)**: mounted at `$HOME=/home/node`.
  Holds config, agents, auth-profiles, workspace — the stuff worth backing up.
- **`cache` (ephemeral `emptyDir`, NOT backed up)**: mounted over `$HOME/.cache`
  with a `sizeLimit` cap. Holds regenerable agent/toolchain caches (npm, pip,
  go, …) so they don't bloat the restic backups of the config PVC. Discarded on
  pod recreation (re-downloaded as needed) — cheaper than a dedicated PVC for
  throwaway data. Add more sub-mounts (or switch to a PVC) if a tool caches
  outside `~/.cache` or the re-download cost becomes annoying. (JJGadgets keeps a
  similar split — a separate non-backed `misc` PVC for brew/nix/go/mise.)

## Egress hardening (deferred follow-up)

The egress policy currently allows the agent to reach **any** public host on
443/80. The tighter model — adopted from JJGadgets' reference — is a Cilium
`toFQDNs` allowlist of only the provider domains the agent needs (e.g.
`api.anthropic.com`, `*.openrouter.ai`). To switch:

1. Upgrade the CoreDNS egress rule in `app/networkpolicy.yaml` to L7 by adding
   `rules: { dns: [{ matchPattern: "*" }] }` under its `toPorts`, so Cilium's
   DNS proxy can learn name→IP mappings.
2. Replace the `0.0.0.0/0` `toCIDRSet` rule with a `toFQDNs` rule listing the
   allowed domains.

Deferred because it trades the agent's general web access for tighter
containment — enable it once the needed domain set is known. `ndots:1` is
already set (`helmrelease.yaml`) in preparation.

## Node prerequisites (apply to talos1 BEFORE Flux reconciles)

`talos/talconfig.yaml` adds two things to talos1, both needed before the pod
can run (and on any future cluster rebuild):

1. `siderolabs/gvisor` system extension (provides the `runsc` runtime).
2. `user.max_user_namespaces: "11255"` sysctl — gVisor needs unprivileged user
   namespaces to build its sandbox (Talos defaults this to 0).

```sh
# The extension is a schematic change → talos1 gets a new installer image and
# REBOOTS. The sysctl applies in the same upgrade.
talhelper genconfig
talosctl upgrade -n 10.0.42.4 --image <factory-image-from-clusterconfig>
# verify after reboot:
talosctl -n 10.0.42.4 get extensions | grep -i gvisor
talosctl -n 10.0.42.4 list /usr/local/bin | grep runsc
talosctl -n 10.0.42.4 read /proc/sys/user/max_user_namespaces   # expect 11255
```

Only then let Flux reconcile `ai-sandbox` (the RuntimeClass `gvisor` won't
schedule until the handler exists on talos1).

## Onboarding

OpenClaw setup is interactive, so the `setup` initContainer **blocks pod
startup** until it's done — no unconfigured gateway ever serves. On first
deploy the pod sits in Init; complete setup with:

```sh
kubectl -n ai-sandbox exec -it <pod> -c setup -- openclaw setup
```

Once `$HOME/.openclaw/openclaw.json` exists the gate clears and the gateway
starts. The Control UI is then at `https://openclaw.${SECRET_DOMAIN}/`, behind a
Pocket-ID SSO login (the Envoy OIDC `SecurityPolicy`). An in-cluster model is
already reachable per the egress policy; external provider APIs work over the
public-internet rule.

> **Network bind is config-only, not env** (verified in OpenClaw source
> v2026.6.8). The gateway reads `gateway.bind` from `openclaw.json` (or the
> `--bind` flag) — `OPENCLAW_GATEWAY_BIND` is **inert** in a plain pod (only the
> Docker `setup.sh` would translate it to config, and we don't run that). With no
> config value the default is `auto`, which binds `0.0.0.0` **only when OpenClaw
> detects a container runtime**; gVisor isn't detected, so it fell back to
> loopback and was unreachable (CrashLoop). The `setup` initContainer therefore
> forces `gateway.bind: "lan"` (→ `0.0.0.0` unconditionally) in the persisted
> config. `OPENCLAW_GATEWAY_PORT` *is* honored via env (source-confirmed), which
> is why the gateway listens on 18789.
>
> Auth: `OPENCLAW_GATEWAY_TOKEN` (`app/secret.sops.yaml`) is read directly from
> env. A non-loopback bind makes OpenClaw require a credential, so a
> wrong/missing token CrashLoops rather than exposing an unauthenticated UI.
> JJGadgets uses `OPENCLAW_GATEWAY_PASSWORD` only because he selected
> password-mode auth.

## Runtime validation (after first deploy)

Can't be verified from manifests:

- [ ] Pod schedules on talos1 under RuntimeClass `gvisor` and passes readiness.
- [ ] **OpenClaw runs cleanly under gVisor** — watch for syscall-compat issues
      in the node app; gVisor trades some compatibility/perf for isolation.
- [ ] **`config` PVC is writable** by uid 1000 at `$HOME=/home/node` under
      `fsGroup: 1000` on OpenEBS-ZFS (with `readOnlyRootFilesystem`, this is the
      only writable persistent path).
- [ ] **NetworkPolicy selects the pod** (`app.kubernetes.io/name: openclaw`);
      confirm with `cilium endpoint list` / Hubble that it's enforced.
- [ ] **SSO works end-to-end**: `https://openclaw.${SECRET_DOMAIN}/` redirects to
      Pocket-ID and back. Watch for OIDC interfering with non-browser clients —
      the OpenClaw Control UI's API/websocket calls must survive the forward-auth
      filter (if a CLI/agent client needs unauthenticated access, carve out its
      path in the `SecurityPolicy` rather than disabling OIDC).
- [ ] **`cache` emptyDir is writable** at `$HOME/.cache` by uid 1000.
- [ ] Agent can reach an in-cluster LLM (`ai` :8080) and the public internet.
- [ ] Negative check: from inside the pod, kube-apiserver and a LAN host
      (e.g. 10.0.42.1) are **unreachable**; DNS still resolves.
