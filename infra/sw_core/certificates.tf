resource "routeros_system_certificate" "self_signed_root" {
  name        = "self-signed-root"
  common_name = "self-signed-root"

  key_size   = "prime256v1"
  key_usage  = ["key-cert-sign", "crl-sign"]
  days_valid = 3650

  trusted = true
  sign {}

  lifecycle {
    ignore_changes = [sign]
  }
}

resource "routeros_system_certificate" "webfig" {
  name        = "webfig"
  common_name = "sw-core"

  key_size   = "prime256v1"
  key_usage  = ["key-cert-sign", "crl-sign", "digital-signature", "key-agreement", "tls-server"]
  days_valid = 3650

  trusted = true
  sign {
    ca = routeros_system_certificate.self_signed_root.name
  }

  lifecycle {
    ignore_changes = [sign]
  }
}
