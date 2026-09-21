# Only the datasets the cluster mounts. Names interpolate the pool resource so
# Terraform orders pool before dataset before share. Attributes are limited to
# what is set locally on the box: everything else inherits and is left to follow
# the server.
#
# /mnt/warm/media/{media,torrents,usenet}, which jellyfin, qbittorrent and
# sabnzbd mount, are plain directories inside warm/media, not datasets.

resource "truenas_dataset" "scans" {
  name = "${truenas_pool.flash.name}/scans"
  # The only dataset here not inheriting the pool default. Lowercase: the
  # provider reads acltype back lowercased, and a case mismatch forces
  # replacement rather than an in-place update.
  acltype = "nfsv4"

  lifecycle {
    prevent_destroy = true
  }
}

resource "truenas_dataset" "media" {
  name  = "${truenas_pool.warm.name}/media"
  quota = 5497558138880 # 5 TiB

  lifecycle {
    prevent_destroy = true
  }
}

resource "truenas_dataset" "kopia" {
  name = "${truenas_pool.warm.name}/backups/kopia"

  lifecycle {
    prevent_destroy = true
  }
}

resource "truenas_dataset" "nvr" {
  name = "${truenas_pool.hot.name}/nvr"

  lifecycle {
    prevent_destroy = true
  }
}
