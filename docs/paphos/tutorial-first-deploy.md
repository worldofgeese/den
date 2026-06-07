# Tutorial: First deploy and verify

Assumes flake checkout on paphos at `/etc/nixos` and SSH alias `paphos` on your workstation.

## 1. Deploy configuration

```bash
just deploy-paphos
```

## 2. Verify Forgejo (tailnet only)

```bash
curl -fsS https://paphos.hound-celsius.ts.net/ | head
```

Port 3000 is not exposed on the public firewall; HTTPS is via Tailscale Serve.

## 3. Run backup once

On paphos:

```bash
sudo systemctl start paphos-forgejo-backup.service
sudo journalctl -u paphos-forgejo-backup.service -n 30
```

On mother, confirm a timestamped directory under Johnny Decimal path `71 Server backups/paphos/forgejo`.

## 4. Test health check

```bash
sudo systemctl start paphos-health-check-test.service
echo $?   # 0 = healthy
```

Force a failure (stop Forgejo) to confirm Telegram alert if token secret is present.
