#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${0}")/lib/common.sh"

export LOG_LEVEL="debug"

function create_zpool() {
    local node="${1}"

    log debug "Creating zpool on node ${node}"

    POOL_NAME=tank
    POOL_DISK=/dev/disk/by-partlabel/r-openebs-zpool

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
        -O compression=on \
        -O atime=off \
        $POOL_NAME \
        $POOL_DISK
}

function main() {
    local node="${1:-}"

    if [[ -z "${node}" ]]; then
        log error "Missing required argument" "usage=${0##*/} <node-name>"
    fi

    check_env KUBECONFIG
    check_cli kubectl

    create_zpool "${node}"
}

main "$@"
