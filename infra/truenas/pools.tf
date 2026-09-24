# Disks are pinned by serial, not the sdX kernel name the middleware reports: the
# provider resolves either form to the same physical disk at plan time, so a
# renumber across a reboot or HBA rescan is not a topology change. Serials come
# from `midclt call disk.query '[]' '{"select": ["name", "serial"]}'`.
#
# Mirror members are listed in the order pool.query returns them. prevent_destroy
# is belt-and-braces: the provider already refuses to plan a pool replacement, but
# that does not stop an explicit destroy or -replace.

resource "truenas_pool" "flash" {
  name     = "flash"
  autotrim = true

  topology = {
    data = [
      { type = "MIRROR", disks = ["24526H800858", "252050390B49"] },
    ]
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "truenas_pool" "warm" {
  name     = "warm"
  autotrim = false

  topology = {
    data = [
      { type = "MIRROR", disks = ["9LK4MU2G", "9LK50PPG"] },
      { type = "MIRROR", disks = ["9LK4KXNG", "9LK59LEG"] },
    ]
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "truenas_pool" "hot" {
  name     = "hot"
  autotrim = false

  # Single-disk vdev. pool.query spells this "DISK"; the provider accepts it as
  # an alias for "STRIPE", so either reads back clean.
  topology = {
    data = [
      { type = "STRIPE", disks = ["5PGW3H7E"] },
    ]
  }

  lifecycle {
    prevent_destroy = true
  }
}
