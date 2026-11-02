# omarchy-pkg-install / omarchy-pkg-aur-install  (Guix: add a nixpkgs package to den)
set -uo pipefail
echo "Packages here are declared in den and applied with Home Manager."
echo "Find a name with 'nix search nixpkgs <word>' or https://search.nixos.org/packages"
echo
read -r -p "nixpkgs attribute(s) to add: " -a attrs
((${#attrs[@]})) || exit 0
@denApps@ add "${attrs[@]}"
omarchy-show-done $?
