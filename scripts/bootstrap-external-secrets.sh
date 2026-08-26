#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${0}")/lib/common.sh"

export LOG_LEVEL="${LOG_LEVEL:-info}"

readonly NAMESPACE="external-secrets"
readonly SECRET_NAME="onepassword-service-account-token"
readonly TOKEN_REFERENCE="op://homelab/Service Account Auth Token - external-secrets/credential"

function main() {
    check_env KUBECONFIG
    check_cli kubectl op

    if ! kubectl get namespace "${NAMESPACE}" &>/dev/null; then
        log error "Namespace must exist before bootstrapping ESO" "namespace=${NAMESPACE}"
    fi

    local token
    token="$(op read "${TOKEN_REFERENCE}")"
    if [[ -z "${token}" ]]; then
        log error "1Password service-account token is empty" "reference=${TOKEN_REFERENCE}"
    fi

    if ! printf '%s' "${token}" \
        | kubectl --namespace "${NAMESPACE}" create secret generic "${SECRET_NAME}" \
            --from-file=token=/dev/stdin --dry-run=client --output=yaml \
        | kubectl apply --server-side --filename - &>/dev/null; then
        unset token
        log error "Failed to apply the ESO bootstrap Secret" "resource=${SECRET_NAME}"
    fi
    unset token

    log info "ESO bootstrap Secret applied" "resource=${SECRET_NAME}"
}

main "$@"
