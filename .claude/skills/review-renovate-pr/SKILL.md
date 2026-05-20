---
name: review-renovate-pr
description: Review a Renovate PR in this homelab repo. Fetches upstream changelogs/release notes, identifies breaking changes, and analyzes impact on the in-repo configuration (manifest values, CRDs, dependent charts). Trigger when the user asks to "review renovate PR", "check this renovate update", passes a Renovate PR number/URL, or asks whether a Renovate bump is safe to merge.
---

# Review a Renovate PR

Produce an evidence-backed verdict on whether a Renovate PR is safe to merge. Default output: concise review comment with verdict, breaking changes, and in-repo impact.

## Inputs

Accept any of:
- PR number (e.g. `693`) → `owner/repo` is this repo
- Full PR URL
- "latest" / "all open" → list open Renovate PRs first via `gh pr list --author "app/renovate" --state open`, then ask which one(s)

If the user did not specify a PR, list candidates and ask. Do not review all open PRs unless explicitly asked.

## Tool rules

**Use `gh` for all GitHub data** — PRs, issues, releases, file contents via `gh api`. Never `curl https://api.github.com/...` and never pipe JSON into `python3 -c` to parse it; `gh`'s `--jq` and `-R` flags already cover every case this skill needs. `curl` **is** fine for downloading release assets where `gh release download` doesn't fit (e.g. chart tarballs for local inspection); it's forbidden specifically for things you'd have to parse yourself.

**Never scrape doc sites** (`docs.victoriametrics.com`, `kubernetes.io`, chart project homepages, etc.) — they return HTML you'd have to parse. If a release note links to docs for a migration detail, either stay with the release note or `WebFetch` the **raw GitHub URL** for the relevant markdown file, not the rendered doc page.

**Prefer combined calls and parallel tool calls.** `gh pr view && gh pr diff` in one Bash call saves a round-trip. Independent greps/reads should go in a single message.

## Procedure

### 1. Load the PR

Fetch the PR with `gh pr view <num>` (title, body, labels) and `gh pr diff <num>` (changed files). Extract:
- Package name (`depName`) and datasource (container / helm / github-releases / mise / github-actions)
- `currentValue` → `newValue` (and `currentDigest` → `newDigest` for digest bumps)
- Update type from labels (`type/major`, `type/minor`, `type/patch`, `type/digest`)
- Files changed — these are the actual call sites that consume the dependency

The PR body that Renovate generates usually includes a **Release Notes** collapsible section with upstream changelog excerpts. Read it first — it often contains everything you need and saves a round-trip.

### 2. Fetch upstream changelog

Only go upstream if the PR body's release notes are missing, truncated, or ambiguous.

- **Container / github-releases**: resolve the source repo (for `ghcr.io/owner/repo`, it's `owner/repo`; otherwise check the image's `org.opencontainers.image.source` label via `docker manifest inspect` or the registry's package page). Then `gh release list -R <owner>/<repo>` and `gh release view <tag> -R <owner>/<repo>` for each tag between `currentValue` and `newValue` (inclusive of the new, exclusive of the current).
- **Helm charts**: the chart repo is in the manifest (`HelmRepository` or `sourceRef`). Most charts link to a GitHub repo in `Chart.yaml`; fetch the chart's `CHANGELOG.md` via `gh api repos/<owner>/<repo>/contents/<path> --jq .content | base64 -d` (or just `gh browse`/WebFetch the raw URL), or the corresponding GitHub releases. For `app-template` and other common charts, the chart version ≠ app version — **read the chart changelog first, then also skim the app changelog when the appVersion bumped**. The binary changes can matter independently (perf regressions, schema migrations, bugfixes relevant to this single-node setup).
- **Mise tools / GitHub Actions**: `gh release list -R <owner>/<repo>` on the source repo.
- **Digest-only bumps**: no version change — check if the new digest corresponds to a rebuild of the same tag (common for `:latest`-style pins or security rebuilds). If the tag is immutable and only the digest moved, the upstream likely republished; `gh api repos/<owner>/<repo>/commits/<sha>` on the image's source-commit label can confirm.

**Tag format gotcha:** multi-chart repos (e.g. `VictoriaMetrics/helm-charts`, `bitnami/charts`, `prometheus-community/helm-charts`) prefix release tags with the chart name — the tag for chart `0.73.0` is `victoria-metrics-k8s-stack-0.73.0`, **not** `v0.73.0`. When a `gh release view` returns nothing, run `gh release list -R <repo> --limit 30 | grep <chart-name>` first to confirm the actual tag format before retrying.

**Chase issue/PR references in release notes — and always escalate issues to their implementing PR.** When a release note says "See #2785" or "fixes #1234":

1. `gh issue view <n> -R <repo>` to read the issue.
2. **Then find the merged PR that closed it:** `gh pr list -R <repo> --search "closes #<n>" --state merged` (or `--search "fixes #<n>"` / `--search "#<n>"`). The PR title and description are usually much more specific about *scope* than the issue — e.g. the issue may say "non-standard labels used" while the PR says "remove chart name prefix from `app.kubernetes.io/component` **label value**". Reading the issue alone can leave a release note's meaning ambiguous; the PR disambiguates. **This step is the single highest-value check for minor bumps that contain breaking changes.**

If a release note directly cites a PR number (not an issue), just `gh pr view` it.

For multi-version jumps (e.g. `1.2.0 → 1.5.0`), walk every intermediate minor release — breaking changes often land in the middle.

### 3. Identify breaking changes

In each release note / changelog entry, flag:
- Explicit `BREAKING CHANGE:` / `⚠ BREAKING` / `!:` markers
- Removed or renamed CRD fields, Helm values, env vars, CLI flags
- Required Kubernetes version bumps
- Database schema migrations (especially one-way)
- Default behavior changes (e.g. auth defaults, storage class defaults)
- Deprecation warnings that become errors in this version
- New required config keys with no default
- **Label value changes** where the key stays the same but the value shifts (e.g. chart-name prefix stripped from `app.kubernetes.io/component` values). These are subtle — a grep for the label *key* will still hit, but anything selecting on the old *value* breaks silently.

Minor/patch bumps can still contain breaking changes — do not skip the check based on semver alone.

**Language watch:** release notes like "chart name prefix was removed" are ambiguous — it could mean label values, resource names, or both. Do not infer scope from the release note alone. Escalate per §2 (issue → PR) and/or verify from templates (see §4) before prescribing any edit.

### 4. Analyze in-repo impact

For each breaking change, determine which of these categories it falls into, then run the matching check. The common mistake is asking "does this repo *set* the old thing?" when the real question is "does anything in this repo *depend on* the old thing?"

- **Label key rename or label value change** (e.g. `app` → `app.kubernetes.io/component`, or chart-name prefix stripped from a value): grep `kubernetes/` for anything that **selects on** the old key *or the old value* — `matchLabels:`, `selector:`, `labelSelector:`, `jobLabel:` in VMServiceScrape/VMPodScrape/ServiceMonitor, PromQL/LogQL queries inside VMRules and Grafana dashboard JSON (in ConfigMaps or the `GrafanaDashboard` CRD). A label being emitted differently matters only if something reads it.
- **Resource name change** (e.g. dropping a chart-name prefix from a Service/Deployment): grep for references to the old name — `HTTPRoute` `backendRefs`, `VMUser` `targetRefs`, `ServiceMonitor`/`VMServiceScrape` selectors, `Ingress` backends, cross-namespace Service DNS (`<name>.<ns>.svc.cluster.local`), NetworkPolicy `podSelector`.
- **Value / flag / CRD-field rename**: grep HelmRelease `values:` blocks, any `valuesFrom` ConfigMaps/Secrets (check they exist, flag SOPS ones as manual follow-up — do not decrypt), `postRenderers`, `kustomize` patches, and CRD manifests (`apiVersion: <group>`) consumed by other apps.

**Verify before prescribing a rename.** If you're about to recommend the user edit a file to match a renamed resource, label value, or field, confirm the new value from the chart itself — do not infer it from the release-note text. Acceptable evidence:

1. The upstream PR (from §2) explicitly shows old/new (e.g. a diff or migration table). *Preferred — cheapest.*
2. `helm template` the old and new chart locally and diff the rendered output for the resources this repo references.
3. Read the **specific template** that emits the resource (e.g. `templates/vmagent/vmagent.yaml`), not just `_helpers.tpl` definitions — helper definitions show how names *could* be constructed, not the actual rendered result for this chart's values.

If you can't produce one of these, drop the rename from `Recommended actions` and downgrade it to `post-merge verification` (see §5). A wrong rename recommendation that the user applies is worse than no recommendation.

**Stop rule to avoid grep sprawl.** Once each impact category has returned either zero hits or a small enumerated set of hits, *stop* grepping. Further negative greps (rephrasing the same query, probing adjacent directories) add no information. If you find yourself on a 5th+ grep for the same change and still getting no output, the conclusion is "no impact" — move on.

A breaking change that touches nothing in this repo is not blocking — say so explicitly.

### 5. Produce the review

Output a concise markdown block suitable for pasting as a PR comment. Format:

```
## Renovate review: <depName> <current> → <new>

**Verdict:** ✅ safe to merge | ⚠ review required | ⛔ do not merge

**Update type:** <major|minor|patch|digest> (<datasource>)

### Breaking changes
- <change> — upstream: <release URL>
  - Impact here: <path/to/file.yaml:NN> | no impact — not used

### Notable changes
- <non-breaking behavior change worth knowing>

### Recommended actions
- <migration step, values change, or "none — direct merge">
```

**Citation rule:** every `Impact here:` entry must either be a concrete `path/to/file.yaml:NN` reference (line number required — find it with Grep's `-n` output) or the literal string `no impact — not used`. Prose claims like "our helmrelease doesn't reference it" are not acceptable — if it's truly absent, show the grep came up empty; if it's present, cite the line.

**Recommended-actions rule:** every concrete edit in `Recommended actions` (renames, value changes, field swaps) must be backed by template evidence per §4's verify-before-prescribing step. If you only have the release-note text, phrase the action as verification, not a prescribed edit — e.g. `after merge, confirm that the rendered VMAgent Service name still matches httproute.yaml:14; if not, update the backendRef`. Better to ask the user to verify than to prescribe a wrong rename.

Keep it tight. If there are no breaking changes and nothing notable, say so in one line and stop. If verdict is `⛔`, explain what would need to change for it to become safe.

Do not post the comment yourself unless the user asks. Show the review and wait.

## Repo-specific notes

- Renovate auto-merges patch/minor for `github-actions` (3d release age) and `mise` tools (1d release age) — if the user asks to review one of these, mention it will auto-merge and focus on whether to intervene before that happens.
- Flux reconciles continuously from `kubernetes/` — a bad merge to `main` starts deploying immediately. Weight "do not merge" accordingly.
- `*.sops.*` files are encrypted — never try to read them. If a breaking change might require a SOPS-encrypted value update, flag it as a manual follow-up.
- Major version bumps get a `!` in the commit prefix via the `.renovaterc.json5` rules — if the PR title doesn't match its labels, that's a Renovate config drift worth mentioning.
- The cluster is single-node. Storage migrations, CSI changes, and anything touching OpenEBS ZFS or VolSync need extra scrutiny since there's no HA fallback.
