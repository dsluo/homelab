# Homelab

A single-node Kubernetes homelab with GitOps-driven deployments.

## Stack

- **OS**: Talos Linux
- **Kubernetes**: k8s on Talos, bootstrapped via `talhelper` + `helmfile`
- **GitOps**: Flux CD (flux-operator + flux-instance) — watches `kubernetes/` and reconciles continuously
- **CNI**: Cilium (also replaces kube-proxy)
- **Ingress**: Envoy Gateway + k8s-gateway (internal DNS)
- **Storage**: OpenEBS ZFS (persistent) + Local HostPath
- **Backups**: VolSync
- **Secrets**: SOPS + Age (encrypted in-repo), 1Password as the Age key backend
- **Certs**: cert-manager
- **DB**: CloudNative-PG (PostgreSQL operator)
- **Monitoring**: Victoria Metrics + Grafana (with Grafana MCP)
- **Infra-as-code**: OpenTofu — manages MikroTik switch (`infra/sw_core/`) and Backblaze B2 (`infra/backblaze/`)
- **Dependency updates**: Renovate (auto-merges patch/minor for GitHub Actions and mise tools)
- **Tool versions**: mise-en-place (`.mise.toml`)
- **Task runner**: Taskfile (`task <command>`)

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

## Key Apps by Namespace

| Namespace | Apps |
|---|---|
| kube-system | Cilium, CoreDNS, Metrics Server, Intel GPU driver |
| network | Cloudflare DNS + Tunnel, Envoy Gateway, k8s-gateway |
| database | CloudNative-PG |
| observability | Victoria Metrics, Grafana, SNMP Exporter |
| documents | Paperless-ngx |
| security | Pocket-ID (SSO) |

## Conventions

- use MCPs over command line tools when possible