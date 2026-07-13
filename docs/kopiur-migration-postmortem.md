# Postmortem: VolSync → kopiur backup migration

**Date:** 2026-07-12 (window 8:27–10:10 PM EDT, ~103 minutes of app downtime; all times below are EDT, UTC-4)
**Outcome:** Success. 17 apps cut over from VolSync/restic to kopiur/kopia with zero data loss; one app (prowlarr) removed from the backup set entirely after the migration exposed that its PVC had been empty for months.
**PRs:** #1245 (operator + repository), #1246 (cutover), #1257 (mid-window fixes), #1247 (volsync removal).

## Background

VolSync had backed the app PVCs with per-app restic repositories since the cluster was built. It worked, but accumulated sharp edges over months of operation: the mover UID/GID matching problem (restores silently landing as `4003:4003` and producing unusable apps), the `IfNotPresent` ReplicationDestination staleness trap, a mover-jitter MutatingAdmissionPolicy hack to stagger schedules, a cache-PVC resize failure that silently broke vmks backups for a month, and a mover scheduling deadlock. kopiur (home-operations' kopia operator) consolidates everything into a single deduplicated repository with native schedule hashing, first-class health/status conditions, and an operator-managed offsite replication — a much better fit for how this cluster is run.

## Design (what shipped)

- **kopiur 0.7.2** in `kopiur-system`; `ClusterRepository homelab` on inline NFS (`storage.lan:/mnt/tank/backup/kopia`, export `mapall=4003:4003` so repo writes never depend on mover uid).
- **Credential projection** is a fail-closed three-legged handshake in 0.7.2 — chart RBAC flag, `credentialProjection.allowed` on the ClusterRepository, `credentialProjection.enabled` on every SnapshotPolicy/Restore. All three legs shipped together.
- **`components/kopiur`** as the drop-in successor to `components/volsync`: SnapshotPolicy (zstd, keepLatest 3 / hourly 24 / daily 7 / weekly 4, openebs-zfs-snapshot staging, mover `podSecurityContext` from `KOPIUR_UID/GID`), hourly `H * * * *` SnapshotSchedule (hashed cron replaces the jitter policy), and a Restore populator + PVC `dataSourceRef`.
- **`RepositoryReplication homelab-offsite`**: daily blob mirror to B2 (`crayon-club-backups`, prefix `kopia/`).
- **Health gating**: the `kopiur-repository` ks only reports Ready once the ClusterRepository phase is `Ready`, and every app ks depends on it — a bad NFS export or wrong `KOPIA_PASSWORD` can't leave PVCs Pending while Flux shows green. tuppr node-upgrade gates were rewritten against kopiur CRs, fail-closed (`has(status.phase)` guards).
- **Migration tooling**: `scripts/migrate-kopiur.sh` with idempotent phases (`suspend` → `final-backup` → `stop-volsync` → `seed` → `verify-seeds` → `delete` → `resume`), each preflighting its own safety gates. Restic repos can't be adopted by kopia, so the plan was: quiesce, take a final restic baseline, seed kopia from the live PVCs, delete the old PVCs, and let Flux recreate them via the Restore populator.

Preparation was thorough and paid off: NFS export write-tested in-cluster, B2 key tofu-applied and live-authenticated (including a prefix rename that rotated credentials), `KOPIA_PASSWORD` hash-matched against 1Password, a broken vmks restic baseline diagnosed and fixed *before* the window, three stacked PRs reviewed against upstream (onedr0p/home-ops, kopiur CRDs/chart) plus an external model review, and everything rendered offline with konflate/flate.

## Timeline (2026-07-12, EDT)

| Time | Event |
| --- | --- |
| ~4:10 PM | #1245 merged. `kopiur-repository` deadlocks on a webhook/dry-run bootstrap cycle (incident 1); one manual `kubectl apply` of the ClusterRepository breaks it. Repo initializes on NFS, `kopiur doctor` 8/8. |
| ~4:25 PM | #1246 merged **early** — before `suspend`/`final-backup`, out of runbook order (incident 2). Contained by design: every cutover ks fails Flux's dry-run on the immutable PVC `dataSourceRef`, so nothing applies or prunes. |
| 8:27 PM | `suspend`: 18 ks suspended, workloads to 0. First run had died on macOS bash 3.2 (incident 3); label-selector waits burned ~10 cosmetic minutes (incident 4). Hard PVC-unmount gate passes. |
| 8:45–8:47 PM | `final-backup`: all 18 restic manual syncs Successful in ~90 s (movers run concurrently; apps quiesced with a fresh hourly behind them). Recovery baseline secured. |
| 8:49 PM | `stop-volsync`. |
| 8:50–8:56 PM | Seed run 1: 8 apps OK, dies on qbittorrent — root-exec `.bash_history` unreadable by the mover (incident 5). prowlarr "succeeds" at 0 bytes → its PVC turns out to be empty since February (incident 6). |
| ~9:06 PM | Debug pods scan all remaining PVCs for mover-unreadable files; qbittorrent fixed; vmks flagged (root-owned non-world-readable cache dirs, data actually 1000:1000). PR #1257: drop prowlarr from backups, vmks mover uid 65534→1000. |
| 9:11–9:20 PM | Seed run 2: dies on vmks — the four cache dirs are root-owned mode 0700, unreadable by *any* non-root mover (incident 7). One-time `chown -R 1000:1000` of the cache. |
| 9:34–9:46 PM | vmks seeds (34 GiB); seed run 3 completes victoria-logs + continuwuity (never reached before — both prior runs died earlier in the order). |
| 9:48 PM | `verify-seeds`: 17/17 OK, `filesFailed=0`, sizes eyeballed against on-disk usage. #1257 merged. |
| ~9:52 PM | `delete`: silent no-op first (interactive prompt got EOF without a TTY, incident 8), then hangs on recyclarr — a 21 h-old Completed CronJob pod held the PVC via pvc-protection (incident 9). Pod deleted; all 17 PVCs + volsync CRs removed. |
| ~9:55 PM | `resume`: Helm's three-way merge computes an empty patch for unchanged templates, so manual `replicas=0` survives — nothing scales up (incident 10). Script then dies resuming vmks: its ks needs the VM operator's admission webhook, but operators are only scaled up *after* the resume loop (incident 11). Manual scale-ups + operator-first recovery. |
| 10:00–10:15 PM | Restore populator fills all PVCs from seeds (vmks last). recyclarr needs a `kubectl create job --from=cronjob` kick to give its WaitForFirstConsumer PVC a consumer. Apps Running by ~10:10 PM, 0 restarts; paperless processing, VMSingle serving restored data. |
| 10:06 / 10:14 PM | First *scheduled* hourly snapshots succeed unattended (paperless; vmks as uid 1000). |
| ~10:50 PM | #1247 rebased (`--onto main` — the stacked branch still carried squash-merged cutover commits) and merged. The volsync ks was pruned while suspended, so Flux skipped garbage collection (incident 12); operator/namespace/CRDs/orphan CRs torn down manually. Tree fully green. |

## What went wrong (and what held)

**Held:** the layered safety design worked every time it was tested. The immutable `dataSourceRef` made the out-of-order #1246 merge a non-event. `verify-seeds` correctly rejected both a missing seed and a 0-byte seed. The final restic baseline was never needed, but existed. Every failure happened *loudly, before* anything destructive.

**Broke — by incident:**

1. **Bootstrap deadlock** — `kopiur-repository` bundles secret + ClusterRepository + RepositoryReplication in one ks; Flux server-side dry-runs the whole set before creating anything, and kopiur's fail-closed webhook denies the RepositoryReplication because the ClusterRepository in the same batch doesn't exist yet. Unreachable offline (flate has no webhooks). *Fix:* one-time manual apply; durable fix is splitting RepositoryReplication into its own ks with `dependsOn`.
2. **Runbook ordering** — #1246 merged early partly because the migration script itself lived in #1246 (steps 3–4 needed a script that only landed on main at step 5).
3. **macOS bash 3.2** — `scripts/lib/common.sh` uses `local -A`; Apple's 2007 bash parses `[debug]=1` as an arithmetic subscript and dies under `set -u`. Homebrew bash 5 + explicit interpreter.
4. **Label-selector waits** — `kubectl wait --for=delete -l instance=<app>` matches Completed CronJob pods and chart satellite pods (vmks's vmagent/vmalert/etc.), burning full timeouts on pods that will never delete.
5. **fsGroup does not remap read-only snapshot clones.** The load-bearing false assumption of the whole design: VolSync's mover read a *read-write*, fsGroup-re-chowned clone; kopiur's mover mounts the clone read-only, and kubelet skips the fsGroup chown on RO mounts. Any file neither world-readable nor mover-uid-owned fails the snapshot fatally. Component comments had encoded the false premise and were rewritten.
6. **prowlarr backed up nothing for months.** Postgres-backed, `readOnlyRootFilesystem`, PVC empty since 2026-02-24 — and every VolSync backup of it was "Successful". Backup-green ≠ data-backed-up; only the migration's `sizeBytes > 0` gate surfaced it.
7. **VMSingle still runs as root** and creates cache subdirs mode 0700, despite its data being mostly 1000:1000. Mixed ownership on one PVC defeats any single non-root mover uid until the workload itself is made non-root.
8. **Interactive prompts don't survive non-TTY execution** — `read -p` got EOF and the script exited as if declined, silently.
9. **pvc-protection counts Completed pods.** A finished CronJob pod blocks PVC deletion until the pod object is deleted.
10. **Helm doesn't undo manual scale.** Unchanged template → empty three-way-merge patch → `kubectl scale --replicas=0` persists straight through `flux resume` + upgrade. No driftDetection on these HRs.
11. **Operator webhooks are a resume dependency.** Resuming a ks that applies operator CRs before the operator's webhook is back deadlocks the reconcile.
12. **Pruning a suspended Kustomization skips GC.** Flux deleted the volsync ks object but orphaned its entire inventory; `flux get ks -A` showed green while a namespace full of leftovers sat there.

## Lessons learned

1. **Verify backups by restored content, not mover status.** prowlarr's empty PVC hid behind months of green. The `verify-seeds` pattern (Succeeded + `sizeBytes > 0` + `filesFailed == 0` + eyeballed sizes) should be a periodic drill, not a migration one-off.
2. **Mover uid must match on-disk ownership, verified with a debug pod** — not inferred from the HelmRelease securityContext (vmks proved they drift). The pre-seed scan (find files not world-readable and not uid-owned, per app) found every failure in one pass and should be standard before onboarding any app to kopiur.
3. **Fail-closed webhooks change bootstrap semantics.** Any Flux ks that applies both a webhook-validated CR and its referent needs the dependency split into separate Kustomizations. Offline rendering cannot catch this class.
4. **Maintenance tooling belongs in the first PR** of a stack (or its own), not the PR whose merge is a mid-runbook step.
5. **Scripts that drive a window need**: bash-version guards (or POSIX), no bare `read -p` (support `--yes`/env override), terminal-pod-aware waits (filter `Succeeded`/`Failed`, or just rely on the PVC-mount gate), operators scaled up *before* resuming their CR-consuming ks's, and explicit workload scale-up in `resume`.
6. **Squash-merged stacks must be rebased `--onto main`** before merging the next PR, every time — GitHub retargets the base but keeps the stale commits.
7. **Resume suspended Kustomizations before letting a merge prune them**, or plan the manual teardown.
8. **The layered-gates philosophy is right.** Three seed attempts, two ad-hoc cluster surgeries, one mid-window PR — and at no point was data at risk, because every destructive step sat behind an independent, verifiable gate.

## Follow-ups

Tracked from the window (none urgent):

- `migrate-kopiur.sh` fixes per lesson 5 (kept in-tree as the reference for future windows).
- Split RepositoryReplication into its own Flux ks (`dependsOn: kopiur-repository`) so fresh bootstraps don't deadlock.
- VMSingle → non-root (useStrictSecurity / securityContext 1000) + one-time full-PVC chown; until then a VM cache reset recreates root-0700 dirs and breaks hourly vmks snapshots.
- victoria-logs: same non-root TODO; its 65534 mover works only while VL writes world-readable files.
- Decide: flip topology so B2 is the primary repository and TrueNAS the replica; set `sync.deleteExtra: true` on the replication once stable (B2 grows unboundedly without it).
- Optional hardening from review: persistent mover cache, `scheduleDefaults.timezone`, operator pod securityContext.
- Post-checks (time-gated): first B2 replication (`H 10 * * *` — the schedule is UTC, ≈ 6:00 AM EDT), Grafana kopiur dashboard, tuppr dry-check against the new gates.
- Delete the restic dataset `tank/backup/volsync` on TrueNAS only after weeks of stable kopiur operation. Credentials archived at `docs/volsync-restic-recovery.sops.yaml`.
