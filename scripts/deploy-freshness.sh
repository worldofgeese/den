#!/usr/bin/env bash
# Run by `just deploy-darwin` first. Stops a deploy from a checkout that does
# not contain origin/main.
#
# A deploy builds the checkout as it is. Agents merge their work through PRs
# from workspaces, and nobody pulls the main checkout, so it falls behind. On
# 2026-10-30 topgrade deployed a main checkout that did not have PRs #52, #64,
# #65 and #66 of origin/main (11 commits). That deploy took Chorus back from
# 0.23.0 (PR #64) to 0.21.1 and removed the CodeGraph `exposure` of PR #66.
# The deploy reported success.
#
# The check compares commits only. Uncommitted edits are a separate rule: see
# "Deploy only committed inputs" in .decapod/managed/specs/OPERATIONS.md.
#
# If the fetch fails (no network), the check uses the origin/main ref of the
# last fetch. To deploy an older commit on purpose, for example to roll back a
# bad merge, set DEN_DEPLOY_STALE=1.
set -euo pipefail

if [[ -n "${DEN_DEPLOY_STALE:-}" ]]; then
  echo "deploy-freshness: DEN_DEPLOY_STALE is set; the origin/main check is skipped" >&2
  exit 0
fi

if ! timeout 30 git fetch --quiet origin main; then
  echo "deploy-freshness: git fetch failed; the check uses the origin/main of the last fetch" >&2
fi

if ! git rev-parse --verify --quiet origin/main >/dev/null; then
  echo "deploy-freshness: this checkout has no origin/main ref; the check is skipped" >&2
  exit 0
fi

if git merge-base --is-ancestor origin/main HEAD; then
  exit 0
fi

missing="$(git rev-list --count HEAD..origin/main)"
cat >&2 <<EOF
deploy-freshness: HEAD ($(git rev-parse --short HEAD)) does not contain origin/main ($(git rev-parse --short origin/main)).
A deploy now removes the work of $missing merged commit(s) from this machine:
$(git log --oneline --no-decorate -n 10 HEAD..origin/main | sed 's/^/  /')
Commit or stash the local edits, run 'git pull --ff-only', and deploy again.
To deploy this commit on purpose, run: DEN_DEPLOY_STALE=1 just deploy-darwin
EOF
exit 1
