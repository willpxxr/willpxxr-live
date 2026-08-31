# Cloudflare API token + 1Password item for ExternalDNS and the cert-manager
# DNS-01 solver, both of which manage records for *.internal.willpxxr.com in
# the willpxxr.com zone (WEP-0003). The token is scoped to DNS-edit on this
# zone only -- it cannot touch anything else in the Cloudflare account.

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
