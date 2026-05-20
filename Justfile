# Den mono-repo deploy recipes

default:
    @just --list

# Deploy everything on mahakala (Guix System + Guix Home + Home Manager)
deploy-mahakala:
    sudo guix pull -C ~/.config/home-manager/guix/channels.scm
    guix pull
    just update
    sudo guix system reconfigure --fallback -L ~/.config/home-manager/guix-packages ~/.config/home-manager/guix/system.scm
    guix home reconfigure guix/home-configuration.scm
    home-manager switch --flake .#worldofgeese
    update-desktop-database ~/.local/share/applications

# Deploy only Home Manager on mahakala
deploy-mahakala-hm:
    just update
    home-manager switch --flake .#worldofgeese
    update-desktop-database ~/.local/share/applications

# Deploy only Guix Home on mahakala
deploy-mahakala-guix:
    guix pull
    guix home reconfigure guix/home-configuration.scm

# Reconfigure Guix System (requires sudo)
deploy-mahakala-system:
    sudo guix pull -C ~/.config/home-manager/guix/channels.scm
    sudo guix system reconfigure --fallback -L ~/.config/home-manager/guix-packages ~/.config/home-manager/guix/system.scm

# Deploy NixOS on paphos (remote server)
deploy-paphos host="paphos":
    just update
    nixos-rebuild switch --flake .#paphos --target-host {{host}} --use-remote-sudo

# Deploy nix-darwin on M-02877 (macOS)
deploy-darwin:
    just update
    sudo -H darwin-rebuild switch --flake .#M-02877

# Deploy nix-on-droid on pixel-fold (Android/Termux)
deploy-pixel-fold:
    just update
    nix-on-droid switch --flake .#pixel-fold

# Check flake evaluates without errors
check:
    nix flake check --all-systems

# Update all flake inputs
update:
    nix flake update
    just update-rust-tools

# Update pinned Rust tools to latest upstream releases
update-rust-tools:
    ./scripts/update-rust-tools.sh

# Update a single flake input
update-input input:
    nix flake update {{input}}

# Upgrade CachyOS kernel to latest stable release
upgrade-kernel:
    ./scripts/upgrade-cachyos-kernel.sh

# Show flake outputs
show:
    nix flake show
