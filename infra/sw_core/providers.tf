terraform {
  required_providers {
    routeros = {
      source  = "terraform-routeros/routeros"
      version = "1.99.0"
    }
  }

  backend "s3" {}
}

provider "routeros" {}
