# openclaw

Self-hosted AI agent gateway. Runs an agent **sandbox** via a Docker-in-Docker
sidecar, which is why it lives in the dedicated, privileged-PSA `ai-sandbox`
namespace, pinned to `talos1`, and firewalled by a default-deny egress
CiliumNetworkPolicy.

## Security model

- **`hostUsers: false`** (k8s 1.36 userns GA): the pod runs in its own user
  namespace, so the `dind` daemon's `privileged` root maps to an unprivileged
  UID on the host. A sandbox/agent breakout cannot become root on the node.
- **Pinned to `talos1`** (worker), never the control-plane/GPU host `talos0`.
- **Egress is default-deny** (`app/networkpolicy.yaml`): only cluster DNS and
  the *public* internet (private/link-local CIDRs excluded). The kube-apiserver,
  other namespaces, and the LAN are unreachable.
- **dind socket is `0660`, group `1000`** — only the gateway can drive the daemon.

## Apply ordering (IMPORTANT — Talos before Flux)

`hostUsers: false` will not admit unless talos1 allows user namespaces. Talos
disables them by default, so the node sysctl must be applied **before** Flux
reconciles this app (and on any future cluster rebuild):

```sh
# 1. Apply the Talos sysctl (user.max_user_namespaces: "11255") to talos1 first.
talhelper genconfig
talosctl apply-config -n 10.0.42.4 --file talos/clusterconfig/<talos1>.yaml
# This sysctl is runtime-writable and applies live; reboot talos1 if it doesn't
# take effect. Confirm:
talosctl -n 10.0.42.4 read /proc/sys/user/max_user_namespaces   # expect 11255

# 2. Then let Flux reconcile ai-sandbox.
```

## Runtime validation (after first deploy)

These can't be verified from manifests:

- [ ] Pod schedules on talos1 and passes readiness (gateway + dind up, init
      `docker-cli` completed).
- [ ] **dockerd starts inside the userns** — check `dind` logs for
      overlayfs/cgroup-v2 errors. If overlay fails under userns on the Talos
      1.13 kernel, switch dind's storage driver to `fuse-overlayfs`.
- [ ] **`config` PVC is writable** by uid 1000 in the gateway
      (`/home/node/.openclaw`) under `fsGroup: 1000` + userns idmap on
      OpenEBS-ZFS.
- [ ] **NetworkPolicy selects the pod** — running pod carries
      `app.kubernetes.io/name: openclaw`; verify with `cilium endpoint list` /
      Hubble that the policy is enforced (a selector mismatch silently no-ops).
- [ ] Sandboxed agents spawn and run end-to-end.
- [ ] Negative check: from inside the gateway, kube-apiserver and a LAN host
      (e.g. 10.0.42.1) are **unreachable** on 80/443; DNS still resolves.
- [ ] If dind needs `overlay`/`br_netfilter`/`ip_tables` modules (userns cannot
      load them), add them via `machine.kernel.modules` on talos1.

## Onboarding

OpenClaw's model-provider credentials and messaging channels are configured
interactively via the Control UI at `https://openclaw.${SECRET_DOMAIN}/` (auth
with the gateway token in `app/secret.sops.yaml`). External provider APIs work
through the egress policy; an **in-cluster** model would need a scoped
`toEndpoints` rule added to `app/networkpolicy.yaml`.
