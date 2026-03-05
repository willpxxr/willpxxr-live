variable "cloudflare_api_token" {
  sensitive   = true
  description = "Cloudflare API Token"
}

variable "hetzner_token" {
  sensitive   = true
  description = "Hetzner Cloud API Token"
}

variable "vpn_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach the Kubernetes API (:6443) and Talos API (:50000), e.g. your Tailscale/Meshnet subnet (100.64.0.0/10)"

  validation {
    condition     = length(var.vpn_cidrs) > 0
    error_message = "At least one VPN CIDR must be provided; otherwise the Kubernetes and Talos APIs are unreachable."
  }
}
