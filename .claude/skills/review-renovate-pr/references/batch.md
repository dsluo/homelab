# Batch mode: reviewing multiple Renovate PRs

Review all open Renovate PRs with one subagent per PR when delegation is available. Respect the environment's concurrency limit and dispatch remaining PRs as slots become available. Claude Code runs at most 20 subagents at once; Agent calls past that in the same message fail with "Concurrent subagent limit reached". If delegation is unavailable, review serially and still perform the cross-PR check and batch summary below.

When reviewing serially, finish and emit each PR's review block before starting the next. Carry forward only compact findings needed for the cross-PR check and summary, not raw changelogs.

## 1. Enumerate

```
gh pr list --state open --search "head:renovate/" --json number,title,labels,createdAt
```

Skip PRs labeled `hold` and list them as skipped under the batch summary.

## 2. Dispatch — one subagent per PR

### Model routing

Pick each reviewer's model and reasoning effort from its PR's update type and what it touches (the `title` and `labels` fields above). Skip this subsection when reviewing serially; a single-PR review runs on whatever model the session has active.

| Update type | Claude Code: Agent `model` / `effort` | Codex: `spawn_agent` `model` / `reasoning_effort` |
|---|---|---|
| Major, including 0.x minors | `opus` / `xhigh` (Opus 5.5) | `gpt-6.1-sol` / `xhigh` |
| Minor | `opus` / `high` | `gpt-6.1-sol` / `high` |
| Patch, digest | `sonnet` / `high` (Sonnet 5.5) | `gpt-6-luna` / `high` |

- Take the update type from the `type/*` label, except that a minor bump of a 0.x package is major whatever its label says. Renovate labels these `type/minor` but puts a `!` in the title, so route any `!` title to the major tier; group titles like `Update flux-operator group` show no versions to check. A PR with no type label takes the major tier.
- Core cluster patch or digest PRs move up to the minor tier: anything labeled `area/talos` or `area/bootstrap`, or whose title names `cloudnative-pg`, `external-secrets`, `kopiur` or `pocket-id`. A bad rollout of these takes down the nodes, networking, the shared database, or the dozens of apps that `dependsOn` them. Core minors stay in the minor tier; xhigh found nothing extra on them.
- If the harness offers a newer model in a series already in the table (e.g. a later Luna in `spawn_agent`'s model list), tell the user and ask whether to update this table to match. A new series is not a newer model.
- In any other harness, ask the user how to proceed. The default is the session's current model and effort for every tier.
- Ask whichever of these questions apply in one message, before dispatching.

### Dispatch prompt

Use the environment's delegation tools to launch independent reviewers concurrently, each on its routed model and effort. Give each reviewer the repository working directory and network access for `gh` and upstream downloads; prohibit writes to repository files. Keep this dispatch prompt's constraints verbatim, filling in only the placeholders (`<repo-root>` is the actual repository root):

```
You are reviewing a single Renovate PR in the homelab repo at <repo-root>.

FIRST: read and follow the skill instructions verbatim at
<repo-root>/.agents/skills/review-renovate-pr/SKILL.md. That file
defines your entire procedure, tool rules, and output format. Also read
<repo-root>/AGENTS.md for repo context. You are a leaf reviewer: skip the
skill's "Batch mode" section; do not fan out further.

Your assigned PR: **#<num>** — `<title>` (labels: <labels>).

Do NOT post any comment to GitHub. Do NOT modify any files in the repo. Read-only review only.

Your final report must be exactly the markdown review block the skill's §5 specifies (starting
with `## Renovate review: ...`), with no extra preamble or commentary around it. Drop empty
sections entirely, heading included. Follow the citation rule strictly: every `Impact here:`
must be a `path/to/file.yaml:NN` with a real line number, or the literal `no impact: not used`.
End the block with one line:
`Summary: <verdict> | <blast radius> | <couplings with other open PRs, or none>`
```

Add a PR-specific note to the prompt only when there is something the leaf should chase: a companion PR for the same package family, or a package-specific gotcha. Before dispatching, recall memory (memini) for each package in the batch and pass any relevant gotcha in that note.

Dispatch the major tier first, then minor, then patch/digest, so any PRs past the concurrency limit are the fast leaves.

## 3. Cross-PR coupling check — after the leaves return, before final verdicts

Leaf reviews see one PR each; couplings between PRs are the orchestrator's job and have produced the highest-value findings in past runs (e.g. pocket-id and pocket-id-operator hard-gating each other's versions in both directions — each ⛔ alone, ✅ merged as a pair in the right order). Check for:

- **Operator ↔ operand pairs** (an operator bump and its managed app's bump in the same batch): read the version-gate logic — min/max supported version fields, `halt`-on-mismatch — and derive the required merge order from it.
- **Chart ↔ appVersion pairs**: two PRs touching the same app via different datasources.
- **OS ↔ component coupling**: a Talos bump and a kubelet/kubernetes bump in the same batch — check the new Talos release's bundled/supported kubelet range.
- **Shared call sites**: two PRs whose changed files or rendered resources overlap (same namespace, same HTTPRoute/VMServiceScrape targets).
- **Renovate config PRs** (presets, `.renovaterc.json5`): a changed match rule or regex can widen or narrow other open PRs on Renovate's next run. Decide whether those PRs merge first or get re-reviewed after.

Revise individual verdicts if a coupling changes them, and say which PR gates which.

## 4. Batch summary — the required final output

End with a summary table plus a staged merge order (this, not the individual blocks, is what the user acts on). Build the table from each leaf's `Summary:` line:

```
## Batch summary

| PR | Package | Bump | Verdict | Blast radius |
|----|---------|------|---------|--------------|
| #1470 | pocket-id-operator | 0.13.1 → 0.14.0 | ⚠ pair with #1469 | SSO outage ~1min |
| ... | | | | |

**Suggested merge order:**
1. <inert/config-only PRs — any time, any order>
2. <workload rollouts — when a brief restart is tolerable>
3. <CNI / node / DB-migration PRs — last, individually, watching Flux between each>

<couplings: "#A must merge before #B because ...">
```

Order by blast radius, not PR number: config-only first; workload restarts second; anything cycling the CNI, the nodes themselves, or a database last and individually.

## 5. Merge phase ("merge the safe ones")

Only on explicit user request. Mechanics that matter:

- **Pre-flight each PR** before merging: `gh pr view <n> --json mergeable,mergeStateStatus,statusCheckRollup` — a ✅ review verdict says nothing about branch state or CI.
- **One `gh pr merge <n> --squash` per shell call.** Check each result before proceeding so a failure does not silently carry the batch forward.
- **Respect the staged order** from the batch summary. Between the high-blast-radius merges, verify Flux converged before the next one (`just reconcile`, then `flux get ks -A` / `flux get hr -A` for anything not Ready).
- ⚠ PRs are not merged in this phase unless the user upgraded them explicitly; restate what was left unmerged and why at the end.
