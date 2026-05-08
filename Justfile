# Den mono-repo deploy recipes

default:
    @just --list

# Deploy everything on mahakala (Guix System + Guix Home + Home Manager)
deploy-mahakala:
    sudo guix system reconfigure guix/system.scm
    guix home reconfigure guix/home-configuration.scm
    home-manager switch --flake .#worldofgeese

# Deploy only Home Manager on mahakala
deploy-mahakala-hm:
    home-manager switch --flake .#worldofgeese

# Deploy only Guix Home on mahakala
deploy-mahakala-guix:
    guix home reconfigure guix/home-configuration.scm

# Reconfigure Guix System (requires sudo)
deploy-mahakala-system:
    sudo guix system reconfigure guix/system.scm

# Deploy NixOS on paphos (remote server)
deploy-paphos host="paphos":
    nixos-rebuild switch --flake .#paphos --target-host {{host}} --use-remote-sudo

# Deploy nix-darwin on M-02877 (macOS)
deploy-darwin:
    sudo -H darwin-rebuild switch --flake .#M-02877

# Deploy nix-on-droid on pixel-fold (Android/Termux)
deploy-pixel-fold:
    nix-on-droid switch --flake .#pixel-fold

# Check flake evaluates without errors
check:
    nix flake check

# Update all flake inputs
update:
    nix flake update

# Update a single flake input
update-input input:
    nix flake update {{input}}

# Show flake outputs
show:
    nix flake show
