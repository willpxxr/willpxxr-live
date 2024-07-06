resource "cloudflare_record" "main" {
  for_each = local.records
  zone_id  = data.cloudflare_zone.main.id
  name     = each.key
  type     = each.value.type
  proxied  = each.value.proxied
  value    = each.value.value
}

resource "cloudflare_ruleset" "main" {
  zone_id     = data.cloudflare_zone.main.id
  name        = "Redirect for willpxxr.com zone"
  description = "Defines redirect rules for domains under willpxxr.com"
  kind        = "zone"
  phase       = "http_request_dynamic_redirect"
  dynamic "rules" {
    for_each = local.redirects
    iterator = redirect
    content {
      action = "redirect"
      action_parameters {
        from_value {
          status_code = 301
          target_url {
            value = redirect.value.to
          }
          preserve_query_string = false
        }
      }

      expression  = "http.host eq \"${redirect.key}\""
      description = "Redirects hostname ${redirect.key} to ${redirect.value.to}"
      enabled     = true
    }
  }
}