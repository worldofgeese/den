#!/usr/bin/env bash
# Adapt the Arch Distrobox's pacman hooks to a rootless container. Runs as root
# inside the box, before every Topgrade upgrade, so a recreated box gets the
# same treatment.
#
# The box has no systemd as PID 1 and cannot chown the host's /dev, /tmp and
# /run mounts, so these hooks failed or printed errors on every upgrade:
#  - the sshd restart and systemd reload hooks call systemctl or bail out with
#    "Failed to check for chroot() environment";
#  - the tmpfiles hook tried to chown host-owned paths such as /dev/kvm.
# Pacman runs a hook in /etc/pacman.d/hooks instead of the packaged one of the
# same name, and skips it entirely when that file is a link to /dev/null.
set -euo pipefail

hooks=/etc/pacman.d/hooks
mkdir -p "$hooks"
for hook in \
  10-openssh-mark-sshd-for-restart \
  25-systemd-sysctl \
  30-systemd-daemon-reload-system \
  30-systemd-daemon-reload-user \
  35-systemd-enqueue-marked \
  35-systemd-udev-reload \
  70-openssh-restart-sshd \
  dbus-reload; do
  ln -sfn /dev/null "$hooks/$hook.hook"
done

cat >"$hooks/21-systemd-tmpfiles.hook" <<'HOOK'
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Target = usr/lib/tmpfiles.d/*.conf

[Action]
Description = Creating temporary files (container-owned paths only)...
When = PostTransaction
Exec = /usr/bin/systemd-tmpfiles --create --exclude-prefix=/dev --exclude-prefix=/tmp --exclude-prefix=/run
HOOK

# The openssl package ships this directory as 0700; the image has it at 0755,
# and pacman warns about the mismatch on every openssl upgrade.
chmod 0700 /etc/ssl/private
