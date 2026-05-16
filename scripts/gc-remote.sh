#!/bin/sh
# Gas City CLI — proxied to remote gascity container on loving-kypris.
# Managed by home-manager (modules/workstation.nix).

args=""
for arg in "$@"; do
  escaped=$(printf '%s' "$arg" | sed "s/'/'\\\\'''/g")
  args="$args '$escaped'"
done

exec ssh -q loving-kypris "podman exec -i gascity bash -lc 'cd /gc && gc ${args}'"
