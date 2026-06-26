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

variable "oci_rsa_private_key_base64enc" {
  sensitive   = true
  description = "OCI API Key RSA Private Key, base64-encoded. Only used to satisfy provider configuration for detaching decommissioned OCI resources from state (see moves.tf) — no real OCI resources are managed."
}
