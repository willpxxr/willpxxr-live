# Scope naming convention for this file, applied consistently to every
# service protected by Auth0 (kept here since it's the one place all
# scopes are defined): "<resource>:<tier>", where <resource> is the actual
# service being protected (not an abstract domain -- hubble, not
# "network"), and <tier> is one of:
#   - get   -- read-only/view access to the resource's data (cicd:get)
#   - admin -- full administrative/management access
#   - use   -- invoke the resource's core function, for resources that
#              are fundamentally action-oriented rather than data-oriented
#              (llm:use, hubble:use -- neither is "read" in a CRUD sense,
#              they're dashboards/tools you use)
# These three are deliberately route-level access tiers, not CRUD
# operation-level permissions (get/list/create/update/delete) -- Envoy
# Gateway's SecurityPolicy authorization gates access to a whole route as
# one unit, not by HTTP method within it, so CRUD-style verbs would only
# make sense for a resource that genuinely needs per-operation splitting,
# and should replace (not sit alongside) admin for that resource to avoid
# overlap/ambiguity. New scopes should fit one of the three tiers above
# rather than inventing a new verb by default.
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

  # Confirmed live (and matching a known Auth0 community issue): without
  # this block explicitly set, refresh tokens were never actually issued
  # at all, even with offline_access requested, allow_offline_access
  # enabled on the resource server, and a forced consent screen. rotating
  # matches how the login script already behaves (it writes back the new
  # refresh token every time, per rotation's invalidate-on-use model) --
  # rotating requires expiration_type=expiring, which itself requires an
  # explicit token_lifetime -- leaving it computed/unset produced an
  # inconsistent client that broke the authorize flow entirely (Auth0's
  # own generic "Oops! something went wrong" error page). 30 days is a
  # reasonable lifetime for personal use, not guessed at length.
  refresh_token {
    rotation_type   = "rotating"
    expiration_type = "expiring"
    token_lifetime  = 2592000
  }
}

# Not a secret (public/native clients have no client_secret -- that's the
# whole point of PKCE), but persisted here anyway so it's easy to find
# for oauth2c logins/refreshes without digging through the Auth0
# dashboard each time. Lives in the terraform vault (same as
# talosconfig/kubeconfig in hetzner.tf), not the kubernetes vault --
# this is for local/operator use only, the cluster has no business
# reading it.
resource "onepassword_item" "ai_gateway_llm" {
  vault    = data.onepassword_vault.terraform.uuid
  title    = "ai-gateway-llm-oauth2c"
  category = "login"

  section_map = {
    credentials = {
      field_map = {
        client_id = {
          type  = "CONCEALED"
          value = auth0_client.ai_gateway_llm.client_id
        }
        issuer = {
          type  = "CONCEALED"
          value = "https://auth.willpxxr.com"
        }
        audience = {
          type  = "CONCEALED"
          value = "https://ai.tailb40090.ts.net"
        }
      }
    }
  }
}

# Same shape as ai_gateway_llm above, for the MCP gateway. MCPRoute's own
# OAuth mechanism (MCP spec's RFC 8414/9728-based discovery) supports
# Dynamic Client Registration for generic clients that don't already have
# credentials, but that's not needed here -- this is a pre-registered
# client for personal/single-user oauth2c use, same as the LLM gateway.
resource "auth0_client" "ai_gateway_mcp" {
  name        = "willpxxr-live-ai-gateway-mcp"
  description = "Native/public client used by oauth2c for the self-hosted MCP gateway (mcp.tailb40090.ts.net)."
  app_type    = "native"

  oidc_conformant = true
  grant_types     = ["authorization_code", "refresh_token"]

  callbacks = [
    "http://localhost:9876/callback",
  ]

  jwt_configuration {
    alg = "RS256"
  }

  # Same fix as ai_gateway_llm above, including the explicit
  # token_lifetime (required alongside expiration_type=expiring, missing
  # it broke the authorize flow entirely). Note this only helps if
  # scripts/ai-gateway-login.sh mcp (using this pre-registered client) is
  # used directly -- opencode's own native MCP OAuth uses a separately
  # DCR-created client instead, which this Terraform resource doesn't
  # manage, so this fix may not apply to that path.
  refresh_token {
    rotation_type   = "rotating"
    expiration_type = "expiring"
    token_lifetime  = 2592000
  }
}

resource "onepassword_item" "ai_gateway_mcp" {
  vault    = data.onepassword_vault.terraform.uuid
  title    = "ai-gateway-mcp-oauth2c"
  category = "login"

  section_map = {
    credentials = {
      field_map = {
        client_id = {
          type  = "CONCEALED"
          value = auth0_client.ai_gateway_mcp.client_id
        }
        issuer = {
          type  = "CONCEALED"
          value = "https://auth.willpxxr.com"
        }
        audience = {
          type = "CONCEALED"
          # Was a hardcoded literal string -- went stale when
          # auth0_resource_server.ai_mcp.identifier was changed to add
          # the /mcp path (fixing the earlier "Service not found" bug)
          # and this dependent value was never updated, causing
          # access_denied on login (requesting an audience that no
          # longer matched any resource server). Real Terraform
          # reference now, so it can't drift out of sync again.
          value = auth0_resource_server.ai_mcp.identifier
        }
      }
    }
  }
}

resource "auth0_role" "cicd_get" {
  name        = "cicd:get"
  description = "Grants access to the flux-operator UI (flux.tailb40090.ts.net)."
}

resource "auth0_role" "hubble_use" {
  name        = "hubble:use"
  description = "Grants access to the Hubble UI (hubble.tailb40090.ts.net) -- a network flow observability dashboard, not something administered through it."
}

resource "auth0_role" "llm_use" {
  name        = "llm:use"
  description = "Grants access to the self-hosted LLM gateway (ai.tailb40090.ts.net), proxying to the OpenCode Go subscription."
}

# Deliberately separate from llm_use, not folded into it -- explicit
# consent to the models this gates (see auth0_resource_server_scopes.ai_llm
# above) shouldn't be implied just by having general gateway access.
resource "auth0_role" "llm_free_use" {
  name        = "llm-free:use"
  description = "Grants access to the self-hosted LLM gateway's free-tier models, which are served in exchange for prompt logging/training by the underlying provider (OpenRouter) -- a separate consent from general gateway access."
}

resource "auth0_role" "mcp_use" {
  name        = "mcp:use"
  description = "Grants access to the self-hosted MCP gateway (mcp.tailb40090.ts.net)."
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
    auth0_role.hubble_use.id,
    auth0_role.llm_use.id,
    auth0_role.llm_free_use.id,
    auth0_role.mcp_use.id,
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
    # which renders badly for scope names like these (e.g. the original
    # "network:admin" rendered as "Admin: network your admin"). This makes
    # it use the scopes' own description text below instead.
    use_scope_descriptions_for_consent = true

    # Required for opencode's native MCP OAuth (RFC 7591 Dynamic Client
    # Registration) -- confirmed live: without this, DCR attempts against
    # /oidc/register fail even though the endpoint is advertised in the
    # authorization server metadata, since Auth0 disables DCR tenant-wide
    # by default regardless of what's advertised. This is a genuinely
    # tenant-wide toggle, not scoped to the MCP resource server alone --
    # per Auth0's own docs, anyone can register a new application without
    # a token once this is on.
    enable_dynamic_client_registration = true

    # Required alongside DCR above -- confirmed live via an actual Auth0
    # log entry ("no connections enabled for the client"): a
    # dynamically-registered client doesn't automatically get any identity
    # provider connections (e.g. the Google social connection you actually
    # log in with) enabled for it, and there's no way to configure that
    # per-client during DCR itself, same class of problem as the client
    # grant fix above. This is also genuinely tenant-wide -- it applies to
    # every future client, not just DCR-created ones.
    enable_client_connections = true
  }
}

# Dedicated Resource Server per service (rather than one shared
# "internal-services" API) -- hubble and flux-operator are unrelated
# services that happen to share a client today; splitting them now keeps
# each API's scope list scoped to just its own concerns as more get added,
# and shows as two clearly-named entries in Auth0's dashboard instead of
# one ambiguous shared one. A real API/Resource Server is what makes
# Auth0's consent screen show actual scope names in the first place --
# there's no way to get genuine user consent from a bare custom token
# claim, which is what the previous (now-removed) Action-based approach did.
resource "auth0_resource_server" "hubble" {
  name       = "willpxxr-live hubble"
  identifier = "https://hubble.tailb40090.ts.net"

  enforce_policies = true
  token_dialect    = "access_token_authz"

  # Explicit: this app is first-party, and Auth0's default for first-party
  # apps is to silently skip consent -- which would defeat the entire point
  # of this change if left at its default.
  skip_consent_for_verifiable_first_party_clients = false
}

resource "auth0_resource_server_scopes" "hubble" {
  resource_server_identifier = auth0_resource_server.hubble.identifier

  scopes {
    name        = "hubble:use"
    description = "View network flow data in Hubble"
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

  # Confirmed live: without this, Auth0 silently drops the offline_access
  # scope from issued tokens regardless of what the client requests --
  # refresh tokens can't be issued for a resource server that doesn't
  # allow it, no matter how the authorization request is shaped.
  allow_offline_access = true
}

resource "auth0_resource_server_scopes" "ai_llm" {
  resource_server_identifier = auth0_resource_server.ai_llm.identifier

  scopes {
    name        = "llm:use"
    description = "Use the self-hosted LLM gateway"
  }

  # Separate scope (not folded into llm:use) gating the specific models
  # OpenRouter only serves in exchange for prompt logging/training data
  # usage -- confirmed live via OpenRouter's own "no endpoints available
  # matching your ... data policy" error. Named as its own resource
  # (llm-free, not a new tier on llm) to keep the <resource>:<tier>
  # convention at the top of this file intact rather than inventing a
  # fourth tier. Enforced by security-policy-free.yaml, which requires
  # both llm:use and llm-free:use together (AND semantics, confirmed via
  # the live SecurityPolicy CRD field description) -- holding llm:use
  # alone must not imply consent to this.
  scopes {
    name        = "llm-free:use"
    description = "Use the self-hosted LLM gateway's free-tier models (served in exchange for prompt logging/training by the underlying provider)"
  }
}

resource "auth0_resource_server" "ai_mcp" {
  name = "willpxxr-live ai-mcp"
  # Must match MCPRoute.spec.securityPolicy.oauth.protectedResourceMetadata.resource
  # exactly (gitops apps/ai-gateway-mcp/mcp-route.yaml) -- confirmed live via an
  # actual Auth0 log entry ("Service not found: https://mcp.tailb40090.ts.net/mcp"):
  # the MCP spec (RFC 9728) requires the resource to be the full MCP endpoint URL
  # including its path, not just the bare host the LLM gateway uses. identifier is
  # ForceNew, so this replaces the resource server (and its dependent scopes/
  # role_permissions, handled automatically).
  identifier = "https://mcp.tailb40090.ts.net/mcp"

  enforce_policies                                = true
  token_dialect                                   = "access_token_authz"
  skip_consent_for_verifiable_first_party_clients = false

  # Same fix as ai_llm above -- opencode's native MCP OAuth also needs
  # real refresh tokens to actually work.
  allow_offline_access = true
}

resource "auth0_resource_server_scopes" "ai_mcp" {
  resource_server_identifier = auth0_resource_server.ai_mcp.identifier

  scopes {
    name        = "mcp:use"
    description = "Use the self-hosted MCP gateway"
  }
}

# Required for opencode's DCR-created client to access this API at all --
# confirmed live via an actual Auth0 log entry ("Client ... is not
# authorized to access resource server ..."): Auth0 has no way to
# configure per-application client grants during the DCR flow itself
# (there's no application to attach a grant to until after registration),
# so third-party/DCR clients need a default_for grant instead, applied to
# ALL such clients rather than one specific client_id (mutually exclusive
# with client_id). This is scoped to just llm:use's mcp equivalent
# (mcp:use), matching the scope already granted to the user via their
# role -- DCR clients still only work for a user who's actually entitled.
#
# subject_type = "user" specifically (not the default "client") -- Auth0's
# dashboard splits default third-party permissions into two independent
# categories, User-delegated Access and Client Access. opencode's MCP
# OAuth is Authorization Code + PKCE, a real user login, never
# client_credentials/M2M, so only the "user" grant is needed; a "client"
# one would just be unused scope creep for a flow that's never exercised
# here. Confirmed live: the first attempt (without subject_type, which
# defaults to "client") granted Client Access but left User-delegated
# Access at 0/1 in the dashboard, which is what actually blocked opencode.
resource "auth0_client_grant" "ai_mcp_third_party_default_user" {
  default_for  = "third_party_clients"
  audience     = auth0_resource_server.ai_mcp.identifier
  scopes       = ["mcp:use"]
  subject_type = "user"

  depends_on = [auth0_resource_server_scopes.ai_mcp]
}

# Links each role to the permission (scope) it actually grants -- the RBAC
# gate: a user can request/consent to a scope, but Auth0 only issues it if
# they're entitled via a role like this.
#
# depends_on is required here: these resources only reference
# auth0_resource_server (the API itself) by identifier, a plain string --
# there's no attribute reference to auth0_resource_server_scopes (the
# resource that actually creates the cicd:get/hubble:use permissions),
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

resource "auth0_role_permissions" "hubble_use" {
  role_id = auth0_role.hubble_use.id

  permissions {
    name                       = "hubble:use"
    resource_server_identifier = auth0_resource_server.hubble.identifier
  }

  depends_on = [auth0_resource_server_scopes.hubble]
}

resource "auth0_role_permissions" "llm_use" {
  role_id = auth0_role.llm_use.id

  permissions {
    name                       = "llm:use"
    resource_server_identifier = auth0_resource_server.ai_llm.identifier
  }

  depends_on = [auth0_resource_server_scopes.ai_llm]
}

resource "auth0_role_permissions" "llm_free_use" {
  role_id = auth0_role.llm_free_use.id

  permissions {
    name                       = "llm-free:use"
    resource_server_identifier = auth0_resource_server.ai_llm.identifier
  }

  depends_on = [auth0_resource_server_scopes.ai_llm]
}

resource "auth0_role_permissions" "mcp_use" {
  role_id = auth0_role.mcp_use.id

  permissions {
    name                       = "mcp:use"
    resource_server_identifier = auth0_resource_server.ai_mcp.identifier
  }

  depends_on = [auth0_resource_server_scopes.ai_mcp]
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

# The Google social connection you actually log in with (hubble/flux/llm/
# mcp all rely on it) was created manually via the dashboard, not
# Terraform -- this imports it as a MINIMAL stub deliberately, setting
# only is_domain_connection, not the connection's full configuration
# (client_id/secret, allowed clients, etc). Confirmed live via an actual
# Auth0 log entry ("no connections enabled for the client"): DCR-created
# clients get no identity provider connections enabled by default, and
# per Auth0 staff (community forum), there's no way to set a default
# connection for future applications generally -- marking a specific
# connection as domain-level is the only confirmed-working mechanism.
# enable_client_connections (tenant flag, see flags block above) does
# NOT cover DCR-created clients specifically, confirmed live -- it was
# insufficient on its own.
#
# IMPORTANT: review the plan output carefully before applying this --
# `name` is ForceNew, so if it doesn't exactly match the live connection,
# Terraform will want to destroy and recreate a connection that
# EVERYTHING (hubble, flux, the LLM gateway, the MCP gateway) actually
# depends on for login. Everything below other than is_domain_connection
# is intentionally omitted rather than guessed, to let Terraform/Auth0's
# provider read the real values on import instead.
import {
  to = auth0_connection.google
  id = "con_MtURC6dEAyIsh3No"
}

resource "auth0_connection" "google" {
  name     = "google-oauth2"
  strategy = "google-oauth2"

  is_domain_connection = true
}
