#!/usr/bin/env bash
# Prove that Decapod loads the project overrides in .decapod/OVERRIDE.md.
# `just check-decapod-overrides` and the Dagger check ci:decapod-overrides run
# this script. The Justfile comment above that recipe gives the reason.
set -euo pipefail

if ! command -v decapod >/dev/null 2>&1; then
  echo "check-decapod-overrides: decapod not found, skipping"
  exit 0
fi

applied=$(decapod rpc --op context.resolve 2>/dev/null |
  jq '[..|objects|select(has("directive_id"))]|length')
if [[ "${applied:-0}" -lt 1 ]]; then
  echo "check-decapod-overrides: 0 overrides applied - OVERRIDE.md is inert." >&2
  echo "  Each authored body must sit inside a bare four-backtick block:" >&2
  echo "  a tagged opener such as '\`\`\`\`markdown' is not recognised and" >&2
  echo "  fails with OVERRIDE_UNCLOSED_BODY_FENCE." >&2
  exit 1
fi
echo "check-decapod-overrides: $applied override(s) applied"
