# omarchy-channel-set  (Guix: the channel is den's nixarchy flake input)
cat <<MSG
Omarchy comes from the nixarchy input that den pins in flake.nix, so there is
no channel to switch here. To move it:

  cd ${DEN_DIR:-$HOME/.config/home-manager}
  just update-input nixarchy
  just deploy-mahakala-hm-only

To follow another branch, change nixarchy.url in flake.nix first.
MSG
exit 1
