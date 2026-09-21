# path references the dataset's mountpoint rather than a literal /mnt/... string
# so Terraform has a dependency edge from share back to dataset and pool.
#
# 10.0.42.0/24 is the Talos node VLAN (talos0 .3, talos1 .4). Mounts are made by
# the kubelet on the node, so the node addresses are what the export sees, not
# the pod CIDR.

resource "truenas_nfs_share" "scans" {
  path          = truenas_dataset.scans.mountpoint
  networks      = ["10.0.42.0/24"]
  maproot_user  = "nobody"
  maproot_group = "nobody"
  enabled       = true
}

resource "truenas_nfs_share" "media" {
  path          = truenas_dataset.media.mountpoint
  networks      = ["10.0.42.0/24"]
  maproot_user  = "nobody"
  maproot_group = "nobody"
  enabled       = true
}

resource "truenas_nfs_share" "kopia" {
  path     = truenas_dataset.kopia.mountpoint
  networks = ["10.0.42.0/24"]
  # Every kopiur mover uid presents as the directory owner server-side, so repo
  # writes never depend on the per-app mover uid.
  mapall_user  = "volsync"
  mapall_group = "volsync"
  enabled      = true
}

resource "truenas_nfs_share" "nvr" {
  path         = truenas_dataset.nvr.mountpoint
  networks     = ["10.0.42.0/24"]
  mapall_user  = "frigate"
  mapall_group = "frigate"
  enabled      = true
}
