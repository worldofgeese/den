# omarchy-update  (Guix: fast-forward den, then deploy system, Guix Home and Home Manager)
#
# den's flake.lock and Guix channels move through den pull requests, so an
# update here applies whatever den's main has.
set -euo pipefail
den=${DEN_DIR:-$HOME/.config/home-manager}
export PATH=/run/privileged/bin:$PATH
cd "$den"
branch=$(git rev-parse --abbrev-ref HEAD)
if [[ $branch == main ]]; then
  git pull --ff-only || echo "Could not fast-forward den; deploying the checkout as it is." >&2
else
  echo "den is on $branch, not main; deploying it as it is."
fi
just deploy-mahakala-system
just deploy-mahakala-guix-only
just deploy-mahakala-hm-only
