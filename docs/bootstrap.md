# bootstrap

Steps:

1. `cd` into `talos/` and use `talhelper` to generate config and commands to apply config to node(s).
2. Use the `bootstrap-apps.sh` script (yoinked from [cluster-template](https://github.com/onedr0p/cluster-template/blob/main/scripts/bootstrap-apps.sh)) to bootstrap:
   1. Deploy namespaces, cluster secrets, CRDs, then helm releases required for bootstrap, including...
   2. flux, by first deploying `flux-operator` via `helm`/`helmfile`, then `flux-instance`, again with `helm`/`helmfile`. `values.yaml` values are pulled from the HelmRelease yamls in their respective directory in `kubernetes/apps/flux-system` using `yq`.
