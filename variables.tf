variable "cloudflare_api_token" {
  sensitive   = true
  description = "Cloudflare API Token"
}

variable "ovh_client_id" {
  sensitive   = true
  description = "OVH OAuth2 service account client ID. Leave unset to fall back to OVH_APPLICATION_KEY/OVH_APPLICATION_SECRET/OVH_CONSUMER_KEY env vars for one-time bootstrap runs."
  default     = null
}

variable "ovh_client_secret" {
  sensitive   = true
  description = "OVH OAuth2 service account client secret. Leave unset to fall back to OVH_APPLICATION_KEY/OVH_APPLICATION_SECRET/OVH_CONSUMER_KEY env vars for one-time bootstrap runs."
  default     = null
}

variable "ovh_kube_region" {
  description = "OVH region for the Kubernetes cluster"
  default     = "UK1"
}

variable "ovh_kube_allowed_cidrs" {
  description = "CIDRs allowed to reach the Kubernetes API server's public endpoint. Leave empty to leave the endpoint unrestricted (e.g. until a stable Terraform Cloud agent IP exists to allowlist)."
  type        = list(string)
  default     = []
}

variable "oci_rsa_private_key_base64enc" {
  sensitive   = true
  description = "OCI API Key RSA Private Key, base64-encoded. Only used to satisfy provider configuration for detaching decommissioned OCI resources from state (see moves.tf) — no real OCI resources are managed."
}

variable "tailscale_bootstrap_oauth_client_id" {
  description = "Client ID of the Tailscale OIDC federated-identity trust credential (custom issuer https://app.terraform.io) with rights to create other OAuth clients. Non-secret per Tailscale's own docs -- auth itself happens via identity_token, sourced from the TFC-injected TFC_WORKLOAD_IDENTITY_TOKEN_TAILSCALE env var (see providers.tf). The actual k8s-operator OAuth client is created by Terraform itself (see tailscale.tf)."
}

variable "onepassword_terraform_service_account_token" {
  sensitive   = true
  description = "1Password Service Account token with read/write access to the 'kubernetes' vault. Used only to authenticate the onepassword Terraform provider (creating/updating items, e.g. tailscale-operator-oauth)."
}

variable "onepassword_vault" {
  description = "Name of the 1Password vault items are created in."
  default     = "kubernetes"
}
