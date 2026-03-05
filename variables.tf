variable "cloudflare_api_token" {
  sensitive   = true
  description = "Cloudflare API Token"
}

variable "hetzner_token" {
  sensitive   = true
  description = "Hetzner Cloud API Token"
}

variable "tailscale_auth_key" {
  type        = string
  sensitive   = true
  description = "Tailscale auth key used to enrol cluster nodes into the Tailscale network (tskey-auth-...)"
}
