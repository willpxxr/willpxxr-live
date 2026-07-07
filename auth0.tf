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

resource "auth0_role" "cicd_get" {
  name        = "cicd:get"
  description = "Grants access to the flux-operator UI (flux.tailb40090.ts.net)."
}

resource "auth0_role" "network_admin" {
  name        = "network:admin"
  description = "Grants access to the Hubble UI (hubble.tailb40090.ts.net)."
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
  ]
}

# Injects the user's Auth0 role names verbatim as a custom claim on both the
# ID and access tokens, so Envoy Gateway's SecurityPolicy authorization rules
# can match on them directly with no separate Resource Server/audience setup
# -- see auth0.tf's SecurityPolicy usage in apps/kube-system and
# apps/flux-operator-route for the consuming side.
resource "auth0_action" "inject_roles_claim" {
  name = "inject-roles-claim"

  supported_triggers {
    id      = "post-login"
    version = "v3"
  }

  runtime = "node22"
  deploy  = true

  code = <<-JS
    exports.onExecutePostLogin = async (event, api) => {
      const namespace = 'https://willpxxr.com';
      if (event.authorization) {
        api.idToken.setCustomClaim(`$${namespace}/scope`, event.authorization.roles);
        api.accessToken.setCustomClaim(`$${namespace}/scope`, event.authorization.roles);
      }
    };
  JS
}

resource "auth0_trigger_actions" "post_login" {
  trigger = "post-login"

  actions {
    id           = auth0_action.inject_roles_claim.id
    display_name = auth0_action.inject_roles_claim.name
  }
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
