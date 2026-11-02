# omarchy-pkg-remove  (Guix: pick from den's app list)
set -uo pipefail
current=$(@denApps@ list) || exit 1
listed=()
[[ -z $current ]] || mapfile -t listed <<<"$current"
if ((${#listed[@]} == 0)); then
  echo "Nothing was added from the Install menu. Every other package is"
  echo "declared in den (modules/ and guix/); remove it there."
  omarchy-show-done 0
  exit 0
fi
picked=$(printf '%s\n' "${listed[@]}" | fzf --multi --color 'pointer:red,marker:red' \
  --header 'Remove from den (tab: multi-select)') || exit 0
mapfile -t picked <<<"$picked"
@denApps@ remove "${picked[@]}"
omarchy-show-done $?
