#!/usr/bin/env bash
# One-shot VolSync -> kopiur cutover runbook (see docs in the kopiur PRs).
#
# Upstream restic repos cannot be adopted by kopiur, so the sequence is:
# suspend + scale down every volsync-backed app, take a final restic backup
# (recovery baseline), seed the kopia repository from the still-live PVCs,
# delete the old PVCs, then let Flux recreate them with dataSourceRef ->
# kopiur Restore. Run the phases in order; each is idempotent and re-runnable.
#
#   migrate-kopiur.sh apps          # show the derived app inventory
#   migrate-kopiur.sh suspend       # flux suspend + scale workloads to 0
#   migrate-kopiur.sh final-backup  # trigger + wait for final restic backups
#   migrate-kopiur.sh stop-volsync  # suspend volsync ks + scale operator to 0
#   migrate-kopiur.sh seed          # apply SnapshotPolicies + snapshot every PVC
#   migrate-kopiur.sh verify-seeds  # GATE: all seeds Succeeded w/ bytes moved
#   migrate-kopiur.sh delete        # delete RS/RD/PVC per app (destructive!)
#   migrate-kopiur.sh resume        # flux resume + reconcile (restores PVCs)
#   migrate-kopiur.sh status        # per-app PVC/pod/snapshot overview
#
# ORDERING: run 'suspend' and 'final-backup' BEFORE Flux reconciles the
# cutover merge — Flux (prune: true) deletes every app's volsync CRs the
# moment its ks.yaml flips from components/volsync to components/kopiur,
# taking the final-backup safety net with them. Both phases preflight this
# and abort if the ReplicationSources are already gone. The restic
# credentials for the baseline are archived in
# docs/volsync-restic-recovery.sops.yaml.
set -Eeuo pipefail

source "$(dirname "${0}")/lib/common.sh"

export ROOT_DIR="$(git rev-parse --show-toplevel)"

# App inventory, derived from every ks.yaml that consumes components/kopiur.
# Emits: <flux-ks-name> <namespace> <app> <uid> <gid>
function apps() {
    grep -rl "components/kopiur" "${ROOT_DIR}/kubernetes/apps" --include=ks.yaml | sort | while read -r f; do
        yq -r '
            select(.spec.components[]? | contains("components/kopiur"))
            | [.metadata.name, .spec.targetNamespace,
               .spec.postBuild.substitute.APP,
               .spec.postBuild.substitute.KOPIUR_UID,
               .spec.postBuild.substitute.KOPIUR_GID]
            | @tsv' "$f"
    done | awk 'NF'
}

# Deployments/statefulsets in <ns> that mount PVC <app>
function workloads() {
    local ns="${1}" app="${2}"
    kubectl get deploy,sts -n "${ns}" -o json | jq -r --arg pvc "${app}" '
        .items[]
        | select([.spec.template.spec.volumes[]?
                  | select(.persistentVolumeClaim.claimName == $pvc)] | length > 0)
        | "\(.kind | ascii_downcase)/\(.metadata.name)"'
}

# Operators that would fight a direct scale-down of their managed workloads
function scale_operators() {
    local replicas="${1}"
    for d in victoria-metrics-operator grafana-operator; do
        kubectl get deploy -n observability -o name | grep "${d}" \
            | xargs -r kubectl scale -n observability --replicas="${replicas}"
    done
}

# The final restic baseline needs the volsync CRs, which Flux prunes as soon
# as it reconciles the cutover merge. Refuse to continue once they are gone.
function require_volsync_crs() {
    local missing
    missing=$(apps | while read -r _ ns app _ _; do
        kubectl get replicationsource "${app}" -n "${ns}" >/dev/null 2>&1 || echo "${ns}/${app}"
    done)
    if [[ -n "${missing}" ]]; then
        log error "ReplicationSources already pruned — Flux reconciled the cutover before the final restic baseline was taken" "apps" "${missing//$'\n'/,}"
    fi
}

function cmd_suspend() {
    require_volsync_crs
    scale_operators 0
    apps | while read -r ks ns app _ _; do
        log info "Suspending" "app" "${app}"
        flux suspend kustomization "${ks}" -n "${ns}"
        flux suspend helmrelease "${app}" -n "${ns}" 2>/dev/null || true
        workloads "${ns}" "${app}" | xargs -r kubectl scale -n "${ns}" --replicas=0
    done
    apps | while read -r _ ns app _ _; do
        kubectl wait pod -n "${ns}" -l "app.kubernetes.io/instance=${app}" \
            --for=delete --timeout=5m 2>/dev/null || true
    done
}

function cmd_final_backup() {
    require_volsync_crs
    local stamp="pre-kopiur-$(date +%s)"
    apps | while read -r _ ns app _ _; do
        kubectl patch replicationsource "${app}" -n "${ns}" --type merge \
            -p "{\"spec\":{\"trigger\":{\"manual\":\"${stamp}\"}}}"
    done
    apps | while read -r _ ns app _ _; do
        log info "Waiting for final restic backup" "app" "${app}"
        kubectl wait replicationsource "${app}" -n "${ns}" \
            --for=jsonpath="{.status.lastManualSync}=${stamp}" --timeout=30m
    done
}

function cmd_stop_volsync() {
    flux suspend kustomization volsync -n volsync-system
    kubectl scale deploy volsync -n volsync-system --replicas=0
}

function cmd_seed() {
    apps | while read -r _ ns app uid gid; do
        log info "Seeding kopia snapshot" "app" "${app}"
        # Mirrors kubernetes/components/kopiur/snapshotpolicy.yaml; Flux takes
        # ownership of the identical object when the app is resumed.
        kubectl apply -n "${ns}" -f - <<EOF
apiVersion: kopiur.home-operations.com/v1alpha1
kind: SnapshotPolicy
metadata:
  name: ${app}
spec:
  compression:
    compressor: zstd
  credentialProjection:
    enabled: true
  mover:
    podSecurityContext:
      runAsUser: ${uid}
      runAsGroup: ${gid}
      fsGroup: ${gid}
  repository:
    kind: ClusterRepository
    name: homelab
  retention:
    keepLatest: 3
    keepHourly: 24
    keepDaily: 7
    keepWeekly: 4
  sources:
    - pvc:
        name: ${app}
  volumeSnapshotClassName: openebs-zfs-snapshot
EOF
        # mise installs the CLI as plain `kopiur` (kubectl plugin discovery
        # would need a kubectl-kopiur binary, which only krew/brew provide).
        kopiur snapshot now --policy "${app}" -n "${ns}" --wait
    done
}

function cmd_verify_seeds() {
    local failures
    failures=$(apps | while read -r _ ns app _ _; do
        if kubectl get snapshot -n "${ns}" -o json | jq -e --arg app "${app}" '
            [.items[] | select(.spec.policyRef.name == $app)
             | select(.status.phase == "Succeeded")
             | select((.status.stats.sizeBytes // 0) > 0)
             | select((.status.stats.filesFailed // 0) == 0)] | length > 0' >/dev/null; then
            echo "OK   ${ns}/${app}" >&2
        else
            echo "FAIL ${ns}/${app}" >&2
            echo "${app}"
        fi
    done)
    if [[ -n "${failures}" ]]; then
        log error "Seed snapshots missing/failed/empty/incomplete — do NOT run 'delete'" "apps" "${failures//$'\n'/,}"
    fi
    log info "Also eyeball sizes: kopiur snapshots list -A"
}

function cmd_delete() {
    read -r -p "This deletes every app's PVC + volsync CRs. Seeds verified? (yes/no) " ok
    [[ "${ok}" == "yes" ]] || exit 1
    apps | while read -r _ ns app _ _; do
        log warn "Deleting volsync CRs + PVC" "app" "${app}"
        kubectl delete replicationsource "${app}" -n "${ns}" --ignore-not-found
        kubectl delete replicationdestination "${app}-dst" -n "${ns}" --ignore-not-found
        kubectl delete pvc "${app}" -n "${ns}" --ignore-not-found
    done
}

function cmd_resume() {
    apps | while read -r ks ns app _ _; do
        log info "Resuming" "app" "${app}"
        flux resume helmrelease "${app}" -n "${ns}" 2>/dev/null || true
        flux resume kustomization "${ks}" -n "${ns}"
    done
    scale_operators 1
    apps | while read -r ks ns _ _ _; do
        flux reconcile kustomization "${ks}" -n "${ns}" || true
    done
}

function cmd_status() {
    apps | while read -r _ ns app _ _; do
        pvc=$(kubectl get pvc "${app}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "-")
        pods=$(kubectl get pod -n "${ns}" -l "app.kubernetes.io/instance=${app}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        echo "${ns}/${app}: pvc=${pvc} pods=${pods}"
    done
}

case "${1:-}" in
    apps) apps ;;
    suspend) cmd_suspend ;;
    final-backup) cmd_final_backup ;;
    stop-volsync) cmd_stop_volsync ;;
    seed) cmd_seed ;;
    verify-seeds) cmd_verify_seeds ;;
    delete) cmd_delete ;;
    resume) cmd_resume ;;
    status) cmd_status ;;
    *) grep '^#   migrate' "$0" | sed 's|^#   ||'; exit 1 ;;
esac
