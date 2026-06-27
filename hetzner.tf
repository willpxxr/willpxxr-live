resource "tailscale_tailnet_key" "cluster_nodes" {
  reusable      = true
  ephemeral     = false
  preauthorized = true
  description   = "willpxxr-live Hetzner Talos node enrollment"
  tags          = ["tag:k8s-system"]

  depends_on = [tailscale_acl.main]
}

module "talos" {
  source  = "hcloud-talos/talos/hcloud"
  version = "~> 3.1"

  hcloud_token = var.hetzner_token

  cluster_name  = "willpxxr-prod"
  location_name = "nbg1"

  # Keep in sync with the talos_version default in packer/talos/talos.pkr.hcl --
  # the snapshot image and the generated machine config must match.
  talos_version      = "v1.12.2"
  kubernetes_version = "1.35.0"

  # Packer only builds an x86 snapshot (see packer/talos/talos.pkr.hcl) -- without
  # this the module also looks up an ARM image by label selector and fails to find one.
  disable_arm = true

  # Open to all IPs rather than restricted to the Tailscale CGNAT range: an
  # IP-based firewall would have blocked Terraform Cloud's own remote runners
  # from reaching the Talos API during bootstrap (no stable egress IP exists
  # for them to allowlist). Security boundary is mTLS (Talos API) and TLS+RBAC
  # (Kubernetes API), not network-level IP filtering -- same reasoning as
  # commit c18784a on the prior branch this was ported from.
  firewall_use_current_ip   = false
  firewall_kube_api_source  = ["0.0.0.0/0", "::/0"]
  firewall_talos_api_source = ["0.0.0.0/0", "::/0"]

  # Talos image — built by Packer (packer/talos/talos.pkr.hcl) from the schematic in
  # packer/talos/schematic.yaml, which includes siderolabs/qemu-guest-agent and
  # siderolabs/tailscale. Run `packer build packer/talos/talos.pkr.hcl` once per Talos
  # version upgrade; the data source below resolves the most-recently pushed snapshot.
  talos_image_id_x86 = data.hcloud_image.talos.id

  # Single CX23 control plane -- no etcd quorum/HA, so losing this node takes the
  # cluster fully down until it's back. Acceptable for this workload's usage.
  control_plane_nodes = [
    { id = 1, type = "cx23" },
  ]

  # 2x CX23 workers.
  worker_nodes = [
    { id = 1, type = "cx23" },
    { id = 2, type = "cx23" },
  ]

  # Public IPs so Terraform Cloud's remote runners can reach the cluster
  # directly -- see the firewall comment above for why this is safe.
  kubeconfig_endpoint_mode   = "public_ip"
  talosconfig_endpoints_mode = "public_ip"

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
