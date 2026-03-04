terraform {
  required_providers {
    b2 = {
      source  = "Backblaze/b2"
      version = "0.12.1"
    }
  }

  backend "s3" {}
}

provider "b2" {}
