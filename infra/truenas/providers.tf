terraform {
  required_providers {
    truenas = {
      source  = "truenas/truenas"
      version = "1.5.19"
    }
  }
}

provider "truenas" {
  insecure = var.insecure
}
