#!/usr/bin/env bash
# Run the steps of .github/workflows/decapod-validate.yml: a CI-local
# `decapod validate --refresh-specs`, then the check for spec or entrypoint
# drift. The Dagger check ci:decapod-validate runs this script.
#
# A Dagger container gets the files without their git history. Then the script
# makes a history of two commits on main, Decapod's configured base: an empty
# base, and the files as the candidate. Decapod needs two different commits,
# and the drift check needs a HEAD to compare with. The change range then holds
# every file. The workflow keeps the real change range of a pull request.
set -euo pipefail

if git rev-parse --git-dir >/dev/null 2>&1; then
  base=$(git rev-parse HEAD~1)
else
  git init -q -b main
  git -c user.name=ci -c user.email=ci@localhost commit -q --allow-empty -m base
  base=$(git rev-parse HEAD)
  git add -A
  git -c user.name=ci -c user.email=ci@localhost commit -q -m candidate
fi
head=$(git rev-parse HEAD)

GITHUB_ACTIONS=true CI=true DECAPOD_VALIDATE_SKIP_GIT_GATES=1 \
  CHANGE_EVENT=push CHANGE_BASE="$base" CHANGE_HEAD="$head" \
  decapod validate --refresh-specs

# The refresh writes a new generated_at. Put the committed value back, as the
# workflow does, so that the time stamp alone is not drift.
manifest=.decapod/managed/specs/.manifest.json
if git cat-file -e "HEAD:$manifest" 2>/dev/null && [[ -f "$manifest" ]]; then
  old=$(git show "HEAD:$manifest" | sed -n 's/.*"generated_at": "\([^"]*\)".*/\1/p' | head -1)
  if [[ -n "$old" ]]; then
    # -i.bak works with GNU and BSD sed.
    sed -i.bak "s/\"generated_at\": \"[^\"]*\"/\"generated_at\": \"$old\"/" "$manifest"
    rm -f "$manifest.bak"
  fi
fi

if ! git diff --exit-code -- . ':!.decapod/governance/' ':!.decapod/governance.json'; then
  echo "decapod-validate: spec or entrypoint drift after validate --refresh-specs." >&2
  echo "Commit the regenerated entrypoints and .decapod/managed/specs." >&2
  exit 1
fi
