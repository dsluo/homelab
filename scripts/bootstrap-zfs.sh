#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${0}")/lib/common.sh"

export LOG_LEVEL="debug"

function create_zpool() {
    local node="${1}"
    local pool_name="${2}"
    local pool_disk="/dev/disk/by-partlabel/${3}"

    log debug "Creating zpool on node ${node}" "pool=${pool_name}" "disk=${pool_disk}"

    kubectl debug \
        "node/${node}" \
        -n kube-system \
        --image=busybox:1.36 \
        --profile=sysadmin \
        -it \
        -- \
        chroot /host \
        zpool create \
        -m legacy \
        -o ashift=12 \
        -o autotrim=on \
        -O compression=on \
        -O atime=off \
        "${pool_name}" \
        "${pool_disk}"
}

function main() {
    local node="${1:-}"
    local pool_name="${2:-tank}"
    local partlabel="${3:-r-openebs-zpool}"

    if [[ -z "${node}" ]]; then
        log error "Missing required argument" "usage=${0##*/} <node-name> [pool-name] [partlabel]"
    fi

    check_env KUBECONFIG
    check_cli kubectl

    create_zpool "${node}" "${pool_name}" "${partlabel}"
}

main "$@"
