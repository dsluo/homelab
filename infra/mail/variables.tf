variable "domain" {
  type = string
}

variable "migadu" {
  type = object({
    username = string
    token    = string
  })
}


variable "onepassword" {
  type = object({
    account = string
    vault   = string
  })
}
