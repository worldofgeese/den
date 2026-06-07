data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_ocid
}

data "oci_core_compute_global_image_capability_schemas" "global" {
}

data "oci_core_compute_global_image_capability_schema" "global" {
  compute_global_image_capability_schema_id = data.oci_core_compute_global_image_capability_schemas.global.compute_global_image_capability_schemas[0].id
}

locals {
  availability_domain                         = var.availability_domain != "" ? var.availability_domain : data.oci_identity_availability_domains.ads.availability_domains[0].name
  global_image_capability_schema_version_name = data.oci_core_compute_global_image_capability_schema.global.current_version_name
}

resource "oci_core_vcn" "oracle" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "oracle-nixos"
  dns_label      = "oraclenix"
}

resource "oci_core_internet_gateway" "oracle" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.oracle.id
  display_name   = "oracle-igw"
  enabled        = true
}

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.oracle.id
  display_name   = "oracle-public-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.oracle.id
  }
}

resource "oci_core_security_list" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.oracle.id
  display_name   = "oracle-public-sl"

  ingress_security_rules {
    protocol    = "6"
    source      = "0.0.0.0/0"
    description = "SSH"

    tcp_options {
      min = 22
      max = 22
    }
  }

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
}

resource "oci_core_subnet" "public" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.oracle.id
  cidr_block                 = var.public_subnet_cidr
  display_name               = "oracle-public"
  dns_label                  = "public"
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.public.id]
}

resource "oci_objectstorage_object" "nixos_image" {
  bucket    = var.bucket_name
  namespace = var.namespace
  object    = var.image_object_name
  source    = var.image_path
}

resource "oci_core_image" "nixos" {
  compartment_id = var.compartment_ocid
  display_name   = "NixOS ARM64"

  image_source_details {
    source_type    = "objectStorageTuple"
    namespace_name = var.namespace
    bucket_name    = var.bucket_name
    object_name    = oci_objectstorage_object.nixos_image.object
  }

  launch_mode = "PARAVIRTUALIZED"

  timeouts {
    create = "60m"
  }
}

resource "oci_core_shape_management" "nixos_compat" {
  for_each = toset(var.image_compatible_shapes)

  compartment_id = var.compartment_ocid
  image_id       = oci_core_image.nixos.id
  shape_name     = each.value

  depends_on = [oci_core_image.nixos]
}

moved {
  from = oci_core_shape_management.nixos_a1_compat
  to   = oci_core_shape_management.nixos_compat["VM.Standard.A1.Flex"]
}

resource "oci_core_compute_image_capability_schema" "nixos_caps" {
  compartment_id                                      = var.compartment_ocid
  image_id                                            = oci_core_image.nixos.id
  compute_global_image_capability_schema_version_name = local.global_image_capability_schema_version_name

  schema_data = {
    "Compute.Firmware" = jsonencode({
      descriptorType = "enumstring"
      source         = "IMAGE"
      defaultValue   = "UEFI_64"
      values         = ["UEFI_64"]
    })

    "Compute.LaunchMode" = jsonencode({
      descriptorType = "enumstring"
      source         = "IMAGE"
      defaultValue   = "PARAVIRTUALIZED"
      values         = ["PARAVIRTUALIZED", "EMULATED", "CUSTOM", "NATIVE"]
    })

    "Storage.BootVolumeType" = jsonencode({
      descriptorType = "enumstring"
      source         = "IMAGE"
      defaultValue   = "PARAVIRTUALIZED"
      values         = ["PARAVIRTUALIZED", "ISCSI", "SCSI", "IDE", "NVME"]
    })

    "Network.AttachmentType" = jsonencode({
      descriptorType = "enumstring"
      source         = "IMAGE"
      defaultValue   = "PARAVIRTUALIZED"
      values         = ["PARAVIRTUALIZED", "E1000", "VFIO", "VDPA"]
    })
  }
}

resource "oci_core_instance" "oracle" {
  compartment_id      = var.compartment_ocid
  availability_domain = local.availability_domain
  display_name        = var.instance_display_name
  shape               = var.instance_shape

  shape_config {
    memory_in_gbs = var.instance_memory_gbs
    ocpus         = var.instance_ocpus
  }

  source_details {
    source_type             = "image"
    source_id               = oci_core_image.nixos.id
    boot_volume_vpus_per_gb = 10
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.public.id
    assign_public_ip = true
  }

  launch_options {
    network_type     = "PARAVIRTUALIZED"
    boot_volume_type = "PARAVIRTUALIZED"
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
  }

  depends_on = [
    oci_core_shape_management.nixos_compat,
    oci_core_compute_image_capability_schema.nixos_caps,
  ]
}
