# Tutorial: Build and provision Oracle NixOS

Goal: go from zero to SSH on a new `oracle` instance using this repo.

## Prerequisites

- Oracle Cloud Free Tier account with Flex ARM capacity (A1 preferred; see [explanation](explanation-network-design.md) for A2 bootstrap).
- Object Storage bucket created in your tenancy.
- OCI API signing key uploaded (PEM on disk — never commit it).
- SSH key pair for the `nixos` user.
- Build host with Nix flakes and (for x86_64) `boot.binfmt.emulatedSystems = [ "aarch64-linux" ]` if cross-building the image.

## 1. Build the OCI image

From the repo root:

```bash
just build-oracle-image
```

This produces `result/nixos.qcow2` (symlink to the built qcow2).

## 2. Configure Terraform variables

```bash
cp terraform/oracle/terraform.tfvars.example terraform/oracle/terraform.tfvars
```

Edit `terraform.tfvars` with OCIDs, region, bucket, `image_path = "../../result/nixos.qcow2"`, and `ssh_public_key`. Keep `terraform.tfvars` out of git.

See [reference](reference-operations.md) for every variable.

## 3. Initialize and apply OpenTofu

```bash
just oracle-tofu-init
just oracle-tofu-validate
just oracle-tofu-plan
just oracle-tofu-apply
```

Apply uploads the qcow2, imports the custom image (~30–45 minutes), and launches the VM. Security list allows SSH (TCP 22) and Tailscale peer relay (UDP 40000).

## 4. Connect

```bash
ssh nixos@$(just oracle-tofu-output instance_public_ip)
```

Or use the suggested command from `just oracle-tofu-output ssh_command`.

## Next steps

- [Deploy NixOS config and enable Tailscale peer relay](how-to-deploy-and-peer-relay.md)
- [Troubleshoot tailnet throughput](how-to-troubleshoot-speed.md)
