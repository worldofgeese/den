output "instance_id" {
  description = "Launched instance OCID"
  value       = oci_core_instance.oracle.id
}

output "instance_public_ip" {
  description = "Public IPv4 address for SSH"
  value       = oci_core_instance.oracle.public_ip
}

output "custom_image_id" {
  description = "Imported custom image OCID"
  value       = oci_core_image.nixos.id
}

output "ssh_command" {
  description = "Suggested SSH command after apply completes"
  value       = "ssh nixos@${oci_core_instance.oracle.public_ip}"
}
