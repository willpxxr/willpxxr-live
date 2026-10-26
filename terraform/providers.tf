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
    minio = {
      source  = "aminueza/minio"
      version = "3.33.1"
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
  access_token = var.supabase_token
}

# Hetzner Object Storage S3 endpoint (objectstorage.tf) -- the official
# docs route (docs.hetzner.com ST-507F6, "Creating a Bucket via MinIO
# Terraform Provider", 3.33.1 pinned). Object Storage has no Cloud API, so
# the credentials are Console-generated S3 keys set as TFC workspace
# variables; until they are set the bucket resource is count-gated
# (terraform/objectstorage.tf) and configure stays offline:
# s3_compat_mode skips the MinIO-admin edition probe entirely (verified
# against provider source: detectEdition short-circuits on that flag,
# whose own description names Hetzner), so secretless applies are green.
# skip_bucket_tagging: Hetzner's S3 surface does not document tagging.
provider "minio" {
  minio_server        = "nbg1.your-objectstorage.com"
  minio_user          = var.hetzner_s3_access_key
  minio_password      = var.hetzner_s3_secret_key
  minio_region        = "nbg1"
  minio_ssl           = true
  s3_compat_mode      = true
  skip_bucket_tagging = true
}
