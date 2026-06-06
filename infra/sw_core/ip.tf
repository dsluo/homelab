resource "routeros_ip_address" "management" {
  address   = "10.0.20.2/24"
  interface = "ether1"
  network   = "10.0.20.0"
}

resource "routeros_ip_dns" "dns" {
  servers = [
    "fe80::e638:83ff:fe32:5a47",
    "10.0.20.1"
  ]
}

resource "routeros_ip_route" "default_gateway" {
  gateway     = "10.0.20.1"
  dst_address = "0.0.0.0/0"
}

