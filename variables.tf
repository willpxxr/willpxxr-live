variable "cloudflare_api_token" {
  sensitive   = true
  description = "Cloudflare API Token"
}

variable "hetzner_token" {
  sensitive   = true
  description = "Hetzner Cloud API Token"
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

variable "auth0_domain" {
  description = "Auth0 tenant domain (e.g. your-tenant.us.auth0.com). Used both as the auth0 Terraform provider's Management API target and, via the oauth2-proxy-auth0 1Password item, as the OIDC issuer for oauth2-proxy."
}

variable "auth0_mgmt_client_id" {
  sensitive   = true
  description = "Client ID of an Auth0 Machine-to-Machine application authorized for the Auth0 Management API (needs create/read/update/delete:clients grants), used to authenticate the auth0 Terraform provider."
}

variable "auth0_mgmt_client_secret" {
  sensitive   = true
  description = "Client secret for the Auth0 Management API M2M application above."
}
