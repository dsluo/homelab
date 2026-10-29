terraform {
  required_providers {
    migadu = {
      source  = "metio/migadu"
      version = "2026.10.29"
    }

    onepassword = {
      source  = "1password/onepassword"
      version = "3.4.1"
    }
  }
}

provider "migadu" {
  username = var.migadu.username
  token    = var.migadu.token
}

provider "onepassword" {
  account = var.onepassword.account
}
