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
  # The pooler data source returns a map of mode -> connection string (keys
  # are the raw Supavisor PoolMode values, per the provider source), with a
  # [YOUR-PASSWORD] placeholder and the built-in postgres role as user.
  pooler_urls = data.supabase_pooler.token_vault.url

  supabase_session_url = one([
    for mode, url in local.pooler_urls : url
    if strcontains(lower(mode), "session")
  ])

  # Fallback for the first apply: a just-created project can race Supavisor
  # provisioning, and the provider silently yields an EMPTY url map then
  # (one([]) -> null). Construct the documented session-pooler host directly;
  # the data-source result wins on any later run once the pooler exists.
  supabase_session_url_fallback = coalesce(
    local.supabase_session_url,
    "postgresql://postgres.${supabase_project.token_vault.id}:[YOUR-PASSWORD]@aws-0-${var.supabase_region}.pooler.supabase.com:5432/postgres"
  )

  # Only the HOST is taken from the pooled URL; both connection strings are
  # then built from parts. (A literal username swap can never match here:
  # the URL carries the password placeholder between username and @.)
  supabase_pooler_host = element(
    regex("^[^@]+@([^:/]+):[0-9]+", local.supabase_session_url_fallback),
    0
  )

  # Supavisor session mode usernames are "<role>.<project-ref>". The vault
  # bootstraps the token_vault role at startup (admin_url below): it
  # reconciles its own role/password against db_url on every boot.
  token_vault_db_url = format(
    "postgresql://token_vault.%s:%s@%s:5432/postgres",
    supabase_project.token_vault.id,
    random_password.token_vault_role.result,
    local.supabase_pooler_host
  )

  # Admin connection (built-in postgres role), consumed by the vault at
  # startup to reconcile the token_vault role against db_url.
  token_vault_admin_url = format(
    "postgresql://postgres.%s:%s@%s:5432/postgres",
    supabase_project.token_vault.id,
    random_password.supabase_db.result,
    local.supabase_pooler_host
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
        admin_url = {
          type  = "CONCEALED"
          value = local.token_vault_admin_url
        }
      }
    }
  }
}

# Linear OAuth client for the mcp-token-vault elicitation flow (WEP-0006
# phase 2). Created here with placeholders so the ExternalSecret syncs and
# the vault pod can start; the values fail closed until the real
# client_id/client_secret are pasted after creating the Linear OAuth
# application (redirect URI:
# https://mcp.internal.willpxxr.com/oauth/linear/callback). ignore_changes:
# the later hand-paste in 1Password must not be reverted by applies (same
# pattern as synthetic.tf).
resource "onepassword_item" "linear_mcp_oauth" {
  vault    = data.onepassword_vault.kubernetes.uuid
  title    = "linear-mcp-oauth"
  category = "login"

  section_map = {
    credentials = {
      field_map = {
        client_id = {
          type  = "STRING"
          value = "placeholder-create-the-linear-oauth-app"
        }
        client_secret = {
          type  = "CONCEALED"
          value = "placeholder-create-the-linear-oauth-app"
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [section_map]
  }
}
