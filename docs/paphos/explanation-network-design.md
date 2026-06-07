# Explanation: Network and exposure

## Tailscale Serve for Forgejo

Forgejo listens on `127.0.0.1:3000` (default HTTP bind). `tailscale-serve-forgejo.service` runs:

```bash
tailscale serve --bg http://127.0.0.1:3000
```

Tailnet clients use `https://paphos.hound-celsius.ts.net/` (MagicDNS + Serve TLS). No public port 3000 on the host firewall.

## Firewall

`networking.firewall.trustedInterfaces = [ "tailscale0" ]` allows tailnet traffic. `allowedTCPPorts` is empty so Forgejo is not exposed on the LAN/WAN interface.

SSH for administration uses Tailscale (`ssh paphos`). Initrd SSH on port 2222 remains configured in `hardware.nix` for disk unlock.

## Backups

Backup traffic uses Tailscale to `mother.hound-celsius.ts.net:2235`, not the public internet.
