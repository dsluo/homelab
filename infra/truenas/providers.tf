terraform {
  required_providers {
    truenas = {
      source  = "truenas/truenas"
      version = "1.2.0"
    }
  }
}

provider "truenas" {
  insecure = var.insecure
}
