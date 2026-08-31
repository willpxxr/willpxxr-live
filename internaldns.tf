# Cloudflare API token for ExternalDNS + the cert-manager DNS-01 solver,
# minted by Terraform and scoped down to DNS-edit on the willpxxr.com zone
# only (WEP-0003). Consumed from the cluster via 1Password ExternalSecrets
# (apps/external-dns + apps/gateway/externalsecret.yaml).
#
# Minted as an ACCOUNT token via the account-token surface (provider v5) --
# the automation token is account-owned, and v4's user-endpoint-only token
# management couldn't touch it at all (error 9109). PREREQUISITE (one-time,
# granted in the Cloudflare dashboard): the automation token needs
# Account/API-Tokens Read + Write.
locals {
  # Zone-scoped "DNS Write" permission group. Pinned because the v5
  # cloudflare_account_api_token_permission_groups data source returns a
  # null permission_groups list regardless of input (verified v5.24.0);
  # the id comes from GET /accounts/{id}/tokens/permission_groups and is a
  # stable, account-independent identifier.
  internal_dns_group_id = "4755a26eedb94da69e1066d98aa820be"
}

resource "cloudflare_account_token" "internal_dns" {
  account_id = data.cloudflare_accounts.main.result[0].id
  name       = "willpxxr-internal-dns (external-dns + cert-manager)"

  policies = [{
    effect            = "allow"
    permission_groups = [{ id = local.internal_dns_group_id }]
    resources = jsonencode({
      "com.cloudflare.api.account.zone.${data.cloudflare_zone.main.id}" = "*"
    })
  }]
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
          value = cloudflare_account_token.internal_dns.value
        }
      }
    }
  }
}
