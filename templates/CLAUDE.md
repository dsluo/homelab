# templates/

Copier templates for scaffolding new Flux-managed app deployments.

## Usage

Run from the repo root:

```bash
copier copy templates/ .
```

Copier will prompt for answers, then render files into `kubernetes/apps/<namespace>/<app>/`.

## Questions

| Variable | Type | Default | Description |
|---|---|---|---|
| `namespace_select` | str (select) | — | Pick an existing namespace from `kubernetes/apps/`, or `(new)` to enter one manually |
| `namespace_new` | str | — | New namespace name (only prompted when `namespace_select == "(new)"`) |
| `namespace` | str (computed) | — | Resolved namespace used throughout the template |
| `app` | str | — | App name |
| `component` | str | `app` | Component subdirectory name |
| `secret` | bool | `false` | Generate a `secret.sops.yaml` scaffold |
| `volsync` | bool | `true` | Add VolSync PVC dependency and component |
| `app_template` | bool | `true` | Use bjw-s app-template chart (vs. a standalone OCI chart) |
| `oci_repo` | str | `oci://ghcr.io/bjw-s-labs/helm/app-template` | OCI repo URL (only when `app_template=false`) |
| `version` | str | `4.6.2` | OCI artifact tag (only when `app_template=false`) |
| `image` | str | — | Container image repository (only when `app_template=true`) |
| `tag` | str | — | Container image tag (only when `app_template=true`) |
| `hash` | str | — | Container image digest hash (only when `app_template=true`) |

## Generated Files

```
kubernetes/apps/
  <namespace>/
    kustomization.yaml        # skip_if_exists — adds namespace.yaml + app ks.yaml
    namespace.yaml            # skip_if_exists — Namespace resource
    <app>/
      ks.yaml                 # Multi-doc Flux Kustomizations — appended to per component
      <component>/
        kustomization.yaml    # Kustomize root listing HelmRelease, OCIRepository, optional secret
        helmrelease.yaml      # HelmRelease referencing the OCIRepository
        ocirepository.yaml    # OCIRepository for the Helm chart
        secret.sops.yaml      # (optional) SOPS-encrypted Secret scaffold
```

## Post-generation Tasks

After rendering, Copier runs two tasks:

1. A `yq` task that inserts `<app>/ks.yaml` into the existing `kubernetes/apps/<namespace>/kustomization.yaml` resources list (keeping `namespace.yaml` first and the rest sorted).
2. A `cat`/`rm` task that appends the per-component Flux Kustomization fragment (`.ks-fragment-<component>.yaml`) to `<app>/ks.yaml` and deletes the fragment. This lets new components be added to an existing app without overwriting prior components' Flux Kustomizations.

## Extension

`extensions/namespaces.py` contains a `ContextHook` that scans `kubernetes/apps/` in the destination for existing namespace directories and injects them as `existing_namespaces` into the Jinja context before prompting. This requires `--trust` (already included in the Taskfile task).

## Notes

- `kustomization.yaml` and `namespace.yaml` at the namespace level use `skip_if_exists` — they won't be overwritten if the namespace already exists, but will be created fresh for new namespaces.
- After generating, `secret.sops.yaml` must be encrypted with `sops --encrypt --in-place` before committing.
- The `helmrelease.yaml` scaffold assumes a single controller/container/service/route following the app-template pattern. Adjust as needed for the actual app.
- `ks.yaml` defaults `VOLSYNC_CAPACITY` to `5Gi`; update after generation.
