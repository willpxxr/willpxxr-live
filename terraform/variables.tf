variable "cloudflare_api_token" {
  sensitive   = true
  description = "Cloudflare API Token"
}

variable "hetzner_token" {
  sensitive   = true
  description = "Hetzner Cloud API Token"
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
  description = "Client ID of an Auth0 Machine-to-Machine application authorized for the Auth0 Management API. Needs create/read/update/delete:clients grants for auth0_client itself, plus read:client_credentials (or read:client_keys) for the auth0_client_credentials resource to read back the generated client secret. Used to authenticate the auth0 Terraform provider."
}

variable "auth0_mgmt_client_secret" {
  sensitive   = true
  description = "Client secret for the Auth0 Management API M2M application above."
}

variable "betterstack_api_token" {
  sensitive   = true
  description = "Better Stack Telemetry API token (from https://betterstack.com/docs/logs/api/getting-started/#get-an-logs-api-token), used to authenticate the logtail Terraform provider so it can create the OTel Collector's Source via logtail_source. Distinct from the source token that resource then produces."
}

variable "supabase_token" {
  sensitive   = true
  description = "Supabase Management API personal access token (from https://supabase.com/dashboard/account/tokens), used to authenticate the supabase Terraform provider. The Management API has no OIDC/federation surface (unlike Tailscale above), so this is a static token by necessity."
}

variable "supabase_organization_id" {
  description = "Supabase organization slug the mcp-token-vault project is created in (from the dashboard URL: supabase.com/dashboard/org/<id>). The supabase provider has no organization data source, so this is user-supplied."
}

variable "supabase_region" {
  description = "AWS region for the Supabase project; picked to sit near the de/hetzner cluster (nbg1)."
  default     = "eu-central-1"
}

# Hetzner Object Storage S3 keys (WEP-0016 Phase 1). Console-generated --
# Object Storage has no Cloud API -- and used only by the MinIO provider
# to manage the substrate snapshot bucket. Entered as TFC write-only
# workspace variables, hence `ephemeral` here -- the hard pairing for
# write-only vars (TFC refuses writes otherwise); provider configuration
# is the one sanctioned context for ephemeral values, so the bucket
# resource carries no gate: missing keys fail the apply loudly.
variable "s3_access_key" {
  sensitive   = true
  ephemeral   = true
  description = "Hetzner Object Storage access key (Console-generated S3 key; carried as a TFC write-only variable)"
}

variable "s3_secret_key" {
  sensitive   = true
  ephemeral   = true
  description = "Hetzner Object Storage secret key (Console-generated S3 key; carried as a TFC write-only variable)"
}

# Substrate runtime S3 pair (WEP-0016 Phase 1): dedicated credentials for
# the objectstore-plugin sidecars, written into the `substrate-s3`
# 1Password item (terraform/objectstorage.tf). Regular Sensitive -- NOT
# write-only/ephemeral: the item write must persist (writer-of-record),
# and ephemeral values cannot cross into resource attributes.
variable "substrate_s3_access_key" {
  sensitive   = true
  description = "Hetzner Object Storage access key for the substrate runtime (dedicated pair; TF writes it into the substrate-s3 1Password item)"
}

variable "substrate_s3_secret_key" {
  sensitive   = true
  description = "Hetzner Object Storage secret key for the substrate runtime (dedicated pair; TF writes it into the substrate-s3 1Password item)"
}
