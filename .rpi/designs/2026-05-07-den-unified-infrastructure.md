---
date: 2026-05-07T17:54:54+02:00
related_research: .rpi/research/2026-05-07-dendritic-unification-landscape.md
status: active
tags:
    - design
    - nix
    - den
    - dendritic
    - architecture
topic: den-unified-infrastructure
---

# Design: den-unified-infrastructure

## Summary

A single Den (vic/den) mono-repo flake managing all Nix-based systems — mahakala (HM standalone), paphos (NixOS), M-02877 (nix-darwin), and google-pixel-fold (Nix-on-Droid) — with Guix System/Home configs co-located in the same repo. Shared aspects provide cross-pollinated config for git, shell, dev tools, and SSH across all platforms. Den sits on flake-parts, so `moduleWithSystem` is available for clean per-system input access.

## Context

5 system configs spread across 4 repos share 60-70% of their user-facing configuration (git, starship, bat, eza, direnv, SSH, etc.) but are maintained independently. Changes to shared concerns require manual propagation. The Dendritic/Den pattern solves this by making each feature a single file that contributes to all relevant configuration classes.

## Constraints

- **Guix co-location**: Guix System + Guix Home `.scm` files live in the same repo but are evaluated by Guile, not Nix. Shared data (hostnames, user identity) is co-located for single-repo convenience. The Guix Home on mahakala sources the Nix profile (`~/.nix-profile/etc/profile.d/nix.sh`), so they're tightly coupled and should be versioned together.
- **Nix-on-Droid OOM**: pixel-fold has limited RAM. Evaluations must stay minimal. Heavy packages should be excluded from mobile aspects.
- **Lix on macOS**: M-02877 uses Lix. The flake must not assume standard Nix features unavailable in Lix.
- **Secrets heterogeneity**: agenix on NixOS, GPG-agent for HM-only hosts. No single solution spans all.
- **Incremental migration**: Can't break existing systems. Each host migrates independently while the old config remains functional.

## Components

### Hosts

```nix
# One-liner host definitions in a hosts.nix module
den.hosts.x86_64-linux.mahakala.users.worldofgeese = {};
den.hosts.x86_64-linux.paphos.users.kypris = {};
den.hosts.aarch64-linux.pixel-fold.users.nix-on-droid = {};
den.hosts.aarch64-darwin.M-02877.users.dktaohan = {};
```

**mahakala** — HM-only. Den produces a `homeConfigurations."worldofgeese"` output. No nixosConfiguration. Guix owns the system layer.

**paphos** — Full NixOS. Den produces `nixosConfigurations.paphos`. Includes Forgejo, Forgesync, agenix, Dropbear initrd, auto-upgrade, weekly GC.

**M-02877** — nix-darwin. Den produces `darwinConfigurations.M-02877`. Includes Lix, Homebrew integration, macOS-specific programs.

**pixel-fold** — Nix-on-Droid. Den produces a nix-on-droid configuration. Minimal footprint, tmux+Catppuccin, SSH matchBlocks.

### Aspects (shared features)

```nix
# modules/worldofgeese.nix — User identity & tools
den.aspects.worldofgeese = {
  homeManager = { pkgs, ... }: {
    programs.git = { ... };      # signing, user config
    programs.starship = { ... }; # λ prompt, k8s enabled
    programs.bat.enable = true;
    programs.eza.enable = true;
    programs.zoxide.enable = true;
    programs.direnv = { enable = true; nix-direnv.enable = true; };
    programs.jq.enable = true;
    programs.atuin = { ... };
  };
  includes = [ den.aspects.ssh den.aspects.shell-aliases ];
};
```

```nix
# modules/workstation.nix — Desktop/dev tools (mahakala + M-02877)
den.aspects.workstation = {
  homeManager = { pkgs, ... }: {
    home.packages = with pkgs; [ kubectl k9s kubie krew uv claude-code opencode decapod ];
    programs.gh = { ... };
    programs.topgrade = { ... };
  };
  darwin = { pkgs, ... }: { ... };  # macOS-specific (Homebrew, etc.)
};
```

```nix
# modules/server.nix — Server hardening (paphos only)
den.aspects.server = {
  nixos = { ... }: {
    system.autoUpgrade = { ... };
    nix.gc = { ... };
    services.openssh = { ... };
  };
  includes = [ den.aspects.agenix ];
};
```

```nix
# modules/mobile.nix — Lightweight mobile (pixel-fold)
den.aspects.mobile = {
  homeManager = { pkgs, ... }: {
    programs.tmux = { ... };  # Catppuccin + mouse
    programs.starship = { ... };
    home.packages = with pkgs; [ bat eza git ];
  };
};
```

```nix
# modules/ssh.nix — SSH matchBlocks for the fleet
den.aspects.ssh = {
  homeManager = { ... }: {
    programs.ssh.matchBlocks = {
      paphos = { hostname = "paphos.hound-celsius.ts.net"; user = "kypris"; };
      pixel-fold = { hostname = "google-pixel-fold.hound-celsius.ts.net"; port = 8022; user = "nix-on-droid"; };
      mother = { hostname = "mother"; port = 2235; user = "taohansen"; };
    };
  };
};
```

### Host-specific modules

Each host gets a dedicated aspect for hardware/platform config that doesn't belong in shared aspects:

- `den.aspects.paphos` — Forgejo, Forgesync, LUKS, Dropbear initrd, networking
- `den.aspects.M-02877` — Lix config, Homebrew casks, macOS defaults
- `den.aspects.pixel-fold` — nix-on-droid system packages, OOM workarounds

### Secrets

- **paphos**: agenix — encrypted `.age` files in repo under `secrets/`, decrypted at runtime
- **mahakala/M-02877**: GPG-agent for SSH, gopass/pass for passwords (managed outside Nix)
- **pixel-fold**: No secrets management needed (SSH keys only)

Alternative considered: sops-nix (supports all platforms). Deferred — agenix already working on paphos, and HM-only hosts don't need encrypted secrets in the repo.

## `moduleWithSystem` Usage

Den builds on flake-parts, so `moduleWithSystem` is available for threading per-system input packages into system-agnostic modules. This avoids the `specialArgs` anti-pattern that Dendritic explicitly discourages:

```nix
# modules/devtools.nix — using moduleWithSystem for input-derived packages
{ moduleWithSystem, inputs, ... }:
{
  den.aspects.devtools = {
    homeManager = moduleWithSystem (
      { inputs', ... }:
      { pkgs, ... }:
      {
        home.packages = [
          inputs'.devenv.packages.devenv
          pkgs.claude-code
          pkgs.decapod
        ];
      }
    );
  };
}
```

This is preferable to `inputs.devenv.packages.${pkgs.stdenv.hostPlatform.system}.devenv` because it's cleaner, avoids reaching into `pkgs` for system string, and flake-parts handles the system resolution.

## File Structure

```
den/                              # New mono-repo (or evolves current ~/.config/home-manager/)
├── flake.nix                     # Entry point: inputs + import-tree ./modules
├── flake.lock
├── modules/
│   ├── hosts.nix                 # Host/user definitions
│   ├── worldofgeese.nix          # Shared user aspect (git, shell, tools)
│   ├── workstation.nix           # Desktop/dev aspect
│   ├── server.nix                # Server aspect
│   ├── mobile.nix                # Mobile aspect
│   ├── ssh.nix                   # Fleet SSH matchBlocks
│   ├── shell-aliases.nix         # Shared aliases
│   ├── kubernetes.nix            # K8s tools aspect
│   ├── devtools.nix              # Dev tools using moduleWithSystem for inputs
│   ├── paphos/
│   │   ├── hardware.nix          # Hardware config
│   │   ├── forgejo.nix           # Forgejo + Forgesync
│   │   ├── secrets.nix           # agenix declarations
│   │   └── networking.nix        # Tailscale, firewall, Dropbear
│   ├── M-02877/
│   │   ├── darwin.nix            # macOS system config
│   │   └── homebrew.nix          # Casks and formulae
│   └── pixel-fold/
│       └── system.nix            # nix-on-droid system packages
├── guix/                         # Guix configs (evaluated by Guile, not Nix)
│   ├── system.scm                # mahakala Guix System
│   ├── home-configuration.scm    # mahakala Guix Home
│   ├── channels.scm              # Guix channel declarations
│   ├── bashrc                    # Shell config sourced by Guix Home
│   └── vterm-bash.sh             # Emacs vterm integration
├── secrets/                      # agenix encrypted files (paphos)
│   ├── secrets.nix               # Age key declarations
│   ├── forgejo-password.age
│   └── forgesync-token.age
└── Justfile                      # Deploy commands per host
```

## Deploy Commands

```bash
# mahakala (current machine — HM standalone)
home-manager switch --flake .#worldofgeese

# paphos (remote NixOS)
nixos-rebuild switch --flake .#paphos --target-host kypris@paphos.hound-celsius.ts.net

# M-02877 (macOS)
darwin-rebuild switch --flake .#M-02877

# pixel-fold (Nix-on-Droid — must be run ON the phone or piped)
nix-on-droid switch --flake .#pixel-fold
```

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Den evaluation too heavy for pixel-fold | Medium | OOM during switch | Minimal mobile aspect; pre-build on mahakala, copy closure |
| Breaking paphos during migration | Low | Server downtime | Migrate paphos last; test with `nixos-rebuild build` first |
| Lix compatibility issues | Low | macOS build failures | Pin Den to Lix-compatible nixpkgs; test in CI |
| Flake lock conflicts across platforms | Medium | Annoying but not blocking | Single lock file; pin nixpkgs to unstable for all |

## Out of Scope

- **Guix-to-Nix migration**: Guix System/Home configs move into the mono-repo but remain Scheme. No rewriting them in Nix.
- **Guix/Nix data sharing automation**: No code generation between Scheme↔Nix yet. Co-location is the first step; automated extraction of shared data (hostnames, keys) is future work.
- **mother NAS Nix setup**: No plan to run Nix on the Synology. Files archived for harvesting later.
- **CI/CD**: Not designing automated deployment yet. Manual `switch` per host.
- **Impermanence/disko**: Not adding these patterns in initial migration.

## References

- Research: .rpi/research/2026-05-07-dendritic-unification-landscape.md
- Den docs: https://den.oeiuwq.com
- Den repo: https://github.com/vic/den
- Dendritic pattern: https://github.com/mightyiam/dendritic
- Den default template: `nix flake init -t github:vic/den`
- Real example (cross-platform): https://github.com/vic/den/tree/main/templates/example
