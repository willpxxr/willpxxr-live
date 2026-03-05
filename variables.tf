variable "cloudflare_api_token" {
  sensitive   = true
  description = "Cloudflare API Token"
}

variable "hetzner_token" {
  sensitive   = true
  description = "Hetzner Cloud API Token"
}
