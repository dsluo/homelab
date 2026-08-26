# Dependency routing table

Known consumption sites and failure modes for the dependencies that recur in Renovate PRs.
Verified against the repo as of 2026-08-25 — if a path below doesn't exist anymore, trust the
repo, and update this file.

## OS / cluster core

- **Talos** → pinned in `talos/talconfig.yaml` (`talosVersion`) **and** driven by
  `kubernetes/apps/system-upgrade/tuppr/upgrades/talosupgrade.yaml`. Check that the factory
  image for the new version publishes the system extensions this cluster uses. Blast radius:
  a rolling power-cycle of **both nodes** — always last in a merge order.
- **kubelet / Kubernetes** → `talos/talconfig.yaml` (`kubernetesVersion`) and
  `kubernetes/apps/system-upgrade/tuppr/upgrades/kubernetesupgrade.yaml`. Pinned independently
  of the version bundled in the Talos release — check the new Talos' supported kubelet range
  when both bump in the same batch.
- **Cilium, CoreDNS, cert-manager, flux-operator, flux-instance** → **two call sites each**:
  `bootstrap/helmfile.d/01-apps.yaml` (bootstrap) and their app dir under `kubernetes/apps/`.
  The failure mode is version drift between the two — a Renovate PR usually bumps both;
  confirm it did. Cilium is the CNI and replaces kube-proxy: a bad rollout takes the whole
  cluster's networking with it.
- **Gateway API / Envoy Gateway CRDs** → CRDs upgrade automatically on chart bump because the
  cluster-wide Kustomization patch in `kubernetes/flux/cluster/ks.yaml` sets
  `crds: CreateReplace` on every HelmRelease (install and upgrade). So a chart bump *is* a CRD
  bump — check the CRD changelog, not just the controller's.

## Charts with wide fan-out

- **app-template** (bjw-s) → ~19 HelmReleases under `kubernetes/apps/` consume it
  (`grep -rl app-template kubernetes/apps --include='*.yaml' | grep ocirepository`). For a
  bump, render-and-diff **all** consumers, not a sample — a no-op render across all of them is
  the ✅ evidence.

## Amplifiers

- **`wait: true` in a `ks.yaml`** makes that app a choke point: if it crash-loops, every
  Kustomization with `dependsOn` on it stalls. Currently set on (among others) cloudnative-pg,
  flux-operator, pocket-id, victoria, snapshot-controller, tuppr —
  `grep -rln 'wait: true' kubernetes/apps/*/*/ks.yaml` for the live list. A bump that can
  crash-loop one of these is ⛔-leaning, not ⚠.
- **pocket-id** is the OIDC provider for the SSO-protected apps — any pocket-id restart is a
  brief total SSO outage. Count consumers via `grep -rl pocket-id kubernetes/apps` before
  stating blast radius.
- **CloudNative-PG databases**: `instances: 1` plus `primaryUpdateMethod: restart` means every
  image/operator bump that restarts the primary is a short DB outage for that app — no HA
  fallback on this cluster. One-way schema migrations: take/verify a CNPG backup first, and
  check the CRD actually exposes a version-pin/rollback field before claiming rollback is
  possible.
