# Valheim dedicated server password (WEP-0015). Randomly generated and written
# to 1Password by Terraform, same pattern as the ArgoCD redis auth
# (terraform/argocd.tf). The ExternalSecret in gitops:
# apps/valheim/externalsecret.yaml syncs the field into the cluster.
resource "random_password" "valheim_server_pass" {
  length  = 24
  special = false
}

resource "onepassword_item" "valheim" {
  vault    = data.onepassword_vault.kubernetes.uuid
  title    = "valheim"
  category = "login"

  section_map = {
    credentials = {
      field_map = {
        password = {
          type  = "CONCEALED"
          value = random_password.valheim_server_pass.result
        }
      }
    }
  }
}
