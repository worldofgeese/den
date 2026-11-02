# omarchy-den-apps {list | add ATTR... | remove ATTR...}
#
# The Install and Remove menus' package list. It lives in den, as a JSON list of
# nixpkgs attribute paths that modules/omarchy.nix adds to home.packages, and a
# change is applied with `just deploy-mahakala-hm-only`. A failed deploy puts
# the previous list back.
set -euo pipefail
den=${DEN_DIR:-$HOME/.config/home-manager}
list=$den/modules/omarchy-apps.json
usage() { echo "Usage: omarchy-den-apps {list | add ATTR... | remove ATTR...}" >&2; exit 2; }
[[ -f $list ]] || { echo "No den app list at $list. Set DEN_DIR to your den checkout." >&2; exit 1; }
cmd=${1:-list}
(($#)) && shift
case $cmd in
  list) jq -r '.[]' "$list"; exit 0 ;;
  add) filter='(. + $a) | unique' ;;
  remove) filter='. - $a' ;;
  *) usage ;;
esac
(($#)) || usage
new=$(jq --argjson a "$(printf '%s\n' "$@" | jq -R . | jq -s .)" "$filter" "$list")
if [[ $new == "$(jq . "$list")" ]]; then
  echo "den's app list already matches; nothing to apply."
  exit 0
fi
backup=$(mktemp)
trap 'rm -f "$backup"' EXIT
cp "$list" "$backup"
printf '%s\n' "$new" >"$list"
echo "den app list ($list):"
jq -r '.[] | "  " + .' "$list"
echo
echo "Applying: just deploy-mahakala-hm-only"
if ! (cd "$den" && just deploy-mahakala-hm-only); then
  cp "$backup" "$list"
  echo "The deploy failed, so $list was put back." >&2
  exit 1
fi
echo
echo "Applied. Commit modules/omarchy-apps.json in $den to keep it."
