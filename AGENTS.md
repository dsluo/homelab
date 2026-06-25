# Homelab

A two-node Kubernetes homelab with GitOps-driven deployments. `talos0` is the control plane (Intel GPU host); `talos1` is a worker.

## Stack

The non-obvious, load-bearing choices that shape how changes get made:

- **OS / Kubernetes**: Talos Linux, bootstrapped via `talhelper` + `helmfile`
- **GitOps**: Flux CD watches `kubernetes/` and reconciles continuously — changes land via commit, not `kubectl apply`
- **CNI**: Cilium, which also replaces kube-proxy
- **Secrets**: SOPS + Age, encrypted in-repo, with 1Password as the Age key backend
- **Infra-as-code**: OpenTofu under `infra/` (MikroTik switch in `infra/sw_core/`, Backblaze B2 in `infra/backblaze/`)
- **Dependency updates**: Renovate (auto-merges patch/minor for GitHub Actions and mise tools)

Other tooling is discoverable from the repo: mise (`.mise.toml`), Just (the justfile), and the apps under `kubernetes/apps/` (Envoy Gateway, OpenEBS, VolSync, cert-manager, CloudNative-PG, Victoria Metrics + Grafana, tuppr, etc.).

## Directory Structure

```
kubernetes/
  apps/        # App deployments, organized by namespace
  components/  # Shared Kustomize components (SOPS, VolSync)
  flux/        # Flux CD config
talos/         # Talos OS cluster config (talconfig.yaml + generated clusterconfig/)
infra/         # OpenTofu infra (MikroTik switch, Backblaze B2)
bootstrap/     # One-time cluster bootstrap (helmfile.d/)
scripts/       # Automation scripts
docs/          # Hardware and bootstrap documentation
```

Apps are organized by namespace under `kubernetes/apps/<namespace>/` — list that directory to see what's deployed and where.

## Working in this repo

**App layout (the two-file split).** Each app is:

```
kubernetes/apps/<ns>/<app>/
  ks.yaml          # Flux Kustomization: dependsOn, components, postBuild substitutions, targetNamespace
  app/
    kustomization.yaml   # lists the resources below
    helmrelease.yaml     # the actual workload (usually the app-template chart)
    ocirepository.yaml   # chart source
    secret.sops.yaml     # SOPS-encrypted secrets (when needed)
```

`ks.yaml` is Flux's wrapper — edit it for dependencies, shared `components/`, and `postBuild.substitute` values. The `app/` dir holds the real manifests — edit it to change the workload itself.

**Scaffold new apps with `just newapp`** (copier from `templates/`). Don't hand-roll the boilerplate.

**Validate before committing: `just test`** (runs `flate test all`). This is what CI gates on (`.github/workflows/flate.yaml`), so it's the pre-push check.

**Secrets are SOPS — never commit plaintext.** Files matching `*.sops.yaml` are encrypted per `.sops.yaml` rules; edit them via `sops`. Cluster-wide values come from the `cluster-secrets` Secret via `postBuild.substituteFrom`.

**Operational loop:** `just reconcile` force-pulls from Git. To test a feature branch live before merging, `just flux-branch` points Flux at the current branch; `just flux-branch-reset` reverts to `main`.

## Memory

- **Save memories to memini** (the MCP memory service, namespace `homelab`) via `memory_remember`. This is the primary, preferred store — do **not** write new memories to the on-disk file-based store when memini is reachable.
- **Disk is a fallback only.** Write a memory to the on-disk file-based store (indexed in its `MEMORY.md`) **only if memini is unavailable** (e.g. the MCP server is unreachable). Note in the entry that it is a stopgap pending migration.
- **Migrate stopgap disk memories at the first opportunity.** Whenever memini becomes available again and on-disk memory files exist, prompt the user to migrate them into memini using a subagent. Once migrated, delete the disk files and clear the `MEMORY.md` index.
