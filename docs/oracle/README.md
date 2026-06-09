# Oracle Cloud NixOS documentation

Diátaxis docs for the `oracle` NixOS host (Oracle Cloud Free Tier A1/A2 Flex) and related tailnet speed tooling.

| Quadrant | Document | Purpose |
|----------|----------|---------|
| Tutorial | [Build and provision](tutorial-build-and-provision.md) | First-time path: image → Terraform → SSH |
| How-to | [Deploy config and peer relay](how-to-deploy-and-peer-relay.md) | `just deploy-oracle`, Tailscale auth, relay grants |
| How-to | [Rebuild after reclaim](how-to-rebuild-after-reclaim.md) | State restore, reserved IP, monitoring, full rebuild |
| How-to | [Troubleshoot tailnet speed](how-to-troubleshoot-speed.md) | OpenSpeedtest, BBR, DERP vs direct vs peer-relay |
| Reference | [Operations reference](reference-operations.md) | tfvars, ports, sysctl, commands |
| Explanation | [Network design](explanation-network-design.md) | A2 bootstrap, peer relay vs DERP, mother BBR limits |

Related: [terraform/oracle/README.md](../../terraform/oracle/README.md) (OpenTofu scaffold).
