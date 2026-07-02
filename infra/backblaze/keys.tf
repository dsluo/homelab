resource "b2_application_key" "cnpg" {
  key_name   = "cnpg"
  bucket_ids = [b2_bucket.homelab_backups.bucket_id]
  capabilities = [
    "listBuckets",
    "readBuckets",
    "listFiles",
    "readFiles",
    "writeFiles",
    "deleteFiles",
  ]
  name_prefix = "cnpg/"
}

resource "b2_application_key" "kopiur" {
  key_name   = "kopiur"
  bucket_ids = [b2_bucket.homelab_backups.bucket_id]
  capabilities = [
    "listBuckets",
    "readBuckets",
    "listFiles",
    "readFiles",
    "writeFiles",
    "deleteFiles",
  ]
  name_prefix = "kopiur/"
}

data "onepassword_vault" "vault" {
  name = var.onepassword.vault
}

resource "onepassword_item" "cnpg_key" {
  vault    = data.onepassword_vault.vault.uuid
  title    = "cnpg key"
  category = "login"

  username            = b2_application_key.cnpg.application_key_id
  password_wo         = b2_application_key.cnpg.application_key
  password_wo_version = 1
}

resource "onepassword_item" "kopiur_key" {
  vault    = data.onepassword_vault.vault.uuid
  title    = "kopiur key"
  category = "login"

  username            = b2_application_key.kopiur.application_key_id
  password_wo         = b2_application_key.kopiur.application_key
  password_wo_version = 1
}
