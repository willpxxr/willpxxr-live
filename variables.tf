variable "cloudflare_api_token" {
  sensitive   = true
  description = "Cloudflare API Token"
}

variable "oci_rsa_private_key_base64enc" {
  sensitive   = true
  description = "OCI API Key RSA Private Key"
}
