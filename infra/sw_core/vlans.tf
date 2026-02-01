locals {
  bridge_vlans = {
    "vlan10" = {
      vlan_ids = ["10"]
      tagged   = ["trunk-native20"]
      untagged = ["access-vlan10"]
    }
    "vlan11-19" = {
      vlan_ids = ["11-19"]
      tagged   = ["trunk-native20"]
    }
    "vlan20-29" = {
      vlan_ids = ["20-29"]
      tagged   = ["trunk-native20"]
    }
    "vlan30-39" = {
      vlan_ids = ["30-39"]
      tagged   = ["trunk-native20"]
    }
    "vlan40-49" = {
      vlan_ids = ["40-49"]
      tagged   = ["trunk-native20", "trunk-native40"]
    }
    "vlan50-59" = {
      vlan_ids = ["50-59"]
      tagged   = ["trunk-native20"]
    }
  }
}

resource "routeros_interface_bridge_vlan" "vlans" {
  for_each = local.bridge_vlans

  bridge   = routeros_interface_bridge.bridge.name
  tagged   = [for t in each.value.tagged : routeros_interface_list.lists[t].name]
  untagged = [for u in try(each.value.untagged, []) : routeros_interface_list.lists[u].name]
  vlan_ids = each.value.vlan_ids
}
