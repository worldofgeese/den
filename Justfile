# Den mono-repo deploy recipes

# Explicit Guix substituters (matches guix/system.scm + official defaults).
# Passing --substitute-urls overrides daemon config until reconfigure applies new settings.
guix-substitute-urls := "https://substitutes.nonguix.org https://cache-cdn.guix.moe https://guix.tobias.gr/substitutes/ https://guix.bordeaux.inria.fr https://bordeaux.guix.gnu.org https://ci.guix.gnu.org"

default:
    @just --list

# Deploy everything on mahakala (Guix System + Guix Home + Home Manager)
deploy-mahakala:
    sudo bash -c 'source /root/.config/guix/current/etc/profile && guix pull --substitute-urls="{{guix-substitute-urls}}" -C /home/worldofgeese/.config/home-manager/guix/channels.scm && guix system reconfigure --substitute-urls="{{guix-substitute-urls}}" --fallback -L /home/worldofgeese/.config/home-manager/guix-packages /home/worldofgeese/.config/home-manager/guix/system.scm'
    guix pull --substitute-urls="{{guix-substitute-urls}}"
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
    sudo bash -c 'source /root/.config/guix/current/etc/profile && guix pull --substitute-urls="{{guix-substitute-urls}}" -C /home/worldofgeese/.config/home-manager/guix/channels.scm && guix system reconfigure --substitute-urls="{{guix-substitute-urls}}" --fallback -L /home/worldofgeese/.config/home-manager/guix-packages /home/worldofgeese/.config/home-manager/guix/system.scm'

# Deploy NixOS on paphos (remote server)
deploy-paphos host="paphos":
    just update
    NIX_CONFIG='warn-dirty = false' nixos-rebuild switch --flake .#paphos --target-host {{host}} --use-remote-sudo

# Deploy NixOS on oracle (Oracle Cloud aarch64; build on target by default)
deploy-oracle host="nixos@158.180.52.169" build-host="nixos@158.180.52.169":
    NIX_CONFIG='warn-dirty = false' nix run nixpkgs#nixos-rebuild -- switch --flake .#oracle --target-host {{host}} --build-host {{build-host}} --use-remote-sudo

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
    nix eval --no-warn-dirty .#nixosConfigurations.oracle.config.system.build.toplevel.drvPath >/dev/null
    nix eval --no-warn-dirty .#packages.aarch64-linux.oracle-image.drvPath >/dev/null
    nix eval --no-warn-dirty .#homeConfigurations.worldofgeese.activationPackage.drvPath >/dev/null
    nix eval --no-warn-dirty .#darwinConfigurations.M-02877.config.system.build.toplevel.drvPath >/dev/null
    nix eval --no-warn-dirty --json .#nixOnDroidConfigurations.pixel-fold.config.system.stateVersion >/dev/null
    just test-pi-extensions
    just typecheck-pi-extensions
    just check-fmt

# TypeScript type-check pi-extensions/governance/index.ts; skips if npx absent
typecheck-pi-extensions:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v npx >/dev/null 2>&1; then
        echo "typecheck-pi-extensions: npx not found, skipping"
        exit 0
    fi
    ( cd pi-extensions/governance && npm install --silent && npx tsc -p tsconfig.json )

# Run pi-extensions node tests (anthropic-proxy); skips if node absent
test-pi-extensions:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v node >/dev/null 2>&1; then
        echo "test-pi-extensions: node not found, skipping"
        exit 0
    fi
    ( cd pi-extensions/anthropic-proxy && node --test *.test.js )

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

# Format all Nix files with alejandra
fmt:
    nix run nixpkgs#alejandra -- flake.nix modules/ secrets/ guix/ guix-packages/ pkgs/

# Check Nix formatting (fails if unformatted)
check-fmt:
    nix run nixpkgs#alejandra -- --check flake.nix modules/ secrets/ guix/ guix-packages/ pkgs/

# Install git hooks (pre-commit runs 'just check')
install-hooks:
    cp .githooks/pre-commit .git/hooks/pre-commit
    chmod +x .git/hooks/pre-commit
    @echo "Hooks installed."

# Build Oracle Cloud NixOS OCI qcow2 (aarch64-linux; cross-build needs binfmt)
build-oracle-image:
    #!/usr/bin/env bash
    set -euo pipefail
    nix build .#packages.aarch64-linux.oracle-image -L --out-link result/oracle-image
    qcow="$(find -L result/oracle-image -maxdepth 1 -name '*.qcow2' -print -quit)"
    if [[ -z "$qcow" ]]; then
        echo "build-oracle-image: no .qcow2 found under result/oracle-image" >&2
        exit 1
    fi
    ln -sfn "$(readlink -f "$qcow")" result/nixos.qcow2
    echo "build-oracle-image: linked result/nixos.qcow2 -> $qcow"

# Evaluate Oracle image package without building
check-oracle-image:
    nix eval --no-warn-dirty .#packages.aarch64-linux.oracle-image.drvPath

oracle-tofu-init:
    cd terraform/oracle && nix run nixpkgs#opentofu -- init

oracle-tofu-validate:
    cd terraform/oracle && nix run nixpkgs#opentofu -- validate

oracle-tofu-fmt-check:
    cd terraform/oracle && nix run nixpkgs#opentofu -- fmt -check -recursive

oracle-tofu-fmt:
    cd terraform/oracle && nix run nixpkgs#opentofu -- fmt -recursive

oracle-tofu-plan:
    cd terraform/oracle && nix run nixpkgs#opentofu -- plan

oracle-tofu-apply:
	cd terraform/oracle && nix run nixpkgs#opentofu -- apply -auto-approve

oracle-tofu-output output:
    cd terraform/oracle && nix run nixpkgs#opentofu -- output -raw {{output}}

# Back up local OpenTofu state to gopass (never commit state to git)
oracle-tofu-backup-state:
    #!/usr/bin/env bash
    set -euo pipefail
    cd /home/worldofgeese/.config/home-manager
    state="terraform/oracle/terraform.tfstate"
    backup="terraform/oracle/terraform.tfstate.backup"
    secret="dev/oci/oracle-cloud-nixos/terraform-state"
    backup_secret="dev/oci/oracle-cloud-nixos/terraform-state.backup"
    if [[ ! -f "$state" ]]; then
        echo "oracle-tofu-backup-state: missing $state" >&2
        exit 1
    fi
    if ! command -v gopass >/dev/null 2>&1; then
        echo "oracle-tofu-backup-state: gopass not found" >&2
        exit 1
    fi
    gopass insert -f "$secret" < "$state"
    if [[ -f "$backup" ]]; then
        gopass insert -f "$backup_secret" < "$backup"
    fi
    echo "oracle-tofu-backup-state: stored $secret"

# Restore OpenTofu state from gopass (overwrites local terraform.tfstate)
oracle-tofu-restore-state:
    #!/usr/bin/env bash
    set -euo pipefail
    cd /home/worldofgeese/.config/home-manager
    state="terraform/oracle/terraform.tfstate"
    backup="terraform/oracle/terraform.tfstate.backup"
    secret="dev/oci/oracle-cloud-nixos/terraform-state"
    backup_secret="dev/oci/oracle-cloud-nixos/terraform-state.backup"
    if ! command -v gopass >/dev/null 2>&1; then
        echo "oracle-tofu-restore-state: gopass not found" >&2
        exit 1
    fi
    gopass show -o "$secret" > "$state"
    if gopass show -o "$backup_secret" > /dev/null 2>&1; then
        gopass show -o "$backup_secret" > "$backup"
    fi
    echo "oracle-tofu-restore-state: restored $secret -> $state"
