# Den mono-repo deploy recipes

default:
    @just --list

# Deploy everything on mahakala (Guix System + Guix Home + Home Manager)
deploy-mahakala:
    sudo bash -c 'source /root/.config/guix/current/etc/profile && guix pull -C /home/worldofgeese/.config/home-manager/guix/channels.scm && guix system reconfigure --fallback -L /home/worldofgeese/.config/home-manager/guix-packages /home/worldofgeese/.config/home-manager/guix/system.scm'
    guix pull
    just update
    guix home reconfigure guix/home-configuration.scm
    NIX_CONFIG='warn-dirty = false' home-manager switch --flake .#worldofgeese
    update-desktop-database ~/.local/share/applications

# Deploy only Home Manager on mahakala
deploy-mahakala-hm:
    just update
    NIX_CONFIG='warn-dirty = false' home-manager switch --flake .#worldofgeese
    update-desktop-database ~/.local/share/applications

# Deploy only Guix Home on mahakala
deploy-mahakala-guix:
    guix pull
    guix home reconfigure guix/home-configuration.scm

# Reconfigure Guix System (requires sudo)
deploy-mahakala-system:
    sudo bash -c 'source /root/.config/guix/current/etc/profile && guix pull -C /home/worldofgeese/.config/home-manager/guix/channels.scm && guix system reconfigure --fallback -L /home/worldofgeese/.config/home-manager/guix-packages /home/worldofgeese/.config/home-manager/guix/system.scm'

# Deploy NixOS on paphos (remote server)
deploy-paphos host="paphos":
    just update
    NIX_CONFIG='warn-dirty = false' nixos-rebuild switch --flake .#paphos --target-host {{host}} --use-remote-sudo

# Deploy nix-darwin on M-02877 (macOS)
deploy-darwin:
    just update
    sudo -H env NIX_CONFIG='warn-dirty = false' darwin-rebuild switch --flake .#M-02877

# Deploy nix-on-droid on pixel-fold (Android/Termux)
deploy-pixel-fold:
    just update
    NIX_CONFIG='warn-dirty = false' nix-on-droid switch --flake .#pixel-fold

# Check host outputs evaluate without known-noise custom-output warnings
check:
    nix eval --no-warn-dirty .#nixosConfigurations.paphos.config.system.build.toplevel.drvPath >/dev/null
    nix eval --no-warn-dirty .#homeConfigurations.worldofgeese.activationPackage.drvPath >/dev/null
    nix eval --no-warn-dirty .#darwinConfigurations.M-02877.config.system.build.toplevel.drvPath >/dev/null
    nix eval --no-warn-dirty --json .#nixOnDroidConfigurations.pixel-fold.config.system.stateVersion >/dev/null
    just test-pi-extensions
    just typecheck-pi-extensions

# TypeScript type-check pi-extensions/governance/index.ts; skips if npx absent
typecheck-pi-extensions:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v npx >/dev/null 2>&1; then
        echo "typecheck-pi-extensions: npx not found, skipping"
        exit 0
    fi
    ( cd pi-extensions/governance && npm install --silent && npx tsc -p tsconfig.json )

# Run pi-extensions node tests (anthropic-proxy + pi-subagents hotfix); skips if node absent
test-pi-extensions:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v node >/dev/null 2>&1; then
        echo "test-pi-extensions: node not found, skipping"
        exit 0
    fi
    ( cd pi-extensions/anthropic-proxy && node --test *.test.js )
    node --test pi-extensions/hotfixes/pi-subagents/get-final-output.test.mjs

# Update all flake inputs
update:
    nix flake update --no-warn-dirty
    just update-rust-tools

# Update pinned Rust tools to latest upstream releases
update-rust-tools:
    ./scripts/update-rust-tools.sh

# Update a single flake input
update-input input:
    nix flake update --no-warn-dirty {{input}}

# Upgrade CachyOS kernel to latest stable release
upgrade-kernel:
    ./scripts/upgrade-cachyos-kernel.sh

# Show flake outputs
show:
    nix flake show
