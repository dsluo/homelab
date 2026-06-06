include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  extra_arguments "routeros_creds" {
    commands = get_terraform_commands_that_need_vars()
    env_vars = {
      ROS_HOSTURL  = include.root.locals.secrets.sw_core.host
      ROS_USERNAME = include.root.locals.secrets.sw_core.username
      ROS_PASSWORD = include.root.locals.secrets.sw_core.password
      ROS_INSECURE = include.root.locals.secrets.sw_core.insecure
    }
  }
}
