resource "tailscale_tailnet_key" "cluster_nodes" {
  reusable      = true
  ephemeral     = false
  preauthorized = true
  description   = "willpxxr-live Hetzner/Talos cluster node enrollment"
}

module "talos" {
  source  = "hcloud-talos/talos/hcloud"
  version = "~> 3.1"

  hcloud_token = var.hetzner_token

  cluster_name  = "willpxxr-prod"
  location_name = "nbg1"

  # Firewall: restrict Kubernetes API (:6443) and Talos API (:50000) to the
  # Tailscale CGNAT range only. terraform apply must be run from a machine
  # connected to Tailscale, or via the TFC OIDC bridge for in-cluster resources.
  firewall_use_current_ip   = false
  firewall_kube_api_source  = ["100.64.0.0/10"]
  firewall_talos_api_source = ["100.64.0.0/10"]

  # Talos image — built by Packer (packer/talos/talos.pkr.hcl) from the schematic in
  # packer/talos/schematic.yaml, which includes siderolabs/qemu-guest-agent and
  # siderolabs/tailscale. Run `packer build packer/talos/talos.pkr.hcl` once per Talos
  # version upgrade; the data source below resolves the most-recently pushed snapshot.
  talos_image_id_x86 = data.hcloud_image.talos.id

  # 2x CX23 control planes.
  # Note: a 2-member etcd cluster requires both nodes for write quorum -- losing either
  # makes the cluster read-only. Add a third control plane for true fault tolerance.
  control_plane_nodes = [
    { id = 1, type = "cx23" },
    { id = 2, type = "cx23" },
  ]

  # 2x CX23 workers.
  worker_nodes = [
    { id = 1, type = "cx23" },
    { id = 2, type = "cx23" },
  ]

  # VPN-only access: kubeconfig and talosconfig use private IPs.
  # Clients must be connected to Tailscale to reach the cluster.
  kubeconfig_endpoint_mode   = "private_ip"
  talosconfig_endpoints_mode = "private_ip"

  # Tailscale system extension -- nodes join the tailnet on first boot using a
  # Terraform-managed reusable pre-authorized key, rather than a manually pasted one.
  tailscale = {
    enabled  = true
    auth_key = tailscale_tailnet_key.cluster_nodes.key
  }
}

# Resolve the Talos snapshot built by Packer (packer/talos/talos.pkr.hcl).
# The snapshot is labelled os=talos,tailscale=true and includes both
# siderolabs/qemu-guest-agent and siderolabs/tailscale.
data "hcloud_image" "talos" {
  with_selector     = "os=talos,tailscale=true"
  with_architecture = "x86"
  most_recent       = true
}

locals {
  talos_kubeconfig = yamldecode(module.talos.kubeconfig)
}

provider "kubernetes" {
  host                   = local.talos_kubeconfig["clusters"][0]["cluster"]["server"]
  cluster_ca_certificate = base64decode(local.talos_kubeconfig["clusters"][0]["cluster"]["certificate-authority-data"])
  client_certificate     = base64decode(local.talos_kubeconfig["users"][0]["user"]["client-certificate-data"])
  client_key             = base64decode(local.talos_kubeconfig["users"][0]["user"]["client-key-data"])
}

provider "helm" {
  kubernetes = {
    host                   = local.talos_kubeconfig["clusters"][0]["cluster"]["server"]
    cluster_ca_certificate = base64decode(local.talos_kubeconfig["clusters"][0]["cluster"]["certificate-authority-data"])
    client_certificate     = base64decode(local.talos_kubeconfig["users"][0]["user"]["client-certificate-data"])
    client_key             = base64decode(local.talos_kubeconfig["users"][0]["user"]["client-key-data"])
  }
}

# Expose the Talos client config so operators can manage the cluster via Tailscale:
#   terraform output -raw talosconfig > ~/.talos/config
#   talosctl bootstrap --nodes <first-control-plane-private-ip>
#   talosctl kubeconfig --nodes <first-control-plane-private-ip>
output "talosconfig" {
  description = "Talos client configuration -- use via Tailscale to bootstrap and manage the cluster"
  value       = module.talos.talosconfig
  sensitive   = true
}

# Expose the kubeconfig for cluster access via Tailscale:
#   terraform output -raw kubeconfig > ~/.kube/willpxxr-prod.yaml
output "kubeconfig" {
  description = "Kubeconfig for the willpxxr-prod cluster -- use via Tailscale"
  value       = module.talos.kubeconfig
  sensitive   = true
}

module "flux_operator_bootstrap" {
  source  = "controlplaneio-fluxcd/flux-operator-bootstrap/kubernetes"
  version = "0.7.0"

  revision = 1

  gitops_resources = {
    instance_yaml = file("${path.root}/gitops/clusters/de/hetzner/cluster/flux-system/flux-instance.yaml")
  }

  depends_on = [module.talos]
}
