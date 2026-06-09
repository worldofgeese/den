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

## Oracle relay checks (hourly)

`paphos-oracle-relay-check.timer` runs `paphos-oracle-relay-check.service`:

| Check | Failure signal |
|-------|----------------|
| Local `tailscaled.service` active | `tailscaled-local` |
| `tailscale ping` to oracle Tailscale IP `100.87.121.45` (3 attempts, 8s timeout, 5s between) | `oracle-tailscale-ping-…` |
| Oracle peer visible in `tailscale status --json` | `oracle-tailscale-status` |
| TCP 22 on `oracle.hound-celsius.ts.net` | `oracle-ssh-tcp-…` |

Manual test:

```bash
sudo systemctl start paphos-oracle-relay-check-test.service
sudo journalctl -u paphos-oracle-relay-check-test.service -n 20
```

Does not probe UDP 40000 relay port (no fake relay traffic). Confirms tailnet reachability only.

## Token setup

Ensure `secrets/telegram-lbob-bot-token.age` decrypts on paphos and contains the bot token (not committed in plaintext). Re-key with agenix if you rotate the token.
