# Cloudflare API token for ExternalDNS + the cert-manager DNS-01 solver,
# minted by Terraform and scoped down to DNS-edit on the willpxxr.com zone
# only (WEP-0003). Consumed from the cluster via 1Password ExternalSecrets
# (apps/external-dns + apps/gateway/externalsecret.yaml).
#
# PREREQUISITE (one-time, granted in the Cloudflare dashboard): the
# automation token this provider runs with (var.cloudflare_api_token) needs
# API-Tokens Read + API-Tokens Write. Terraform deliberately holds token-
# minting power so it can produce downscoped tokens like this one on every
# apply; rotating or revoking them is a git change, not a dashboard visit.
data "cloudflare_api_token_permission_groups" "main" {}

locals {
  internal_dns_group_id = data.cloudflare_api_token_permission_groups.main.zone["DNS Write"]
}

resource "cloudflare_api_token" "internal_dns" {
  name = "willpxxr-internal-dns (external-dns + cert-manager)"

  policy {
    permission_groups = [local.internal_dns_group_id]
    resources = {
      "com.cloudflare.api.account.zone.${data.cloudflare_zone.main.id}" = "*"
    }
  }
}

resource "onepassword_item" "internal_dns_cloudflare" {
  vault    = data.onepassword_vault.kubernetes.uuid
  title    = "internal-dns-cloudflare"
  category = "login"

  section_map = {
    credentials = {
      field_map = {
        token = {
          type  = "CONCEALED"
          value = cloudflare_api_token.internal_dns.value
        }
      }
    }
  }
}
