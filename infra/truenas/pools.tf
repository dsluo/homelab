# Read-only on purpose. The provider can only express vdev members as kernel device
# names, which are resolved fresh on every query and renumber on a disk swap or HBA
# rescan; since topology forces replacement, managing pools here would let a renumber
# plan a pool destroy. See truenas/terraform-provider-truenas#9.
#
# These lookups exist so scrub tasks and dataset names get a dependency edge. Pool
# geometry and autotrim stay unmanaged until that issue is resolved.

data "truenas_pool" "flash" {
  name = "flash"
}

data "truenas_pool" "warm" {
  name = "warm"
}

data "truenas_pool" "hot" {
  name = "hot"
}
