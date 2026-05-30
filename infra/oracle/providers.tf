terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "8.16.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "3.6.0"
    }
  }
}

provider "oci" {
  region              = var.region
  auth                = "SecurityToken"
  config_file_profile = var.oci_profile
}
