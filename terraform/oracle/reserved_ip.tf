data "oci_core_vnic_attachments" "oracle" {
  count = var.assign_reserved_public_ip ? 1 : 0

  compartment_id = var.compartment_ocid
  instance_id    = oci_core_instance.oracle.id
}

data "oci_core_vnic" "oracle_primary" {
  count = var.assign_reserved_public_ip ? 1 : 0

  vnic_id = data.oci_core_vnic_attachments.oracle[0].vnic_attachments[0].vnic_id
}

data "oci_core_private_ips" "oracle_primary" {
  count = var.assign_reserved_public_ip ? 1 : 0

  vnic_id = data.oci_core_vnic.oracle_primary[0].id
}

resource "oci_core_public_ip" "oracle_reserved" {
  count = var.reserve_public_ip || var.assign_reserved_public_ip ? 1 : 0

  compartment_id = var.compartment_ocid
  display_name   = var.reserved_public_ip_display_name
  lifetime       = "RESERVED"
  private_ip_id  = var.assign_reserved_public_ip ? data.oci_core_private_ips.oracle_primary[0].private_ips[0].id : null

  lifecycle {
    precondition {
      condition     = !var.assign_reserved_public_ip || var.reserve_public_ip
      error_message = "assign_reserved_public_ip requires reserve_public_ip = true. Reserve a floating IP first, then assign on a follow-up apply (see terraform/oracle/README.md)."
    }
  }
}
