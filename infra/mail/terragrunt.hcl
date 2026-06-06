include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

inputs = {
  domain      = include.root.locals.secrets.domain
  migadu      = include.root.locals.secrets.migadu
  onepassword = include.root.locals.secrets.onepassword
}
