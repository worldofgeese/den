# shellcheck shell=bash
set -euo pipefail

tree=${1:?}
case $tree in
  /nix/store/*)
    if ! resolved_tree=$(readlink -e -- "$tree"); then
      printf 'Cannot resolve the running Omarchy tree: %s\n' "$tree" >&2
      exit 1
    fi
    case $resolved_tree in
      /nix/store/*) ;;
      *)
        printf 'The running Omarchy tree resolves outside the Nix store: %s\n' "$resolved_tree" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo 'Omarchy session synchronization deferred: the running session uses a mutable profile path.' >&2
    exit 2
    ;;
esac
