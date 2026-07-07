resource "auth0_client" "envoy_gateway_oidc" {
  name        = "willpxxr-live-envoy-gateway-oidc"
  description = "Confidential client used by Envoy Gateway SecurityPolicy (native OIDC) for hubble/flux-operator"
  app_type    = "regular_web"

  oidc_conformant = true
  grant_types     = ["authorization_code", "refresh_token"]

  callbacks = [
    "https://hubble.tailb40090.ts.net/oauth2/callback",
    "https://flux.tailb40090.ts.net/oauth2/callback",
  ]
  allowed_logout_urls = [
    "https://hubble.tailb40090.ts.net",
    "https://flux.tailb40090.ts.net",
  ]
  web_origins = [
    "https://hubble.tailb40090.ts.net",
    "https://flux.tailb40090.ts.net",
  ]

  jwt_configuration {
    alg = "RS256"
  }
}

# auth0_client has no client_secret attribute -- it's exposed only via this
# separate resource. Requires the Management API M2M app to also have the
# read:client_credentials (or read:client_keys) grant, in addition to the
# client CRUD grants needed for auth0_client itself.
resource "auth0_client_credentials" "envoy_gateway_oidc" {
  client_id             = auth0_client.envoy_gateway_oidc.client_id
  authentication_method = "client_secret_post"
}

# Native/public client for oauth2c (github.com/cloudentity/oauth2c) --
# a mature, actively maintained OAuth2 CLI, not custom-built code -- to
# perform the Authorization Code + PKCE login (and later, refresh-token
# grant) against Auth0 on behalf of the crush CLI, which has no built-in
# support for arbitrary custom OAuth issuers. Deliberately separate from
# envoy_gateway_oidc, which is a confidential (regular_web) client for the
# browser-based hubble/flux flows. PKCE public clients authenticate with a
# code_verifier instead of a secret, so intentionally no
# auth0_client_credentials resource for this one -- there's nothing to
# store.
resource "auth0_client" "ai_gateway_llm" {
  name        = "willpxxr-live-ai-gateway-llm"
  description = "Native/public client used by oauth2c for the self-hosted LLM gateway (ai.tailb40090.ts.net), consumed by the crush CLI."
  app_type    = "native"

  oidc_conformant = true
  grant_types     = ["authorization_code", "refresh_token"]

  # oauth2c's own default redirect/callback listener -- using it as-is
  # avoids needing any custom code or non-default flags for the flow.
  callbacks = [
    "http://localhost:9876/callback",
  ]

  jwt_configuration {
    alg = "RS256"
  }
}

resource "auth0_role" "cicd_get" {
  name        = "cicd:get"
  description = "Grants access to the flux-operator UI (flux.tailb40090.ts.net)."
}

resource "auth0_role" "network_admin" {
  name        = "network:admin"
  description = "Grants access to the Hubble UI (hubble.tailb40090.ts.net)."
}

resource "auth0_role" "llm_use" {
  name        = "llm:use"
  description = "Grants access to the self-hosted LLM gateway (ai.tailb40090.ts.net), proxying to the OpenCode Go subscription."
}

data "auth0_user" "will" {
  query = "email:\"williamparr96@gmail.com\""
}

resource "auth0_user_roles" "will" {
  # The data source only populates the implicit .id via data.SetId() when
  # looked up by query (not the separate user_id schema field, which stays
  # empty unless user_id -- not query -- was the lookup input).
  user_id = data.auth0_user.will.id
  roles = [
    auth0_role.cicd_get.id,
    auth0_role.network_admin.id,
    auth0_role.llm_use.id,
  ]
}

# Required for Envoy Gateway's oidc.resources field, which sends the RFC
# 8707 'resource' authorization-request parameter -- Auth0's native
# equivalent is 'audience', and it only also honors 'resource' when this
# tenant-wide compatibility profile is set. Per Auth0's own docs this is
# additive: if both audience and resource are present, audience still wins,
# so this doesn't change behavior for anything already using audience.
# auth0_tenant is a singleton resource; only these fields are declared so
# Terraform only touches them, not the whole tenant configuration.
resource "auth0_tenant" "main" {
  resource_parameter_profile = "compatibility"

  flags {
    # By default Auth0's consent screen auto-generates its permission text
    # from the scope name alone (splitting on ':' and guessing a verb/noun),
    # which renders badly for names like "network:admin" (e.g. "Admin:
    # network your admin"). This makes it use the scopes' own description
    # text below instead.
    use_scope_descriptions_for_consent = true
  }
}

# Dedicated Resource Server per logical service domain (rather than one
# shared "internal-services" API) -- networking and cicd are unrelated
# domains that happen to share a client today; splitting them now keeps
# each API's scope list scoped to just its own concerns as more get added,
# and shows as two clearly-named entries in Auth0's dashboard instead of
# one ambiguous shared one. A real API/Resource Server is what makes
# Auth0's consent screen show actual scope names in the first place --
# there's no way to get genuine user consent from a bare custom token
# claim, which is what the previous (now-removed) Action-based approach did.
resource "auth0_resource_server" "networking" {
  name       = "willpxxr-live networking"
  identifier = "https://hubble.tailb40090.ts.net"

  enforce_policies = true
  token_dialect    = "access_token_authz"

  # Explicit: this app is first-party, and Auth0's default for first-party
  # apps is to silently skip consent -- which would defeat the entire point
  # of this change if left at its default.
  skip_consent_for_verifiable_first_party_clients = false
}

resource "auth0_resource_server_scopes" "networking" {
  resource_server_identifier = auth0_resource_server.networking.identifier

  scopes {
    name        = "network:admin"
    description = "View and administer network traffic data"
  }
}

resource "auth0_resource_server" "cicd" {
  name       = "willpxxr-live cicd"
  identifier = "https://flux.tailb40090.ts.net"

  enforce_policies                                = true
  token_dialect                                   = "access_token_authz"
  skip_consent_for_verifiable_first_party_clients = false
}

resource "auth0_resource_server_scopes" "cicd" {
  resource_server_identifier = auth0_resource_server.cicd.identifier

  scopes {
    name        = "cicd:get"
    description = "View deployment and CI/CD pipeline status"
  }
}

resource "auth0_resource_server" "ai_llm" {
  name       = "willpxxr-live ai-llm"
  identifier = "https://ai.tailb40090.ts.net"

  enforce_policies                                = true
  token_dialect                                   = "access_token_authz"
  skip_consent_for_verifiable_first_party_clients = false
}

resource "auth0_resource_server_scopes" "ai_llm" {
  resource_server_identifier = auth0_resource_server.ai_llm.identifier

  scopes {
    name        = "llm:use"
    description = "Use the self-hosted LLM gateway"
  }
}

# Links each role to the permission (scope) it actually grants -- the RBAC
# gate: a user can request/consent to a scope, but Auth0 only issues it if
# they're entitled via a role like this.
#
# depends_on is required here: these resources only reference
# auth0_resource_server (the API itself) by identifier, a plain string --
# there's no attribute reference to auth0_resource_server_scopes (the
# resource that actually creates the cicd:get/network:admin permissions),
# so Terraform has no implicit edge forcing the scopes to exist first and
# can otherwise try to link a permission that doesn't exist yet.
resource "auth0_role_permissions" "cicd_get" {
  role_id = auth0_role.cicd_get.id

  permissions {
    name                       = "cicd:get"
    resource_server_identifier = auth0_resource_server.cicd.identifier
  }

  depends_on = [auth0_resource_server_scopes.cicd]
}

resource "auth0_role_permissions" "network_admin" {
  role_id = auth0_role.network_admin.id

  permissions {
    name                       = "network:admin"
    resource_server_identifier = auth0_resource_server.networking.identifier
  }

  depends_on = [auth0_resource_server_scopes.networking]
}

resource "auth0_role_permissions" "llm_use" {
  role_id = auth0_role.llm_use.id

  permissions {
    name                       = "llm:use"
    resource_server_identifier = auth0_resource_server.ai_llm.identifier
  }

  depends_on = [auth0_resource_server_scopes.ai_llm]
}

resource "onepassword_item" "envoy_gateway_oidc" {
  vault    = data.onepassword_vault.kubernetes.uuid
  title    = "envoy-gateway-oidc"
  category = "login"

  section_map = {
    credentials = {
      field_map = {
        # The pre-configured custom domain (Auth0 branding), not the raw
        # tenant domain used by the Terraform provider for Management API
        # calls -- Auth0 requires end-user-facing auth flows (and therefore
        # Envoy Gateway's OIDC issuer) to consistently use the custom domain
        # once one is set up, rather than mixing it with the tenant domain.
        domain = {
          type  = "CONCEALED"
          value = "auth.willpxxr.com"
        }
        client_id = {
          type  = "CONCEALED"
          value = auth0_client.envoy_gateway_oidc.client_id
        }
        client_secret = {
          type  = "CONCEALED"
          value = auth0_client_credentials.envoy_gateway_oidc.client_secret
        }
      }
    }
  }
}

# Unlike envoy_gateway_oidc above, this key has no Terraform-computed
# source -- it's a manually-obtained OpenCode Go subscription key (from
# https://opencode.ai/auth), pasted in by hand after this resource creates
# the item shell. ignore_changes on section_map is required: without it,
# every `terraform apply` would reset the real key back to this placeholder,
# silently breaking the LLM gateway.
resource "onepassword_item" "opencode_go" {
  vault    = data.onepassword_vault.kubernetes.uuid
  title    = "opencode-go"
  category = "login"

  section_map = {
    credentials = {
      field_map = {
        api_key = {
          type  = "CONCEALED"
          value = "REPLACE_ME_MANUALLY_FROM_OPENCODE_AI_AUTH_CONSOLE"
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [section_map]
  }
}
