locals {
  kubernetes_version = "v1.32.1"
  kubernetes_node_disk_boot_size_gb = 50
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

module "workers" {
  source = "oracle-terraform-modules/oke/oci//modules/workers"
  version = "5.2.4"

  worker_pool_mode = "node-pool"
  worker_pool_size = 2
  worker_pools = {
    oke-vm-standard-free-tier = {
      description      = "OKE-managed Node Pool with OKE Oracle Linux 8 image",
      shape            = "VM.Standard.A1.Flex",
      create           = true,
      ocpus            = 2,
      memory           = 12,
      boot_volume_size = 50,
      os               = "Oracle Linux",
      os_version       = "8",
    },
  }
}
