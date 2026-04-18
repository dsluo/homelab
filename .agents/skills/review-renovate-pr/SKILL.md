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
- **Helm charts**: the chart repo is in the manifest (`HelmRepository` or `sourceRef`). Most charts link to a GitHub repo in `Chart.yaml`; fetch the chart's `CHANGELOG.md` via `gh api repos/<owner>/<repo>/contents/<path> --jq .content | base64 -d` (or just `gh browse`/WebFetch the raw URL), or the corresponding GitHub releases. For `app-template` and other common charts, the chart version ≠ app version — read the chart changelog, not the app's.
- **Mise tools / GitHub Actions**: `gh release list -R <owner>/<repo>` on the source repo.
- **Digest-only bumps**: no version change — check if the new digest corresponds to a rebuild of the same tag (common for `:latest`-style pins or security rebuilds). If the tag is immutable and only the digest moved, the upstream likely republished; `gh api repos/<owner>/<repo>/commits/<sha>` on the image's source-commit label can confirm.

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

Minor/patch bumps can still contain breaking changes — do not skip the check based on semver alone.

### 4. Analyze in-repo impact

For each breaking change, check whether *this repo* is affected:
- Grep the changed files and the rest of `kubernetes/` for the removed/renamed value
- Check HelmRelease `values:` blocks and any referenced `valuesFrom` ConfigMaps/Secrets
- Check for CRDs consumed by other apps (`grep -r "apiVersion: <group>"`)
- Check `postRenderers`, `kustomize` patches, and any SOPS-encrypted overrides (don't decrypt — just note that they exist and may need review)
- For chart bumps, compare old vs new default values when the diff is small; focus on values this repo explicitly sets

A breaking change that touches nothing in this repo is not blocking — say so.

### 5. Produce the review

Output a concise markdown block suitable for pasting as a PR comment. Format:

```
## Renovate review: <depName> <current> → <new>

**Verdict:** ✅ safe to merge | ⚠ review required | ⛔ do not merge

**Update type:** <major|minor|patch|digest> (<datasource>)

### Breaking changes
- <change> — upstream: <release URL>
  - Impact here: <affected file:line, or "no impact — not used">

### Notable changes
- <non-breaking behavior change worth knowing>

### Recommended actions
- <migration step, values change, or "none — direct merge">
```

Keep it tight. If there are no breaking changes and nothing notable, say so in one line and stop. If verdict is `⛔`, explain what would need to change for it to become safe.

Do not post the comment yourself unless the user asks. Show the review and wait.

## Repo-specific notes

- Renovate auto-merges patch/minor for `github-actions` (3d release age) and `mise` tools (1d release age) — if the user asks to review one of these, mention it will auto-merge and focus on whether to intervene before that happens.
- Flux reconciles continuously from `kubernetes/` — a bad merge to `main` starts deploying immediately. Weight "do not merge" accordingly.
- `*.sops.*` files are encrypted — never try to read them. If a breaking change might require a SOPS-encrypted value update, flag it as a manual follow-up.
- Major version bumps get a `!` in the commit prefix via the `.renovaterc.json5` rules — if the PR title doesn't match its labels, that's a Renovate config drift worth mentioning.
- The cluster is single-node. Storage migrations, CSI changes, and anything touching OpenEBS ZFS or VolSync need extra scrutiny since there's no HA fallback.
