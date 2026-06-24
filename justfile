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

# Run flate tests
test:
    flate test all --path kubernetes/flux/cluster --allow-missing-secrets
