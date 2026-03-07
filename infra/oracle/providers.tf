terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "8.4.0"
    }
  }
}

provider "oci" {
  region              = var.region
  auth                = "SecurityToken"
  config_file_profile = var.oci_profile
}
