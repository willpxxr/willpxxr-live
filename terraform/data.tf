data "cloudflare_zone" "main" {
  filter = {
    name = "willpxxr.com"
  }
}

data "cloudflare_accounts" "main" {
  name = "willpxxr.com"
}