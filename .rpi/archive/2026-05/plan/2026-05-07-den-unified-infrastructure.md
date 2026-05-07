---
archived_date: "2026-05-07"
date: 2026-05-07T18:05:39+02:00
design: .rpi/designs/2026-05-07-den-unified-infrastructure.md
status: archived
tags:
    - plan
    - nix
    - den
    - implementation
topic: den-unified-infrastructure
---

# den-unified-infrastructure — Implementation Plan

## Overview

Migrate the current standalone Home Manager config into a Den-based mono-repo, then incrementally add each host. Start with mahakala (lowest risk — only HM), then bring in the other systems one at a time.

**Scope**: ~15 new files, 2 modified files, Guix configs moved in, existing home.nix/flake.nix replaced

## Source Documents
- **Design**: .rpi/designs/2026-05-07-den-unified-infrastructure.md
- **Research**: .rpi/research/2026-05-07-dendritic-unification-landscape.md

## Phase 1: Den Scaffold + Shared User Aspect

### Overview

Initialize the Den flake (using the default template as reference), define the mahakala host, and extract the shared user aspect from the current `home.nix`. This phase replaces `flake.nix` and `home.nix` with Den equivalents while preserving identical functionality.

### Tasks:

#### 1. Flake entry point
**File**: `flake.nix`
**Changes**: Replace current flake with Den + flake-parts + import-tree structure. Inputs: nixpkgs, home-manager, den, flake-parts, import-tree, devenv.

#### 2. Host definition
**File**: `modules/hosts.nix`
**Changes**: Define `den.hosts.x86_64-linux.mahakala.users.worldofgeese = {};` and wire standalone HM output.

#### 3. Shared user aspect
**File**: `modules/worldofgeese.nix`
**Changes**: Extract from current home.nix: git (signing, user), starship (λ prompt, k8s), bat, eza, zoxide, direnv+nix-direnv, jq, atuin, password-store, broot, navi, pet, home-manager.enable, fonts, genericLinux, xdg.mime.

#### 4. Workstation aspect
**File**: `modules/workstation.nix`
**Changes**: Desktop/dev packages from current home.nix: kubectl, k9s, kubie, krew, gopass, nodejs, shellcheck, nixfmt, httpie, yt-dlp, python-launcher, yq, glab, opencode, claude-code, uv, decapod, topgrade, gh.

#### 5. SSH aspect
**File**: `modules/ssh.nix`
**Changes**: Fleet SSH matchBlocks (paphos, pixel-fold, mother, openclaw). Pulled from pixel-fold's known config.

#### 6. Guix co-location
**File**: `guix/` directory
**Changes**: Move `~/src/guix-config/{system.scm,home-configuration.scm,channels.scm,bashrc,vterm-bash.sh}` into `guix/` subdirectory.

### Success Criteria:

#### Automated Verification:
- [ ] `nix flake check` passes
- [ ] `nix build .#homeConfigurations.worldofgeese.activationPackage` succeeds
- [ ] Resulting activation package includes all packages from current home.nix
- [ ] No evaluation errors or warnings

#### Manual Verification:
- [ ] `home-manager switch --flake .#worldofgeese` applies successfully on mahakala
- [ ] Shell tools work: starship prompt, bat, eza, zoxide, direnv, atuin
- [ ] Git signing works
- [ ] Topgrade still runs Guix upgrades (references updated guix/ paths)

### Commit:
- [ ] Stage: flake.nix, flake.lock, modules/, guix/
- [ ] Message: `feat(den): scaffold Den mono-repo with mahakala HM and shared aspects`

---

## Phase 2: macOS (M-02877) Migration

### Overview

Add nix-darwin host definition and migrate fleek-nix-darwin config into Den aspects. Shared aspects (worldofgeese, ssh) are already available; only darwin-specific config needs new modules.

### Tasks:

#### 1. Darwin host definition
**File**: `modules/hosts.nix` (update)
**Changes**: Add `den.hosts.aarch64-darwin.M-02877.users.dktaohan = {};`

#### 2. Darwin system aspect
**File**: `modules/M-02877/darwin.nix`
**Changes**: Lix config, nix.settings, system.primaryUser, darwin-specific system config from fleek-nix-darwin.

#### 3. Darwin programs
**File**: `modules/M-02877/programs.nix`
**Changes**: macOS-specific programs from fleek-nix-darwin/programs.nix that don't belong in shared workstation aspect.

#### 4. Decapod overlay
**File**: `modules/overlays.nix`
**Changes**: Shared decapod overlay (already present in both repos). Consolidate into one place using `moduleWithSystem`.

### Success Criteria:

#### Automated Verification:
- [ ] `nix flake check` passes (including darwin system)
- [ ] `nix build .#darwinConfigurations.M-02877.system` succeeds
- [ ] mahakala HM still builds (no regression)

#### Manual Verification:
- [ ] `darwin-rebuild switch --flake .#M-02877` applies on macOS machine
- [ ] All programs from fleek-nix-darwin still available

### Commit:
- [ ] Stage: modules/hosts.nix, modules/M-02877/
- [ ] Message: `feat(den): add M-02877 nix-darwin host`

---

## Phase 3: Paphos NixOS Migration

### Overview

Add paphos NixOS host. This involves migrating the full NixOS config (hardware, services, secrets) from `/etc/nixos/` into Den aspects.

### Tasks:

#### 1. NixOS host definition
**File**: `modules/hosts.nix` (update)
**Changes**: Add `den.hosts.x86_64-linux.paphos.users.kypris = {};`

#### 2. Server aspect
**File**: `modules/server.nix`
**Changes**: Auto-upgrade, nix GC, SSH hardening — reusable for future servers.

#### 3. Paphos hardware + boot
**File**: `modules/paphos/hardware.nix`
**Changes**: AMD microcode, LUKS, Dropbear initrd, filesystem layout.

#### 4. Paphos services
**File**: `modules/paphos/forgejo.nix`
**Changes**: Forgejo + Forgesync configuration.

#### 5. Secrets
**File**: `modules/paphos/secrets.nix` + `secrets/*.age`
**Changes**: agenix declarations, encrypted secret files.

#### 6. Networking
**File**: `modules/paphos/networking.nix`
**Changes**: Tailscale, firewall, DHCP reservation config.

### Success Criteria:

#### Automated Verification:
- [ ] `nix build .#nixosConfigurations.paphos.config.system.build.toplevel` succeeds
- [ ] mahakala HM + M-02877 darwin still build (no regression)

#### Manual Verification:
- [ ] `nixos-rebuild switch --flake .#paphos --target-host kypris@paphos.hound-celsius.ts.net` applies
- [ ] Forgejo accessible at https://paphos.hound-celsius.ts.net/
- [ ] LUKS unlock still works via Dropbear on port 2222

### Commit:
- [ ] Stage: modules/paphos/, modules/server.nix, secrets/
- [ ] Message: `feat(den): add paphos NixOS host with Forgejo and agenix`

---

## Phase 4: Pixel Fold Nix-on-Droid Migration

### Overview

Add the Nix-on-Droid configuration for pixel-fold. Minimal aspect — just tmux, starship, and basic tools.

### Tasks:

#### 1. Nix-on-Droid host definition
**File**: `modules/hosts.nix` (update)
**Changes**: Add `den.hosts.aarch64-linux.pixel-fold.users.nix-on-droid = {};`

#### 2. Mobile aspect
**File**: `modules/mobile.nix`
**Changes**: tmux (Catppuccin + mouse), starship (λ), bat, eza, git, bash aliases (cc-sessions, cc-attach, ll, la).

#### 3. Nix-on-Droid system
**File**: `modules/pixel-fold/system.nix`
**Changes**: nix-on-droid system packages (openssh, tmux, git), nix-on-droid-specific config.

#### 4. Nix-on-Droid flake integration
**File**: `flake.nix` (update inputs)
**Changes**: Add nix-on-droid flake input, wire output.

### Success Criteria:

#### Automated Verification:
- [ ] Flake check passes
- [ ] All other hosts still build (no regression)

#### Manual Verification:
- [ ] `nix-on-droid switch --flake .#pixel-fold` applies on the phone (with app open)
- [ ] starship prompt, tmux, SSH matchBlocks all work

### Commit:
- [ ] Stage: modules/pixel-fold/, modules/mobile.nix, flake.nix
- [ ] Message: `feat(den): add pixel-fold nix-on-droid host`

---

## Phase 5: Cleanup + Harvest

### Overview

Remove old standalone configs, update deploy documentation, review mother-nix-files for reusable packages.

### Tasks:

#### 1. Remove old files
**Changes**: Remove `home.nix` (replaced by modules/), old flake.nix backup, any legacy files.

#### 2. Justfile
**File**: `Justfile`
**Changes**: Deploy recipes for each host (`just deploy-mahakala`, `just deploy-paphos`, etc.)

#### 3. Harvest mother-nix-files
**File**: `modules/chemistry.nix` (if worthwhile)
**Changes**: Review `mother-nix-files/projects/nixwithchemistry/` for packages worth preserving as an overlay.

#### 4. Update topgrade
**Changes**: Update topgrade pre_commands to reference `guix/` paths instead of `~/src/guix-config/`.

### Success Criteria:

#### Automated Verification:
- [ ] `nix flake check` passes
- [ ] All hosts build
- [ ] `decapod validate` passes

#### Manual Verification:
- [ ] Full `home-manager switch` on mahakala
- [ ] `just deploy-*` recipes work for each reachable host

### Commit:
- [ ] Stage: Justfile, removed files, updated modules
- [ ] Message: `chore(den): cleanup legacy files, add deploy recipes`

---

## References
- Design: .rpi/designs/2026-05-07-den-unified-infrastructure.md
- Research: .rpi/research/2026-05-07-dendritic-unification-landscape.md
- Den default template: `github:vic/den?dir=templates/default`
- Den docs: https://den.oeiuwq.com
