# Den

Unified Nix infrastructure for all my machines. Built on [Den](https://github.com/vic/den) (aspect-oriented flake-parts framework) with [import-tree](https://github.com/vic/import-tree) for automatic module discovery.

## Hosts

| Host | Platform | Description |
|------|----------|-------------|
| **mahakala** | x86_64-linux | Personal workstation (standalone Home Manager) |
| **M-02877** | aarch64-darwin | Work MacBook (nix-darwin + Home Manager) |
| **paphos** | x86_64-linux | Home server (NixOS, Forgejo, Tailscale) |
| **pixel-fold** | aarch64-linux | Android phone (nix-on-droid) |

The Guix System configuration for mahakala lives in `guix/` and is managed separately via `guix system reconfigure`.

## Prerequisites

- [Nix](https://nixos.org/download/) with flakes enabled
- [just](https://github.com/casey/just) (optional, for deploy shortcuts)
- Platform-specific tools: `darwin-rebuild` (macOS), `nixos-rebuild` (NixOS), `nix-on-droid` (Android)

## Deploying

```bash
# Personal workstation (Home Manager only)
just deploy-mahakala

# Work MacBook (nix-darwin)
just deploy-darwin

# Home server (remote NixOS)
just deploy-paphos

# Android phone (run on-device)
just deploy-pixel-fold
```

Or without just:

```bash
home-manager switch --flake .#worldofgeese
darwin-rebuild switch --flake .#M-02877
nixos-rebuild switch --flake .#paphos --target-host paphos --use-remote-sudo
nix-on-droid switch --flake .#pixel-fold
```

## Architecture

Every `.nix` file under `modules/` is automatically imported as a top-level [flake-parts](https://flake-parts.hercules-ci.com/) module (via import-tree). Files prefixed with `_` are skipped.

### Key concepts

- **`den.hosts.<system>.<hostname>`** — Declares a full system (NixOS or nix-darwin) with users
- **`den.homes.<system>.<username>`** — Declares standalone Home Manager configs (no system management)
- **`den.aspects.<name>`** — Reusable feature bundles with `.nixos`, `.darwin`, and `.homeManager` sub-attributes
- **`den.default`** — Global settings applied to all hosts/homes

### Module layout

```
modules/
├── dendritic.nix        # Imports Den framework
├── hosts.nix            # Host/home declarations
├── defaults.nix         # Global defaults + aspect wiring
├── worldofgeese.nix     # Shared user aspect (git, shell tools)
├── workstation.nix      # Desktop/dev packages
├── ssh.nix              # Fleet SSH matchBlocks
├── server.nix           # Reusable server aspect
├── overlays.nix         # Nixpkgs overlays
├── mahakala.nix         # Wires worldofgeese → workstation + ssh
├── M-02877/
│   ├── darwin.nix       # macOS system config (Homebrew, Lix, system defaults)
│   └── dktaohan.nix     # Work user aspect (separate identity)
├── paphos/
│   ├── system.nix       # Auto-upgrade, users, sudo
│   ├── hardware.nix     # Disks, LUKS, Dropbear initrd SSH
│   ├── networking.nix   # Tailscale, openssh, locale
│   └── forgejo.nix      # Forgejo + Forgesync + agenix secrets
└── pixel-fold/
    ├── system.nix       # nix-on-droid config (custom flake output)
    └── _home.nix        # Home Manager config (skipped by import-tree)
```

## Secrets

Secrets are managed with [agenix](https://github.com/ryantm/agenix). Encrypted `.age` files live in `secrets/` and are decrypted at activation time on the target host.

To edit a secret:

```bash
nix run github:ryantm/agenix -- -e secrets/forgejo-runner-token.age
```

Keys authorized to decrypt are declared in `secrets/secrets.nix`.

## Guix

The `guix/` directory contains GNU Guix configurations for the mahakala workstation (system + home). These are managed independently:

```bash
sudo guix system reconfigure guix/system.scm
guix home reconfigure guix/home-configuration.scm
```

## Backups

`mother-nix-files/backups/` contains archived configs from defunct machines (T15s, XPS 13, Garden.io workstation) for reference.
