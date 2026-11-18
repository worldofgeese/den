#!/usr/bin/env bash
set -euo pipefail

selector=$1
for scope in package home system; do
  if [[ $scope == system ]]; then
    command=(sudo guix)
  else
    command=(guix)
  fi
  if ! generations=$("${command[@]}" repl -q -- "$selector" "$scope"); then
    printf 'Failed to select %s generations.\n' "$scope" >&2
    exit 1
  fi
  if [[ -z $generations ]]; then
    printf 'No %s generations older than two weeks to remove.\n' "$scope"
    continue
  fi
  if [[ ! $generations =~ ^[0-9]+(,[0-9]+)*$ ]]; then
    printf 'Invalid %s generation selection: %s\n' "$scope" "$generations" >&2
    exit 1
  fi
  case $scope in
    package) "${command[@]}" package "--delete-generations=$generations" ;;
    home) "${command[@]}" home delete-generations "$generations" ;;
    system) "${command[@]}" system delete-generations "$generations" ;;
  esac
done
sudo guix gc
