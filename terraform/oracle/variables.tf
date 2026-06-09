variable "tenancy_ocid" {
  description = "Tenancy OCID (Profile → Tenancy → Copy OCID)"
  type        = string
}

variable "user_ocid" {
  description = "User OCID (Profile → User Settings → Copy OCID)"
  type        = string
}

variable "fingerprint" {
  description = "API key fingerprint (Profile → User Settings → API Keys)"
  type        = string
}

variable "private_key_path" {
  description = "Filesystem path to the OCI API private key PEM (never commit key contents)"
  type        = string
}

variable "region" {
  description = "OCI region identifier (e.g. eu-frankfurt-1)"
  type        = string
}

variable "compartment_ocid" {
  description = "Compartment OCID for network, image, and compute resources"
  type        = string
}

variable "namespace" {
  description = "Object Storage namespace (Profile → Tenancy → Object Storage Namespace)"
  type        = string
}

variable "bucket_name" {
  description = "Pre-created Object Storage bucket name for the qcow2 upload"
  type        = string
}

variable "image_object_name" {
  description = "Object name for the uploaded NixOS qcow2"
  type        = string
  default     = "nixos-aarch64.qcow2"
}

variable "image_path" {
  description = "Local path to built NixOS qcow2 (from just build-oracle-image)"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key for instance metadata bootstrap (cloud-init authorized_keys)"
  type        = string
}

variable "instance_display_name" {
  description = "Compute instance display name"
  type        = string
  default     = "oracle"
}

variable "instance_shape" {
  description = "Flex instance shape (VM.Standard.A1.Flex or VM.Standard.A2.Flex)"
  type        = string
  default     = "VM.Standard.A1.Flex"
}

variable "image_compatible_shapes" {
  description = "Shapes to register via oci_core_shape_management for the custom image"
  type        = list(string)
  default     = ["VM.Standard.A1.Flex", "VM.Standard.A2.Flex"]
}

variable "instance_ocpus" {
  description = "Flex instance OCPU count"
  type        = number
  default     = 4
}

variable "instance_memory_gbs" {
  description = "Flex instance memory in GiB"
  type        = number
  default     = 24
}

variable "availability_domain" {
  description = "Optional availability domain name; first AD in compartment when empty"
  type        = string
  default     = ""
}

variable "vcn_cidr" {
  description = "VCN CIDR block"
  type        = string
  default     = "10.42.0.0/16"
}

variable "public_subnet_cidr" {
  description = "Public subnet CIDR block"
  type        = string
  default     = "10.42.1.0/24"
}

variable "reserve_public_ip" {
  description = "Create a RESERVED public IPv4 (floating until assigned). Default false — enable for IP stability; see README migration steps."
  type        = bool
  default     = false
}

variable "assign_reserved_public_ip" {
  description = "Assign the reserved public IP to the instance primary private IP (replaces ephemeral public IP). Requires reserve_public_ip = true. Default false."
  type        = bool
  default     = false
}

variable "reserved_public_ip_display_name" {
  description = "Display name for the reserved public IP resource"
  type        = string
  default     = "oracle-reserved-public-ip"
}
