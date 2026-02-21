# disable auto-negotiation on downstream because
# mikrotik <-> unifi switches don't do that properly apparently
resource "routeros_interface_ethernet" "downstream" {
  factory_name     = "sfp-sfpplus23"
  name             = "sfp-sfpplus23"
  auto_negotiation = false
  speed            = "1G-baseT-full"
}

locals {
  interface_lists = {
    "management" = {
      interfaces = [
        "ether1",
        "sfp-sfpplus19", # david-desktop
      ]
      vlan   = 20
      trunk  = false
      bridge = false
    }
    "access-vlan10" = {
      comment = "clients"
      interfaces = [
        "sfp-sfpplus19", # david-desktop
        "sfp-sfpplus20", # emily-desktop
        "sfp-sfpplus21", # macmini
      ]
      vlan  = 10
      trunk = false
    }
    "trunk-native20" = {
      comment = "infra"
      interfaces = [
        "sfp-sfpplus23", # sw-access downstream
        "sfp-sfpplus24", # udm pro upstream
      ]
      vlan  = 20
      trunk = true
    }
    "trunk-native40" = {
      comment = "services"
      interfaces = [
        "sfp-sfpplus17", # storage
        "sfp-sfpplus18", # storage
      ]
      vlan  = 40
      trunk = true
    }
    "trunk-native42" = {
      comment = "kubernetes"
      interfaces = [
        "sfp-sfpplus15", # talos0
        "sfp-sfpplus16", # talos0
      ]
      vlan  = 42
      trunk = true
    }
  }
  interface_comments = {
    "ether1"        = "management"
    "sfp-sfpplus15" = "talos0"
    "sfp-sfpplus16" = "talos0"
    "sfp-sfpplus17" = "storage"
    "sfp-sfpplus18" = "storage"
    "sfp-sfpplus19" = "david-desktop"
    "sfp-sfpplus20" = "emily-desktop"
    "sfp-sfpplus21" = "macmini"
    "sfp-sfpplus23" = "sw-access downstream"
    "sfp-sfpplus24" = "udm pro upstream"
  }
}

resource "routeros_interface_list" "lists" {
  for_each = local.interface_lists
  name     = each.key
  comment  = try(each.value.comment, "")
}

resource "routeros_interface_list_member" "list_members" {
  for_each = merge([
    for list_name, list in local.interface_lists : {
      for iface in list.interfaces : "${list_name}_${iface}" => {
        list      = list_name
        interface = iface
      }
    }
  ]...)

  interface = each.value.interface
  list      = routeros_interface_list.lists[each.value.list].name
  comment   = local.interface_comments[each.value.interface]
}
