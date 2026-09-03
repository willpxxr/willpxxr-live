packer {
  required_plugins {
    hcloud = {
      source  = "github.com/hetznercloud/hcloud"
      version = "~> 1.5"
    }
  }
}

variable "hcloud_token" {
  type        = string
  sensitive   = true
  description = "Hetzner Cloud API token used to create the build server and snapshot"
}

variable "talos_version" {
  type        = string
  default     = "v1.13.9"
  description = "Talos Linux version to build (e.g. v1.13.2). Must match the talos_version set in hetzner.tf's talos module block."

  # NOTE (2026-09-03): this default leads hetzner.tf's talos_version on
  # purpose -- this file is in the talos-image workflow's paths filter, so
  # bumping it builds the new snapshot first; the hetzner.tf bump follows
  # once the snapshot exists (its data source selects the newest os=talos
  # snapshot). See docs/wep/0009 for the phased upgrade plan.
}

variable "location" {
  type        = string
  default     = "nbg1"
  description = "Hetzner Cloud location for the temporary build server"
}

# Boot a temporary server into Hetzner rescue mode so /dev/sda is free to
# overwrite, submit the schematic to Talos Image Factory, stream the resulting
# disk image onto /dev/sda, then snapshot the server.
source "hcloud" "talos" {
  token       = var.hcloud_token
  image       = "debian-12"
  rescue      = "linux64"
  location    = var.location
  server_type = "cx23"

  snapshot_name = "talos-${var.talos_version}"
  snapshot_labels = {
    os        = "talos"
    version   = var.talos_version
    tailscale = "true"
  }

  ssh_username = "root"
}

build {
  sources = ["source.hcloud.talos"]

  # Upload the schematic definition to the build server.
  provisioner "file" {
    source      = "${path.root}/schematic.yaml"
    destination = "/tmp/schematic.yaml"
  }

  provisioner "shell" {
    inline_shebang = "/bin/bash -e"
    environment_vars = [
      "TALOS_VERSION=${var.talos_version}",
    ]
    inline = [
      "set -euo pipefail",
      "export DEBIAN_FRONTEND=noninteractive",
      "apt-get update -qq",
      "apt-get install -y --no-install-recommends curl jq xz-utils",

      "# Submit the schematic to Talos Image Factory and resolve the schematic ID.",
      "SCHEMATIC_ID=$(curl -fsSL -X POST --data-binary @/tmp/schematic.yaml https://factory.talos.dev/schematics | jq -r '.id')",
      "echo \"Resolved schematic ID: $SCHEMATIC_ID\"",

      "# Download the Talos disk image for Hetzner Cloud (hcloud-amd64.raw.xz).",
      "IMAGE_URL=\"https://factory.talos.dev/image/$SCHEMATIC_ID/$TALOS_VERSION/hcloud-amd64.raw.xz\"",
      "echo \"Downloading $IMAGE_URL\"",
      "curl -fL --progress-bar -o /tmp/talos.raw.xz \"$IMAGE_URL\"",

      "# Write the Talos image directly to the root disk.",
      "xz -dc /tmp/talos.raw.xz | dd of=/dev/sda bs=4M status=progress",
      "sync",
      "echo \"Done: Talos $TALOS_VERSION written to /dev/sda\"",
    ]
  }
}
