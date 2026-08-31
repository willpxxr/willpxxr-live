# Cloudflare has no way for our automation token to mint sub-tokens (it lacks
# API-Tokens permissions by design -- widening it would let Terraform create
# arbitrary tokens), so like synthetic.tf this item is created with a
# placeholder and the real token is pasted into the 1Password app by hand.
# Token scope (see WEP-0003): Zone/Zone/Read + Zone/DNS/Edit on willpxxr.com
# only -- consumed by ExternalDNS (apps/external-dns) and the cert-manager
# DNS-01 solver (apps/gateway/issuer.yaml).
#
# ignore_changes = [section_map] is load-bearing (same reasoning as
# synthetic.tf): Terraform owns the item's existence but never overwrites the
# hand-pasted token.
resource "onepassword_item" "internal_dns_cloudflare" {
  vault    = data.onepassword_vault.kubernetes.uuid
  title    = "internal-dns-cloudflare"
  category = "login"

  section_map = {
    credentials = {
      field_map = {
        token = {
          type  = "CONCEALED"
          value = "REPLACE-ME-with-Cloudflare-API-token"
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [section_map]
  }
}
