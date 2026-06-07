# How-to: Health checks and Telegram

## Checks (hourly)

`paphos-health-check.timer` runs `paphos-health-check.service`:

| Check | Failure signal |
|-------|----------------|
| Forgejo HTTP on `127.0.0.1:3000` | `forgejo-http` |
| `tailscaled.service` active | `tailscaled` |
| `nixos-upgrade.service` not failed | `nixos-upgrade-failed` |
| `forgesync-github.timer` active (if present) | `forgesync-timer` |
| Root disk &lt; 90% | `disk-root-Npct` |
| Last backup &lt; 36h | `forgejo-backup-stale-Nh` or `forgejo-backup-never` |

On failure, a Telegram message is sent using agenix secret `telegram-lbob-bot-token` and chat id `488228716` (in `modules/paphos/ops.nix`).

## Manual test

```bash
sudo systemctl start paphos-health-check-test.service
sudo journalctl -u paphos-health-check-test.service -n 20
```

Exit code 0 = all checks passed. Failures notify Telegram but do not page on success.

## Token setup

Ensure `secrets/telegram-lbob-bot-token.age` decrypts on paphos and contains the bot token (not committed in plaintext). Re-key with agenix if you rotate the token.
