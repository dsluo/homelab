include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

inputs = {
  region               = include.root.locals.secrets.pangolin.region
  compartment_ocid     = include.root.locals.secrets.pangolin.compartment_ocid
  ssh_public_key       = include.root.locals.secrets.pangolin.ssh_public_key
  availability_domain  = include.root.locals.secrets.pangolin.availability_domain
}
