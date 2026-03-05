variable "cloudflare_api_token" {
  sensitive   = true
  description = "Cloudflare API Token"
}

variable "digitalocean_token" {
  sensitive   = true
  description = "DigitalOcean API Token"
}
