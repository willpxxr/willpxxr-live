resource "tailscale_oauth_client" "k8s_operator" {
  description = "willpxxr-live-ovh Kubernetes operator"
  # Verify these scope identifiers against the Tailscale admin console's
  # OAuth client scope picker before relying on this apply succeeding --
  # could not get fully authoritative confirmation of the exact scope
  # string format from Tailscale's docs.
  scopes = ["devices:core:write", "auth_keys:write"]
  tags   = ["tag:k8s-operator"]
}

data "onepassword_vault" "kubernetes" {
  name = var.onepassword_vault
}

resource "onepassword_item" "tailscale_operator_oauth" {
  vault    = data.onepassword_vault.kubernetes.uuid
  title    = "tailscale-operator-oauth"
  category = "login"

  section_map = {
    credentials = {
      field_map = {
        client_id = {
          type  = "CONCEALED"
          value = tailscale_oauth_client.k8s_operator.id
        }
        client_secret = {
          type  = "CONCEALED"
          value = tailscale_oauth_client.k8s_operator.key
        }
      }
    }
  }
}

resource "kubernetes_namespace_v1" "external_secrets" {
  metadata {
    name = "external-secrets"
  }
}

data "onepassword_item" "eso_service_account_token" {
  vault = data.onepassword_vault.kubernetes.uuid
  title = "Service Account Auth Token: Kubernetes Read Only"
}

resource "kubernetes_secret_v1" "onepassword_service_account_token" {
  metadata {
    name      = "onepassword-service-account-token"
    namespace = kubernetes_namespace_v1.external_secrets.metadata[0].name
  }

  data = {
    token = data.onepassword_item.eso_service_account_token.credential
  }
}
