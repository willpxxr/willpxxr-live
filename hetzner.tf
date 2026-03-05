locals {
  # Schematic ID for the public Talos image provided by Hetzner Cloud (Talos + qemu-guest-agent).
  # Available as a public Hetzner image since 2025-04-23; minor patch updates are managed by Hetzner.
  # https://factory.talos.dev/?schematic=ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515
  talos_schematic = "ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515"

  # Explicit IP assignments. Counts are derived from list length to prevent drift.
  control_plane_ips = ["10.0.1.1", "10.0.1.2"]
  worker_ips        = ["10.0.1.11", "10.0.1.12"]

  # Private IP of the load balancer — used as the stable cluster endpoint.
  # Access via VPN (Tailscale/Meshnet) which routes into the Hetzner private network.
  lb_private_ip = "10.0.1.254"
}

# Resolve the public Talos image provided by Hetzner Cloud using the schematic ID.
# No manual snapshot upload required.
data "hcloud_image" "talos" {
  name              = local.talos_schematic
  with_architecture = "x86"
}

# Private network for intra-cluster traffic
resource "hcloud_network" "main" {
  name     = "willpxxr-prod"
  ip_range = "10.0.0.0/16"
}

resource "hcloud_network_subnet" "main" {
  network_id   = hcloud_network.main.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = "10.0.1.0/24"
}

# Firewall: restrict Kubernetes API (:6443) and Talos API (:50000) to the private
# network and VPN only. Servers receive the Talos machine config via user_data at
# first boot, so the Talos API never needs to be reachable from the public internet.
resource "hcloud_firewall" "main" {
  name = "willpxxr-prod"

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "6443"
    source_ips  = concat(["10.0.0.0/16"], var.vpn_cidrs)
    description = "Kubernetes API: private network + VPN only"
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "50000"
    source_ips  = concat(["10.0.0.0/16"], var.vpn_cidrs)
    description = "Talos API: private network + VPN only"
  }
}

# Load balancer for the Kubernetes API — provides a stable endpoint across control plane nodes.
# Public interface is disabled: the LB is only reachable via the private network (i.e. via VPN).
resource "hcloud_load_balancer" "control_plane" {
  name               = "willpxxr-prod-cp"
  load_balancer_type = "lb11"
  location           = "nbg1"
}

resource "hcloud_load_balancer_network" "control_plane" {
  load_balancer_id        = hcloud_load_balancer.control_plane.id
  network_id              = hcloud_network.main.id
  ip                      = local.lb_private_ip
  enable_public_interface = false

  depends_on = [hcloud_network_subnet.main]
}

resource "hcloud_load_balancer_service" "kube_api" {
  load_balancer_id = hcloud_load_balancer.control_plane.id
  protocol         = "tcp"
  listen_port      = 6443
  destination_port = 6443
}

resource "hcloud_load_balancer_target" "control_plane" {
  count            = length(local.control_plane_ips)
  type             = "server"
  load_balancer_id = hcloud_load_balancer.control_plane.id
  server_id        = hcloud_server.control_plane[count.index].id
  use_private_ip   = true

  depends_on = [hcloud_load_balancer_network.control_plane]
}

# Talos PKI and secrets — generated once, stored in Terraform state
resource "talos_machine_secrets" "main" {}

# Control plane machine configuration
data "talos_machine_configuration" "control_plane" {
  cluster_name     = "willpxxr-prod"
  machine_type     = "controlplane"
  cluster_endpoint = "https://${local.lb_private_ip}:6443"
  machine_secrets  = talos_machine_secrets.main.machine_secrets
}

# Worker machine configuration
data "talos_machine_configuration" "worker" {
  cluster_name     = "willpxxr-prod"
  machine_type     = "worker"
  cluster_endpoint = "https://${local.lb_private_ip}:6443"
  machine_secrets  = talos_machine_secrets.main.machine_secrets
}

# CX22: 2 vCPU, 4 GB RAM, 40 GB NVMe — dedicated control plane nodes.
# Note: a 2-member etcd cluster requires both nodes for write quorum; losing either
# member makes the cluster read-only. Add a third control plane for true fault tolerance.
# Machine config is injected via user_data at first boot — the Talos API (:50000) is
# therefore never publicly reachable and is protected by the firewall and Talos mTLS.
resource "hcloud_server" "control_plane" {
  count        = length(local.control_plane_ips)
  name         = "willpxxr-prod-cp-${count.index + 1}"
  server_type  = "cx22"
  location     = "nbg1"
  image        = data.hcloud_image.talos.id
  user_data    = data.talos_machine_configuration.control_plane.machine_configuration
  firewall_ids = [hcloud_firewall.main.id]

  network {
    network_id = hcloud_network.main.id
    ip         = local.control_plane_ips[count.index]
  }

  depends_on = [hcloud_network_subnet.main]
}

# CX22: 2 vCPU, 4 GB RAM, 40 GB NVMe — dedicated worker nodes.
resource "hcloud_server" "worker" {
  count        = length(local.worker_ips)
  name         = "willpxxr-prod-worker-${count.index + 1}"
  server_type  = "cx22"
  location     = "nbg1"
  image        = data.hcloud_image.talos.id
  user_data    = data.talos_machine_configuration.worker.machine_configuration
  firewall_ids = [hcloud_firewall.main.id]

  network {
    network_id = hcloud_network.main.id
    ip         = local.worker_ips[count.index]
  }

  depends_on = [hcloud_network_subnet.main]
}

# Talos client configuration for manual cluster operations via VPN:
#   terraform output -raw talosconfig > ~/.talos/config
#   talosctl bootstrap --nodes <first-control-plane-private-ip>
#   talosctl kubeconfig --nodes <first-control-plane-private-ip>
data "talos_client_configuration" "main" {
  cluster_name         = "willpxxr-prod"
  client_configuration = talos_machine_secrets.main.client_configuration
  nodes                = concat(local.control_plane_ips, local.worker_ips)
  endpoints            = local.control_plane_ips
}

# Expose the Talos client config so operators can manage the cluster via VPN.
output "talosconfig" {
  description = "Talos client configuration — use via VPN to bootstrap and manage the cluster"
  value       = data.talos_client_configuration.main.talos_config
  sensitive   = true
}
