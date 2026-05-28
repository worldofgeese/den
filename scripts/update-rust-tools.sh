#!/usr/bin/env bash
# Update pinned Rust tools in modules/overlays.nix to their latest upstream releases.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OVERLAYS_FILE="$REPO_ROOT/modules/overlays.nix"

export CARGO_TERM_COLOR=never
export GH_PAGER=cat
export PAGER=cat

run_with_nix() {
  local package="$1"
  local command="$2"
  shift 2

  if command -v "$command" >/dev/null 2>&1; then
    "$command" "$@"
  else
    nix shell --quiet --no-warn-dirty --inputs-from "$REPO_ROOT" "nixpkgs#$package" -c "$command" "$@"
  fi
}

run_python() {
  run_with_nix python3 python3 "$@"
}

prefetch_unpack_hash() {
  local url="$1"
  local json

  json=$(nix store prefetch-file --json --hash-type sha256 --unpack "$url")
  sed -n 's/.*"hash":"\([^"]*\)".*/\1/p' <<<"$json"
}

overlay_value() {
  local package="$1"
  local key="$2"

  run_python - "$OVERLAYS_FILE" "$package" "$key" <<'PY'
import re
import sys

path, package, key = sys.argv[1:]
text = open(path, encoding="utf-8").read()
block_match = re.search(
    rf"(?ms)^        {re.escape(package)} = final\.rustPlatform\.buildRustPackage \{{.*?^        \}};",
    text,
)
if not block_match:
    raise SystemExit(f"Could not find package block for {package}")

block = block_match.group(0)
patterns = {
    "version": r'version = "([^"]+)";',
    "rev": r'rev = "([^"]+)";',
    "hash": r'hash = "([^"]+)";',
    "cargoHash": r'cargoHash = (?:"([^"]+)"|final\.lib\.fakeHash);',
}
match = re.search(patterns[key], block)
if not match:
    raise SystemExit(f"Could not find {key} for {package}")

print(match.group(1) or "final.lib.fakeHash")
PY
}

patch_decapod() {
  local version="$1"
  local source_hash="$2"
  local cargo_hash="$3"

  run_python - "$OVERLAYS_FILE" "$version" "$source_hash" "$cargo_hash" <<'PY'
import re
import sys

path, version, source_hash, cargo_hash = sys.argv[1:]
text = open(path, encoding="utf-8").read()

def replace_block(match):
    block = match.group(0)
    block = re.sub(r'version = "[^"]+";', f'version = "{version}";', block)
    block = re.sub(r'hash = "[^"]+";', f'hash = "{source_hash}";', block, count=1)
    replacement = "cargoHash = final.lib.fakeHash;" if cargo_hash == "fake" else f'cargoHash = "{cargo_hash}";'
    block = re.sub(r'cargoHash = (?:"[^"]+"|final\.lib\.fakeHash);', replacement, block)
    return block

updated, count = re.subn(
    r'(?ms)^        decapod = final\.rustPlatform\.buildRustPackage \{.*?^        \};',
    replace_block,
    text,
    count=1,
)
if count != 1:
    raise SystemExit("Could not patch decapod block")

open(path, "w", encoding="utf-8").write(updated)
PY
}

patch_rtk() {
  local tag="$1"
  local version="${tag#v}"
  local source_hash="$2"
  local cargo_hash="$3"

  run_python - "$OVERLAYS_FILE" "$version" "$tag" "$source_hash" "$cargo_hash" <<'PY'
import re
import sys

path, version, tag, source_hash, cargo_hash = sys.argv[1:]
text = open(path, encoding="utf-8").read()

def replace_block(match):
    block = match.group(0)
    block = re.sub(r'version = "[^"]+";', f'version = "{version}";', block, count=1)
    block = re.sub(r'rev = "[^"]+";', f'rev = "{tag}";', block, count=1)
    block = re.sub(r'hash = "[^"]+";', f'hash = "{source_hash}";', block, count=1)
    replacement = "cargoHash = final.lib.fakeHash;" if cargo_hash == "fake" else f'cargoHash = "{cargo_hash}";'
    block = re.sub(r'cargoHash = (?:"[^"]+"|final\.lib\.fakeHash);', replacement, block)
    return block

updated, count = re.subn(
    r'(?ms)^        rtk = final\.rustPlatform\.buildRustPackage \{.*?^        \};',
    replace_block,
    text,
    count=1,
)
if count != 1:
    raise SystemExit("Could not patch rtk block")

open(path, "w", encoding="utf-8").write(updated)
PY
}

nix_package_expr() {
  local package="$1"

  cat <<EOF
let
  flake = builtins.getFlake "path:$REPO_ROOT";
  system = builtins.currentSystem;
  basePkgs = import flake.inputs.nixpkgs { inherit system; config.allowUnfree = true; };
  overlayModule = import $REPO_ROOT/modules/overlays.nix { inputs = flake.inputs; den = {}; };
  hmModule = overlayModule.den.aspects.devtools.homeManager { pkgs = basePkgs; };
  pkgs = import flake.inputs.nixpkgs {
    inherit system;
    overlays = hmModule.nixpkgs.overlays;
    config.allowUnfree = true;
  };
in pkgs.$package
EOF
}

compute_cargo_hash() {
  local package="$1"
  local log_file
  local cargo_hash

  log_file="$(mktemp)"
  if nix build --no-link --impure --no-warn-dirty --expr "$(nix_package_expr "$package")" >"$log_file" 2>&1; then
    cat "$log_file" >&2
    rm -f "$log_file"
    echo "ERROR: $package unexpectedly built with a fake cargoHash" >&2
    exit 1
  fi

  cargo_hash=$(sed -n 's/.*got:[[:space:]]*\(sha256-[A-Za-z0-9+\/=]*\).*/\1/p' "$log_file" | tail -1)
  if [[ -z "$cargo_hash" ]]; then
    cat "$log_file" >&2
    rm -f "$log_file"
    echo "ERROR: Could not determine cargoHash for $package" >&2
    exit 1
  fi

  rm -f "$log_file"
  printf '%s\n' "$cargo_hash"
}

latest_decapod_version=$(
  run_with_nix cargo cargo info decapod \
    | sed -n 's/^version: //p' \
    | head -1
)
latest_rtk_tag=$(run_with_nix gh gh release view --repo rtk-ai/rtk --json tagName --jq .tagName)

if [[ -z "$latest_decapod_version" ]]; then
  echo "ERROR: Could not determine latest decapod crate version" >&2
  exit 1
fi

if [[ -z "$latest_rtk_tag" || "$latest_rtk_tag" == "null" ]]; then
  echo "ERROR: Could not determine latest rtk release tag" >&2
  exit 1
fi

current_decapod_version=$(overlay_value decapod version)
current_rtk_rev=$(overlay_value rtk rev)

if [[ "${SKIP_DECAPOD_UPDATE:-0}" == "1" ]]; then
  latest_decapod_version="$current_decapod_version"
fi

echo "Current decapod: $current_decapod_version"
if [[ "${SKIP_DECAPOD_UPDATE:-0}" == "1" ]]; then
  echo "Latest decapod:  skipped (SKIP_DECAPOD_UPDATE=1)"
else
  echo "Latest decapod:  $latest_decapod_version"
fi
echo "Current rtk:     $current_rtk_rev"
echo "Latest rtk:      $latest_rtk_tag"

if [[ "$current_decapod_version" == "$latest_decapod_version" && "$current_rtk_rev" == "$latest_rtk_tag" ]]; then
  echo "Rust tools are already up to date."
  exit 0
fi

backup_file="$(mktemp)"
cp "$OVERLAYS_FILE" "$backup_file"
updated=false
trap 'if [[ "$updated" != true ]]; then cp "$backup_file" "$OVERLAYS_FILE"; fi; rm -f "$backup_file"' EXIT

if [[ "$current_decapod_version" != "$latest_decapod_version" ]]; then
  echo "Prefetching decapod $latest_decapod_version..."
  decapod_source_hash=$(prefetch_unpack_hash "https://static.crates.io/crates/decapod/decapod-${latest_decapod_version}.crate")
  patch_decapod "$latest_decapod_version" "$decapod_source_hash" fake
  echo "Computing decapod cargoHash..."
  decapod_cargo_hash=$(compute_cargo_hash decapod)
  patch_decapod "$latest_decapod_version" "$decapod_source_hash" "$decapod_cargo_hash"
  echo "Updated decapod to $latest_decapod_version"
fi

if [[ "$current_rtk_rev" != "$latest_rtk_tag" ]]; then
  echo "Prefetching rtk $latest_rtk_tag..."
  rtk_source_hash=$(prefetch_unpack_hash "https://github.com/rtk-ai/rtk/archive/refs/tags/${latest_rtk_tag}.tar.gz")
  patch_rtk "$latest_rtk_tag" "$rtk_source_hash" fake
  echo "Computing rtk cargoHash..."
  rtk_cargo_hash=$(compute_cargo_hash rtk)
  patch_rtk "$latest_rtk_tag" "$rtk_source_hash" "$rtk_cargo_hash"
  echo "Updated rtk to $latest_rtk_tag"
fi

updated=true
echo "Updated $OVERLAYS_FILE"
