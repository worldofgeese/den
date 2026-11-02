# omarchy-guix-set-timezone ZONE  (sets (timezone ...) in den's guix/system.scm, then deploys)
set -euo pipefail
tz=$1
den=${DEN_DIR:-$HOME/.config/home-manager}
scm=$den/guix/system.scm
export PATH=/run/privileged/bin:$PATH
if ! grep -q '^  (timezone "[^"]*")' "$scm"; then
  echo "No (timezone \"...\") line in $scm." >&2
  exit 1
fi
sed -i "s|^  (timezone \"[^\"]*\")|  (timezone \"$tz\")|" "$scm"
cd "$den"
just deploy-mahakala-system
omarchy-shell -q omarchy.clock refresh || true
echo
echo "Timezone is $tz for new logins. Commit guix/system.scm in $den to keep it."
