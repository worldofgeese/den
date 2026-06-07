# How-to: Forgejo backup and restore

## What runs

- **Service:** `paphos-forgejo-backup.service`
- **Timer:** daily with up to 45 minutes jitter
- **Target:** `mother` NAS — `/volume1/homes/taohansen/jd/70-79 Operations/71 Server backups/paphos/forgejo/<timestamp>/`
- **Contents:** `forgejo.sql` (PostgreSQL dump), `forgejo-data.tar.gz` (`/var/lib/forgejo`), `SHA256SUMS`

No remote deletion on mother (mother AGENTS forbids `rm`).

## One-time mother setup

Backup SSH public key must be in `taohansen@mother:~/.ssh/authorized_keys`. Key is agenix secret `paphos-mother-backup-ssh-key` on paphos.

Create backup directory (safe on mother):

```bash
ssh mother 'mkdir -p "/volume1/homes/taohansen/jd/70-79 Operations/71 Server backups/paphos/forgejo" && chmod 700 "/volume1/homes/taohansen/jd/70-79 Operations/71 Server backups/paphos/forgejo"'
```

## Manual backup

```bash
sudo systemctl start paphos-forgejo-backup.service
```

## Restore (outline)

On paphos, from a backup timestamp directory on mother:

1. Copy `forgejo.sql` and `forgejo-data.tar.gz` to paphos.
2. Stop Forgejo: `sudo systemctl stop forgejo.service`
3. Restore DB: `sudo -u postgres psql -c 'DROP DATABASE IF EXISTS forgejo;' && sudo -u postgres psql -c 'CREATE DATABASE forgejo OWNER forgejo;' && sudo -u postgres psql forgejo < forgejo.sql`
4. Restore data: `sudo tar -C /var/lib -xzf forgejo-data.tar.gz`
5. Start Forgejo: `sudo systemctl start forgejo.service`

Test on a non-production host before relying on this in an emergency.
