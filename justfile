_:
    @just --list

# Force Flux to pull changes from Git repo.
reconcile:
    flux --namespace flux-system reconcile kustomization flux-system --with-source

# Generate boilerplate for a new app.
newapp:
    copier copy templates . --trust

# Run flate tests
test:
    flate test all --path kubernetes/flux/cluster --allow-missing-secrets
