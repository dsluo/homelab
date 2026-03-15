terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "8.5.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "5.18.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "3.5.0"
    }
  }
}

provider "oci" {
  region              = var.region
  auth                = "SecurityToken"
  config_file_profile = var.oci_profile
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
