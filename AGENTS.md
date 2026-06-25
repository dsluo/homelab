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

## Memory

- **Save memories to memini** (the MCP memory service, namespace `homelab`) via `memory_remember`. This is the primary, preferred store — do **not** write new memories to the on-disk file-based store when memini is reachable.
- **Disk is a fallback only.** Write a memory to the on-disk file-based store (indexed in its `MEMORY.md`) **only if memini is unavailable** (e.g. the MCP server is unreachable). Note in the entry that it is a stopgap pending migration.
- **Migrate stopgap disk memories at the first opportunity.** Whenever memini becomes available again and on-disk memory files exist, prompt the user to migrate them into memini using a subagent. Once migrated, delete the disk files and clear the `MEMORY.md` index.
