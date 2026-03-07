variable "region" {
  type = string
}

variable "oci_profile" {
  type    = string
  default = "DEFAULT"
}

variable "compartment_ocid" {
  type      = string
  sensitive = true
}

variable "ssh_public_key" {
  type = string
}

variable "availability_domain" {
  type = string
}
