# Den mono-repo deploy recipes

default:
    @just --list

# Deploy Home Manager on mahakala (local x86_64 workstation)
deploy-mahakala:
    home-manager switch --flake .#worldofgeese

# Deploy NixOS on paphos (remote server)
deploy-paphos host="paphos":
    nixos-rebuild switch --flake .#paphos --target-host {{host}} --use-remote-sudo

# Deploy nix-darwin on M-02877 (macOS)
deploy-darwin:
    darwin-rebuild switch --flake .#M-02877

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
