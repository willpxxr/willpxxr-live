# Supabase project backing the mcp-token-vault credential vault
# (services/mcp-token-vault/, gitops: apps/mcp-token-vault/, WEP-0006).
#
# Auth note: unlike the Tailscale path in providers.tf (TFC workload-identity
# OIDC), the Supabase Management API has no federation surface -- the
# supabase provider's only auth is a static personal access token (verified
# against the provider schema), hence var.supabase_token.
#
# The project's own database password is set once at create and then ignored
# (per the provider guide's recommendation): rotating it would invalidate the
# db_url handed to 1Password below, which would need a coordinated re-paste.
resource "random_password" "supabase_db" {
  length  = 32
  special = false
}

# Separate from the project's admin password: this belongs to the dedicated
# least-privilege `token_vault` role created by the manual bootstrap SQL. The
# role password is generated here and surfaced via the 1Password item below,
# because the SQL step is run by hand.
resource "random_password" "token_vault_role" {
  length  = 32
  special = false
}

resource "supabase_project" "token_vault" {
  organization_id   = var.supabase_organization_id
  name              = "mcp-token-vault"
  database_password = random_password.supabase_db.result
  region            = var.supabase_region

  lifecycle {
    ignore_changes = [database_password]
  }
}

# Connection path via the Supavisor session-mode pooler: the direct endpoint
# is IPv6-only without the paid IPv4 add-on (verified against Supabase's
# connecting docs), and pod IPv6 egress from the de/hetzner nodes is
# unproven -- the shared pooler is IPv4 on every tier. WEP-0006 carries the
# full IPv4/IPv6 verification note.
data "supabase_pooler" "token_vault" {
  project_ref = supabase_project.token_vault.id
}

locals {
  # The pooler data source returns a map of mode -> connection string with a
  # [YOUR-PASSWORD] placeholder and the built-in postgres role as user.
  # TO VERIFY at first apply: the exact map key naming (matched loosely on
  # "session" here) and the placeholder format; both come straight from the
  # Management API response and are not documented in the provider schema.
  supabase_session_url = one([
    for mode, url in data.supabase_pooler.token_vault.url : url
    if strcontains(lower(mode), "session")
  ])

  # Supavisor session mode usernames are "<role>.<project-ref>"; swap the
  # built-in postgres user for the dedicated least-privilege role created by
  # services/mcp-token-vault/scripts/0000-bootstrap-role.sql (still a manual
  # dashboard step -- the provider has no SQL-execution resource).
  token_vault_db_url = replace(
    replace(
      local.supabase_session_url,
      "postgres.${supabase_project.token_vault.id}@",
      "token_vault.${supabase_project.token_vault.id}@"
    ),
    "[YOUR-PASSWORD]",
    random_password.token_vault_role.result
  )

  # 32 random bytes, base64 -- exactly what the vault's VAULT_ENCRYPTION_KEY
  # expects (XChaCha20-Poly1305 master key).
  # random_bytes exposes the value base64-encoded directly.
  token_vault_encryption_key = random_bytes.token_vault_key.base64
}

resource "random_bytes" "token_vault_key" {
  length = 32
}

# Written straight into the same 1Password vault the cluster's
# ExternalSecrets read from (apps/mcp-token-vault/externalsecret-vault.yaml,
# remoteRef keys mcp-token-vault/credentials/db_url + .../encryption_key) --
# same pattern as betterstack.tf / argocd.tf. The service-account token
# cannot read these back, so treat this resource as the writer of record.
resource "onepassword_item" "mcp_token_vault" {
  vault    = data.onepassword_vault.kubernetes.uuid
  title    = "mcp-token-vault"
  category = "login"

  section_map = {
    credentials = {
      field_map = {
        db_url = {
          type  = "CONCEALED"
          value = local.token_vault_db_url
        }
        encryption_key = {
          type  = "CONCEALED"
          value = local.token_vault_encryption_key
        }
        role_password = {
          type  = "CONCEALED"
          value = random_password.token_vault_role.result
        }
      }
    }
  }
}
