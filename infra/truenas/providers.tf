terraform {
  required_providers {
    truenas = {
      source  = "truenas/truenas"
      version = "1.5.23"
    }
  }
}

provider "truenas" {
  insecure = var.insecure
}
