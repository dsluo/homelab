#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${0}")/lib/common.sh"

export LOG_LEVEL="debug"

function create_zpool() {
    log debug "Creating zpool"

    POOL_NAME=tank
    POOL_DISK=/dev/disk/by-partlabel/r-openebs-zpool

    kubectl debug \
        node/talos0 \
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
    check_env KUBECONFIG
    check_cli kubectl

    create_zpool
}

main "$@"
