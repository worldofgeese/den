# Reference: Oracle operations

Quick lookup for Terraform, NixOS, ports, and commands. No narrative — see [tutorial](tutorial-build-and-provision.md) and [how-to guides](how-to-deploy-and-peer-relay.md) for procedures.

## Just recipes

| Recipe | Purpose |
|--------|---------|
| `just build-oracle-image` | Build aarch64 OCI qcow2 → `result/nixos.qcow2` |
| `just check-oracle-image` | Evaluate image derivation without building |
| `just deploy-oracle [host] [build-host]` | Remote `nixos-rebuild switch` for `.#oracle` |
| `just oracle-tofu-init` | OpenTofu init |
| `just oracle-tofu-validate` | OpenTofu validate |
| `just oracle-tofu-fmt` / `oracle-tofu-fmt-check` | Format check |
| `just oracle-tofu-plan` | Plan (needs `terraform.tfvars`) |
| `just oracle-tofu-apply` | Apply infrastructure |
| `just oracle-tofu-output <name>` | Raw output (`instance_public_ip`, `ssh_command`, …) |
| `just oracle-tofu-backup-state` | Copy `terraform.tfstate` (+ backup) to gopass |
| `just oracle-tofu-restore-state` | Restore state from gopass (destructive overwrite) |

Default deploy host: `nixos@158.180.52.169`.

## Flake outputs

| Output | Description |
|--------|-------------|
| `nixosConfigurations.oracle` | NixOS system for live deploy |
| `packages.aarch64-linux.oracle-image` | OCI qcow2 disk image |

Evaluate without build:

```bash
nix eval --no-warn-dirty .#nixosConfigurations.oracle.config.system.build.toplevel.drvPath
```

## Terraform / tfvars

| Variable | Required | Notes |
|----------|----------|-------|
| `tenancy_ocid`, `user_ocid`, `fingerprint`, `private_key_path`, `region` | yes | OCI provider auth |
| `compartment_ocid` | yes | Resource compartment |
| `namespace`, `bucket_name` | yes | Object Storage for qcow2 |
| `image_path` | yes | Local qcow2 (e.g. `../../result/nixos.qcow2`) |
| `ssh_public_key` | yes | Instance metadata |
| `instance_shape` | no | Default `VM.Standard.A1.Flex` |
| `instance_ocpus` / `instance_memory_gbs` | no | Default 4 / 24 |
| `image_compatible_shapes` | no | Default A1 + A2 |
| `reserve_public_ip` | no | Default `false` — create floating reserved IPv4 |
| `assign_reserved_public_ip` | no | Default `false` — attach reserved IP to instance (requires `reserve_public_ip`) |

Dashboard lookup table: [terraform/oracle/README.md](../../terraform/oracle/README.md).

## Reclaim and rebuild

Always Free idle reclaim (7 days: CPU, network, memory all &lt; 20%): [how-to-rebuild-after-reclaim.md](how-to-rebuild-after-reclaim.md).

State backup gopass paths: `dev/oci/oracle-cloud-nixos/terraform-state`, `.../terraform-state.backup`.

## Network ports

| Port | Protocol | Where | Purpose |
|------|----------|-------|---------|
| 22 | TCP | OCI SL + NixOS firewall | SSH |
| 40000 | UDP | OCI SL + NixOS firewall | Tailscale peer relay |
| 41641 | UDP | Tailscale (dynamic) | WireGuard / STUN (Tailscale default; opened via service if `openFirewall`) |

Peer relay uses **40000** explicitly via `extraSetFlags`.

## NixOS module knobs (`modules/oracle/_configuration.nix`)

| Setting | Value |
|---------|-------|
| `services.tailscale.enable` | `true` |
| `services.tailscale.extraSetFlags` | `--relay-server-port=40000`, `--relay-server-static-endpoints=158.180.52.169:40000` |
| `networking.firewall.allowedUDPPorts` | `[ 40000 ]` |
| Exit node / subnet router | disabled (defaults) |
| `system.autoUpgrade.enable` | `true` |
| `system.autoUpgrade.flake` | `github:worldofgeese/den#oracle` |
| `system.autoUpgrade.dates` | `04:00` daily (+ `45min` randomized delay) |
| `system.autoUpgrade.allowReboot` | `true` (hours 04:00–05:00 local, only when upgrade requires it) |
| `system.autoUpgrade.flags` | `[ "--print-build-logs" ]` (no `--update-input`; remote GitHub flake cannot mutate lockfile on host) |
| `nix.gc.automatic` | `true` (`--delete-older-than 8d`) |
| `nix.optimise.automatic` | `true` |
| `systemd.services.oracle-anti-idle-cpu` | enabled — low-priority `stress-ng` CPU load |

### Anti-idle CPU load

`oracle-anti-idle-cpu.service` runs continuously with **Nice=19**, **CPUWeight=1**, and **IOSchedulingClass=idle**. One `stress-ng` worker targets roughly **20–25% total CPU** on typical A1.Flex shapes:

| OCPUs | `--cpu-load` | Approx. total CPU |
|-------|--------------|-------------------|
| 1 | 25% | ~25% |
| 2 | 46% | ~23% |
| 4 | 90% | ~22.5% |

Formula: `min(max(ocpus × 23, 25), 90)` on a single worker (no synthetic network or memory load).

**Intent:** reduce risk that OCI marks the instance idle (CPU &lt; 20% for 7 days) and reclaims Always Free compute. **Not a guarantee** — Oracle policy and metering can change.

**Trade-offs:** wastes free-tier CPU cycles; real workloads stay preferred via low priority. Disable if undesirable — remove or comment out `systemd.services.oracle-anti-idle-cpu` in `modules/oracle/_configuration.nix`, rebuild, and redeploy. Temporary stop: `sudo systemctl stop oracle-anti-idle-cpu`.

Check: `systemctl status oracle-anti-idle-cpu`, `ps -o pid,nice,cmd -C stress-ng`.

### Automatic maintenance

`systemd` timer `nixos-upgrade.timer` runs daily around **04:00 local** (with up to 45 minutes jitter). Each run fetches `github:worldofgeese/den#oracle` at whatever **flake.lock** is on GitHub `main` and `switch`es if the config changed. Input bumps happen in the repo (e.g. `just update` + push), not on the host — unlike paphos, which uses a local `/etc/nixos#paphos` checkout and can pass `--update-input`.

If the new generation needs a reboot (kernel/initrd change), `nixos-upgrade` reboots only inside the **04:00–05:00** window; otherwise the reboot waits until the next eligible window.

`nix-gc.timer` drops store paths older than **8 days**. `nix-optimise.timer` compacts the store on the default schedule.

Manual deploy (`just deploy-oracle`) still pushes whatever flake you have locally; auto-upgrade tracks **GitHub `main`**, not an uncommitted working tree.

## Sysctl (BBR) — not on oracle

BBR tuning applies to **loving-kypris** (and similar Linux servers), not oracle. Typical production values:

```bash
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
```

**mother** (Synology): kernel 4.4 — only `cubic`/`reno`; BBR unavailable.

## Tailscale CLI

```bash
tailscale up                          # first auth
tailscale set --relay-server-port=40000
tailscale status
tailscale ping -verbose HOST
tailscale netcheck
```

## SSH

Fleet SSH (`modules/ssh.nix`): `oracle` → `oracle.hound-celsius.ts.net`, `oracle-public` → `158.180.52.169`. Direct:

```bash
ssh nixos@$(just oracle-tofu-output instance_public_ip)
```
