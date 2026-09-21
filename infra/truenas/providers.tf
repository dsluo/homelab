terraform {
  required_providers {
    truenas = {
      source  = "truenas/truenas"
      version = "1.0.8"
    }
  }
}

provider "truenas" {
  insecure = var.insecure
}
