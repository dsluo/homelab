include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

inputs = {
  region              = include.root.locals.secrets.oracle.region
  compartment_ocid    = include.root.locals.secrets.oracle.compartment_ocid
  ssh_public_key      = include.root.locals.secrets.oracle.ssh_public_key
  availability_domain = include.root.locals.secrets.oracle.availability_domain
}
