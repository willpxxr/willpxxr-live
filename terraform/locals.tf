locals {
  lists = {
    vpn = {
      kind = "ip"
      values = [
        "84.21.169.0/24"
      ]
    }
  }

  proxied_a_record_placeholder = "192.0.2.1"

  records = [
    {
      name    = "git"
      type    = "A"
      value   = local.proxied_a_record_placeholder
      proxied = true
    },
    {
      name    = "www"
      type    = "A"
      value   = local.proxied_a_record_placeholder
      proxied = true
    },
    {
      name    = "@"
      type    = "A"
      value   = local.proxied_a_record_placeholder
      proxied = true
    },
    {
      name    = "@"
      type    = "TXT"
      value   = "ENS1 dnsname.ens.eth 0x20373F5a3Bb30b528a9acdAbE02a3f99fb74ee45"
      proxied = false
    },
    {
      name    = "_discord"
      type    = "TXT"
      value   = "dh=7302e029c74bae4f578b37e1d21e676f12c9f9be"
      proxied = false
    },
    {
      name    = "status"
      type    = "CNAME"
      value   = "willpxxr.github.io"
      proxied = true
    },
    {
      name    = "auth"
      type    = "CNAME"
      value   = "dev-5tebe1ce-cd-nfe0aksybxkgh4pr.edge.tenants.us.auth0.com"
      proxied = false
    },
  ]

  redirects = [
    {
      hosts = ["willpxxr.com", "www.willpxxr.com"]
      to    = "https://www.linkedin.com/in/williamtjparr/"
    },
    {
      hosts = ["git.willpxxr.com"]
      to    = "https://github.com/willpxxr"
    },
  ]

  // ideally this would be a list, but limited to one per account :sadge:.
  waf_allowed_hosted = [
    "willpxxr.com",
    "www.willpxxr.com",
    "git.willpxxr.com",
    "status.willpxxr.com",
    "teleport.willpxxr.com",
  ]



  waf = [
    {
      name       = "zone lockdown"
      expression = "(not ip.src in $vpn and not http.host in {${join(" ", [for host in local.waf_allowed_hosted : "\"${host}\""])}})"
    }
  ]
}
