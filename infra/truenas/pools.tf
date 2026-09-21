# Topology is a required attribute, so the config has to reproduce the live vdev
# layout exactly; a transcription error reads as a topology change. Nothing here
# should ever be replaced, hence prevent_destroy on all three.

resource "truenas_pool" "flash" {
  name     = "flash"
  autotrim = true

  topology = {
    data = [{ type = "MIRROR", disks = ["nvme0n1", "nvme1n1"] }]
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
      { type = "MIRROR", disks = ["sda", "sdb"] },
      { type = "MIRROR", disks = ["sdd", "sdc"] },
    ]
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "truenas_pool" "hot" {
  name     = "hot"
  autotrim = false

  topology = {
    data = [{ type = "DISK", disks = ["sdg"] }]
  }

  lifecycle {
    prevent_destroy = true
  }
}
