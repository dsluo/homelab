resource "oci_budget_budget" "monthly" {
  amount         = 1
  compartment_id = var.compartment_ocid
  reset_period   = "MONTHLY"
  display_name   = "homelab-budget"
  description    = "Alert if spending exceeds free tier"
  target_type    = "COMPARTMENT"
  targets        = [var.compartment_ocid]
}

resource "oci_budget_alert_rule" "overspend" {
  budget_id      = oci_budget_budget.monthly.id
  threshold      = 100
  threshold_type = "PERCENTAGE"
  type           = "ACTUAL"
  display_name   = "homelab-overspend-alert"
  description    = "Alert when actual spend reaches budget"
  message        = "OCI spending has reached the budget threshold."
}
