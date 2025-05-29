terraform {
  required_version = "~> 1.9"
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    oci = {
      source = "oracle/oci"
      version = "~> 7.0"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

provider "oci" {
  tenancy_ocid = "ocid1.tenancy.oc1..aaaaaaaal7ioy4xx4zw4g2fhbxrcbvkdzuea2t4gm3gbi7jayibgkk55amua"
  user_ocid    = "ocid1.user.oc1..aaaaaaaa6q7pgadu7l4mxnxa5dwmf3sayhvc254u7mtpxezqfhi56yaibc4a"
  private_key  = base64decode(var.oci_rsa_private_key_base64enc)
  fingerprint  = "0a:78:a5:18:2e:4f:1a:a1:83:91:2b:93:51:ff:03:fe"
  region       = "uk-london-1"
}
