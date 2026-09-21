terraform {
  required_providers {
    truenas = {
      source  = "truenas/truenas"
      version = "1.0.11"
    }
  }
}

provider "truenas" {
  insecure = var.insecure
}
