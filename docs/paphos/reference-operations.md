# Reference: paphos operations

## Just recipes

| Recipe | Purpose |
|--------|---------|
| `just deploy-paphos [host]` | Remote `nixos-rebuild switch` for `.#paphos` (default host `paphos`) |
| `just check` | Evaluates paphos among other flake outputs |

## Nix modules

| Path | Role |
|------|------|
| `modules/paphos/forgejo.nix` | Forgejo, forgesync, agenix secrets |
| `modules/paphos/ops.nix` | Backup, health, Tailscale Serve, firewall, `nix.optimise` |
| `modules/paphos/system.nix` | Users, auto-upgrade |
| `modules/paphos/networking.nix` | Hostname, locale, ssh-server aspect |

## Systemd units

| Unit | Schedule |
|------|----------|
| `paphos-forgejo-backup.service` | On demand / daily timer |
| `paphos-forgejo-backup.timer` | Daily + 45min jitter |
| `paphos-health-check.service` | On demand / hourly timer |
| `paphos-health-check.timer` | Hourly + 10min jitter |
| `paphos-health-check-test.service` | Manual test only |
| `tailscale-serve-forgejo.service` | Oneshot after boot |

## Secrets (agenix)

| Secret | Use |
|--------|-----|
| `paphos-mother-backup-ssh-key` | SSH to mother for backups |
| `telegram-lbob-bot-token` | Health alert Telegram bot |

## Firewall

- `tailscale0` trusted
- No public TCP ports (Forgejo via Tailscale Serve HTTPS only)

## Forgejo

- Registration disabled (`DISABLE_REGISTRATION = true`)
- `ROOT_URL` / `DOMAIN`: `paphos.hound-celsius.ts.net`
