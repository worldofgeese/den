#!/usr/bin/env bash
set -euo pipefail

claude --bare plugin marketplace update
marketplaces=$(claude --bare plugin marketplace list --json)
plugins=$(claude --bare plugin list --json)

if ! jq -e 'type == "array" and all(.[]; .name | type == "string")' \
  <<<"$marketplaces" >/dev/null ||
  ! jq -e '
    type == "array" and all(.[];
      (.id | type == "string" and (contains("\u0000") | not)) and
      (.scope | type == "string" and (contains("\u0000") | not)) and
      (.projectPath == null or
        (.projectPath | type == "string" and (contains("\u0000") | not))))
  ' <<<"$plugins" >/dev/null; then
  echo 'Claude returned an invalid marketplace or plugin inventory.' >&2
  exit 1
fi

mapfile -d '' -t fields < <(
  jq --raw-output0 --argjson marketplaces "$marketplaces" '
    .[] | select(.id | contains("@"))
    | . as $plugin
    | select(($plugin.id | split("@") | last) as $market
        | $marketplaces | any(.name == $market))
    | .id, .scope, (.projectPath // "")
  ' <<<"$plugins"
)
if ! wait "$!"; then
  echo 'Failed to select Claude marketplace plugins.' >&2
  exit 1
fi

status=0
for ((index = 0; index < ${#fields[@]}; index += 3)); do
  id=${fields[index]}
  scope=${fields[index + 1]}
  project=${fields[index + 2]}
  printf 'Updating Claude plugin %s\n' "$id"
  if ! (
    if [[ -n $project ]]; then
      cd -- "$project" || exit 1
    fi
    claude --bare plugin update --scope "$scope" -- "$id"
  ); then
    printf 'Failed to update Claude plugin %s.\n' "$id" >&2
    status=1
  fi
done
exit "$status"
