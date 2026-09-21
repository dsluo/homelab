# pool takes the numeric pool id, so it references the resource rather than a
# literal. Minute and hour are transcribed as the box stores them ("0" on flash,
# "00" on the other two); normalising them would show as a diff.

resource "truenas_scrub_task" "flash" {
  pool      = data.truenas_pool.flash.id
  enabled   = true
  threshold = 35

  schedule = {
    minute = "0"
    hour   = "0"
    dom    = "1"
    month  = "*"
    dow    = "*"
  }
}

resource "truenas_scrub_task" "warm" {
  pool      = data.truenas_pool.warm.id
  enabled   = true
  threshold = 35

  schedule = {
    minute = "00"
    hour   = "00"
    dom    = "*"
    month  = "*"
    dow    = "7"
  }
}

resource "truenas_scrub_task" "hot" {
  pool      = data.truenas_pool.hot.id
  enabled   = true
  threshold = 35

  schedule = {
    minute = "00"
    hour   = "00"
    dom    = "*"
    month  = "*"
    dow    = "7"
  }
}
