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
| Mother recovery checkpoint heartbeat from loving-kypris &lt; 36h | `mother-checkpoint-stale-Nh` or `mother-checkpoint-never` |
| `paphos-firmware-update.service` not failed | `firmware-update-failed` |

On failure, a Telegram message is sent using agenix secret `telegram-lbob-bot-token` and chat id `488228716` (in `modules/paphos/ops.nix`).

## Manual test

```bash
sudo systemctl start paphos-health-check-test.service
sudo journalctl -u paphos-health-check-test.service -n 20
```

Exit code 0 = all checks passed. Failures notify Telegram but do not page on success.

## loving-kypris liveness (every 2 minutes)

`paphos-loving-kypris-liveness.timer` runs `paphos-loving-kypris-liveness.service`. It checks two targets:

| Target | Probe |
|--------|-------|
| Host | LAN ping or TCP 22 on `192.168.99.134`, else `tailscale ping 100.80.28.13` |
| Home Assistant | HTTPS `GET /manifest.json` returns 200 on `home-assistant.hound-celsius.ts.net` (HA has no LAN port) |

A target that fails for 10 minutes without a break sends `loving-kypris DOWN: ...` to Telegram. A normal reboot takes about 6.5 minutes, so it does not alert. While the target stays down, the message repeats every 2 hours. The first passing sample after an alert sends `loving-kypris RECOVERED: ...` with the outage time. There is no blackout window, because the nightly update reboot is the event that hung on 2026-11-02. The state is in `/var/lib/paphos-lk-liveness`. This check only reports. It does not power-cycle anything.

Manual run:

```bash
sudo systemctl start paphos-loving-kypris-liveness.service
sudo journalctl -u paphos-loving-kypris-liveness.service -n 20
```

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
