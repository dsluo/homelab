#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(git rev-parse --show-toplevel)"
readonly EXPECTED_APP_SECRETS=32
readonly EXPECTED_APP_FIELDS=62
readonly EXPECTED_MANAGED_NAMESPACES=19
readonly EXPECTED_APP_CONTRACT_SHA256="539f3a24d8008cf948042e134528492d1ee7ddb2cf702bfc95801b72c7e74eea"

function fail() {
    printf 'external-secrets check failed: %s\n' "$*" >&2
    exit 1
}

function main() {
    command -v jq &>/dev/null || fail "jq is required"
    command -v shasum &>/dev/null || fail "shasum is required"
    command -v yq &>/dev/null || fail "yq is required"

    local secret_count=0
    local field_count=0
    local contract_lines=""
    local file namespace documents invalid

    while IFS= read -r -d '' file; do
        namespace="${file#${ROOT_DIR}/kubernetes/apps/}"
        namespace="${namespace%%/*}"
        documents="$(yq eval-all --output-format=json --indent=0 \
            'select(.kind == "ExternalSecret")' "${file}" | jq --slurp '.')"

        local kustomization_file="$(dirname "${file}")/kustomization.yaml"
        local resources
        [[ -f "${kustomization_file}" ]] || fail "missing kustomization for ${file}"
        resources="$(yq --unwrapScalar '.resources[]' "${kustomization_file}")"
        grep --fixed-strings --line-regexp --quiet "./$(basename "${file}")" <<<"${resources}" \
            || fail "${file} is not included by ${kustomization_file}"

        secret_count=$((secret_count + $(jq 'length' <<<"${documents}")))
        field_count=$((field_count + $(jq '[.[].spec.target.template.data | length] | add // 0' <<<"${documents}")))

        invalid="$(jq -r --arg namespace "${namespace}" '
            .[]
            | select(
                .apiVersion != "external-secrets.io/v1"
                or .spec.refreshPolicy != "Periodic"
                or .spec.refreshInterval != "1h"
                or .spec.secretStoreRef.kind != "ClusterSecretStore"
                or .spec.secretStoreRef.name != "onepassword"
                or .spec.target.creationPolicy != "Owner"
                or .spec.target.deletionPolicy != "Retain"
                or (.spec.target.template.type | type) != "string"
                or .spec.target.template.mergePolicy != "Replace"
                or (.spec.target.template.data | type) != "object"
                or (.spec.data != null)
                or (.spec.dataFrom | length) != 1
                or (.spec.dataFrom[0] | keys) != ["extract"]
                or .spec.dataFrom[0].extract.key != ("k8s-" + $namespace + "-" + .spec.target.name)
                or .metadata.name != .spec.target.name
            )
            | .metadata.name
        ' <<<"${documents}")"
        [[ -z "${invalid}" ]] || fail "invalid ExternalSecret policy in ${file}: ${invalid}"

        contract_lines+="$(jq --compact-output --arg namespace "${namespace}" '
            .[] | {
                namespace: $namespace,
                name: .spec.target.name,
                type: .spec.target.template.type,
                labels: (.spec.target.template.metadata.labels // {}),
                annotations: (.spec.target.template.metadata.annotations // {}),
                keys: (.spec.target.template.data | keys)
            }
        ' <<<"${documents}")"$'\n'

        while IFS=$'\t' read -r target remote_key secret_key template_value; do
            [[ -n "${target}" ]] || continue
            [[ "${remote_key}" == "k8s-${namespace}-${target}" ]] \
                || fail "item mapping mismatch in ${file}: ${target} -> ${remote_key}"
            [[ "${template_value}" == "{{ index . \"${secret_key}\" }}" ]] \
                || fail "template mapping mismatch in ${file}: ${secret_key}"
        done < <(jq -r '.[] as $secret | $secret.spec.target.template.data | to_entries[]
            | [$secret.spec.target.name, $secret.spec.dataFrom[0].extract.key, .key, .value]
            | @tsv' <<<"${documents}")
    done < <(find "${ROOT_DIR}/kubernetes/apps" -type f -name '*externalsecret.yaml' \
        ! -path '*/external-secrets/*' -print0)

    [[ "${secret_count}" -eq "${EXPECTED_APP_SECRETS}" ]] \
        || fail "expected ${EXPECTED_APP_SECRETS} app Secrets, found ${secret_count}"
    [[ "${field_count}" -eq "${EXPECTED_APP_FIELDS}" ]] \
        || fail "expected ${EXPECTED_APP_FIELDS} app fields, found ${field_count}"

    local contract_sha256
    contract_sha256="$(printf '%s' "${contract_lines}" | LC_ALL=C sort \
        | shasum -a 256 | awk '{print $1}')"
    [[ "${contract_sha256}" == "${EXPECTED_APP_CONTRACT_SHA256}" ]] \
        || fail "Secret names, types, keys, labels, or annotations changed from the migration contract"

    local source_file="${ROOT_DIR}/kubernetes/apps/external-secrets/external-secrets/config/clusterexternalsecret.yaml"
    local source
    source="$(yq eval-all --output-format=json --indent=0 \
        'select(.kind == "ExternalSecret" and .metadata.name == "cluster-secrets-source")' \
        "${source_file}" | jq --slurp '.[0]')"
    [[ "$(jq '.spec.target.template.data | length' <<<"${source}")" -eq 3 ]] \
        || fail "cluster-secrets-source must contain exactly three fields"
    invalid="$(jq -r '
        select(
            .spec.refreshPolicy != "Periodic"
            or .spec.refreshInterval != "1h"
            or .spec.secretStoreRef.name != "onepassword"
            or .spec.target.name != "cluster-secrets-source"
            or .spec.target.creationPolicy != "Owner"
            or .spec.target.deletionPolicy != "Retain"
            or .spec.target.template.mergePolicy != "Replace"
            or (.spec.target.template.data | keys) != ["CLOUDFLARE_TUNNEL_ID", "GARAGE_ENDPOINT_URL", "SECRET_DOMAIN"]
            or any(.spec.target.template.data | to_entries[];
                .value != ("{{ index . \"" + .key + "\" }}"))
            or (.spec.data != null)
            or (.spec.dataFrom | length) != 1
            or (.spec.dataFrom[0] | keys) != ["extract"]
            or .spec.dataFrom[0].extract.key != "k8s-cluster-secrets"
        )
        | .metadata.name
    ' <<<"${source}")"
    [[ -z "${invalid}" ]] || fail "invalid cluster-secrets-source contract"

    local fanout
    fanout="$(yq eval-all --output-format=json --indent=0 \
        'select(.kind == "ClusterExternalSecret" and .metadata.name == "cluster-secrets")' \
        "${source_file}" | jq --slurp '.[0]')"
    invalid="$(jq -r '
        select(
            .spec.externalSecretName != "cluster-secrets"
            or .spec.externalSecretSpec.refreshPolicy != "Periodic"
            or .spec.externalSecretSpec.refreshInterval != "1h"
            or .spec.externalSecretSpec.secretStoreRef.name != "cluster-secrets-fanout"
            or .spec.externalSecretSpec.target.name != "cluster-secrets"
            or .spec.externalSecretSpec.target.creationPolicy != "Owner"
            or .spec.externalSecretSpec.target.deletionPolicy != "Retain"
            or (.spec.externalSecretSpec.data | length) != 3
            or any(.spec.externalSecretSpec.data[];
                .remoteRef.key != "cluster-secrets-source"
                or .remoteRef.property != .secretKey)
        )
        | .metadata.name
    ' <<<"${fanout}")"
    [[ -z "${invalid}" ]] || fail "invalid cluster-secrets fan-out contract"

    local managed_namespaces=0
    while IFS= read -r -d '' file; do
        if [[ "$(yq '.metadata.labels."external-secrets.io/cluster-secrets" // "false"' "${file}")" == "true" ]]; then
            [[ "$(yq '.metadata.labels."external-secrets.io/managed" // "false"' "${file}")" == "true" ]] \
                || fail "fan-out namespace is not provider-managed: ${file}"
            managed_namespaces=$((managed_namespaces + 1))
        fi
    done < <(find "${ROOT_DIR}/kubernetes/apps" -mindepth 2 -maxdepth 2 \
        -type f -name namespace.yaml -print0)
    [[ "${managed_namespaces}" -eq "${EXPECTED_MANAGED_NAMESPACES}" ]] \
        || fail "expected ${EXPECTED_MANAGED_NAMESPACES} fan-out namespaces, found ${managed_namespaces}"

    [[ "$(yq '.metadata.labels."external-secrets.io/managed"' \
        "${ROOT_DIR}/kubernetes/apps/external-secrets/namespace.yaml")" == "true" ]] \
        || fail "external-secrets namespace must be provider-managed"
    [[ "$(yq '.metadata.labels."external-secrets.io/cluster-secrets" // "false"' \
        "${ROOT_DIR}/kubernetes/apps/external-secrets/namespace.yaml")" == "false" ]] \
        || fail "external-secrets namespace must not receive the fan-out Secret"

    if find "${ROOT_DIR}/kubernetes" -type f -name '*.sops.yaml' -print -quit | grep -q .; then
        fail "Kubernetes still contains SOPS manifests"
    fi
    if git -C "${ROOT_DIR}" grep --line-number --ignore-case sops -- kubernetes bootstrap scripts/bootstrap-apps.sh; then
        fail "Kubernetes/bootstrap still references SOPS"
    fi

    printf 'external-secrets contracts valid: %d items, %d fields, %d fan-out namespaces\n' \
        "$((secret_count + 1))" "$((field_count + 3))" "${managed_namespaces}"
}

main "$@"
