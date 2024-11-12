locals {
  proxied_a_record_placeholder = "192.0.2.1"
  records = {
    "git" = {
      type    = "A"
      value   = local.proxied_a_record_placeholder
      proxied = true
    }
    "www" = {
      type    = "A"
      value   = local.proxied_a_record_placeholder
      proxied = true
    }
    "willpxxr.com" = {
      type    = "A"
      value   = local.proxied_a_record_placeholder
      proxied = true
    }
    "_ens" = {
      type    = "TXT"
      value   = "ENS1 dnsname.ens.eth 0x20373F5a3Bb30b528a9acdAbE02a3f99fb74ee45"
      proxied = false
    }
  }
  redirects = {
    "willpxxr.com" = {
      to = "https://www.linkedin.com/in/williamtjparr/"
    }
    "git.willpxxr.com" = {
      to = "https://github.com/willpxxr"
    }
  }
}
