module "talos" {
  source  = "hcloud-talos/talos/hcloud"
  version = "~> 3.1"

  hcloud_token = var.hetzner_token

  cluster_name  = "willpxxr-prod"
  location_name = "nbg1"

  # Firewall: restrict Kubernetes API (:6443) and Talos API (:50000) to the
  # Tailscale CGNAT range only. terraform apply must be run from a machine
  # connected to Tailscale/Meshnet.
  firewall_use_current_ip   = false
  firewall_kube_api_source  = ["100.64.0.0/10"]
  firewall_talos_api_source = ["100.64.0.0/10"]

  # Talos image — PREREQUISITE: the image must include the siderolabs/tailscale extension for
  # Tailscale integration to work. Generate a new schematic at https://factory.talos.dev
  # (add siderolabs/tailscale alongside the existing Hetzner extensions), upload the resulting
  # image or use Packer, then replace the schematic ID below.
  # Current schematic (ce4c980...) includes only Talos + qemu-guest-agent — no Tailscale.
  talos_image_id_x86 = data.hcloud_image.talos.id

  # 2× CX23 control planes.
  # Note: a 2-member etcd cluster requires both nodes for write quorum — losing either
  # makes the cluster read-only. Add a third control plane for true fault tolerance.
  control_plane_nodes = [
    { id = 1, type = "cx23" },
    { id = 2, type = "cx23" },
  ]

  # 2× CX23 workers.
  worker_nodes = [
    { id = 1, type = "cx23" },
    { id = 2, type = "cx23" },
  ]

  # VPN-only access: kubeconfig and talosconfig use private IPs.
  # Clients must be connected to Tailscale/Meshnet to reach the cluster.
  kubeconfig_endpoint_mode   = "private_ip"
  talosconfig_endpoints_mode = "private_ip"

  # Tailscale system extension — nodes join the Tailscale network on first boot.
  # Requires a Talos image built with the siderolabs/tailscale extension (see note above).
  tailscale = {
    enabled  = true
    auth_key = var.tailscale_auth_key
  }
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

