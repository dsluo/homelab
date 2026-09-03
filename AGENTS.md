# Homelab

A two-node Kubernetes homelab with GitOps-driven deployments. `talos0` is the control plane (Intel GPU host); `talos1` is a worker.

## Stack

The non-obvious, load-bearing choices that shape how changes get made:

- **OS / Kubernetes**: Talos Linux, bootstrapped via `talhelper` + `helmfile`
- **GitOps**: Flux CD watches `kubernetes/` and reconciles continuously — changes land via commit, not `kubectl apply`
- **CNI**: Cilium, which also replaces kube-proxy
- **Kubernetes secrets**: External Secrets Operator with the 1Password SDK provider
- **Bootstrap / IaC secrets**: SOPS + Age for Talos, OpenTofu, and encrypted recovery documents
- **Infra-as-code**: OpenTofu under `infra/` (MikroTik switch in `infra/sw_core/`, Backblaze B2 in `infra/backblaze/`)
- **Dependency updates**: Renovate (auto-merges patch/minor for GitHub Actions and mise tools)

Other tooling is discoverable from the repo: mise (`.mise.toml`), Just (the justfile), and the apps under `kubernetes/apps/` (Envoy Gateway, OpenEBS, kopiur, cert-manager, CloudNative-PG, Victoria Metrics + Grafana, tuppr, etc.).

## Directory Structure

```
kubernetes/
  apps/        # App deployments, organized by namespace
  components/  # Shared Kustomize components (kopiur, OIDC, database)
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
    externalsecret.yaml  # ESO mapping to a 1Password item (when needed)
```

`ks.yaml` is Flux's wrapper — edit it for dependencies, shared `components/`, and `postBuild.substitute` values. The `app/` dir holds the real manifests — edit it to change the workload itself.

**Scaffold new apps with `just newapp`** (copier from `templates/`). Don't hand-roll the boilerplate.

**Validate before committing: `just test`.** It runs `flate test all` — flate renders the whole Flux tree (Kustomizations and HelmReleases) offline and reports what would fail to reconcile, without touching the cluster.

**Kubernetes secrets come from 1Password through ESO — never commit plaintext.** Reference fields explicitly from `externalsecret.yaml`. Cluster-wide values live in the `cluster-global-config` ConfigMap and remain available through `postBuild.substituteFrom`. SOPS remains only for Talos, OpenTofu, and encrypted recovery documents.

**Comments: short and load-bearing.** A comment states the non-obvious constraint in a line or two — what breaks if you change this, or why the obvious approach doesn't work. Don't write essay-style blocks that narrate investigation history, enumerate rejected alternatives, cite source files of third-party code, or argue the change is correct. That context belongs in the commit message, PR description, or memory — not in the manifest.

**Operational loop:** merging a PR to `main` fires a GitHub webhook that reconciles Flux right away — the merge *is* the deploy, so don't tell anyone to wait for a poll interval. `just reconcile` force-pulls when a sync is needed outside that path. To test a feature branch live before merging, `just flux-branch` points Flux at the current branch; `just flux-branch-reset` reverts to `main`.

## Memory

- **Save memories to memini** (the MCP memory service, namespace `homelab`) via `memory_remember`. This is the primary, preferred store — do **not** write new memories to the on-disk file-based store when memini is reachable.
- **Disk is a fallback only.** Write a memory to the on-disk file-based store (indexed in its `MEMORY.md`) **only if memini is unavailable** (e.g. the MCP server is unreachable). Note in the entry that it is a stopgap pending migration.
- **Migrate stopgap disk memories at the first opportunity.** Whenever memini becomes available again and on-disk memory files exist, prompt the user to migrate them into memini using a subagent. Once migrated, delete the disk files and clear the `MEMORY.md` index.
