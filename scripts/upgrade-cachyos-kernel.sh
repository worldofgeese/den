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

CURRENT_VERSION=$(sed -n 's/^(define %cachyos-version "\([^"]*\)").*/\1/p' "$SCM_FILE" | head -1)
CURRENT_REVISION=$(sed -n 's/^(define %cachyos-revision "\([^"]*\)").*/\1/p' "$SCM_FILE" | head -1)

echo "Current: $CURRENT_VERSION-$CURRENT_REVISION"
echo "Latest:  $VERSION-$REVISION"

if [[ "$VERSION" == "$CURRENT_VERSION" && "$REVISION" == "$CURRENT_REVISION" ]]; then
  echo "Already up to date."
  exit 0
fi

PATCHES_URL="https://github.com/CachyOS/linux/releases/download/$TAG/$TAG.tar.gz"
echo "Downloading and hashing CachyOS patches: $PATCHES_URL"
PATCHES_HASH=$(guix download "$PATCHES_URL" 2>&1 | tail -1)
echo "Patches hash: $PATCHES_HASH"

# Only download kernel source if the major.minor.patch version changed
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v${VERSION%%.*}.x/linux-$VERSION.tar.xz"
if [[ "$VERSION" != "$CURRENT_VERSION" ]]; then
  echo "Downloading and hashing kernel source: $KERNEL_URL"
  KERNEL_HASH=$(guix download "$KERNEL_URL" 2>&1 | tail -1)
  echo "Kernel hash: $KERNEL_HASH"
fi

# Patch the .scm file
sed -i "s/(define %cachyos-version \".*\")/(define %cachyos-version \"$VERSION\")/" "$SCM_FILE"
sed -i "s/(define %cachyos-revision \".*\")/(define %cachyos-revision \"$REVISION\")/" "$SCM_FILE"

# Update CachyOS patches hash (first base32 occurrence)
sed -i "0,/(base32 \".*\")/{s/(base32 \".*\")/(base32 \"$PATCHES_HASH\")/}" "$SCM_FILE"

# Update kernel source hash (second base32 occurrence) if version changed
if [[ "$VERSION" != "$CURRENT_VERSION" && -n "${KERNEL_HASH:-}" ]]; then
  # Use awk to replace the second (base32 ...) occurrence
  awk -v hash="$KERNEL_HASH" '
    /\(base32 "/ { count++ }
    count == 2 { sub(/\(base32 "[^"]*"\)/, "(base32 \"" hash "\")"); count++ }
    { print }
  ' "$SCM_FILE" > "$SCM_FILE.tmp" && mv "$SCM_FILE.tmp" "$SCM_FILE"
fi

echo ""
echo "Updated $SCM_FILE:"
echo "  version:  $VERSION"
echo "  revision: $REVISION"
echo "  patches:  $PATCHES_HASH"
if [[ -n "${KERNEL_HASH:-}" ]]; then
  echo "  kernel:   $KERNEL_HASH"
fi
echo ""
echo "Next: just deploy-mahakala-system"
