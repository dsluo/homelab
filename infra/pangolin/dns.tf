data "oci_core_vnic_attachments" "gateway" {
  compartment_id  = var.compartment_ocid
  instance_id     = oci_core_instance.gateway.id
}

data "oci_core_vnic" "gateway" {
  vnic_id = data.oci_core_vnic_attachments.gateway.vnic_attachments[0].vnic_id
}

data "oci_core_ipv6s" "gateway" {
  vnic_id = data.oci_core_vnic.gateway.id
}

resource "cloudflare_dns_record" "gateway_ipv4" {
  zone_id = var.cloudflare_zone_id
  name = "gateway"
  content = oci_core_instance.gateway.public_ip
  type = "A"
  ttl = 1
  proxied = false
}
resource "cloudflare_dns_record" "gateway_ipv6" {
  zone_id = var.cloudflare_zone_id
  name = "gateway"
  content = data.oci_core_ipv6s.gateway.ipv6s[0].ip_address
  type = "AAAA"
  ttl = 1
  proxied = false
}