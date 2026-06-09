output "instance_id" {
  description = "Launched instance OCID"
  value       = oci_core_instance.oracle.id
}

output "instance_public_ip" {
  description = "Effective public IPv4 for SSH (reserved when assigned, else instance ephemeral)"
  value = coalesce(
    var.assign_reserved_public_ip ? try(oci_core_public_ip.oracle_reserved[0].ip_address, null) : null,
    oci_core_instance.oracle.public_ip,
  )
}

output "instance_ephemeral_public_ip" {
  description = "Ephemeral public IPv4 from the instance resource (null after reserved IP assignment)"
  value       = oci_core_instance.oracle.public_ip
}

output "reserved_public_ip" {
  description = "Reserved public IPv4 address when reserve_public_ip or assign_reserved_public_ip is enabled"
  value       = try(oci_core_public_ip.oracle_reserved[0].ip_address, null)
}

output "reserved_public_ip_id" {
  description = "OCID of the reserved public IP when enabled"
  value       = try(oci_core_public_ip.oracle_reserved[0].id, null)
}

output "reserved_public_ip_assigned" {
  description = "Whether the reserved public IP is assigned to the instance primary private IP"
  value       = var.assign_reserved_public_ip
}

output "custom_image_id" {
  description = "Imported custom image OCID"
  value       = oci_core_image.nixos.id
}

output "ssh_command" {
  description = "Suggested SSH command after apply completes"
  value = "ssh nixos@${coalesce(
    var.assign_reserved_public_ip ? try(oci_core_public_ip.oracle_reserved[0].ip_address, null) : null,
    oci_core_instance.oracle.public_ip,
  )}"
}
