#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${0}")/lib/common.sh"

export LOG_LEVEL="${LOG_LEVEL:-info}"

readonly ROOT_DIR="$(git rev-parse --show-toplevel)"
readonly VAULT="homelab"
readonly EXPECTED_ITEMS=34
readonly EXPECTED_FIELDS=69

apply=false
overwrite_conflicts=false
items="[]"
processed_items=0
processed_fields=0

function usage() {
    printf 'Usage: %s [--apply] [--overwrite-conflicts]\n' "$(basename "$0")"
}

function sha256() {
    shasum -a 256 | awk '{print $1}'
}

function item_title() {
    local -r file="$1"
    local -r secret_name="$2"
    local relative namespace

    relative="${file#${ROOT_DIR}/}"
    if [[ "${relative}" == "kubernetes/components/sops/cluster-secrets.sops.yaml" ]] \
        && [[ "${secret_name}" == "cluster-secrets" ]]; then
        printf 'k8s-cluster-secrets'
        return
    fi

    if [[ "${relative}" != kubernetes/apps/* ]]; then
        log error "Unsupported Kubernetes SOPS Secret location" "file=${relative}"
    fi
    namespace="${relative#kubernetes/apps/}"
    namespace="${namespace%%/*}"
    printf 'k8s-%s-%s' "${namespace}" "${secret_name}"
}

function verify_item() {
    local -r desired="$1"
    local -r existing="$2"
    local desired_labels existing_labels key desired_hash existing_hash existing_type

    desired_labels="$(jq --compact-output '.values | keys | sort' <<<"${desired}")"
    existing_labels="$(jq --compact-output '[
        .fields[]
        | select((.purpose // "") == "" and .id != "notesPlain")
        | .label
    ] | sort' <<<"${existing}")"
    [[ "${desired_labels}" == "${existing_labels}" ]] || return 1

    while IFS= read -r key; do
        existing_type="$(jq --raw-output --arg key "${key}" '
            [.fields[] | select(.label == $key)][0].type // ""
        ' <<<"${existing}")"
        [[ "${existing_type}" == "CONCEALED" ]] || return 1

        desired_hash="$(jq --join-output --arg key "${key}" '.values[$key]' \
            <<<"${desired}" | sha256)"
        existing_hash="$(jq --join-output --arg key "${key}" '
            [.fields[] | select(.label == $key)][0].value
        ' <<<"${existing}" | sha256)"
        [[ "${desired_hash}" == "${existing_hash}" ]] || return 1
    done < <(jq --raw-output '.values | keys[]' <<<"${desired}")
}

function create_item() {
    local -r desired="$1"

    printf '%s' "${desired}" | jq '
        (.values | to_entries) as $entries
        | {
            title: .title,
            category: "SECURE_NOTE",
            fields: (
                [{
                    id: "notesPlain",
                    type: "STRING",
                    purpose: "NOTES",
                    label: "notesPlain",
                    value: "Managed by scripts/import-sops-to-onepassword.sh"
                }]
                + [range(0; $entries | length) as $index | {
                    id: ("eso-" + ($index | tostring)),
                    type: "CONCEALED",
                    label: $entries[$index].key,
                    value: $entries[$index].value
                }]
            )
        }
    ' | op item create --vault "${VAULT}" - &>/dev/null
}

function overwrite_item() {
    local -r desired="$1"
    local -r existing="$2"
    local -r item_id="$(jq --raw-output '.id' <<<"${existing}")"

    printf '%s\n%s\n' "${existing}" "${desired}" | jq --slurp '
        .[0] as $item
        | (.[1].values | to_entries) as $entries
        | $item
        | .fields = (
            [.fields[] | select(.purpose != null or .id == "notesPlain")]
            + [range(0; $entries | length) as $index | {
                id: ("eso-" + ($index | tostring)),
                type: "CONCEALED",
                label: $entries[$index].key,
                value: $entries[$index].value
            }]
        )
    ' | op item edit "${item_id}" --vault "${VAULT}" &>/dev/null
}

function preflight_inventory() {
    local item_count=0
    local field_count=0
    local file document_count document_fields

    while IFS= read -r -d '' file; do
        document_count="$(yq eval-all 'select(.kind == "Secret") | 1' "${file}" \
            | awk '{total += $1} END {print total + 0}')"
        document_fields="$(yq eval-all 'select(.kind == "Secret")
            | ((.data // {}) | length) + ((.stringData // {}) | length)' \
            "${file}" | awk '{total += $1} END {print total + 0}')"
        item_count=$((item_count + document_count))
        field_count=$((field_count + document_fields))
    done < <(find "${ROOT_DIR}/kubernetes" -type f -name '*.sops.yaml' -print0)

    [[ "${item_count}" -eq "${EXPECTED_ITEMS}" ]] \
        || log error "Unexpected Secret inventory" "expected=${EXPECTED_ITEMS}" "actual=${item_count}"
    [[ "${field_count}" -eq "${EXPECTED_FIELDS}" ]] \
        || log error "Unexpected field inventory" "expected=${EXPECTED_FIELDS}" "actual=${field_count}"

    log info "SOPS inventory validated" "items=${item_count}" "fields=${field_count}"
}

function process_secret() {
    local -r file="$1"
    local -r source_secret="$2"
    local secret_name title field_count item_matches item_id existing verified desired

    secret_name="$(jq --raw-output '.name' <<<"${source_secret}")"
    title="$(item_title "${file}" "${secret_name}")"
    field_count="$(jq '.values | length' <<<"${source_secret}")"
    desired="$(jq --arg title "${title}" '. + {title: $title}' <<<"${source_secret}")"
    processed_items=$((processed_items + 1))
    processed_fields=$((processed_fields + field_count))

    item_matches="$(jq --arg title "${title}" '[.[] | select(.title == $title)] | length' \
        <<<"${items}")"
    if [[ "${item_matches}" -gt 1 ]]; then
        log error "Multiple 1Password items have the required title" "item=${title}"
    fi

    if [[ "${item_matches}" -eq 0 ]]; then
        if [[ "${apply}" == false ]]; then
            log info "Would create 1Password item" "item=${title}" "fields=${field_count}"
            return
        fi

        create_item "${desired}"
        existing="$(op item get "${title}" --vault "${VAULT}" --format json)"
        if ! verify_item "${desired}" "${existing}"; then
            log error "Created item failed hash verification" "item=${title}"
        fi
        log info "Created and verified 1Password item" "item=${title}" "fields=${field_count}"
        return
    fi

    item_id="$(jq --raw-output --arg title "${title}" \
        '.[] | select(.title == $title) | .id' <<<"${items}")"
    existing="$(op item get "${item_id}" --vault "${VAULT}" --format json)"
    if verify_item "${desired}" "${existing}"; then
        log info "Verified existing 1Password item" "item=${title}" "fields=${field_count}"
        return
    fi

    if [[ "${apply}" == false || "${overwrite_conflicts}" == false ]]; then
        log error "Existing 1Password item conflicts with the SOPS source" \
            "item=${title}" "hint=use --apply --overwrite-conflicts"
    fi

    overwrite_item "${desired}" "${existing}"
    verified="$(op item get "${item_id}" --vault "${VAULT}" --format json)"
    if ! verify_item "${desired}" "${verified}"; then
        log error "Overwritten item failed hash verification" "item=${title}"
    fi
    log info "Overwrote and verified 1Password item" "item=${title}" "fields=${field_count}"
}

function main() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --apply) apply=true ;;
            --overwrite-conflicts) overwrite_conflicts=true ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                usage >&2
                log error "Unknown argument" "argument=$1"
                ;;
        esac
        shift
    done

    if [[ "${overwrite_conflicts}" == true && "${apply}" == false ]]; then
        log error "--overwrite-conflicts requires --apply"
    fi

    check_cli jq op shasum sops yq
    op whoami &>/dev/null || log error "1Password CLI is not signed in"
    op vault get "${VAULT}" &>/dev/null || log error "1Password vault is unavailable" "vault=${VAULT}"

    preflight_inventory

    # Item listings contain identifiers and titles only, never field values.
    items="$(op item list --vault "${VAULT}" --format json)"

    local file secret
    while IFS= read -r -d '' file; do
        while IFS= read -r secret; do
            [[ -n "${secret}" ]] || continue
            process_secret "${file}" "${secret}"
        done < <(
            sops decrypt --output-type yaml "${file}" \
                | yq eval-all --output-format=json --indent=0 '
                    select(.kind == "Secret")
                    | {
                        "name": .metadata.name,
                        "values": (
                            ((.data // {}) | with_entries(.value |= @base64d))
                            * (.stringData // {})
                        )
                    }
                ' -
        )
    done < <(find "${ROOT_DIR}/kubernetes" -type f -name '*.sops.yaml' -print0)

    [[ "${processed_items}" -eq "${EXPECTED_ITEMS}" ]] \
        || log error "Decrypted item count did not match preflight" \
            "expected=${EXPECTED_ITEMS}" "actual=${processed_items}"
    [[ "${processed_fields}" -eq "${EXPECTED_FIELDS}" ]] \
        || log error "Decrypted field count did not match preflight" \
            "expected=${EXPECTED_FIELDS}" "actual=${processed_fields}"

    if [[ "${apply}" == false ]]; then
        log info "Dry run complete; no 1Password items were changed"
    else
        log info "Import complete" "items=${EXPECTED_ITEMS}" "fields=${EXPECTED_FIELDS}"
    fi
}

main "$@"
