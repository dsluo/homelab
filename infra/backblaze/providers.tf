terraform {
  required_providers {
    b2 = {
      source  = "Backblaze/b2"
      version = "0.14.1"
    }
    onepassword = {
      source  = "1password/onepassword"
      version = "3.4.1"
    }
  }
}

provider "b2" {}

provider "onepassword" {
  account = var.onepassword.account
}
