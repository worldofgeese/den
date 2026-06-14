# Oracle Cloud Free Tier — NixOS ARM (A1/A2 Flex)

Terraform/OpenTofu scaffold for importing a Den-built NixOS OCI qcow2 and launching a Flex ARM instance (default `VM.Standard.A1.Flex`, 2 OCPU / 12 GiB).

**Operations docs (Diátaxis):** [docs/oracle/](../../docs/oracle/) — build tutorial, deploy/peer-relay how-to, speed troubleshooting, reference, network design explanation.

Based on [Oracle Cloud NixOS](https://erikparawell.com/oracle-cloud-nixos.html), adapted for this repo.

## Prerequisites

1. Oracle Cloud Free Tier account with Always Free A1 capacity in your region.
2. Object Storage bucket created manually (Storage → Buckets → Create Bucket).
3. API signing key uploaded (Profile → User Settings → API Keys → Add API Key).
4. Built image: `just build-oracle-image` from repo root (ARM host or binfmt for cross-build).

## OCI dashboard values

| Variable | Where to find it |
|----------|------------------|
| `tenancy_ocid` | Profile (avatar) → Tenancy → **Copy OCID** |
| `user_ocid` | Profile → **User Settings** → **Copy OCID** |
| `fingerprint` | Profile → User Settings → **API Keys** → key fingerprint |
| `private_key_path` | Path to PEM saved when creating the API key (**never paste key text into git**) |
| `region` | Console region picker (e.g. `eu-frankfurt-1`, `us-ashburn-1`) |
| `compartment_ocid` | Identity → Compartments → your compartment → **Copy OCID** |
| `namespace` | Profile → Tenancy → **Object Storage Namespace** |
| `bucket_name` | Storage → Buckets → bucket you created |
| `ssh_public_key` | Your local `~/.ssh/id_ed25519.pub` (injected via instance metadata at launch) |

## Configure

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars — keep terraform.tfvars out of git (include ssh_public_key)
just build-oracle-image
```

## Provision (after tfvars ready)

```bash
just oracle-tofu-init
just oracle-tofu-validate
just oracle-tofu-plan
just oracle-tofu-apply   # explicit — uploads qcow2, imports image (~30–45 min), launches VM
```

```bash
ssh nixos@$(just oracle-tofu-output instance_public_ip)
```

After first boot, deploy NixOS config and Tailscale peer relay: [docs/oracle/how-to-deploy-and-peer-relay.md](../../docs/oracle/how-to-deploy-and-peer-relay.md).

## What Terraform creates

- Minimal public VCN/subnet/IGW/security list (SSH 22, Tailscale peer relay UDP 40000)
- Object Storage upload of qcow2
- Custom image import (`PARAVIRTUALIZED`)
- `oci_core_shape_management` for each shape in `image_compatible_shapes` (default A1 + A2)
- `oci_core_compute_image_capability_schema` (UEFI_64 + paravirtualized boot/network/storage)
- Flex instance (`instance_shape`) depending on shape + capability resources
- Optional **reserved public IP** (`reserve_public_ip` / `assign_reserved_public_ip`, default off)

## Reserved public IP migration

Ephemeral public IPs change on instance replace. Optional reserved IP keeps SSH and Tailscale static relay endpoint stable.

**Defaults:** `reserve_public_ip = false`, `assign_reserved_public_ip = false` — no surprise IP changes on existing applies.

**Cost:** Oracle reserved public IP announcement states no charge; confirm on [OCI price list](https://www.oracle.com/cloud/price-list/) and tenancy billing before enabling. See [docs/oracle/how-to-rebuild-after-reclaim.md](../../docs/oracle/how-to-rebuild-after-reclaim.md).

### Two-step apply (existing instance)

Assigning a reserved IP to a private IP that already has an ephemeral public IP **replaces** the ephemeral address. Expect brief SSH disconnect.

1. In `terraform.tfvars`:

   ```hcl
   reserve_public_ip          = true
   assign_reserved_public_ip  = false
   ```

2. `just oracle-tofu-plan` → `just oracle-tofu-apply`. Note `just oracle-tofu-output reserved_public_ip`.

3. When ready (maintenance window):

   ```hcl
   assign_reserved_public_ip = true
   ```

4. Plan and apply again. Update NixOS `--relay-server-static-endpoints`, `Justfile` deploy host, and `modules/ssh.nix` if the effective IP changed.

5. `just oracle-tofu-backup-state`

**New instances:** same two-step flow, or set both `true` on first apply if you accept assigning at launch (still replaces ephemeral).

**Outputs:** `instance_public_ip` (effective), `reserved_public_ip`, `instance_ephemeral_public_ip`, `reserved_public_ip_assigned`.

## Terraform state backup

State is local (`terraform.tfstate`) and gitignored. Back up to gopass after apply:

```bash
just oracle-tofu-backup-state
```

Restore: `just oracle-tofu-restore-state`. Paths: `dev/oci/oracle-cloud-nixos/terraform-state` (+ `.backup`). Details: [docs/oracle/how-to-rebuild-after-reclaim.md](../../docs/oracle/how-to-rebuild-after-reclaim.md).

## A2 bootstrap when A1 is out of capacity

If `just oracle-tofu-apply` fails with **Out of host capacity** for `VM.Standard.A1.Flex`, bootstrap on paid `VM.Standard.A2.Flex` during Free Trial, then switch back to A1:

1. In `terraform.tfvars`, set `instance_shape = "VM.Standard.A2.Flex"`.
2. Run `just oracle-tofu-plan` and `just oracle-tofu-apply`.
3. Confirm SSH access and that NixOS boots.
4. Change `instance_shape` back to `"VM.Standard.A1.Flex"`.
5. Run `just oracle-tofu-plan` and `just oracle-tofu-apply` again (instance replace when A1 capacity available).

**Note:** A2 is not Always Free. It can consume Free Trial credits or incur paid charges while the A2 instance runs.

## Troubleshooting

- **Out of host capacity (A1)** — try the A2 bootstrap flow above, or retry in another availability domain/region.
- **Shape not compatible** — confirm `oci_core_shape_management` resources exist for your target shape; re-apply if missing.
- **Instance unresponsive after boot** — re-apply capability schema or use console “Edit image capabilities → Save”.
- **Build fails on x86_64** — enable `boot.binfmt.emulatedSystems = [ "aarch64-linux" ];` on build host.
