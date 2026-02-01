# bridge
resource "routeros_interface_bridge" "bridge" {
  name           = "bridge1"
  vlan_filtering = true
  pvid           = 1
  priority       = "0x4000"
}

resource "routeros_bridge_port" "bridge_ports" {
  for_each = {
    for k, v in routeros_interface_list.lists :
    k => v
    if try(local.interface_lists[k].bridge, true)
  }
  bridge      = routeros_interface_bridge.bridge.name
  interface   = each.value.name
  pvid        = local.interface_lists[each.key].vlan
  frame_types = local.interface_lists[each.key].trunk ? "admit-all" : "admit-only-untagged-and-priority-tagged"
}