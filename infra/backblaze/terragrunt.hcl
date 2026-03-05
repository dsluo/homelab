include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  extra_arguments "b2_creds" {
    commands = get_terraform_commands_that_need_vars()
    env_vars = {
      B2_APPLICATION_KEY_ID = include.root.locals.secrets.backblaze.key_id
      B2_APPLICATION_KEY    = include.root.locals.secrets.backblaze.application_key
    }
  }
}

inputs = {
  backup_bucket_name = include.root.locals.secrets.backblaze.backup_bucket_name
}