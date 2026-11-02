#!@bash@
# mahakala agent unlock: one unattended reboot, BitLocker "suspend for one
# reboot" style. See the agent-unlock comment in guix/system.scm.
#
#   agent-unlock arm      stage a one-shot disk key and BootNext, no reboot
#   agent-unlock reboot   arm, then reboot
#   agent-unlock cleanup  boot service: wipe the key, record the boot mode
#   agent-unlock status   show slot, key, entry and boot mode
set -euo pipefail
PATH=@path@
umask 077

luks_uuid=@luks_uuid@
esp_uuid=@esp_uuid@
slot=@slot@
label="Agent unlock"
esp=/boot/efi
esp_dir=$esp/EFI/agent-unlock
loader='\EFI\agent-unlock\grubx64.efi'
run=/run/agent-unlock
grub=@grub@

die() { echo "agent-unlock: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" = 0 ] || die "run as root (sudo agent-unlock $1)"; }
device() { readlink -f "/dev/disk/by-uuid/$luks_uuid"; }
slot_active() { cryptsetup luksDump "$(device)" | grep -q "^Key Slot $slot: ENABLED"; }
entry() { efibootmgr | awk -F'\t' -v l="$label" '$1 ~ /^Boot[0-9A-Fa-f]{4}/ { n = $1; sub(/^Boot/, "", n); id = substr(n, 1, 4); sub(/^[0-9A-Fa-f]{4}\*? /, "", n); if (n == l) { print id; exit } }'; }
esp_mounted() { findmnt -n "$esp" >/dev/null || die "$esp is not mounted"; }

kill_slot() {
  slot_active || return 0
  # luksKillSlot without a TTY demands a key for ANOTHER slot; removing by
  # the key itself needs no other secret.
  if [ -s "$esp_dir/key" ] &&
     cryptsetup luksRemoveKey --batch-mode --key-file "$esp_dir/key" "$(device)" </dev/null; then
    slot_active || return 0
  fi
  # Key lost: batch mode on a pseudo-TTY skips verification. Slot 0 (the
  # user's passphrase) is never touched.
  script -qec "cryptsetup luksKillSlot --batch-mode $(device) $slot" /dev/null </dev/null >/dev/null || true
  ! slot_active || die "could not kill LUKS slot $slot"
}

wipe_key() {
  if [ -e "$esp_dir/key" ]; then
    # FAT has no secure overwrite guarantee; overwrite best-effort, then remove.
    shred -u "$esp_dir/key" 2>/dev/null || rm -f "$esp_dir/key"
    sync
  fi
}

build_image() {
  local cfg tmp
  cfg=$(mktemp) tmp=$(mktemp)
  cat >"$cfg" <<EOF
insmod part_gpt
insmod fat
insmod ext2
insmod luks
insmod cryptodisk
insmod procfs
search --no-floppy --fs-uuid --set=esp $esp_uuid
if [ -f (\$esp)/EFI/agent-unlock/key ]; then
  cryptomount -k (\$esp)/EFI/agent-unlock/key -u ${luks_uuid//-/}
fi
# Already open when the key worked; otherwise this is the normal prompt.
cryptomount -u ${luks_uuid//-/}
set root=(cryptouuid/${luks_uuid//-/})
set prefix=(\$root)/boot/grub
configfile (\$root)/boot/grub/grub.cfg
EOF
  "$grub/bin/grub-script-check" "$cfg"
  "$grub/bin/grub-mkstandalone" -O x86_64-efi -o "$tmp" \
    --modules="part_gpt fat ext2 luks cryptodisk gcry_rijndael gcry_sha256 procfs search configfile normal" \
    "boot/grub/grub.cfg=$cfg"
  mkdir -p "$esp_dir"
  cp "$tmp" "$esp_dir/grubx64.efi.new"
  mv "$esp_dir/grubx64.efi.new" "$esp_dir/grubx64.efi"
  rm -f "$cfg" "$tmp"
}

ensure_entry() {
  local disk part
  if [ -z "$(entry)" ]; then
    disk=/dev/$(lsblk -no PKNAME "$(findmnt -no SOURCE "$esp")")
    part=$(cat "/sys/class/block/$(basename "$(findmnt -no SOURCE "$esp")")/partition")
    # --create-only: never enters BootOrder, so it is reachable only via BootNext.
    efibootmgr --create-only --disk "$disk" --part "$part" --label "$label" --loader "$loader" >/dev/null
  fi
  [ -n "$(entry)" ] || die "could not create the '$label' boot entry"
}

arm() {
  need_root arm
  esp_mounted
  build_image
  ensure_entry
  mkdir -p "$run"
  kill_slot
  head -c 64 /dev/urandom >"$run/key"
  # The volume key of the open mapping, so no passphrase is ever needed.
  dmsetup table --showkeys cryptroot | awk '{print $5}' | tr a-f A-F | basenc --base16 -d >"$run/mk"
  # A 512-bit random key needs no PBKDF stretching; few iterations keep
  # GRUB's unlock fast.
  if ! cryptsetup luksAddKey --batch-mode --key-slot "$slot" --pbkdf-force-iterations 1000 \
         --master-key-file "$run/mk" "$(device)" "$run/key"; then
    shred -u "$run/mk" "$run/key"; die "luksAddKey failed"
  fi
  shred -u "$run/mk"
  cryptsetup open --test-passphrase --key-slot "$slot" --key-file "$run/key" "$(device)" \
    || { kill_slot; shred -u "$run/key"; die "new key does not open slot $slot"; }
  cp "$run/key" "$esp_dir/key"
  shred -u "$run/key"
  sync
  efibootmgr --bootnext "$(entry)" >/dev/null
  echo "armed: slot $slot, BootNext=$(entry) ($label)"
}

cleanup() {
  need_root cleanup
  local mode=interactive
  mkdir -p "$run"
  chmod 755 "$run"
  # This Dell reports a wrong BootCurrent (0000, a stale entry, after a
  # BootNext=agent boot), so the boot is classed by the armed state instead.
  # Fail closed: a boot that was armed but fell back to the passphrase also
  # starts locked, which only costs one extra password.
  if slot_active || [ -e "$esp_dir/key" ]; then mode=agent; fi
  local rc=0
  ( kill_slot ) || rc=$?
  if findmnt -n "$esp" >/dev/null; then wipe_key; fi
  printf '%s\n' "$mode" >"$run/boot-mode.new"
  chmod 644 "$run/boot-mode.new"
  mv "$run/boot-mode.new" "$run/boot-mode"
  echo "boot-mode=$mode"
  return "$rc"
}

status() {
  echo "boot-mode: $(cat "$run/boot-mode" 2>/dev/null || echo unknown)"
  echo "entry:     $(entry || true)"
  efibootmgr | grep -E '^(BootCurrent|BootNext):' || true
  if [ "$(id -u)" = 0 ]; then
    slot_active && echo "slot $slot:    ENABLED" || echo "slot $slot:    disabled"
    [ -e "$esp_dir/key" ] && echo "esp key:   present" || echo "esp key:   absent"
  fi
}

case "${1:-}" in
  arm) arm ;;
  reboot) arm; /run/current-system/profile/sbin/reboot ;;
  cleanup) cleanup ;;
  status) status ;;
  *) echo "usage: agent-unlock {arm|reboot|cleanup|status}" >&2; exit 2 ;;
esac
