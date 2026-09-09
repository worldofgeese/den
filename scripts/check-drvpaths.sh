#!/usr/bin/env bash
# Forces .drvPath for every check under .#checks, one system/check at a time.
#
# A blanket `nix eval .#checks --apply '... c.drvPath ...'` aborts entirely the
# moment ANY check's drvPath needs an import-from-derivation (IFD) build that
# this host cannot perform (for example a darwin-only check when no remote
# aarch64-darwin builder is configured). That failure mode is a daemon-level
# build error, not an evaluator-level throw, so `builtins.tryEval` cannot catch
# it (confirmed empirically: see home-manager-gti). This loop isolates each
# check so one host's missing builder does not swallow every other check.
#
# A check is skipped only when its failure text matches the specific
# "no builder for this system" signature. Any other failure is a hard error.
set -u

fail=0
skip_pattern='required system or feature not available'

systems=$(nix eval --no-warn-dirty --json .#checks --apply 'builtins.attrNames' 2>/dev/null) \
  || { echo "check-drvpaths: could not list systems under .#checks" >&2; exit 1; }

for system in $(echo "$systems" | jq -r '.[]'); do
  checks=$(nix eval --no-warn-dirty --json ".#checks.\"$system\"" --apply 'builtins.attrNames' 2>/dev/null) \
    || { echo "check-drvpaths: could not list checks for $system" >&2; fail=1; continue; }

  for check in $(echo "$checks" | jq -r '.[]'); do
    output=$(nix eval --no-warn-dirty --json ".#checks.\"$system\".\"$check\".drvPath" 2>&1)
    status=$?
    if [[ $status -eq 0 ]]; then
      continue
    fi
    if [[ "$output" == *"$skip_pattern"* ]]; then
      echo "SKIP: ${system}.${check} — no remote builder for the required system" >&2
      continue
    fi
    echo "FAIL: ${system}.${check}" >&2
    echo "$output" >&2
    fail=1
  done
done

exit $fail
