# References:

- https://rook.io/docs/rook/latest-release/CRDs/Cluster/external-cluster/external-cluster/?h=external
    - https://github.com/rook/rook/blob/release-1.16/deploy/examples/create-external-cluster-resources.py
    - https://github.com/rook/rook/blob/release-1.16/deploy/examples/import-external-cluster.sh
- https://discord.com/channels/673534664354430999/1347420707784757300
- https://github.com/frantathefranta/home-ops/tree/main/kubernetes/apps/rook-ceph-external/rook-ceph

# Notes

- Proxmox needs prometheus monitoring endpoint enabled.

## Changing IPs:

On all PVE nodes:

1. Stop proxmox services.
    ```
    $ systemctl stop pve-cluster
    $ systemctl stop corosync
    $ systemctl stop ceph.target
    ```
2. Mount proxmox filesystem locally.
    ```
    $ pmxcfs -l
    ```
4. Edit network settings.
    ```
    $ vim /etc/network/interfaces
    $ vim /etc/hosts
    $ vim /etc/resolv.conf
    ```
5. Edit cluster settings.
    ```
    $ vim /etc/pve/corosync.conf
    ```
6. Edit ceph settings.
    ```
    $ vim /etc/ceph/ceph.conf
    ```

On all `mon` ceph nodes:

7. Dump monmap.
    ```
    $ ceph-mon -i <host> --extract-monmap /tmp/monmap
    ```
8. Remove old `mon`s and add new ones.
    ```
    $ monmaptool --print /tmp/monmap
    $ monmaptool --rm pve /tmp/monmap
    $ monmaptool --rm pve1 /tmp/monmap
    $ monmaptool --rm pve2 /tmp/monmap
    ...
    $ monmaptool --add pve <new ip> /tmp/monmap
    $ monmaptool --add pve1 <new ip> /tmp/monmap
    $ monmaptool --add pve2 <new ip> /tmp/monmap
    ...
    ```
9. Inject monmap back into `mon`.
    ```
    $ ceph-mon -i <host> --inject-monmap /tmp/monmap
    ```
10. Reboot all nodes.

In k8s:

11. Edit all secrets/config maps in ceph namespace to point to new addresses.
12. Restart ceph deployments/statefulsets.