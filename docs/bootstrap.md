# bootstrap

Steps:

1. `cd` into `talos/` and run `just bootstrap` — `topf` renders the machine config from `topf.yaml` plus the patch tree, applies it to the node(s), bootstraps etcd, and writes a kubeconfig. `just talosconfig` writes the matching `talosconfig`.
2. Use the `bootstrap-apps.sh` script (yoinked from [cluster-template](https://github.com/onedr0p/cluster-template/blob/main/scripts/bootstrap-apps.sh)) to bootstrap:
   1. Deploy namespaces, bootstrap the ESO 1Password service-account token, apply CRDs, then install the Helm releases required for bootstrap. The token must already exist at `op://homelab/Service Account Auth Token - external-secrets/credential`; see [External Secrets](external-secrets.md).
   2. flux, by first deploying `flux-operator` via `helm`/`helmfile`, then `flux-instance`, again with `helm`/`helmfile`. `values.yaml` values are pulled from the HelmRelease yamls in their respective directory in `kubernetes/apps/flux-system` using `yq`.
