terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "8.8.1"
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
