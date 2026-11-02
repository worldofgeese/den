#!/usr/bin/env bash
set -euo pipefail

tree=${1:?Usage: test-omarchy-share.sh OMARCHY_TREE}
test_dir=$(mktemp -d)

cleanup() {
  rm -f "$test_dir/bin/localsend" "$test_dir/bin/systemd-run" \
    "$test_dir/arguments" "$test_dir/expected"
  rmdir "$test_dir/bin" "$test_dir"
}
trap cleanup EXIT

mkdir "$test_dir/bin"
printf '#!%s\n' "$BASH" >"$test_dir/bin/localsend"
cat >>"$test_dir/bin/localsend" <<'EOF'
printf '%s\0' "$@" >"$OMARCHY_TEST_ARGS"
exit "$OMARCHY_TEST_STATUS"
EOF
printf '#!%s\n' "$BASH" >"$test_dir/bin/systemd-run"
cat >>"$test_dir/bin/systemd-run" <<'EOF'
echo "No systemd user manager is available." >&2
exit 1
EOF
chmod +x "$test_dir/bin/localsend" "$test_dir/bin/systemd-run"

export PATH="$test_dir/bin:$PATH"
export OMARCHY_TEST_ARGS="$test_dir/arguments"
printf '%s\0' --headless send "$test_dir/file one" "$test_dir/file-two" \
  >"$test_dir/expected"

for expected_status in 0 42; do
  export OMARCHY_TEST_STATUS=$expected_status
  actual_status=0
  bash "$tree/bin/omarchy-menu-share" file \
    "$test_dir/file one" "$test_dir/file-two" || actual_status=$?
  if [[ $actual_status != "$expected_status" ]]; then
    echo "LocalSend status: expected $expected_status, got $actual_status" >&2
    exit 1
  fi
  cmp "$test_dir/expected" "$test_dir/arguments"
done
