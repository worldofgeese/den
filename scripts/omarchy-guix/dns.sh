# omarchy-dns  (Guix: Tailscale MagicDNS writes /etc/resolv.conf)
#
# Bare, it names the provider for the menu's `checked` test; nothing matches,
# so no entry is ticked.
if (($# == 0)); then
  echo Tailscale
  exit 0
fi
omarchy-notification-send "DNS is managed by Tailscale" \
  "Tailscale MagicDNS writes /etc/resolv.conf. Change nameservers in the Tailscale admin console under DNS."
exit 1
