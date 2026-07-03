resource "auth0_client" "oauth_proxy" {
  name        = "willpxxr-live-oauth-proxy"
  description = "oauth2-proxy confidential client fronting Traefik-routed services via ForwardAuth"
  app_type    = "regular_web"

  oidc_conformant = true
  grant_types     = ["authorization_code", "refresh_token"]

  callbacks           = ["https://oauth.tailb40090.ts.net/oauth2/callback"]
  allowed_logout_urls = ["https://oauth.tailb40090.ts.net"]
  web_origins         = ["https://oauth.tailb40090.ts.net"]

  jwt_configuration {
    alg = "RS256"
  }
}

# auth0_client has no client_secret attribute -- it's exposed only via this
# separate resource. Requires the Management API M2M app to also have the
# read:client_credentials (or read:client_keys) grant, in addition to the
# client CRUD grants needed for auth0_client itself.
resource "auth0_client_credentials" "oauth_proxy" {
  client_id             = auth0_client.oauth_proxy.client_id
  authentication_method = "client_secret_post"
}

resource "random_password" "oauth2_proxy_cookie_secret" {
  length  = 32
  special = false
}

resource "onepassword_item" "oauth2_proxy" {
  vault    = data.onepassword_vault.kubernetes.uuid
  title    = "oauth2-proxy-auth0"
  category = "login"

  section_map = {
    credentials = {
      field_map = {
        # The pre-configured custom domain (Auth0 branding), not the raw
        # tenant domain used by the Terraform provider for Management API
        # calls -- Auth0 requires end-user-facing auth flows (and therefore
        # oauth2-proxy's OIDC issuer) to consistently use the custom domain
        # once one is set up, rather than mixing it with the tenant domain.
        domain = {
          type  = "CONCEALED"
          value = "auth.willpxxr.com"
        }
        client_id = {
          type  = "CONCEALED"
          value = auth0_client.oauth_proxy.client_id
        }
        client_secret = {
          type  = "CONCEALED"
          value = auth0_client_credentials.oauth_proxy.client_secret
        }
        cookie_secret = {
          type  = "CONCEALED"
          value = random_password.oauth2_proxy_cookie_secret.result
        }
      }
    }
  }
}
