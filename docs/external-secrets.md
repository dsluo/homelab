# External Secrets

Kubernetes Secrets are sourced from the `homelab` 1Password vault by External
Secrets Operator (ESO). SOPS remains in use only for Talos, OpenTofu, and the
encrypted recovery document under `docs/`.

## 1Password model

- Use one Secure Note per Kubernetes Secret.
- Name it `k8s-<namespace>-<secret-name>`.
- Add one concealed custom field per Kubernetes key. Field labels must match
  the Kubernetes keys exactly and must be unique within the item.
- Use the special item `k8s-cluster-secrets` for `SECRET_DOMAIN`,
  `CLOUDFLARE_TUNNEL_ID`, and `GARAGE_ENDPOINT_URL`.
- Grant the ESO service account read-only access to the `homelab` vault. Keep
  its token at `op://homelab/Service Account Auth Token - external-secrets/credential`.

Never put a secret value in a manifest, command argument, log, or temporary
file. The bootstrap helper reads the service-account token through the
authenticated `op` CLI and pipes it directly to Kubernetes:

```sh
scripts/bootstrap-external-secrets.sh
```

It is safe to run the helper repeatedly. The `external-secrets` namespace must
already exist.

## Adding or changing a Secret

1. Create or update the matching Secure Note and concealed fields in 1Password.
2. Add an `external-secrets.io/v1` `ExternalSecret` with explicit `spec.data`
   entries. Do not use `dataFrom`.
3. Keep the target Secret's existing name, type, labels, annotations, and keys.
4. Use `Periodic`, `1h`, `Owner`, and `Retain`, matching the existing manifests.
5. Make the owning Flux Kustomization depend on
   `external-secrets/external-secrets-config`.
6. Run `just test`. Its static check validates the item/key naming convention,
   target contract, 34-item/69-field migration baseline, fan-out namespaces,
   and absence of Kubernetes SOPS references before the full Flux render.

## Live verification

Before reconciling a migration branch, confirm all referenced items and fields
exist and install the bootstrap token. Then verify:

```sh
kubectl get clustersecretstore
kubectl get externalsecret --all-namespaces
kubectl get clusterexternalsecret cluster-secrets
```

All stores and ExternalSecrets must report `Ready=True`; the
ClusterExternalSecret must report no failed namespaces. Compare Secret key
hashes, types, labels, and annotations without printing values, and confirm the
affected workloads remain Ready.

For rollback, first change the affected ExternalSecret to
`creationPolicy: Orphan` and reconcile it. Restore the previous Secret source,
then remove the ExternalSecret. Keep the 1Password items and service account
until the migration has been stable long enough to rule out rollback.
