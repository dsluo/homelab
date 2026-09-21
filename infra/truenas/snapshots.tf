# Hourly recursive snapshots of the two pools holding cluster data, kept two
# weeks. hot has no task: it is single-disk NVR scratch.
#
# The live tasks also carry begin/end times (00:00-23:59, the default window).
# The provider's schedule attribute has no equivalent, so that stays on the box.

resource "truenas_periodic_snapshot_task" "warm" {
  dataset        = data.truenas_pool.warm.name
  recursive      = true
  enabled        = true
  allow_empty    = true
  naming_schema  = "auto-%Y-%m-%d_%H-%M"
  lifetime_value = 2
  lifetime_unit  = "WEEK"

  schedule = {
    minute = "0"
    hour   = "*"
    dom    = "*"
    month  = "*"
    dow    = "*"
  }
}

resource "truenas_periodic_snapshot_task" "flash" {
  dataset        = data.truenas_pool.flash.name
  recursive      = true
  enabled        = true
  allow_empty    = true
  naming_schema  = "auto-%Y-%m-%d_%H-%M"
  lifetime_value = 2
  lifetime_unit  = "WEEK"

  schedule = {
    minute = "0"
    hour   = "*"
    dom    = "*"
    month  = "*"
    dow    = "*"
  }
}
