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
      name    = "status"
      type    = "CNAME"
      value   = "willpxxr.github.io"
      proxied = true
    }
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
  ]



  waf = [
    {
      name       = "zone lockdown"
      expression = "(not ip.src in $vpn and not http.host in {${join(" ", [for host in local.waf_allowed_hosted : "\"${host}\""])}})"
    }
  ]
}
