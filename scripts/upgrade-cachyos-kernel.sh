#!/usr/bin/env bash
# Upgrade CachyOS kernel in guix-packages/linux-cachyos.scm
# Fetches latest stable release, computes hash, patches the file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCM_FILE="$SCRIPT_DIR/../guix-packages/linux-cachyos.scm"

echo "Fetching latest CachyOS stable release..."
TAG=$(curl -sf https://api.github.com/repos/CachyOS/linux/releases \
  | jq -r '[.[] | select(.tag_name | test("^cachyos-[0-9]+\\.[0-9]+\\.[0-9]+-[0-9]+$"))][0].tag_name')

if [[ -z "$TAG" || "$TAG" == "null" ]]; then
  echo "ERROR: Could not determine latest stable release" >&2
  exit 1
fi

# Parse version and revision from tag (e.g., cachyos-7.0.6-2)
VERSION=$(echo "$TAG" | sed 's/^cachyos-\(.*\)-[0-9]*$/\1/')
REVISION=$(echo "$TAG" | sed 's/^cachyos-.*-\([0-9]*\)$/\1/')

CURRENT_VERSION=$(grep '%cachyos-version' "$SCM_FILE" | head -1 | grep -oP '"\K[^"]+')
CURRENT_REVISION=$(grep '%cachyos-revision' "$SCM_FILE" | head -1 | grep -oP '"\K[^"]+')

echo "Current: $CURRENT_VERSION-$CURRENT_REVISION"
echo "Latest:  $VERSION-$REVISION"

if [[ "$VERSION" == "$CURRENT_VERSION" && "$REVISION" == "$CURRENT_REVISION" ]]; then
  echo "Already up to date."
  exit 0
fi

URL="https://github.com/CachyOS/linux/releases/download/$TAG/$TAG.tar.gz"
echo "Downloading and hashing: $URL"
HASH=$(guix download "$URL" 2>&1 | tail -1)

echo "New hash: $HASH"

# Patch the .scm file
sed -i "s|(define %cachyos-version \".*\")|(define %cachyos-version \"$VERSION\")|" "$SCM_FILE"
sed -i "s|(define %cachyos-revision \".*\")|(define %cachyos-revision \"$REVISION\")|" "$SCM_FILE"
sed -i "s|(base32 \".*\")|(base32 \"$HASH\")|" "$SCM_FILE"

echo ""
echo "Updated $SCM_FILE:"
echo "  version:  $VERSION"
echo "  revision: $REVISION"
echo "  hash:     $HASH"
echo ""
echo "Next: just deploy-mahakala-system"
