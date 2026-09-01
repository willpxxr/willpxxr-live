# Redis auth secret for ArgoCD (gitops: apps/argocd/). Generated here rather
# than by the chart's one-shot init Job: ArgoCD treats Jobs as sync hooks and
# the init job waits on a rollout the same sync must apply (deadlock ->
# 10m timeout -> failed hook -> stuck sync), so the secret is provisioned the
# repo-standard way instead -- random value -> 1Password kubernetes vault ->
# ExternalSecret (apps/argocd/externalsecret-redis.yaml). Rotating = new
# random_password here + a rollout of the argocd workloads (they read the
# auth value at startup).
resource "random_password" "argocd_redis_auth" {
  length  = 32
  special = false
}

resource "onepassword_item" "argocd_redis" {
  vault    = data.onepassword_vault.kubernetes.uuid
  title    = "argocd-redis"
  category = "login"

  section_map = {
    credentials = {
      field_map = {
        auth = {
          type  = "CONCEALED"
          value = random_password.argocd_redis_auth.result
        }
      }
    }
  }
}
