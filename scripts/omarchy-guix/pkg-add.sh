# omarchy-pkg-add PACKAGE...  (Guix: adds to den's app list, then deploys)
#
# Takes Omarchy's Arch package names, as every install script passes them, and
# maps them to nixpkgs attributes with nixarchy's own tables. A name neither
# table knows is taken to be a nixpkgs attribute already.
set -euo pipefail
table=@table@
appmap=@appmap@
(($#)) || { echo "Usage: omarchy-pkg-add <package>..." >&2; exit 1; }
attrs=()
refused=()
for pkg in "$@"; do
  for candidate in "$pkg" "${pkg%-bin}" "${pkg%-stable}"; do
    if command -v "$candidate" >/dev/null 2>&1; then
      echo "$pkg is already installed."
      continue 2
    fi
  done
  row=$(awk -F'\t' -v p="$pkg" '$1 == p { print $2 "\t" $3; exit }' "$table")
  kind=${row%%$'\t'*}
  attr=${row#*$'\t'}
  case $kind in
    app) attr=$(awk -F'\t' -v k="$attr" '$1 == k { print $2; exit }' "$appmap") ;;
    package | font) ;;
    nixos-option | php-extension) refused+=("$pkg is a NixOS $kind ($attr)"); continue ;;
    *) attr=$pkg ;;
  esac
  if [[ -z $attr ]]; then
    refused+=("$pkg needs a NixOS module, which Guix cannot use")
    continue
  fi
  attrs+=("$attr")
done
for reason in "${refused[@]}"; do
  echo "Not added: $reason. Declare it in den by hand." >&2
done
if ((${#attrs[@]})); then
  @denApps@ add "${attrs[@]}"
fi
((${#refused[@]} == 0))
