module "sw_core" {
  source = "./sw_core"
  providers = {
    routeros = routeros
  }
}