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
  policy denies the API server / other namespaces anyway.
- **Pinned to `talos1`** (worker, has the gVisor extension); never the
  control-plane / GPU host `talos0`.
- **Egress is default-deny** (`app/networkpolicy.yaml`): only cluster DNS, the
  in-cluster LLMs (`ai` namespace :8080), and the *public* internet (private /
  link-local CIDRs excluded). kube-apiserver, the LAN, and other namespaces are
  unreachable.

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
starts. The Control UI is then at `https://openclaw.${SECRET_DOMAIN}/`. An
in-cluster model is already reachable per the egress policy; external provider
APIs work over the public-internet rule.

> Auth + bind are **fail-loud**, not fail-open: with `OPENCLAW_GATEWAY_BIND=lan`
> (a non-loopback bind) OpenClaw refuses to start without a credential, so a
> wrong/missing token CrashLoops rather than exposing an unauthenticated UI.
> `OPENCLAW_GATEWAY_TOKEN` (`app/secret.sops.yaml`) is the documented token-mode
> var; `OPENCLAW_GATEWAY_BIND=lan` is the documented container mechanism for
> binding to the pod interface (env overrides the config key). JJGadgets uses
> `OPENCLAW_GATEWAY_PASSWORD` only because he selected password-mode auth.

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
- [ ] Agent can reach an in-cluster LLM (`ai` :8080) and the public internet.
- [ ] Negative check: from inside the pod, kube-apiserver and a LAN host
      (e.g. 10.0.42.1) are **unreachable**; DNS still resolves.
