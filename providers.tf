terraform {
  required_version = "~> 1.9"
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.60"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.10"
    }
    # Additional providers required by the hcloud-talos/talos/hcloud module
    http = {
      source  = "hashicorp/http"
      version = "~> 3.5"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.1"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.2"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

provider "hcloud" {
  token = var.hetzner_token
}
