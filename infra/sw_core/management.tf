resource "routeros_tool_mac_server" "mac_server" {
  allowed_interface_list = routeros_interface_list.lists["management"].name
}

resource "routeros_tool_mac_server_winbox" "winbox" {
  allowed_interface_list = routeros_interface_list.lists["management"].name
}