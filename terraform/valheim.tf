# Valheim dedicated server password (WEP-0015). Same placeholder pattern as
# the Synthetic API key (terraform/synthetic.tf): Terraform creates the item
# with a placeholder, the real password is pasted into 1Password by hand, and
# ignore_changes = [section_map] prevents the next apply from reverting it.
# The ExternalSecret in gitops: apps/valheim/externalsecret.yaml syncs the
# field into the cluster.
resource "onepassword_item" "valheim" {
  vault    = data.onepassword_vault.kubernetes.uuid
  title    = "valheim"
  category = "login"

  section_map = {
    credentials = {
      field_map = {
        password = {
          type  = "CONCEALED"
          value = "REPLACE-ME-with-Valheim-server-password"
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [section_map]
  }
}
