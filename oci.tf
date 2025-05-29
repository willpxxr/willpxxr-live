resource "oci_identity_compartment" "main" {
  name        = "shared-resources"
  description = "Shared Resources in OCI"
  enable_delete = true
}
