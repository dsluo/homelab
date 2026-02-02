module "sw_core" {
  source = "./sw_core"
}

module "backblaze" {
  source             = "./backblaze"
  backup_bucket_name = var.backup_bucket_name
}