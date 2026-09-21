# Topology is required, but it is NOT drift-detectable: the provider stores
# whatever pool.query resolves .disk to, which is the current kernel devname.
# ZFS itself references partition UUIDs (see `zpool status`) and TrueNAS keys
# disks by {serial_lunid}; neither is expressible here. A disk swap or HBA
# rescan renumbers sd*, which would read as a topology change, and a topology
# change forces replacement of the pool. So topology is ignored after import and
# kept below only as a record of the layout. prevent_destroy is the backstop.
#
# Consequence: real geometry changes (adding a vdev, replacing a disk) happen in
# the TrueNAS UI, and this file gets updated by hand afterwards.

resource "truenas_pool" "flash" {
  name     = "flash"
  autotrim = true

  topology = {
    # serials, since the letters are the unreliable part: 24526H800858, 252050390B49
    data = [{ type = "MIRROR", disks = ["nvme0n1", "nvme1n1"] }]
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [topology]
  }
}

resource "truenas_pool" "warm" {
  name     = "warm"
  autotrim = false

  topology = {
    data = [
      { type = "MIRROR", disks = ["sda", "sdb"] }, # 9LK4MU2G, 9LK50PPG
      { type = "MIRROR", disks = ["sdd", "sdc"] }, # 9LK4KXNG, 9LK59LEG
    ]
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [topology]
  }
}

resource "truenas_pool" "hot" {
  name     = "hot"
  autotrim = false

  topology = {
    # STRIPE, not DISK: pool.query reports a single-disk vdev as DISK, but the
    # provider reads it back as STRIPE, and topology changes force replacement.
    data = [{ type = "STRIPE", disks = ["sdg"] }] # 5PGW3H7E
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [topology]
  }
}
