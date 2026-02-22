terraform {
  required_providers {
    routeros = {
      source  = "terraform-routeros/routeros"
      version = "1.99.0"
    }
    b2 = {
      source  = "Backblaze/b2"
      version = "0.12.1"
    }
  }

  backend "s3" {
    bucket = "tfstate"
    key    = "infra.tfstate"
    region = "garage"

    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    use_path_style              = true
  }
}

provider "routeros" {
}

provider "b2" {
}