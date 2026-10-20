terraform {
  required_providers {
    truenas = {
      source  = "truenas/truenas"
      version = "1.5.16"
    }
  }
}

provider "truenas" {
  insecure = var.insecure
}
