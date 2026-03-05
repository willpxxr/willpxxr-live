module "talos" {
  source  = "hcloud-talos/talos/hcloud"
  version = "~> 3.1"

  hcloud_token = var.hetzner_token

  cluster_name  = "willpxxr-prod"
  location_name = "nbg1"

  # Firewall: restrict Kubernetes API (:6443) and Talos API (:50000) to VPN only.
  # terraform apply for initial bootstrap must be run from a machine inside the VPN.
  firewall_use_current_ip   = false
  firewall_kube_api_source  = var.vpn_cidrs
  firewall_talos_api_source = var.vpn_cidrs

  # Use the Hetzner-provided public Talos image (schematic: Talos + qemu-guest-agent).
  # Available as a public image since 2025-04-23; no manual snapshot upload required.
  # https://factory.talos.dev/?schematic=ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515
  talos_image_id_x86 = data.hcloud_image.talos.id

  # 2× CX22 control planes (2 vCPU / 4 GB RAM / 40 GB NVMe).
  # Note: a 2-member etcd cluster requires both nodes for write quorum — losing either
  # makes the cluster read-only. Add a third control plane for true fault tolerance.
  control_plane_nodes = [
    { id = 1, type = "cx22" },
    { id = 2, type = "cx22" },
  ]

  # 2× CX22 workers (2 vCPU / 4 GB RAM / 40 GB NVMe).
  worker_nodes = [
    { id = 1, type = "cx22" },
    { id = 2, type = "cx22" },
  ]

  # VPN-only access: kubeconfig and talosconfig use private IPs.
  # Clients must be connected to Tailscale/Meshnet to reach the cluster.
  kubeconfig_endpoint_mode   = "private_ip"
  talosconfig_endpoints_mode = "private_ip"

  # Flux manages CNI and CCM post-bootstrap; disable Terraform-driven deployments.
  deploy_cilium    = false
  deploy_hcloud_ccm = false
}

# Resolve the public Talos image provided by Hetzner Cloud using the schematic ID.
# No manual snapshot upload required.
data "hcloud_image" "talos" {
  name              = "ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515"
  with_architecture = "x86"
}

# Expose the Talos client config so operators can manage the cluster via VPN:
#   terraform output -raw talosconfig > ~/.talos/config
#   talosctl bootstrap --nodes <first-control-plane-private-ip>
#   talosctl kubeconfig --nodes <first-control-plane-private-ip>
output "talosconfig" {
  description = "Talos client configuration — use via VPN to bootstrap and manage the cluster"
  value       = module.talos.talosconfig
  sensitive   = true
}

# Expose the kubeconfig for cluster access via VPN:
#   terraform output -raw kubeconfig > ~/.kube/willpxxr-prod.yaml
output "kubeconfig" {
  description = "Kubeconfig for the willpxxr-prod cluster — use via VPN"
  value       = module.talos.kubeconfig
  sensitive   = true
}

