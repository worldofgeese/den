# Den

Unified Nix infrastructure for all my machines. Built on [Den](https://github.com/vic/den) (aspect-oriented flake-parts framework) with [import-tree](https://github.com/vic/import-tree) for automatic module discovery.

## What you get

**Shell & terminal:** zsh (macOS) / bash (Linux) with autocompletions, syntax highlighting, Starship prompt (Dracula theme), WezTerm, tmux with session persistence

**Modern coreutils:** eza, bat, fd, ripgrep, dust, duf, procs, sd, fzf, zoxide, broot, delta (side-by-side diffs)

**History & snippets:** atuin (fuzzy synced shell history), navi, pet, cheat

**Development:** Node.js, Rust (via rustup), Python (via uv), Bun, .NET, Go tooling, Neovim, Zed, Doom Emacs

**Cloud & infra:** kubectl, k9s, Helm, Flux, AWS CLI, Azure CLI, Pulumi, OpenShift, krew, kubie, saml2aws

**Git:** GPG/SSH commit signing, LFS, lazygit, delta, gh + gh-dash

**Containers:** Podman, Docker Compose, DevPod, Distrobox, Kind

**macOS extras:** Homebrew management, Touch ID for sudo (survives tmux), system defaults, AeroSpace tiling, Lix as Nix implementation

**Upgrades:** Run `topgrade --yes` to update everything in one go (Nix, Guix, Homebrew, Doom Emacs, Flatpak — then auto-GC)

## Hosts

| Host | Platform | Description |
|------|----------|-------------|
| **mahakala** | x86_64-linux | Personal workstation — Guix System + Guix Home + Home Manager |
| **M-02877** | aarch64-darwin | Work MacBook — nix-darwin + Home Manager + Homebrew |
| **paphos** | x86_64-linux | Home server — NixOS, Forgejo, Forgesync, Tailscale, agenix secrets |
| **pixel-fold** | aarch64-linux | Android phone — nix-on-droid (proot, not NixOS) |

## Prerequisites

- [Nix](https://nixos.org/download/) (or [Lix](https://lix.systems/install/)) with flakes enabled
- [just](https://github.com/casey/just) (optional, for deploy shortcuts)
- Platform-specific: `darwin-rebuild` (macOS), `nixos-rebuild` (NixOS), `nix-on-droid` (Android), `guix` (Guix System)

## Quick start

### macOS (M-02877)

```bash
# Install Lix
curl -sSf -L https://install.lix.systems/lix | sh -s -- install

# Clone
git clone https://github.com/worldofgeese/den.git ~/.config/home-manager
cd ~/.config/home-manager

# First apply (bootstrap nix-darwin)
nix flake update
sudo -H nix run nix-darwin -- switch --flake .#M-02877

# Subsequent applies
just deploy-darwin
```

After the first successful rebuild, open a new terminal to pick up the shell configuration.

### Linux workstation (mahakala)

mahakala runs Guix System as its base OS with Nix Home Manager layered on top.

```bash
# Ensure Nix is installed with flakes
# Clone to the expected path
git clone https://github.com/worldofgeese/den.git ~/.config/home-manager
cd ~/.config/home-manager

# Deploy all three layers
just deploy-mahakala
```

### NixOS server (paphos)

```bash
# From any machine with SSH access to paphos
just deploy-paphos
```

### Android (pixel-fold)

Must be run on-device from the Nix-on-Droid app (not over SSH — activation requires a real terminal):

```bash
git clone https://github.com/worldofgeese/den.git ~/.config/home-manager
cd ~/.config/home-manager
nix-on-droid switch --flake .#pixel-fold
```

## Deploying

```bash
# Everything on mahakala (Guix System + Guix Home + Home Manager)
just deploy-mahakala

# Only Home Manager on mahakala
just deploy-mahakala-hm

# Only Guix Home
just deploy-mahakala-guix

# Only Guix System (requires sudo)
just deploy-mahakala-system

# Work MacBook (nix-darwin)
just deploy-darwin

# Home server (remote NixOS)
just deploy-paphos

# Android phone (on-device only)
just deploy-pixel-fold
```

Or without just:

```bash
home-manager switch --flake .#worldofgeese              # mahakala HM
darwin-rebuild switch --flake .#M-02877                 # macOS
nixos-rebuild switch --flake .#paphos --target-host paphos --use-remote-sudo
nix-on-droid switch --flake .#pixel-fold                # Android (on-device)
sudo guix system reconfigure guix/system.scm            # Guix System
guix home reconfigure guix/home-configuration.scm       # Guix Home
```

There are also shell aliases on M-02877:

```bash
fleek-apply     # hostname-agnostic darwin-rebuild
apply-M-02877   # same thing, explicit
```

## Upgrading

### Everything at once

```bash
topgrade --yes
```

On mahakala this upgrades Guix System, Guix Home, Nix flake inputs, Doom Emacs, Flatpak, then garbage-collects all package managers. On M-02877 it runs darwin-rebuild with a fresh flake lock.

### Just the Nix configuration

```bash
nix flake update --flake ~/.config/home-manager
just deploy-darwin   # or deploy-mahakala-hm, etc.
```

### A single flake input

```bash
just update-input nixpkgs
```

### Upgrading Lix (macOS)

Lix comes from `pkgs.lixPackageSets.latest.lix`. Bump nixpkgs to get a newer Lix:

```bash
just update-input nixpkgs
just deploy-darwin
nix --version  # reflects the new Lix
```

Don't run `nix upgrade-nix` — it doesn't know about Lix's release channel.

## Architecture

Every `.nix` file under `modules/` is automatically imported as a top-level [flake-parts](https://flake-parts.hercules-ci.com/) module (via import-tree). Files prefixed with `_` are skipped.

### Key concepts

- **`den.hosts.<system>.<hostname>`** — Declares a full system (NixOS or nix-darwin) with users
- **`den.homes.<system>.<username>`** — Declares standalone Home Manager configs (no system management)
- **`den.aspects.<name>`** — Reusable feature bundles with `.nixos`, `.darwin`, and `.homeManager` sub-attributes
- **`den.default`** — Global settings applied to all hosts/homes

**Exception:** pixel-fold bypasses the Den framework entirely because nix-on-droid requires its own `nixOnDroidConfiguration` builder that is incompatible with flake-parts host wiring. It uses a raw `flake.nixOnDroidConfigurations` output and does not receive global Den defaults or aspects.

### Module layout

```
modules/
├── dendritic.nix        # Imports Den framework
├── hosts.nix            # Host/home declarations
├── defaults.nix         # Global defaults + aspect wiring
├── worldofgeese.nix     # Shared user aspect (git, shell tools, direnv, atuin)
├── workstation.nix      # Desktop/dev packages + topgrade + k9s
├── ssh.nix              # Fleet SSH matchBlocks (Tailscale hostnames)
├── server.nix           # Reusable NixOS server aspect
├── overlays.nix         # Nixpkgs overlays (devenv, decapod)
├── mahakala.nix         # Wires worldofgeese → workstation + ssh
├── M-02877/
│   ├── darwin.nix       # macOS system (Lix, Homebrew, Touch ID, zsh, system defaults)
│   └── dktaohan.nix     # Work user (separate git identity, full dev toolchain)
├── paphos/
│   ├── system.nix       # Auto-upgrade, users, sudo, boot
│   ├── hardware.nix     # Disks, LUKS, Dropbear initrd SSH
│   ├── networking.nix   # Tailscale, openssh, locale
│   └── forgejo.nix      # Forgejo + Forgesync + agenix secrets
└── pixel-fold/
    ├── system.nix       # nix-on-droid config (custom flake output, pinned inputs)
    └── _home.nix        # Home Manager config (skipped by import-tree, loaded by system.nix)
```

## Secrets

Secrets are managed with [agenix](https://github.com/ryantm/agenix). Encrypted `.age` files live in `secrets/` and are decrypted at activation time on the target host.

To edit a secret:

```bash
nix run github:ryantm/agenix -- -e secrets/forgejo-runner-token.age
```

Keys authorized to decrypt are declared in `secrets/secrets.nix`.

macOS uses [secretspec](https://secretspec.dev) for Keychain-stored secrets (e.g. `HOMEBREW_GITHUB_API_TOKEN`). After first apply:

```bash
secretspec config init       # pick "keyring" backend
secretspec check             # shows missing secrets
secretspec set HOMEBREW_GITHUB_API_TOKEN
```

## Guix

The `guix/` directory contains GNU Guix configurations for the mahakala workstation (system + home). These are managed independently from Nix:

```bash
sudo guix system reconfigure guix/system.scm
guix home reconfigure guix/home-configuration.scm
```

Guix manages: kernel, desktop environment (GNOME), system services (PipeWire, GPG agent, dbus), fonts, and desktop packages (Emacs, Podman, Steam, browsers).

Nix Home Manager manages: shell development tools, overlays, direnv, starship, atuin, and dev-oriented CLI packages.

The two coexist via `~/.nix-profile` being sourced in the Guix shell profile.

## nix-on-droid pinning

The pixel-fold configuration uses pinned versions of nixpkgs and home-manager (`nixpkgs-nod` and `home-manager-nod` inputs) rather than following the main nixpkgs-unstable. This works around a [proot pty bug](https://github.com/nix-community/nix-on-droid/issues/495) where glibc 2.42's `TCGETS2` ioctl causes "getting pseudoterminal attributes: Permission denied" during activation.

The pins match nix-on-droid release-24.05's tested versions. Remove them once [PR #529](https://github.com/nix-community/nix-on-droid/pull/529) (proot-termux update) is merged and you can reinstall from a new bootstrap zip.

**Important:** `nix-on-droid switch` must be run on-device (from the Nix-on-Droid app), not over SSH — the activation step requires a proper terminal.

## Troubleshooting

### `error: getting status of '/nix/store/.../flake.nix': No such file or directory`

Nix flakes require all referenced files to be tracked by git:

```bash
git add -A && git commit -m "track new files"
```

### `Unexpected files in /etc` on first macOS apply

The Lix installer's `/etc/nix/nix.conf` conflicts with nix-darwin. Move it aside:

```bash
sudo mv /etc/nix/nix.conf /etc/nix/nix.conf.before-nix-darwin
just deploy-darwin
```

### `experimental Lix feature 'nix-command' is disabled`

Happens during bootstrap before nix-darwin writes its own nix.conf. Pass the flag inline:

```bash
sudo -H nix --extra-experimental-features "nix-command flakes" run nix-darwin -- switch --flake .
```

After the first successful rebuild this goes away.

### Hash mismatch / stale lock file

```bash
nix flake update
```

### Guix activation fails with "Read-only file system" on `~/.ssh/`

This happens when Home Manager's `programs.ssh` creates symlinks in `~/.ssh/` that Guix's activation script then tries to `chmod`. The Guix config already skips symlinks — if you see this, ensure `guix/home-configuration.scm` has the `(unless (symbolic-link? file) ...)` guard in the ssh-permissions service.

### nix-on-droid "getting pseudoterminal attributes: Permission denied"

This is the proot pty bug. Ensure you're using the pinned inputs (`nixpkgs-nod` / `home-manager-nod`). If you've accidentally updated the lock, restore the pins:

```bash
nix flake update nixpkgs-nod home-manager-nod nix-on-droid
```

If you see this after a Nix-on-Droid app update, you may need to reinstall from a fresh bootstrap zip (wipes app data).

## Uninstall

### macOS (nix-darwin + Lix)

```bash
nix --extra-experimental-features "nix-command flakes" run nix-darwin#darwin-uninstaller
/nix/lix-installer uninstall
```

If you get "volume in use":

```bash
sudo diskutil unmountDisk force /nix && sudo diskutil apfs deleteVolume "Nix Store"
```

### Linux (Home Manager + Nix)

```bash
home-manager uninstall
/nix/nix-installer uninstall  # or /nix/lix-installer uninstall
```

### nix-on-droid

Uninstall the Nix-on-Droid app from Android settings.

## Reference

- [Home Manager manual](https://nix-community.github.io/home-manager/)
- [Home Manager options search](https://home-manager-options.extranix.com/)
- [nix-darwin manual](https://daiderd.com/nix-darwin/manual/index.html)
- [Den framework](https://github.com/vic/den)
- [nix-on-droid](https://github.com/nix-community/nix-on-droid)
- [GNU Guix manual](https://guix.gnu.org/manual/)
- [agenix](https://github.com/ryantm/agenix)
- [secretspec](https://secretspec.dev)
