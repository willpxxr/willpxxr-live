locals {
  # Kubernetes version prefix to use for the DOKS cluster.
  # Update this to adopt a new minor version; auto_upgrade handles patch-level updates.
  kubernetes_version_prefix = "1.32."
}

data "digitalocean_kubernetes_versions" "main" {
  version_prefix = local.kubernetes_version_prefix
}

resource "digitalocean_kubernetes_cluster" "main" {
  name          = "willpxxr-prod"
  region        = "lon1"
  version       = data.digitalocean_kubernetes_versions.main.latest_version
  auto_upgrade  = true
  surge_upgrade = true

  node_pool {
    name       = "default"
    size       = "s-2vcpu-4gb"
    node_count = 1

    labels = {
      role = "general"
    }
  }
}
