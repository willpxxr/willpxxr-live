terraform {
  required_version = ">= 1.11.0"
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    oci = {
      source  = "oracle/oci"
      version = "~> 7.0"
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
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

provider "oci" {
  tenancy_ocid = "ocid1.tenancy.oc1..aaaaaaaal7ioy4xx4zw4g2fhbxrcbvkdzuea2t4gm3gbi7jayibgkk55amua"
  user_ocid    = "ocid1.user.oc1..aaaaaaaa6q7pgadu7l4mxnxa5dwmf3sayhvc254u7mtpxezqfhi56yaibc4a"
  private_key  = base64decode(var.oci_rsa_private_key_base64enc)
  fingerprint  = "0a:78:a5:18:2e:4f:1a:a1:83:91:2b:93:51:ff:03:fe"
  region       = "uk-london-1"
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
