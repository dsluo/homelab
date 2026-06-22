# Homelab

A two-node Kubernetes homelab with GitOps-driven deployments. `talos0` is the control plane (Intel GPU host); `talos1` is a worker.

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
- **Monitoring**: Victoria Metrics + Grafana (with Grafana MCP), Kepler (power metrics)
- **OS/Talos upgrades**: tuppr (`system-upgrade` namespace)
- **Infra-as-code**: OpenTofu — manages MikroTik switch (`infra/sw_core/`) and Backblaze B2 (`infra/backblaze/`)
- **Dependency updates**: Renovate (auto-merges patch/minor for GitHub Actions and mise tools)
- **Tool versions**: mise-en-place (`.mise.toml`)
- **Task runner**: Just (`just <command>`)

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

| Namespace      | Apps                                                                                        |
| -------------- | ------------------------------------------------------------------------------------------- |
| kube-system    | Cilium, CoreDNS, Metrics Server, Intel GPU driver, Reflector, Reloader, Snapshot Controller |
| network        | Cloudflare DNS + Tunnel, Envoy Gateway, k8s-gateway, towonel-agent                          |
| database       | CloudNative-PG                                                                              |
| observability  | Victoria Metrics, Grafana, SNMP Exporter, Kepler                                            |
| ai             | llama.cpp, SearXNG, ToolHive (MCP servers)                                                  |
| media          | Jellyfin, Sonarr, Radarr, Prowlarr, Bazarr, qBittorrent, SABnzbd, Seerr, Recyclarr          |
| documents      | Paperless-ngx                                                                               |
| finance        | Actual                                                                                      |
| maker          | OrcaSlicer                                                                                  |
| games          | Games-on-Whales (Wolf game streaming) + direwolf-operator                                   |
| social         | Continuwuity (Matrix), Sable                                                                |
| security       | Pocket-ID (SSO)                                                                             |
| system-upgrade | tuppr (Talos upgrades)                                                                      |
| openebs-system | OpenEBS                                                                                     |
| cert-manager   | cert-manager                                                                                |
| volsync-system | VolSync                                                                                     |
| flux-system    | flux-operator, flux-instance                                                                |
| default        | echo                                                                                        |
