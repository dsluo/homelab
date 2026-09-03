# Batch mode: reviewing multiple Renovate PRs

Reviewing all open Renovate PRs in parallel subagents is the normal way this skill runs. Serial review in the main context wastes the user's time and your context — fan out.

## 1. Enumerate

```
gh pr list --state open --search "head:renovate/" --json number,title,labels,createdAt
```

## 2. Dispatch — one subagent per PR, all in one message

Launch one `general-purpose` agent per PR, **all Agent calls in a single message** so they run in parallel. Use this dispatch prompt (it is the proven template from past runs — keep the constraints verbatim, fill in the placeholders):

```
You are reviewing a single Renovate PR in the homelab repo at /Users/dsluo/Projects/homelab.

FIRST: read and follow the skill instructions verbatim at
/Users/dsluo/Projects/homelab/.claude/skills/review-renovate-pr/SKILL.md (cat it). That file
defines your entire procedure, tool rules, and output format. Also read
/Users/dsluo/Projects/homelab/CLAUDE.md for repo context. You are a leaf reviewer — skip the
skill's "Batch mode" section; do not fan out further.

Your assigned PR: **#<num>** — `<title>` (labels: <labels>).

Do NOT post any comment to GitHub. Do NOT modify any files in the repo. Read-only review only.

Your final report must be exactly the markdown review block the skill's §5 specifies (starting
with `## Renovate review: ...`), with no extra preamble or commentary around it. Follow the
citation rule strictly: every `Impact here:` must be a `path/to/file.yaml:NN` with a real line
number, or the literal `no impact — not used`.
```

Add a PR-specific note to the prompt only when the listing shows something the leaf should chase (e.g. a companion PR for the same package family).

## 3. Cross-PR coupling check — after the leaves return, before final verdicts

Leaf reviews see one PR each; couplings between PRs are the orchestrator's job and have produced the highest-value findings in past runs (e.g. pocket-id and pocket-id-operator hard-gating each other's versions in both directions — each ⛔ alone, ✅ merged as a pair in the right order). Check for:

- **Operator ↔ operand pairs** (an operator bump and its managed app's bump in the same batch): read the version-gate logic — min/max supported version fields, `halt`-on-mismatch — and derive the required merge order from it.
- **Chart ↔ appVersion pairs**: two PRs touching the same app via different datasources.
- **OS ↔ component coupling**: a Talos bump and a kubelet/kubernetes bump in the same batch — check the new Talos release's bundled/supported kubelet range.
- **Shared call sites**: two PRs whose changed files or rendered resources overlap (same namespace, same HTTPRoute/VMServiceScrape targets).

Revise individual verdicts if a coupling changes them, and say which PR gates which.

## 4. Batch summary — the required final output

End with a summary table plus a staged merge order (this, not the individual blocks, is what the user acts on):

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
- **One `gh pr merge <n> --squash` per Bash call.** Do not batch merges into a shell loop — a past run's 14-PR loop was blocked by the permission classifier and fell back to individual calls anyway. Individual calls also give per-PR failure isolation.
- **Respect the staged order** from the batch summary. Between the high-blast-radius merges, verify Flux converged before the next one (`just reconcile`, then `flux get ks -A` / `flux get hr -A` for anything not Ready).
- ⚠ PRs are not merged in this phase unless the user upgraded them explicitly; restate what was left unmerged and why at the end.
