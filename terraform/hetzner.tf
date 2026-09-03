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
  # v1.13.9 bump: Phase A of WEP-0009 (Talos-only; k8s stays 1.35.0 until
  # Phase B -- cilium prerequisite + WEP-0005 gate verification first).
  talos_version      = "v1.13.9"
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

  # Worker upgrade (WEP-0009 Phase A): the module requires contiguous ids
  # (1..N), so node replacement is done by DRAIN + `terraform taint` on the
  # server resource + any .tf push (one apply = destroy+create, fresh
  # v1.13.9 snapshot + regenerated config). Old v1.12.2 worker-1 was drained
  # and tainted 2026-09-03; worker-2 follows.
  worker_nodes = [
    { id = 1, type = "cx23" },
    { id = 2, type = "cx23" },
    { id = 3, type = "cx23" },
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

  # The hcloud-talos module only appends its Tailscale ExtensionServiceConfig to
  # the control-plane machine config (talos.tf adds tailscale_config_patch to the
  # control-plane config_patches, never to the workers'), so worker nodes never
  # receive TS_AUTHKEY. The ext-tailscale extension then waits forever on its
  # `configuration: true` dependency, blocking startAllServices and leaving
  # workers stuck in the BOOTING stage permanently (the 2026-09 reboot-loop
  # incident). user_data is lifecycle-ignored, so this only reaches future
  # re-provisions; the live workers were fixed by the one-time `talosctl patch mc`
  # runbook in docs/wep (WEP-0005 precedent).
  talos_worker_extra_config_patches = [yamlencode({
    apiVersion  = "v1alpha1"
    kind        = "ExtensionServiceConfig"
    name        = "tailscale"
    environment = ["TS_AUTHKEY=${tailscale_tailnet_key.cluster_nodes.key}"]
  })]

  # Custom Cilium values:
  # - Enable bpf.socketLB.hostNetworkOnly so socket load balancing only applies to
  #   host-network traffic, not pod namespaces. Without this, Cilium's BPF socket LB
  #   intercepts pod-to-ClusterIP traffic before it reaches netfilter hooks, breaking
  #   the Tailscale operator's proxy pods which use netfilter rules in their network
  #   namespace to forward tailnet traffic to backing Services.
  #   Ref: https://tailscale.com/docs/kubernetes-operator/reference/compatibility#cilium-kube-proxy-replacement-mode
  # - Enable Hubble for flow observability and debugging network policy issues.
  cilium_values = [file("${path.module}/files/cilium-values.yaml")]
}

# Resolve the Talos snapshot built by Packer (packer/talos/talos.pkr.hcl).
# The snapshot is labelled os=talos,tailscale=true and includes both
# siderolabs/qemu-guest-agent and siderolabs/tailscale.
# Schematic is content-addressed: re-POSTing packer/talos/schematic.yaml to
# factory.talos.dev/schematics deterministically returns
# 7d4c31cbd96db9f90c874990697c523482b2bae27fb4631d5583dcd9c281b1ff -- the
# installer-image reference for in-place upgrades (WEP-0009):
#   factory.talos.dev/installer/7d4c31cbd96d…:v<version>
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

data "onepassword_vault" "terraform" {
  name = "terraform"
}

resource "onepassword_item" "talosconfig" {
  vault      = data.onepassword_vault.terraform.uuid
  title      = "willpxxr-prod-talosconfig"
  category   = "secure_note"
  note_value = module.talos.talosconfig
}

resource "onepassword_item" "kubeconfig" {
  vault      = data.onepassword_vault.terraform.uuid
  title      = "willpxxr-prod-kubeconfig"
  category   = "secure_note"
  note_value = module.talos.kubeconfig
}
