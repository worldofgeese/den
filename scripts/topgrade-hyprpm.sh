#!/usr/bin/env bash
set -euo pipefail

if ! repositories=$(hyprpm list); then
  echo 'Could not list Hyprland plugin repositories.' >&2
  exit 1
fi

plain=$(printf '%s\n' "$repositories" | sed -E $'s/\033\\[[0-9;]*m//g')
arrow=$'\342\206\222'
tree=$'\342\224\202'
branch=$'\342\224\224\342\224\200'
has_repository=false

while IFS= read -r line; do
  case $line in
    ""|"$arrow The hyprpm state store doesn't exist. Creating now...")
      ;;
    "$arrow Repository "*' (by '*'):')
      has_repository=true
      ;;
    "  $tree Plugin "*|"  $branch enabled: "*)
      if [[ $has_repository == false ]]; then
        printf 'Unexpected Hyprpm list output: %s\n' "$line" >&2
        exit 1
      fi
      ;;
    *)
      printf 'Unexpected Hyprpm list output: %s\n' "$line" >&2
      exit 1
      ;;
  esac
done <<<"$plain"

if [[ $has_repository == false ]]; then
  echo 'No Hyprland plugin repositories are registered.'
  exit 0
fi

printf '%s\n' "$repositories"
exec hyprpm update
