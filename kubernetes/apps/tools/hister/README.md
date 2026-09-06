# Hister operations

Hister is exposed at `https://hister.${DOMAIN}`. The server uses Pocket ID for browser login and personal tokens for API clients, the browser extension, CLI, and ToolHive.

## ToolHive bootstrap

After the first Pocket ID login, create a personal access token from the Hister profile page. Store it in the 1Password item `k8s-ai-toolhive-hister-mcp-credentials` under the field `HISTER_ACCESS_TOKEN`. ESO then creates the `AUTHORIZATION` value consumed by ToolHive; never store the token in Git or use the OIDC client secret for this field.

The ToolHive route is intentionally on the internal Gateway, and the backend token is only reachable by the Envoy internal data plane; direct ClusterIP access is denied by Cilium. Reconcile the ToolHive Flux Kustomization after the 1Password item exists.

## CLI authentication

Install the Hister CLI matching the server release, then pass the server URL and personal token explicitly. Keep the token in a shell environment or secret manager; do not put it in a config file committed to Git.

```sh
export HISTER_URL="https://hister.${DOMAIN}"
read -rsp 'Hister personal token: ' HISTER_TOKEN; export HISTER_TOKEN; echo

hister --server-url "$HISTER_URL" --token "$HISTER_TOKEN" search 'kubernetes'
hister --server-url "$HISTER_URL" --token "$HISTER_TOKEN" index https://example.com/article
```

## Index and crawl

Direct indexing fetches each URL once and does not create a crawl job:

```sh
hister --server-url "$HISTER_URL" --token "$HISTER_TOKEN" index https://example.com/article
```

Create a bounded persistent recursive crawl by restricting its domain and page count:

```sh
hister --server-url "$HISTER_URL" --token "$HISTER_TOKEN" index \
  --recursive \
  --job-id example-docs \
  --allowed-domain example.com \
  --max-depth 5 \
  --max-links 100 \
  https://example.com/docs
```

Inspect and resume a crawl with the same personal token. `hister crawl` inspects the persisted job; `hister index --job-id` resumes its pending queue:

```sh
hister --server-url "$HISTER_URL" --token "$HISTER_TOKEN" crawl show example-docs
hister --server-url "$HISTER_URL" --token "$HISTER_TOKEN" index --job-id example-docs
```

Crawl queues and statuses are persisted in Hister's PostgreSQL database. Kubernetes does not schedule crawls automatically; run these commands from a trusted client when a crawl is wanted. A stopped crawl can be resumed without restarting from the beginning.
