#!/usr/bin/env bash
# Tests scripts/decapod-deploy-backup.sh. Run by `just check`.
#
# Stub `nix` and `sqlite3` commands come first on PATH, so the test evaluates
# nothing and never opens a real store. The store is an empty file in a
# throwaway git repository, and the copies go to a throwaway XDG_STATE_HOME.
set -euo pipefail

# A git hook exports GIT_DIR and related variables for the repository that is
# being committed to, and GIT_DIR overrides `git -C`. Den's pre-commit hook runs
# this test through `just check`, so the scratch `git init` below re-initialized
# den's own repository, and git recorded core.bare=true (home-manager-i133). The
# script under test then also resolved den's real store path. Clear the hook's
# git variables before any git command.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX \
  GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/decapod-deploy-backup.sh"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

mkdir -p "$work/bin" "$work/repo/.decapod/data"
git -C "$work/repo" init -q
: >"$work/repo/.decapod/data/decapod.db"
copies_dir="$work/state/den-decapod-backups"

# nix eval prints STUB_NIX_OUT, or fails when STUB_NIX_FAIL is set.
cat >"$work/bin/nix" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${STUB_NIX_FAIL:-}" ]]; then
  echo "stub nix: evaluation failed" >&2
  exit 1
fi
printf '%s' "${STUB_NIX_OUT:-}"
EOF
# timeout runs its command, or exits 124 (expired) when STUB_TIMEOUT_EXPIRE
# is set, so the test does not need GNU coreutils.
cat >"$work/bin/timeout" <<'EOF'
#!/usr/bin/env bash
[[ -z "${STUB_TIMEOUT_EXPIRE:-}" ]] || exit 124
shift
exec "$@"
EOF
# sqlite3 answers the three commands that the script sends.
cat >"$work/bin/sqlite3" <<'EOF'
#!/usr/bin/env bash
command="${*: -1}"
case "$command" in
  ".backup '"*)
    file="${command#.backup \'}"
    file="${file%\'}"
    : >"$file"
    if [[ -n "${STUB_BACKUP_FAIL:-}" ]]; then
      echo "Error: file is not a database" >&2
      exit 1
    fi
    echo copy >"$file"
    ;;
  *integrity_check*) echo "${STUB_INTEGRITY:-ok}" ;;
  *page_count*) echo "${STUB_PAGES-1}" ;;
esac
EOF
chmod +x "$work/bin/nix" "$work/bin/timeout" "$work/bin/sqlite3"

# run EXPECTED_STATUS [VAR=value ...]: runs the script in the throwaway repo.
run() {
  local expected=$1 status=0
  shift
  (cd "$work/repo" && env PATH="$work/bin:$PATH" XDG_STATE_HOME="$work/state" \
    "$@" bash "$script") >"$work/output" 2>&1 || status=$?
  if [[ $status != "$expected" ]]; then
    echo "test-decapod-deploy-backup: '$*' exited $status, expected $expected:" >&2
    sed 's/^/  /' "$work/output" >&2
    exit 1
  fi
}

# count GLOB: the number of files in the copies directory that match GLOB.
count() {
  local matches=()
  shopt -s nullglob
  # shellcheck disable=SC2206 # $1 is the glob, so it must stay unquoted
  matches=("$copies_dir"/$1)
  shopt -u nullglob
  echo "${#matches[@]}"
}

expect() {
  if [[ "$2" != "$3" ]]; then
    echo "test-decapod-deploy-backup: $1: got $2, expected $3" >&2
    sed 's/^/  /' "$work/output" >&2
    exit 1
  fi
}

new=/nix/store/00000000000000000000000000000000-decapod-9.9.9

run 0 DEN_SKIP_DECAPOD_BACKUP=1
expect "skip makes no copy" "$(count '*')" 0
run 1 STUB_NIX_FAIL=1
run 1 "STUB_NIX_OUT=$new" STUB_TIMEOUT_EXPIRE=1
run 1 STUB_NIX_OUT=
run 1 "STUB_NIX_OUT=$new $new-2"
expect "no copy after an evaluation failure" "$(count '*')" 0

run 1 "STUB_NIX_OUT=$new" STUB_BACKUP_FAIL=1
expect "a failed backup leaves no file" "$(count '*')" 0
run 1 "STUB_NIX_OUT=$new" "STUB_INTEGRITY=*** in database main *** Page 3: btreeInitPage() returns error code 11"
expect "a failed check leaves no file" "$(count '*')" 0
run 1 "STUB_NIX_OUT=$new" STUB_PAGES=0
run 1 "STUB_NIX_OUT=$new" STUB_PAGES=
expect "an empty copy leaves no file" "$(count '*')" 0

# A killed run leaves a partial file, and the next run removes it. Six old
# copies and a new one leave the newest 5.
mkdir -p "$copies_dir"
: >"$copies_dir/20260101T000000Z-killed.db.partial"
for day in 1 2 3 4 5 6; do
  : >"$copies_dir/2026010${day}T000000Z-decapod-0.0.$day-to-decapod-0.0.$((day + 1)).db"
done
run 0 "STUB_NIX_OUT=$new"
expect "partial files after a copy" "$(count '*.partial')" 0
expect "copies kept" "$(count '*.db')" 5
expect "the new copy" "$(count '*-to-decapod-9.9.9.db')" 1
expect "the oldest copies are removed" "$(count '2026010[12]T*.db')" 0

# The installed decapod exists only on a machine with the profile (M-02877).
installed="$(readlink -f /etc/profiles/per-user/dktaohan/bin/decapod 2>/dev/null || true)"
if [[ "$installed" == /nix/store/*/bin/* ]]; then
  package="${installed%%/bin/*}"
  name="${package#/nix/store/}"
  run 0 "STUB_NIX_OUT=$package"
  expect "the installed decapod makes no copy" "$(count "*-to-${name#*-}.db")" 0
fi

echo "test-decapod-deploy-backup: all cases pass"
