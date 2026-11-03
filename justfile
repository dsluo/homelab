_:
    @just --list

# Force Flux to pull changes from Git repo.
reconcile:
    flux --namespace flux-system reconcile kustomization flux-system --with-source

# Temporarily point the Flux source at a branch (defaults to current).
flux-branch branch=`git rev-parse --abbrev-ref HEAD`:
    # Suspend the HelmRelease so Flux won't reset the FluxInstance back to main.
    flux --namespace flux-system suspend helmrelease flux-instance
    # Patch the FluxInstance CR; flux-operator reconciles this into the GitRepository.
    kubectl --namespace flux-system patch fluxinstance flux --type=merge \
        -p '{"spec":{"sync":{"ref":"refs/heads/{{branch}}"}}}'
    flux --namespace flux-system reconcile kustomization flux-system --with-source

# Revert the Flux source back to main (resumes flux-instance).
flux-branch-reset:
    # Reset the CR explicitly; resuming the HelmRelease is a no-op when values are unchanged.
    kubectl --namespace flux-system patch fluxinstance flux --type=merge \
        -p '{"spec":{"sync":{"ref":"refs/heads/main"}}}'
    flux --namespace flux-system resume helmrelease flux-instance
    flux --namespace flux-system reconcile kustomization flux-system --with-source

# Generate boilerplate for a new app.
newapp:
    copier copy templates . --trust

# Run static migration checks and flate tests
test:
    flate test all --path kubernetes/flux/cluster --allow-missing-secrets

# Stop NFS-backed apps (those using components/zeroscaler) before planned NAS downtime.
nas-down:
    #!/usr/bin/env bash
    set -euo pipefail
    kubectl get kustomizations.kustomize.toolkit.fluxcd.io --all-namespaces --output json |
        jq -r '.items[] | select(any(.spec.components[]?; endswith("/zeroscaler"))) | "\(.metadata.namespace) \(.metadata.name)"' |
        while read -r ns app; do
            # Suspend Flux first, or it recreates the HPA and the HPA scales the app back up.
            flux --namespace "$ns" suspend kustomization "$app"
            flux --namespace "$ns" suspend helmrelease "$app"
            kubectl --namespace "$ns" delete hpa "$app" --ignore-not-found
            kubectl --namespace "$ns" scale deployment "$app" --replicas 0
            kubectl --namespace "$ns" wait --for=delete pod --selector "app.kubernetes.io/controller=$app" \
                --field-selector status.phase=Running --timeout 5m
        done

# Bring NFS-backed apps back once the NAS is up again.
nas-up:
    #!/usr/bin/env bash
    set -euo pipefail
    kubectl get kustomizations.kustomize.toolkit.fluxcd.io --all-namespaces --output json |
        jq -r '.items[] | select(any(.spec.components[]?; endswith("/zeroscaler"))) | "\(.metadata.namespace) \(.metadata.name)"' |
        while read -r ns app; do
            flux --namespace "$ns" resume helmrelease "$app"
            # Recreates the HPA, which scales the app back to one replica.
            flux --namespace "$ns" resume kustomization "$app"
        done
