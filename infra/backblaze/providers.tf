terraform {
  required_providers {
    b2 = {
      source  = "Backblaze/b2"
      version = "0.13.1"
    }
    onepassword = {
      source  = "1password/onepassword"
      version = "3.3.1"
    }
  }
}

provider "b2" {}

provider "onepassword" {
  account = var.onepassword.account
}
