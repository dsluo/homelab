variable "backup_bucket_name" {
  type = string
}

variable "onepassword" {
  type = object({
    account = string
    vault   = string
  })
}
