#!/usr/bin/env bash
set -euo pipefail

inventory=$(gh skill list --json path,sourceURL,pinned)
if ! jq -e '
  type == "array" and all(.[];
    (.path | type == "string" and startswith("/") and (endswith("/") | not) and (contains("\u0000") | not)) and
    (.sourceURL == null or (.sourceURL | type == "string")) and
    (.pinned | type == "boolean"))
' <<<"$inventory" >/dev/null; then
  echo 'GitHub CLI returned an invalid skill inventory.' >&2
  exit 1
fi

mapfile -d '' -t skills < <(
  jq --raw-output0 '.[] | select(.sourceURL != null and .sourceURL != "" and .pinned == false) | .path' <<<"$inventory"
)
if ! wait "$!"; then
  echo 'Failed to select GitHub-managed skills.' >&2
  exit 1
fi

if ((${#skills[@]} == 0)); then
  echo 'No unpinned GitHub-managed skills to update.'
  exit 0
fi

umask 077
backup_base=${XDG_STATE_HOME:-$HOME/.local/state}/den/skill-backups
mkdir -p "$backup_base"
backup_run=$(mktemp -d "$backup_base/gh-XXXXXXXX")
printf 'Skill backups: %s\n' "$backup_run"
stderr_file=$(mktemp "${TMPDIR:-/tmp}/den-gh-skill-stderr.XXXXXXXX")
trap 'rm -f -- "$stderr_file"' EXIT
index=0

for path in "${skills[@]}"; do
  directory=${path%/*}
  name=${path##*/}
  target=$(readlink -f -- "$path")
  if [[ ! -d $target ]]; then
    printf 'Skill directory is missing: %s\n' "$path" >&2
    exit 1
  fi
  index=$((index + 1))
  mkdir "$backup_run/$index"
  cp -a -- "$target" "$backup_run/$index/$name"
  printf 'Updating GitHub-managed skill %s\n' "$name"
  check_status=0
  gh skill update --all --force --dry-run --dir "$directory" -- "$name" \
    >/dev/null 2>"$stderr_file" || check_status=$?
  check_stderr=$(<"$stderr_file")
  if ((check_status != 0)) ||
    [[ $check_stderr != *'1 update(s) available:'* || $check_stderr == *'Skipping '* ]]; then
    sed '/^All skills are up to date\./d' "$stderr_file" >&2
    printf 'Cannot verify GitHub source for selected skill: %s\n' "$name" >&2
    exit 1
  fi

  update_status=0
  gh skill update --all --dir "$directory" -- "$name" 2>"$stderr_file" || update_status=$?
  update_stderr=$(<"$stderr_file")
  # GitHub CLI can skip a selected skill and exit successfully.
  if [[ $update_stderr == *'Skipping '* || $update_stderr == *'No installed skills found.'* ]]; then
    sed '/^All skills are up to date\./d' "$stderr_file" >&2
    printf 'GitHub CLI did not update selected skill: %s\n' "$name" >&2
    exit 1
  fi
  cat "$stderr_file" >&2
  if ((update_status != 0)); then
    printf 'GitHub CLI update failed for %s (exit %d).\n' "$name" "$update_status" >&2
    exit "$update_status"
  fi
done
