data "cloudflare_zone" "main" {
  name = "willpxxr.com"
}

data "cloudflare_accounts" "main" {
  name = "willpxxr.com"
}