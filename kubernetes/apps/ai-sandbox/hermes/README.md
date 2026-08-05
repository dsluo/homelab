# hermes

[Hermes Agent](https://github.com/NousResearch/hermes-agent) (Nous Research) —
a self-hosted agent runtime that runs untrusted agent code. It lives in the
isolated `ai-sandbox` namespace, pinned to `talos1`, sandboxed by **gVisor**,
and firewalled by a default-deny egress CiliumNetworkPolicy.

Replaces **openclaw**, which occupied this namespace previously. Hermes is a
different project, not a rename — see [Relationship to openclaw](#relationship-to-openclaw)
for what actually changed.

## Security model

- **gVisor (`runtimeClassName: gvisor`)** is the sandbox boundary: agent code
  runs against runsc's userspace kernel, so a breakout hits gVisor, not the host
  kernel. No privileged container, no host Docker daemon. Note that Hermes'
  `terminal.backend` must stay `local` (the default) — pointing it at the
  `docker` backend would want a Docker socket and defeat the whole arrangement.
- **gVisor is scoped to hermes only** — not forced namespace-wide. The hermes
  pod opts in via `runtimeClassName: gvisor` (`app/runtimeclass.yaml`); kopiur
  movers and any other infra in the namespace run on the normal runtime. The
  untrusted workload is sandboxed; trusted backup infra is left alone.
- **Pod hardening (restricted-compliant)**: `runAsNonRoot`,
  `allowPrivilegeEscalation: false`, all caps dropped, `seccompProfile:
  RuntimeDefault`, `readOnlyRootFilesystem: true` (`/opt/data` is the only
  writable persistent path; `/run` and `/dev/shm` are capped memory emptyDirs,
  `/tmp` is a capped *disk-backed* emptyDir — it's the one writable path
  untrusted agent code can fill at will, and on `medium: Memory` filling it
  would OOM-kill the pod instead of just hitting a disk quota).
  The hardening is applied per workload, not via the namespace floor: the
  namespace *enforce* level is `baseline`, because kopiur's movers inline-mount
  the NFS repository and `nfs` volumes aren't allowed under `restricted`.
  gVisor + the pod's own securityContext are the real isolation.
- **No kube-API access**: `automountServiceAccountToken: false`, and egress
  policy denies the API server / other namespaces anyway.
- **SSO at the app**: the dashboard authenticates against Pocket-ID directly.
  See [Authentication](#authentication).
- **Pinned to `talos1`** (worker, has the gVisor extension); never the
  control-plane / GPU host `talos0`.
- **Egress is default-deny** (`app/networkpolicy.yaml`): cluster DNS, the
  envoy-cloudflare gateway pods (for Pocket-ID — see below), a short allowlist
  of named in-cluster services (the Qwen model, memini, and the SearXNG MCP
  proxy — via Cilium `toServices`), and the *public* internet (private /
  link-local CIDRs excluded). kube-apiserver, the rest of the LAN, and every
  other namespace/service are unreachable.

### The uid is not a free choice

`runAsUser: 10000` matches the `hermes` user baked into the image
(`useradd -u 10000 -m -d /opt/data hermes`). This is load-bearing: the s6
stage2 hook (`docker/stage2-hook.sh`) **refuses to boot** when the container
starts as a non-root uid that isn't `id -u hermes`, because the bootstrap can
then neither remap the user nor chown the data volume. The only two supported
starts are root (the image default, which drops via `s6-setuidgid`) and uid
10000 exactly. We take the latter so nothing in the pod ever runs as root.

Consequences of not being root: the stage2 hook's `chown` passes become no-ops
(harmless — `fsGroup: 10000` and the uid match already give correct ownership),
and `HERMES_UID`/`PUID` remapping is unavailable (we don't need it).

## Authentication

**This is the main structural change from openclaw.** openclaw had no OIDC of
its own, so it was wrapped in an Envoy forward-auth `SecurityPolicy` (the
`components/oidc/envoy` component) with its own gateway token underneath — two
independent layers. Hermes ships a self-hosted OIDC provider
(`plugins/dashboard_auth/self_hosted`), so it authenticates against Pocket-ID
itself and `ks.yaml` pulls in `components/oidc` — the OIDC *client* only, no
`SecurityPolicy`. One redirect flow instead of two stacked ones.

Three things make this work, and all three are load-bearing:

| Setting | Why |
|---|---|
| `OIDC_CALLBACK_PATH: /auth/callback` | Hermes' callback path. The component defaults to `/oauth2/callback`, which is the *Envoy* filter's path. |
| `OIDC_PKCE_ENABLED: "true"` | The provider sends PKCE (S256) on every exchange, in both public and confidential modes. Pocket-ID must accept it. |
| `HERMES_DASHBOARD_PUBLIC_URL` | The redirect_uri is reconstructed from this. Without it, it's built from the pod-internal host and Pocket-ID rejects the redirect. |

The client id and secret come from the `hermes-oidc-credentials` Secret that
the Pocket-ID operator creates (we use it as a confidential client — PKCE
*and* a client secret).

**This is a reduction in defense-in-depth, and worth being explicit about.**
openclaw had two independent gates: the Envoy forward-auth filter rejected
unauthenticated requests before they reached any app code, and a gateway token
sat behind it. Hermes has one — its own middleware — so the whole dashboard
HTTP surface is now network-reachable by anything that can hit envoy-internal.
That is defensible here (the gate fails closed, and the unauthenticated
allowlist is narrow: `/auth/*`, `/login`, `/api/auth/providers`, the MCP OAuth
callback, and static assets) but it is one layer, not two, on an app whose
whole premise is running untrusted code.

### Reaching Pocket-ID

Because the pod now authenticates itself, it needs to reach the issuer
server-side — for discovery, the token exchange, and the JWKS fetch. That took
a new egress rule, and the obvious form of it does not work:

`pocket-id.${SECRET_DOMAIN}` resolves (via k8s-gateway) to the
**envoy-cloudflare** LoadBalancer VIP — not envoy-internal, which fronts hermes
itself. With Cilium's kube-proxy replacement, a service VIP is DNAT'd to its
backend pod *before* the destination identity is resolved for policy, so the
policy engine only ever sees the gateway pod's identity. A `toFQDNs` or
`toCIDR` rule on that VIP would never match.

So the policy selects the envoy-cloudflare **gateway pods** directly. The
honest cost: Envoy routes by `Host` header, so this transitively allows every
route behind that gateway, not just Pocket-ID. There is no way to narrow it at
L3/L4 while the IdP shares a gateway — tightening it means giving pocket-id its
own Gateway.

**The dashboard fails closed.** Since the June 2026 upstream hardening, a
non-loopback bind with no registered auth provider refuses to start rather than
serving unauthenticated; `HERMES_DASHBOARD_INSECURE` is a deprecated no-op. So
a misconfiguration here shows up as a pod that never becomes ready — not as an
exposed dashboard. That's the intended failure mode, and it's why the probes
target the dashboard port.

## Storage

**`config` PVC (`hermes`, kopiur-backed)**: mounted at `/opt/data`, which is
both `HERMES_HOME` and the `hermes` user's home. Single source of truth for all
state — `config.yaml`, `.env` (provider API keys), `SOUL.md`, sessions,
memories, skills, cron, hooks, logs, and `home/` (the HOME used by tool
subprocesses like `git`, `npm`, and skill CLIs). The install tree at
`/opt/hermes` stays root-owned and immutable at runtime, so this is the only
persistent path that has to be writable.

Unlike openclaw, there is **no separate ephemeral cache mount** — see
[Deferred follow-ups](#deferred-follow-ups).

## Node prerequisites

Unchanged from openclaw — `talos/talconfig.yaml` already carries both, so if
openclaw ever ran on this cluster there is nothing to do. On a cluster rebuild,
talos1 needs:

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

## Onboarding

Unlike openclaw, startup is **not** gated on an interactive setup step: the s6
bootstrap seeds `config.yaml`, `.env`, and `SOUL.md` on first boot, and the
dashboard comes up as soon as OIDC is satisfied. There is no `setup`
initContainer.

Provider API keys are therefore *not* in a SOPS secret — they live in
`/opt/data/.env` on the PVC, written once via the setup wizard:

```sh
kubectl -n ai-sandbox exec -it deploy/hermes -- hermes setup
```

The dashboard is at `https://hermes.${SECRET_DOMAIN}/`, behind a Pocket-ID
login. To point the agent at the in-cluster Qwen model instead of an external
provider (reachable per the egress policy):

```sh
kubectl -n ai-sandbox exec -it deploy/hermes -- sh -c '
  hermes config set model.provider custom
  hermes config set model.default qwen3-6-27b-mtp
  hermes config set model.base_url http://qwen3-6-27b-mtp.ai:8080/v1
  hermes config set model.context_length 262144
'
```

`api_key` needs to be any non-empty string — llama.cpp requires the header but
doesn't validate it. Note this is a one-shot exec against the PVC rather than
openclaw's every-boot config-patch script: Hermes persists config properly and
doesn't rewrite it out from under us, so the self-healing patch loop openclaw
needed isn't warranted here.

> **Unattended gateways should enable tool-loop hard stops.**
> `tool_loop_guardrails.hard_stop_enabled` defaults to `false`, which only makes
> sense for interactive sessions where a human sees the repeated-tool-call
> warnings. Set it in `config.yaml` once the agent is in use.

## Relationship to openclaw

Hermes Agent and OpenClaw are **separate projects**, not a rename (OpenClaw's
own lineage is Clawdbot → Moltbot → OpenClaw). They overlap in purpose and are
broadly protocol-compatible, but the deployment shape differs enough that this
is a rewrite rather than an image bump:

| | openclaw | hermes |
|---|---|---|
| Runtime | Node.js | Python 3.13 + Node 26, s6-overlay as PID 1 |
| Data dir | `/home/node` | `/opt/data` (also `$HOME`) |
| uid | 1000 | 10000 (enforced by the image) |
| Exposed port | 18789 (gateway + Control UI) | 9119 (dashboard) |
| Config | `openclaw.json`, patched every boot by an initContainer | `config.yaml`, seeded by the image bootstrap |
| Startup gate | initContainer blocking on interactive setup | none |
| Auth | gateway token + Envoy OIDC forward-auth | native Pocket-ID OIDC |
| Secret | `openclaw-secret` (SOPS) | none — operator-issued OIDC creds + `.env` on the PVC |

**This PR does not migrate data.** Upstream ships `hermes claw migrate`, which
imports `~/.openclaw/` (SOUL, memory, skills, MCP servers, model/provider
config), but we're starting clean: openclaw's Kustomization is removed and Flux
prunes its PVC with it. If that turns out to be the wrong call, the migration
path is to restore the openclaw PVC from a kopiur snapshot, mount it into the
hermes pod, and run `hermes claw migrate --source <path>`.

## Deferred follow-ups

- **Ephemeral cache mount.** openclaw kept regenerable toolchain caches (npm,
  pip, go) on an `emptyDir` mounted over `$HOME/.cache` so they stayed out of
  the kopia backups. The equivalent path here is `/opt/data/home/.cache`, which
  is *nested inside* the PVC mount — the kubelet would create the intervening
  `/opt/data/home` as `root:root`, and a non-root pod that can't chown would
  then be unable to write the subprocess HOME it needs. Left out until that can
  be verified on-cluster; the cost meanwhile is that caches get snapshotted
  hourly (kopia dedupes them, so this is waste rather than breakage).
- **Per-domain egress allowlist.** The policy still permits any public host on
  443/80. The tighter model is a `toFQDNs` allowlist of just the provider
  domains the agent needs (`api.anthropic.com`, `*.openrouter.ai`, …). That
  needs the CoreDNS egress rule upgraded to L7 (`rules: { dns: [{ matchPattern:
  "*" }] }`) so Cilium's DNS proxy can learn the mappings — note that would be
  the cluster's first L7 policy. Deferred until the needed domain set is known.
- **Dedicated Gateway for pocket-id**, which would let the egress rule above
  name only the IdP's own Envoy pods instead of every route behind
  envoy-cloudflare. Out of scope here because it touches `security/pocket-id`
  and `network/envoy-gateway`.
- **OpenAI-compatible API server.** Off (upstream default). Enabling it means
  `API_SERVER_ENABLED=true`, `API_SERVER_HOST=0.0.0.0`, a SOPS-managed
  `API_SERVER_KEY` (8+ chars), and exposing port 8642 — worth doing only if
  something in-cluster actually wants to drive the agent over `/v1`.

## Runtime validation (after first deploy)

Can't be verified from manifests:

- [ ] **s6-overlay boots as uid 10000 under a read-only rootfs.** Still the
      highest-risk item. `/init` runs unprivileged here (the setuid
      `s6-overlay-suexec` is neutered by `allowPrivilegeEscalation: false`), so
      preinit can't chown `/run` and needs
      `S6_YES_I_WANT_A_WORLD_WRITABLE_RUN_BECAUSE_KUBERNETES=1` to accept the
      emptyDir as-is — see the comment on that env var in `helmrelease.yaml`.
      That was traced against s6-overlay v3.2.3.0's actual `preinit`, but only
      a real boot proves it. Note that relaxing `readOnlyRootFilesystem` alone
      would NOT have fixed it, and neither would running as root while keeping
      `capabilities: drop: [ALL]`.
- [ ] **Watch for `docker_config_migrate.py failed` in the logs.** Upstream's
      `stage2-hook.sh` is the one place in the boot path that calls
      `s6-setuidgid` without a non-root skip, so as uid 10000 with all caps
      dropped its `setgroups()` fails and Hermes' config-schema migration is
      skipped with only a warning. Non-fatal, but it means an image bump can
      silently leave `config.yaml` un-migrated. Worth an upstream issue.
- [ ] Pod schedules on talos1 under RuntimeClass `gvisor` and passes readiness.
- [ ] **Hermes runs cleanly under gVisor** — watch for syscall-compat issues;
      gVisor trades some compatibility/perf for isolation. Chromium (bundled for
      browser tools) is the most likely thing to complain.
- [ ] **`config` PVC is writable** by uid 10000 at `/opt/data` under
      `fsGroup: 10000` on OpenEBS-ZFS.
- [ ] **OIDC works end-to-end**: `https://hermes.${SECRET_DOMAIN}/` redirects to
      Pocket-ID and back to `/auth/callback`. A failure here is a pod that never
      goes ready (fail-closed), so check pod logs for the specific missing-env
      error before touching Pocket-ID.
- [ ] **The pod can reach Pocket-ID.** The failure mode is sneaky: discovery is
      lazy, so the pod goes ready and the browser redirect looks fine, and only
      the server-side token/JWKS calls hang. Check that the egress rule's pod
      selector actually matches the running envoy-cloudflare pods —
      `kubectl -n network get pods -l gateway.envoyproxy.io/owning-gateway-name=envoy-cloudflare`
      should be non-empty.
- [ ] **NetworkPolicy selects the pod** (`app.kubernetes.io/name: hermes`).
- [ ] Agent can reach the in-cluster LLM (`ai` :8080) and the public internet.
- [ ] Negative check: from inside the pod, kube-apiserver and a LAN host
      (e.g. 10.0.42.1) are **unreachable**; DNS still resolves; and
      `pocket-id.${SECRET_DOMAIN}` IS reachable.
- [ ] **`/dev/shm` is 1Gi** and browser tools work.
