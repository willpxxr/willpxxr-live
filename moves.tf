moved {
  from = cloudflare_record.main["git"]
  to   = cloudflare_record.main["records/git/a"]
}

# OCI resources were decommissioned in INF-6. These removed blocks tell Terraform
# to forget the OCI state entries without destroying any real infrastructure
# (destroy = false), so no OCI provider credentials are required.
removed {
  from = oci_identity_compartment.main
  lifecycle {
    destroy = false
  }
}

removed {
  from = module.vcn
  lifecycle {
    destroy = false
  }
}

removed {
  from = oci_core_security_list.private_subnet_sl
  lifecycle {
    destroy = false
  }
}

removed {
  from = oci_core_security_list.public_subnet_sl
  lifecycle {
    destroy = false
  }
}

removed {
  from = oci_core_subnet.vcn_private_subnet
  lifecycle {
    destroy = false
  }
}

removed {
  from = oci_core_subnet.vcn_public_subnet
  lifecycle {
    destroy = false
  }
}

removed {
  from = oci_containerengine_cluster.k8s_cluster
  lifecycle {
    destroy = false
  }
}

removed {
  from = oci_containerengine_node_pool.k8s_node_pool
  lifecycle {
    destroy = false
  }
}

moved {
  from = cloudflare_record.main["www"]
  to   = cloudflare_record.main["records/www/a"]
}

moved {
  from = cloudflare_record.main["willpxxr.com"]
  to   = cloudflare_record.main["records/@/a"]
}

moved {
  from = cloudflare_record.main["@"]
  to   = cloudflare_record.main["records/@/txt"]
}

moved {
  from = cloudflare_ruleset.main
  to   = cloudflare_ruleset.redirect
}
