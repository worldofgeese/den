#!/usr/bin/env bash
# Upgrade CachyOS kernel in guix-packages/linux-cachyos.scm
# Fetches latest stable release, computes hash, patches the file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCM_FILE="$SCRIPT_DIR/../guix-packages/linux-cachyos.scm"
for command in curl jq guix; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "ERROR: Required command not found: $command" >&2
    exit 1
  fi
done


echo "Fetching latest CachyOS stable release..."
TAG=$(curl -sf https://api.github.com/repos/CachyOS/linux/releases \
  | jq -r '[.[] | select(.tag_name | test("^cachyos-[0-9]+\\.[0-9]+\\.[0-9]+-[0-9]+$"))][0].tag_name')

if [[ -z "$TAG" || "$TAG" == "null" ]]; then
  echo "ERROR: Could not determine latest stable release" >&2
  exit 1
fi

TAG_VERSION=${TAG#cachyos-}
VERSION=${TAG_VERSION%-*}
REVISION=${TAG_VERSION##*-}
UPSTREAM_VERSION=${VERSION%.*}

CURRENT_VERSION=$(sed -n 's/^(define %cachyos-version "\([^"]*\)").*/\1/p' "$SCM_FILE")
CURRENT_REVISION=$(sed -n 's/^(define %cachyos-revision "\([^"]*\)").*/\1/p' "$SCM_FILE")

echo "Current: $CURRENT_VERSION-$CURRENT_REVISION"
echo "Latest:  $VERSION-$REVISION"

if [[ "$VERSION" == "$CURRENT_VERSION" && "$REVISION" == "$CURRENT_REVISION" ]]; then
  echo "Already up to date."
  exit 0
fi

SOURCE_URL="https://github.com/CachyOS/linux/releases/download/$TAG/$TAG.tar.gz"
BORE_PATCH_URL="https://raw.githubusercontent.com/cachyos/kernel-patches/master/$UPSTREAM_VERSION/sched/0001-bore-cachy.patch"

download_hash() {
  local label=$1 url=$2 hash
  echo "Downloading and hashing $label: $url" >&2
  hash=$(guix download "$url" 2>&1 | tail -1)
  if [[ ! "$hash" =~ ^[[:alnum:]]{52}$ ]]; then
    echo "ERROR: Invalid $label hash: $hash" >&2
    exit 1
  fi
  printf '%s' "$hash"
}

SOURCE_HASH=$(download_hash "CachyOS source" "$SOURCE_URL")
BORE_PATCH_HASH=$(download_hash "BORE patch" "$BORE_PATCH_URL")

TMP_FILE=$(mktemp "$SCM_FILE.tmp.XXXXXX")
trap 'rm -f "$TMP_FILE"' EXIT
cp "$SCM_FILE" "$TMP_FILE"

replace_definition() {
  local name=$1 value=$2 count
  count=$(sed -n "/^(define $name /p" "$TMP_FILE" | wc -l | tr -d ' ')
  if [[ "$count" != 1 ]]; then
    echo "ERROR: Expected one $name definition, found $count" >&2
    exit 1
  fi
  sed -i.bak "s|^(define $name \"[^\"]*\")|(define $name \"$value\")|" "$TMP_FILE"
  rm -f "$TMP_FILE.bak"
}

replace_definition %cachyos-version "$VERSION"
replace_definition %cachyos-revision "$REVISION"
replace_definition %cachyos-source-hash "$SOURCE_HASH"
replace_definition %cachyos-bore-patch-hash "$BORE_PATCH_HASH"

echo "Validating updated module..."
guix repl -L "$SCRIPT_DIR/../guix-packages" "$TMP_FILE" >/dev/null
mv "$TMP_FILE" "$SCM_FILE"
trap - EXIT

echo ""
echo "Updated $SCM_FILE:"
echo "  version:    $VERSION"
echo "  revision:   $REVISION"
echo "  source:     $SOURCE_HASH"
echo "  BORE patch: $BORE_PATCH_HASH"
echo ""
echo "Next: just deploy-mahakala-system"
