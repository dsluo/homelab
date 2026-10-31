terraform {
  required_providers {
    truenas = {
      source  = "truenas/truenas"
      version = "1.6.1"
    }
  }
}

provider "truenas" {
  insecure = var.insecure
}
