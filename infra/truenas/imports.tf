# Adoption of the existing box. Datasets import by path, shares and tasks by the
# numeric id the middleware assigned. Pools are not here: they are read-only data
# sources, see pools.tf. Delete this file once the first apply has seeded state.

import {
  to = truenas_dataset.scans
  id = "flash/scans"
}

import {
  to = truenas_dataset.media
  id = "warm/media"
}

import {
  to = truenas_dataset.kopia
  id = "warm/backups/kopia"
}

import {
  to = truenas_dataset.nvr
  id = "hot/nvr"
}

import {
  to = truenas_nfs_share.scans
  id = "6"
}

import {
  to = truenas_nfs_share.media
  id = "7"
}

import {
  to = truenas_nfs_share.kopia
  id = "9"
}

import {
  to = truenas_nfs_share.nvr
  id = "10"
}

import {
  to = truenas_periodic_snapshot_task.warm
  id = "16"
}

import {
  to = truenas_periodic_snapshot_task.flash
  id = "17"
}

import {
  to = truenas_scrub_task.flash
  id = "7"
}

import {
  to = truenas_scrub_task.warm
  id = "11"
}

import {
  to = truenas_scrub_task.hot
  id = "12"
}
