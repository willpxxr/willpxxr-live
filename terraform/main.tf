# cloudflare provider v5: cloudflare_record was renamed cloudflare_dns_record
# and ruleset/list "rules"/"items" became list attributes rather than blocks.
resource "cloudflare_dns_record" "main" {
  for_each = { for record in local.records : lower("records/${record.name}/${record.type}") => record }
  zone_id  = data.cloudflare_zone.main.id
  name     = each.value.name
  type     = each.value.type
  proxied  = each.value.proxied
  content  = each.value.value
  ttl      = 1 # automatic, matching the v4 default these records were created with
}

resource "cloudflare_ruleset" "redirect" {
  zone_id     = data.cloudflare_zone.main.id
  name        = "Redirect for willpxxr.com zone"
  description = "Defines redirect rules for domains under willpxxr.com"
  kind        = "zone"
  phase       = "http_request_dynamic_redirect"

  rules = [
    for redirect in local.redirects : {
      action      = "redirect"
      expression  = "http.host in {${join(" ", [for host in redirect.hosts : "\"${host}\""])}}"
      description = "Redirects hostnames [${join(", ", redirect.hosts)}] to ${redirect.to}"
      enabled     = true
      action_parameters = {
        from_value = {
          status_code           = 301
          preserve_query_string = false
          target_url = {
            value = redirect.to
          }
        }
      }
    }
  ]
}

resource "cloudflare_list" "main" {
  for_each    = local.lists
  account_id  = data.cloudflare_accounts.main.result[0].id
  name        = each.key
  description = each.key
  kind        = each.value.kind

  items = [
    for value in each.value.values : {
      ip = value
    }
  ]
}

resource "cloudflare_ruleset" "waf" {
  zone_id = data.cloudflare_zone.main.id
  name    = "Firewall Custom Rules"
  kind    = "zone"
  phase   = "http_request_firewall_custom"

  rules = [
    for rule in local.waf : {
      description = rule.name
      action      = "block"
      expression  = rule.expression
      enabled     = true
    }
  ]
}
