#!/usr/bin/env bash
# Run each night by .github/workflows/bump.yml (Dagger plan P6). Updates each
# input of flake.lock, and opens or updates one pull request from the branch
# bump/flake-inputs. That pull request passes the same gates as any other:
# - The readiness inventory includes flake.lock, so the script renews
#   reviewed_sources_digest in .decapod/config.toml.
# - Decapod wants an authored change to a spec, so the script rewrites the
#   section "Flake Input Updates" of OPERATIONS.md with the nodes that changed.
# - `decapod validate` runs as CI runs it, and the script commits its spec
#   refresh.
#
# It needs GH_TOKEN (contents and pull request write) and GITHUB_REPOSITORY.
set -euo pipefail

branch="bump/flake-inputs"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"
: "${GH_TOKEN:?GH_TOKEN is not set}"
ops=".decapod/managed/specs/OPERATIONS.md"

# Authenticated requests: the runners share their addresses, and the
# anonymous GitHub API limit is low.
NIX_CONFIG="${NIX_CONFIG:-}
access-tokens = github.com=${GH_TOKEN}"
export NIX_CONFIG

before="$(mktemp)"
cp flake.lock "$before"
nix flake update --no-warn-dirty
if git diff --quiet -- flake.lock; then
  echo "bump: each input of flake.lock is current"
  exit 0
fi

python3 - "$before" flake.lock "$ops" <<'EOF'
import json
import sys
import time

old = json.load(open(sys.argv[1]))["nodes"]
new = json.load(open(sys.argv[2]))["nodes"]


def show(node):
    locked = node.get("locked", {})
    rev = locked.get("rev", "")[:7] or "-"
    stamp = locked.get("lastModified")
    day = time.strftime("%Y-%m-%d", time.gmtime(stamp)) if stamp else "-"
    return f"{rev} ({day})"


rows = []
for name in sorted(set(old) | set(new)):
    if name == "root":
        continue
    a, b = old.get(name), new.get(name)
    if a and b and a.get("locked") == b.get("locked"):
        continue
    before = show(a) if a else "(new)"
    after = show(b) if b else "(removed)"
    rows.append(f"| `{name}` | {before} | {after} |")

today = time.strftime("%Y-%m-%d", time.gmtime())
section = (
    "## Flake Input Updates\n\n"
    "The nightly bump (`scripts/bump-flake-inputs.sh`) rewrites this section. "
    f"On {today} it changed {len(rows)} node{'' if len(rows) == 1 else 's'} of `flake.lock`.\n\n"
    "| Node | Before | After |\n|---|---|---|\n" + "\n".join(rows) + "\n\n"
)

path = sys.argv[3]
text = open(path).read()
marker = "<!-- decapod:codebase-attestation:start -->"
start = text.find("## Flake Input Updates\n")
if start < 0:
    # The first run puts the section before the generated part.
    start = stop = text.index(marker)
else:
    # The section ends at the next "## " heading or at the generated part.
    ends = []
    heading = text.find("\n## ", start + 1)
    if heading >= 0:
        ends.append(heading + 1)
    generated = text.find(marker, start)
    if generated >= 0:
        ends.append(generated)
    stop = min(ends) if ends else len(text)
open(path, "w").write(text[:start] + section + text[stop:])
print(f"bump: {len(rows)} node(s) of flake.lock changed")
EOF

# Den runs the Decapod of flake.lock (modules/overlays.nix), and CI runs the
# release in the header of AGENTS.md. When the update moves Decapod, the
# script installs that release, and validate below writes it into the
# entrypoints, Dockerfile.decapod and the manifest. A rev of flake.lock can
# come before its release on crates.io. Then the header stays, and the next
# bump tries again.
pinned="$(sed -n 's/^<!-- decapod-release: \([0-9][0-9.]*\) -->$/\1/p' AGENTS.md)"
# shellcheck disable=SC2016 # Nix expands ${builtins.currentSystem}.
locked="$(nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.decapod.packages.${builtins.currentSystem}.default.version')"
if [[ -n "$locked" && "$locked" != "$pinned" ]]; then
  if cargo binstall --no-confirm "decapod@${locked}"; then
    echo "bump: Decapod ${pinned} -> ${locked}"
  else
    echo "::warning::bump: Decapod ${locked} has no release to install; the entrypoints stay at ${pinned}"
  fi
fi

digest="$(decapod rpc --op agent.init | grep -o '"inventory_digest": *"sha256:[0-9a-f]*"' | grep -o 'sha256:[0-9a-f]*' | head -1)"
if [[ -z "$digest" ]]; then
  echo "bump: decapod agent.init gave no inventory_digest" >&2
  exit 1
fi
# -i.bak works with GNU sed and BSD sed, so the script also runs on macOS.
sed -i.bak "s/^reviewed_sources_digest = \"sha256:[0-9a-f]*\"/reviewed_sources_digest = \"$digest\"/" .decapod/config.toml
rm -f .decapod/config.toml.bak

login="$(gh api user --jq .login)"
git config user.name "$login"
git config user.email "$(gh api user --jq .id)+${login}@users.noreply.github.com"
base="$(git rev-parse HEAD)"
git checkout -q -B "$branch"
git add flake.lock .decapod/config.toml "$ops"
git commit -q -m "chore(flake): update the flake inputs" \
  -m "The nightly bump (.github/workflows/bump.yml). OPERATIONS.md, section Flake Input Updates, lists the nodes that changed."

validate() {
  GITHUB_ACTIONS=true CI=true DECAPOD_VALIDATE_SKIP_GIT_GATES=1 CHANGE_EVENT=pull_request \
    CHANGE_BASE="$base" CHANGE_HEAD="$(git rev-parse HEAD)" decapod validate --refresh-specs
}
# Each refresh writes its time into the manifest. The drift check compares
# without that time and without the governance records, as
# decapod-validate.yml and scripts/decapod-validate-ci.sh do.
manifest=".decapod/managed/specs/.manifest.json"
no_drift() {
  local committed
  committed="$(git show "HEAD:${manifest}" | sed -n 's/.*"generated_at": "\([^"]*\)".*/\1/p' | head -1)"
  if [[ -n "$committed" ]]; then
    sed -i.bak "s/\"generated_at\": \"[^\"]*\"/\"generated_at\": \"${committed}\"/" "$manifest"
    rm -f "$manifest.bak"
  fi
  git diff --quiet -- . ':!.decapod/governance/' ':!.decapod/governance.json'
}
validate
# validate refreshes the specs, and after a new Decapod also the entrypoints.
# The bump commits that refresh.
if ! no_drift; then
  git add .decapod/managed AGENTS.md CLAUDE.md CODEX.md GEMINI.md
  git commit -q --amend --no-edit
  validate
  if ! no_drift; then
    echo "bump: the specs still drift after their refresh" >&2
    git diff --stat -- . ':!.decapod/governance/' ':!.decapod/governance.json' >&2
    exit 1
  fi
fi
# The governance records of validate stay out of the commit.
git checkout -q -- .

gh auth setup-git
git push -q --force origin "HEAD:refs/heads/$branch"
body="The nightly bump updated \`flake.lock\` (.github/workflows/bump.yml). OPERATIONS.md, section Flake Input Updates, lists each node that changed. This pull request passes the same gates as any other: den/dagger-check, validate, the Codex review and the merge rules."
open_pr="$(gh pr list -R "$repo" --head "$branch" --state open --json number --jq '.[0].number // empty')"
if [[ -n "$open_pr" ]]; then
  gh pr edit "$open_pr" -R "$repo" --body "$body" >/dev/null
  echo "bump: updated pull request #$open_pr"
else
  gh pr create -R "$repo" --base main --head "$branch" --title "chore(flake): update the flake inputs" --body "$body"
fi
