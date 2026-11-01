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

Backup traffic goes over the home LAN to mother at `192.168.99.200:2235`, not over the public internet. Since 2026-10-31, mother accepts the backup key only from paphos' own addresses (`from=` in its `authorized_keys`). Over MagicDNS, mother refuses the key. paphos pins mother's host key (`modules/_host-keys.nix`), so the backup does not trust a new key on first use.
