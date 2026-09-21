include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  extra_arguments "truenas_creds" {
    commands = get_terraform_commands_that_need_vars()
    env_vars = {
      TRUENAS_ENDPOINT = include.root.locals.secrets.truenas.endpoint
      TRUENAS_API_KEY  = include.root.locals.secrets.truenas.api_key
      TRUENAS_USERNAME = include.root.locals.secrets.truenas.username
    }
  }
}

inputs = {
  insecure = include.root.locals.secrets.truenas.insecure
}
