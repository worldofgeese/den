#!/usr/bin/env bash
# Fast-forward den's checkout to origin/main before Topgrade deploys from it.
#
# Topgrade's deploy steps run from ~/.config/home-manager, so a checkout left
# behind main silently redeployed old configuration: on 2026-11-18 it undid the
# cgroup group and restored the Trash purge that #183 had removed. Refuses any
# branch but main, and any local change a fast-forward would overwrite.
# flake.lock is the exception: the "3. Flake inputs" step rewrites it on every
# run, so the previous run's input bumps are discarded here and regenerated
# there.
set -euo pipefail

cd "$1"
branch=$(git branch --show-current)
if [ "$branch" != main ]; then
  echo "error: $PWD is on '${branch:-detached HEAD}', not main; refusing to deploy it" >&2
  exit 1
fi
git fetch --quiet origin main
git restore --worktree -- flake.lock
git merge --ff-only --quiet origin/main
