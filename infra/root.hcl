locals {
  secrets = yamldecode(sops_decrypt_file(find_in_parent_folders("secrets.sops.yaml")))
}

remote_state {
  backend = "s3"

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }

  config = {
    region     = "garage"
    bucket     = "tfstate"
    key        = "${path_relative_to_include()}/tofu.tfstate"
    insecure   = true
    access_key = local.secrets.backend.access_key
    secret_key = local.secrets.backend.secret_key
    endpoints = {
      s3 = local.secrets.backend.endpoint
    }

    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    use_path_style              = true
  }
}
