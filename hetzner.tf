locals {
  # Talos version running on cluster nodes.
  # Update to adopt a new release; machines must be re-imaged after changing this value.
  talos_version = "v1.9.4"
}

# Look up the Talos snapshot pre-uploaded to the Hetzner Cloud project.
# To create the snapshot, follow:
# https://www.talos.dev/v1.9/talos-guides/install/cloud-platforms/hetzner/
data "hcloud_image" "talos" {
  with_selector     = "os=talos,version=${local.talos_version}"
  most_recent       = true
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

# Firewall: restrict the Kubernetes and Talos APIs to the VPN subnet only
resource "hcloud_firewall" "main" {
  name = "willpxxr-prod"

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "6443"
    source_ips  = local.lists.vpn.values
    description = "Kubernetes API (VPN only)"
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "50000"
    source_ips  = local.lists.vpn.values
    description = "Talos API (VPN only)"
  }
}

# Talos PKI and secrets — generated once, stored in Terraform state
resource "talos_machine_secrets" "main" {}

# Control plane machine configuration
data "talos_machine_configuration" "control_plane" {
  cluster_name     = "willpxxr-prod"
  machine_type     = "controlplane"
  cluster_endpoint = "https://${hcloud_server.control_plane.ipv4_address}:6443"
  machine_secrets  = talos_machine_secrets.main.machine_secrets
}

# CX32: 4 AMD vCPU, 8 GB RAM, 80 GB NVMe — serves as both control plane and worker.
# Single-node topology is an intentional cost trade-off (no HA). Hetzner Cloud allows
# all outbound traffic by default; the firewall below only restricts inbound access.
resource "hcloud_server" "control_plane" {
  name         = "willpxxr-prod-cp-1"
  server_type  = "cx32"
  location     = "nbg1"
  image        = data.hcloud_image.talos.id
  firewall_ids = [hcloud_firewall.main.id]

  network {
    network_id = hcloud_network.main.id
    ip         = "10.0.1.1"
  }

  lifecycle {
    precondition {
      condition     = data.hcloud_image.talos.id != null
      error_message = "Talos snapshot for version ${local.talos_version} not found in Hetzner Cloud. Upload it first: https://www.talos.dev/v1.9/talos-guides/install/cloud-platforms/hetzner/"
    }
  }

  depends_on = [hcloud_network_subnet.main]
}

# Push the Talos machine config to the control plane
resource "talos_machine_configuration_apply" "control_plane" {
  client_configuration        = talos_machine_secrets.main.client_configuration
  machine_configuration_input = data.talos_machine_configuration.control_plane.machine_configuration
  node                        = hcloud_server.control_plane.ipv4_address

  depends_on = [hcloud_server.control_plane]
}

# Bootstrap the Talos cluster (runs etcd, issues PKI certs)
resource "talos_machine_bootstrap" "main" {
  node                 = hcloud_server.control_plane.ipv4_address
  client_configuration = talos_machine_secrets.main.client_configuration

  depends_on = [talos_machine_configuration_apply.control_plane]
}

# Retrieve kubeconfig once the cluster is bootstrapped
data "talos_cluster_kubeconfig" "main" {
  client_configuration = talos_machine_secrets.main.client_configuration
  node                 = hcloud_server.control_plane.ipv4_address

  depends_on = [talos_machine_bootstrap.main]
}

# Expose the kubeconfig so operators can retrieve it with:
#   terraform output -raw kubeconfig > ~/.kube/willpxxr-prod.yaml
output "kubeconfig" {
  description = "Kubeconfig for the willpxxr-prod Talos cluster"
  value       = data.talos_cluster_kubeconfig.main.kubeconfig_raw
  sensitive   = true
}
