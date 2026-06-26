terraform {
  required_version = ">= 1.11.0"
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    ovh = {
      source  = "ovh/ovh"
      version = "~> 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

provider "ovh" {
  endpoint      = "ovh-eu"
  client_id     = var.ovh_client_id
  client_secret = var.ovh_client_secret
}
