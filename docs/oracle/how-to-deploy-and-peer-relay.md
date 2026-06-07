# How-to: Deploy NixOS config and enable Tailscale peer relay

## Deploy configuration changes

After the instance exists, push flake updates from a machine with SSH access:

```bash
just deploy-oracle
```

Defaults: `--target-host` and `--build-host` both `nixos@130.61.182.149`. Override when the public IP changes:

```bash
just deploy-oracle host=nixos@NEW_IP build-host=nixos@NEW_IP
```

Manual equivalent:

```bash
just update
NIX_CONFIG='warn-dirty = false' nixos-rebuild switch --flake .#oracle \
  --target-host nixos@130.61.182.149 \
  --build-host nixos@130.61.182.149 \
  --use-remote-sudo
```

Building on the ARM instance avoids cross-compiling the full system closure on x86_64.

## What the NixOS module enables

`modules/oracle/_configuration.nix` sets:

- `services.tailscale.enable = true`
- `services.tailscale.extraSetFlags = [ "--relay-server-port=40000" ]`
- Firewall UDP 40000 and `trustedInterfaces = [ "tailscale0" ]`
- **No** exit node, subnet router, or `useRoutingFeatures` — peer relay only

OCI security list mirrors UDP 40000 (see `terraform/oracle/main.tf`).

## Authenticate Tailscale (first boot)

The module does not ship an auth key. On the instance:

```bash
sudo tailscale up
```

Follow the login URL. After login, confirm relay port:

```bash
tailscale set --relay-server-port=40000
tailscale status --json | jq '.Self.CapMap'
```

On reboot, `tailscaled-set` re-applies `extraSetFlags` once Tailscale is running.

## Tailnet policy (grants)

Peer relay requires a grant in the tailnet policy file (Admin console → Access controls). Example pattern:

```json
{
  "grants": [
    {
      "src": ["tag:homelab-clients"],
      "dst": ["tag:oracle-relay"],
      "app": {
        "tailscale.com/cap/relay": []
      }
    }
  ]
}
```

Tag `oracle` (or the relay node) with `tag:oracle-relay`. Adjust `src`/`dst` to your tags. See [Tailscale peer relay docs](https://tailscale.com/docs/features/peer-relay).

## Optional: static relay endpoint

If STUN discovery advertises the wrong public address, set the instance public IP explicitly:

```bash
sudo tailscale set \
  --relay-server-port=40000 \
  --relay-server-static-endpoints="PUBLIC_IP:40000"
```

Replace `PUBLIC_IP` with `just oracle-tofu-output instance_public_ip` (or current elastic IP).

## Verify relay is usable

From another tailnet node:

```bash
tailscale ping oracle
tailscale netcheck
```

When direct paths fail, connections may show `peer-relay` in `tailscale status`. See [speed troubleshooting](how-to-troubleshoot-speed.md).
