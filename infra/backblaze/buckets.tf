resource "b2_bucket" "homelab_backups" {
  bucket_name = var.backup_bucket_name
  bucket_type = "allPrivate"
}