_:
    @just --list

# Force Flux to pull changes from Git repo.
reconcile:
    flux --namespace flux-system reconcile kustomization flux-system --with-source

# Generate boilerplate for a new app.
newapp:
    copier copy templates . --trust

# Run flux-local tests
test:
    flux-local test --enable-helm --all-namespaces --path kubernetes/flux/cluster/ -v
