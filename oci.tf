locals {
  kubernetes_version = "v1.33.0"
  kubernetes_node_disk_boot_size_gb = 50
  # hard code for now because this is painful
  kubernetes_node_version = "v1.32.1"
  kubernetes_node_image_id = "ocid1.image.oc1.uk-london-1.aaaaaaaaovf2cgp52xj5asm4ocj4pt3vwzx477auu34glzzwofsez7i37jtq"
}

resource "oci_identity_compartment" "main" {
  name        = "shared-resources"
  description = "Shared Resources in OCI"
  enable_delete = true
}

module "vcn" {
  source                       = "oracle-terraform-modules/vcn/oci"
  version                      = "3.6.0"
  compartment_id               = oci_identity_compartment.main.id
  internet_gateway_route_rules = null
  local_peering_gateways       = null
  nat_gateway_route_rules      = null
  vcn_name                     = "k8s-vcn"
  vcn_dns_label                = "k8svcn"
  vcn_cidrs                    = ["10.0.0.0/16"]
  create_internet_gateway      = true
  create_nat_gateway           = true
  create_service_gateway       = true
}

resource "oci_core_subnet" "vcn_private_subnet" {
  compartment_id = oci_identity_compartment.main.id
  vcn_id         = module.vcn.vcn_id
  cidr_block     = "10.0.1.0/24"
  route_table_id = module.vcn.nat_route_id
  security_list_ids = [
    oci_core_security_list.private_subnet_sl.id,
  ]
  display_name               = "k8s-private-subnet"
  prohibit_public_ip_on_vnic = true
}

resource "oci_core_subnet" "vcn_public_subnet" {
  compartment_id    = oci_identity_compartment.main.id
  vcn_id            = module.vcn.vcn_id
  cidr_block        = "10.0.0.0/24"
  route_table_id    = module.vcn.ig_route_id
  security_list_ids = [
    oci_core_security_list.public_subnet_sl.id,
  ]
  display_name      = "k8s-public-subnet"
}

resource "oci_core_security_list" "private_subnet_sl" {
  compartment_id = oci_identity_compartment.main.id
  vcn_id         = module.vcn.vcn_id
  display_name   = "k8s-private-subnet-sl"

  egress_security_rules {
    stateless        = false
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
  }

  ingress_security_rules {
    stateless   = false
    source      = "10.0.0.0/16"
    source_type = "CIDR_BLOCK"
    protocol    = "all"
  }
}

resource "oci_core_security_list" "public_subnet_sl" {
  compartment_id = oci_identity_compartment.main.id
  vcn_id         = module.vcn.vcn_id
  display_name   = "k8s-public-subnet-sl"

  # egress everywhere
  egress_security_rules {
    stateless        = false
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
  }

  # ingres only our cidr
  ingress_security_rules {
    stateless   = false
    source      = "10.0.0.0/16"
    source_type = "CIDR_BLOCK"
    protocol    = "all"
  }
}

resource "oci_containerengine_cluster" "k8s_cluster" {
  compartment_id     = oci_identity_compartment.main.id
  kubernetes_version = local.kubernetes_version
  name               = "k8s-cluster"
  vcn_id             = module.vcn.vcn_id
  endpoint_config {
    is_public_ip_enabled = true
    subnet_id            = oci_core_subnet.vcn_public_subnet.id
  }
  options {
    add_ons {
      is_kubernetes_dashboard_enabled = false
      is_tiller_enabled               = false
    }

    kubernetes_network_config {
      pods_cidr     = "10.244.0.0/16"
      services_cidr = "10.96.0.0/16"
    }
    service_lb_subnet_ids = [oci_core_subnet.vcn_public_subnet.id]
  }
}

data "oci_identity_availability_domains" "ads" {
    compartment_id = oci_identity_compartment.main.id
}

resource "oci_containerengine_node_pool" "k8s_node_pool" {
  cluster_id         = oci_containerengine_cluster.k8s_cluster.id
  compartment_id     = oci_identity_compartment.main.id
  kubernetes_version = local.kubernetes_node_version
  name               = "k8s-node-pool"

  node_metadata = {
    user_data = base64encode(file("files/node-pool-init.sh"))
  }

  node_config_details {
    placement_configs {
      availability_domain = data.oci_identity_availability_domains.ads.availability_domains[1].name
      subnet_id           = oci_core_subnet.vcn_private_subnet.id
    }

    size = 2
  }

  node_shape = "VM.Standard.A1.Flex"

  node_shape_config {
    memory_in_gbs = 12
    ocpus         = 2
  }

  initial_node_labels {
    key   = "name"
    value = "k8s-cluster"
  }

  node_source_details {
    image_id = local.kubernetes_node_image_id
    source_type = "IMAGE"
    boot_volume_size_in_gbs = local.kubernetes_node_disk_boot_size_gb
  }
}

