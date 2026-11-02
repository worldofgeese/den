# omarchy-pkg-drop PACKAGE...  (Guix: removes from den's app list, then deploys)
#
# Only what the Install menu added can be removed here. Anything else is
# declared elsewhere in den, so this fails rather than leave the remove script
# to carry on as if it had gone.
set -euo pipefail
table=@table@
appmap=@appmap@
current=$(@denApps@ list) || exit 1
listed=()
[[ -z $current ]] || mapfile -t listed <<<"$current"
attrs=()
missing=()
for pkg in "$@"; do
  row=$(awk -F'\t' -v p="$pkg" '$1 == p { print $2 "\t" $3; exit }' "$table")
  kind=${row%%$'\t'*}
  attr=${row#*$'\t'}
  [[ $kind == app ]] && attr=$(awk -F'\t' -v k="$attr" '$1 == k { print $2; exit }' "$appmap")
  [[ -n $kind && -n $attr ]] || attr=$pkg
  if printf '%s\n' "${listed[@]}" | grep -qxF -- "$attr"; then
    attrs+=("$attr")
  elif command -v "$pkg" >/dev/null 2>&1 || command -v "$attr" >/dev/null 2>&1; then
    missing+=("$pkg")
  fi
done
if ((${#missing[@]})); then
  echo "Not removed: ${missing[*]}. They are declared in den outside the" >&2
  echo "Install menu's list (modules/ or guix/); remove them there." >&2
  exit 1
fi
if ((${#attrs[@]})); then
  @denApps@ remove "${attrs[@]}"
fi
