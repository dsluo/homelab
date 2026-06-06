locals {
  mailboxes = {
    pocketid = {
      name   = "Pocket ID"
      domain = var.domain
    }
  }
}

data "onepassword_vault" "vault" {
  name = var.onepassword.vault
}

# ephemeral "random_password" "mailbox_password" {
#   for_each = local.mailboxes
#   length   = 64
# }

resource "onepassword_item" "mailbox_login" {
  for_each = local.mailboxes
  vault    = data.onepassword_vault.vault.uuid

  title    = "${each.key}@${each.value.domain}"
  category = "login"

  username = each.key
  # password_wo         = ephemeral.random_password.mailbox_password[each.key].result
  # password_wo_version = 1
  password_recipe {
    length = 64
  }
}

# ephemeral "onepassword_item" "mailbox_login" {
#   for_each = onepassword_item.mailbox_login
#   vault    = each.value.vault
#   uuid     = each.value.uuid
# }

# TODO: fork tf provider and add write-only passwords maybe
resource "migadu_mailbox" "mailboxes" {
  for_each    = local.mailboxes
  local_part  = each.key
  domain_name = each.value.domain
  name        = each.value.name
  # password    = ephemeral.random_password.mailbox_password[each.key].password
  password = onepassword_item.mailbox_login[each.key].password
}
