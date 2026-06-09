# How-to: Rebuild after OCI reclaim or termination

Use when Oracle Cloud **reclaims** an Always Free idle instance, you **terminate** it manually, or the VM is lost but you still have Terraform state and backups.

## Reclaim risk (Always Free idle rule)

Oracle may reclaim Always Free compute when **all** of the following hold for **7 consecutive days**:

| Metric | Threshold |
|--------|-----------|
| CPU | &lt; 20% utilization |
| Network | &lt; 20% utilization |
| Memory | &lt; 20% utilization |

Mitigations here are: **low-priority synthetic CPU load** (`oracle-anti-idle-cpu.service` — intentional, not a guarantee), **real** relay traffic where applicable, **state backup**, **reserved public IP** (optional), **monitoring**, and a **documented rebuild path**. No synthetic network or memory load. Disable the anti-idle service if you prefer not to spend free-tier CPU — see [reference-operations.md](reference-operations.md#anti-idle-cpu-load).

See [Oracle Always Free FAQ](https://www.oracle.com/cloud/free/faq/) and your tenancy console for current policy wording.

## Before disaster: backups and IP stability

### Terraform state (gopass)

State lives in `terraform/oracle/terraform.tfstate` and is **not** in git. Back up after every successful apply:

```bash
just oracle-tofu-backup-state
```

Stores:

| gopass path | Content |
|-------------|---------|
| `dev/oci/oracle-cloud-nixos/terraform-state` | Current `terraform.tfstate` |
| `dev/oci/oracle-cloud-nixos/terraform-state.backup` | Local `.backup` file when present |

Restore before replanning:

```bash
just oracle-tofu-restore-state
just oracle-tofu-init
just oracle-tofu-plan
```

### Reserved public IP (optional)

Reserved IPv4 reduces pain when OCI replaces ephemeral addresses. Terraform support: `reserve_public_ip` / `assign_reserved_public_ip` in `terraform/oracle/` (default **false**).

**Cost:** Oracle announced reserved public IPs with **no charge** for standard assignment; the public pricing page has no separate public-IP SKU as of 2026-06. **Verify** in [OCI pricing](https://www.oracle.com/cloud/price-list/) and your tenancy cost report before enabling. If reserved IPs are unavailable or billed in your region, skip them and update `modules/oracle/_configuration.nix`, `Justfile` deploy host, and `modules/ssh.nix` `oracle-public` after each rebuild.

Migration (existing instance with ephemeral IP): [terraform/oracle/README.md](../../terraform/oracle/README.md#reserved-public-ip-migration).

### Monitoring

`paphos-oracle-relay-check.timer` on paphos (hourly) pings oracle on Tailscale and checks SSH over the tailnet. Failures notify Telegram. See [paphos health checks](../paphos/how-to-health-checks.md).

---

## Rebuild procedure

### 1. Restore Terraform state

```bash
just oracle-tofu-restore-state
just oracle-tofu-init
```

If state is lost entirely, you must import or recreate resources manually — prefer gopass backup.

### 2. Build image (if qcow2 missing locally)

```bash
just build-oracle-image
```

Ensure `terraform.tfvars` `image_path` points at `result/nixos.qcow2`.

### 3. Plan and apply infrastructure

```bash
just oracle-tofu-plan
just oracle-tofu-apply
```

- **A1 out of capacity:** bootstrap on A2, then switch back — [terraform/oracle/README.md](../../terraform/oracle/README.md#a2-bootstrap-when-a1-is-out-of-capacity).
- **Reserved IP enabled:** confirm `just oracle-tofu-output instance_public_ip` matches expectations before updating NixOS static relay endpoint.

Back up state again after apply:

```bash
just oracle-tofu-backup-state
```

### 4. SSH and first boot

```bash
ssh nixos@$(just oracle-tofu-output instance_public_ip)
```

### 5. Tailscale auth and relay

On the instance:

```bash
sudo tailscale up
sudo tailscale set --relay-server-port=40000
tailscale status
```

Grant peer relay in tailnet ACL ([how-to-deploy-and-peer-relay.md](how-to-deploy-and-peer-relay.md)).

### 6. Update static relay endpoint and deploy NixOS

When the **public IP changed** (no reserved IP, or new reservation):

1. Edit `modules/oracle/_configuration.nix` — `--relay-server-static-endpoints=NEW_IP:40000`.
2. Edit `Justfile` `deploy-oracle` default host.
3. Edit `modules/ssh.nix` `oracle-public` `HostName` if used.
4. Deploy:

```bash
just deploy-oracle host=nixos@NEW_IP build-host=nixos@NEW_IP
```

With reserved IP assigned, `NEW_IP` should match `just oracle-tofu-output reserved_public_ip`.

### 7. Verify from another tailnet node

```bash
tailscale ping oracle
tailscale netcheck
```

On paphos (after deploy):

```bash
sudo systemctl start paphos-oracle-relay-check-test.service
```

---

## Fallback without reserved IP

If reserved IP create/assign fails (quota, policy, or cost):

1. Use ephemeral IP from `just oracle-tofu-output instance_public_ip` after apply.
2. Update static endpoint + deploy host + SSH config as in step 6.
3. Rely on Terraform state backup + monitoring to detect outages quickly.

## Related

- [Build and provision](tutorial-build-and-provision.md)
- [Deploy config and peer relay](how-to-deploy-and-peer-relay.md)
- [Operations reference](reference-operations.md)
