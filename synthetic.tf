# Synthetic (synthetic.new) has no Terraform provider, so its LLM-gateway
# API key can't be produced by a provider resource the way the tailscale/
# betterstack items are. Instead Terraform creates the 1Password item with
# a placeholder value, and the real key is pasted into the item by hand in
# the 1Password app afterwards.
#
# ignore_changes = [section_map] is load-bearing, not defensive: without it,
# the very next apply after the manual paste would see the hand-updated key
# as drift from this placeholder and revert it back. With it, Terraform
# owns the item's existence (title/vault/category) but never overwrites its
# contents after creation. The ExternalSecret in gitops:
# apps/ai-gateway-llm/externalsecret-synthetic.yaml then syncs the field
# into the cluster the same way as the other items.
resource "onepassword_item" "synthetic" {
  vault    = data.onepassword_vault.kubernetes.uuid
  title    = "synthetic"
  category = "login"

  section_map = {
    credentials = {
      field_map = {
        api_key = {
          type  = "CONCEALED"
          value = "REPLACE-ME-with-Synthetic-API-key"
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [section_map]
  }
}
