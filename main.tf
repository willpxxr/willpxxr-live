resource "cloudflare_record" "main" {
  for_each = { for record in local.records : lower("records/${record.name}/${record.type}") => record }
  zone_id  = data.cloudflare_zone.main.id
  name     = each.value.name
  type     = each.value.type
  proxied  = each.value.proxied
  content  = each.value.value
}

resource "cloudflare_ruleset" "redirect" {
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

resource "cloudflare_list" "main" {
  for_each    = local.lists
  account_id  = data.cloudflare_accounts.main.accounts[0].id
  name        = each.key
  description = each.key
  kind        = each.value.kind

  dynamic "item" {
    for_each = each.value.values
    iterator = value
    content {
      value {
        ip = value.value
      }
    }
  }
}

resource "cloudflare_ruleset" "waf" {
  zone_id = data.cloudflare_zone.main.id
  name    = "Firewall Custom Rules"
  kind    = "zone"
  phase   = "http_request_firewall_custom"

  dynamic "rules" {
    for_each = { for rule in local.waf : rule.name => rule }
    iterator = rule
    content {
      description = rule.key
      action      = "block"
      expression  = rule.value.expression
      enabled     = true
    }
  }
}