resource "tailscale_acl" "main" {
  overwrite_existing_content = true

  acl = jsonencode({
    tagOwners = {
      "tag:k8s-operator" = ["autogroup:admin"]
      "tag:k8s-system"   = ["autogroup:admin"]
      "tag:k8s"          = ["autogroup:admin", "tag:k8s-operator"]
    }
    acls = [
      {
        action = "accept"
        src    = ["*"]
        dst    = ["*:443"]
      }
    ]
  })
}

resource "tailscale_oauth_client" "k8s_operator" {
  description = "willpxxr-live-hetzner Kubernetes operator"
  scopes      = ["devices:core", "auth_keys"]
  tags        = ["tag:k8s-operator"]

  depends_on = [tailscale_acl.main]
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

resource "kubernetes_namespace_v1" "tailscale" {
  metadata {
    name = "tailscale"
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
