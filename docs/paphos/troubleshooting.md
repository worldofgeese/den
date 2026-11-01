# Troubleshooting: paphos

## Forgejo unreachable on tailnet

1. `systemctl status tailscaled tailscale-serve-forgejo forgejo`
2. `tailscale serve status`
3. Re-run serve: `sudo systemctl restart tailscale-serve-forgejo.service`
4. Local check: `curl -v http://127.0.0.1:3000/`

## Backup fails

1. `journalctl -u paphos-forgejo-backup.service -e`
2. Secret present: `ls -l /run/agenix/paphos-mother-backup-ssh-key`
3. SSH test from paphos, with the options of the service:
   ```bash
   sudo ssh -i /run/agenix/paphos-mother-backup-ssh-key -o IdentitiesOnly=yes -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=yes -p 2235 taohansen@192.168.99.200 echo ok
   ```
   "Permission denied (publickey)" means that mother refuses the key: check its `from=` addresses. "Host key verification failed" means that mother's key differs from the pin in `modules/_host-keys.nix`.
4. Confirm mother backup path exists and is writable.

## Health check spams Telegram

- Fix underlying failure (see journal: `journalctl -u paphos-health-check.service`)
- Stale backup: run `paphos-forgejo-backup.service` manually
- False `nixos-upgrade-failed`: `systemctl reset-failed nixos-upgrade.service`

## No Telegram notifications

- `telegram-lbob-bot-token` must decrypt on paphos
- Chat id in `modules/paphos/ops.nix` must match your Telegram user
- Test with `paphos-health-check-test.service` after stopping a service
