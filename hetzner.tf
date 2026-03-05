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

  # Talos image — built by Packer (packer/talos/talos.pkr.hcl) from the schematic in
  # packer/talos/schematic.yaml, which includes siderolabs/qemu-guest-agent and
  # siderolabs/tailscale. Run `packer build packer/talos/talos.pkr.hcl` once per Talos
  # version upgrade; the data source below resolves the most-recently pushed snapshot.
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

# Resolve the Talos snapshot built by Packer (packer/talos/talos.pkr.hcl).
# The snapshot is labelled os=talos,tailscale=true and includes both
# siderolabs/qemu-guest-agent and siderolabs/tailscale.
data "hcloud_image" "talos" {
  with_selector     = "os=talos,tailscale=true"
  with_architecture = "x86"
  most_recent       = true
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

