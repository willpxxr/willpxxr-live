terraform {
  required_version = ">= 1.11.0"
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.19"
    }
    onepassword = {
      source  = "1Password/onepassword"
      version = "~> 3.0"
    }
    auth0 = {
      source  = "auth0/auth0"
      version = "~> 1.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.60"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.10"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.5"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.2"
    }
    logtail = {
      source  = "BetterStackHQ/logtail"
      version = "~> 10.9"
    }
    supabase = {
      source  = "supabase/supabase"
      version = "~> 1.0"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

provider "hcloud" {
  token = var.hetzner_token
}

data "external" "tailscale_identity_token" {
  program = ["sh", "-c", "printf '{\"token\":\"%s\"}' \"$TFC_WORKLOAD_IDENTITY_TOKEN_TAILSCALE\""]
}

provider "tailscale" {
  oauth_client_id = var.tailscale_bootstrap_oauth_client_id
  identity_token  = data.external.tailscale_identity_token.result.token
}

provider "onepassword" {
  service_account_token = var.onepassword_terraform_service_account_token
}

provider "auth0" {
  domain        = var.auth0_domain
  client_id     = var.auth0_mgmt_client_id
  client_secret = var.auth0_mgmt_client_secret
}

provider "logtail" {
  api_token = var.betterstack_api_token
}

provider "supabase" {
  access_token = var.supabase_access_token
}
