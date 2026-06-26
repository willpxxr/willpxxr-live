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
