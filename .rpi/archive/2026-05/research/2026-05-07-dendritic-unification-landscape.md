---
archived_date: "2026-05-07"
branch: main
date: 2026-05-07T17:53:10+02:00
git_commit: 26557fe
repository: home-manager
researcher: Claude
status: archived
tags:
    - research
    - nix
    - dendritic
    - den
    - infrastructure
    - unification
topic: dendritic-unification-landscape
---

# Research: dendritic-unification-landscape

## Research Question

How to unify 5 disparate system configurations (Guix System+Home, NixOS, nix-darwin, Home Manager standalone, Nix-on-Droid) under a single Dendritic/Den architecture that maximizes cross-pollination while respecting each platform's constraints?

## Problem Statement

Tao has 5 system configurations spread across 4 repos and 2 package managers:

1. **mahakala** (current machine) — Guix System (`~/src/guix-config/system.scm`) + Guix Home (`home-configuration.scm`) + standalone Nix Home Manager (`~/.config/home-manager/`)
2. **paphos** — NixOS server at `/etc/nixos/flake.nix` (Forgejo, agenix, LUKS unlock)
3. **google-pixel-fold** — Nix-on-Droid + Home Manager at `~/.config/nix-on-droid/`
4. **M-02877** (macOS) — nix-darwin + Home Manager at `github:worldofgeese/fleek-nix-darwin`
5. **mother** (Synology NAS) — no Nix/Guix (archived files now in `mother-nix-files/`)

These share significant overlap (git config, starship, bat, eza, direnv, shell aliases, SSH matchBlocks) but are maintained independently with no shared modules.

## Summary

**The Dendritic pattern** (mightyiam/dendritic) proposes that every Nix file except entrypoints is a top-level flake-parts module. Features span all configuration classes in a single file. Uses `deferredModule` types for lower-level NixOS/HM/darwin configs.

**Den** (vic/den) extends this with aspect-oriented programming: aspects are functions taking context `{ host, user }` and returning modules for different Nix classes (`nixos`, `darwin`, `homeManager`, `nixOnDroid`). Includes context pipelines, schemas, guarded forwarding, and parametric batteries.

Den is the better fit for Tao's fleet because:
- It natively handles multi-platform (NixOS + Darwin + Home Manager + nix-on-droid)
- Aspects share config between hosts/users without duplication
- The context pipeline handles the topology: hosts → users → homes
- It's zero-dependency and works with/without flake-parts

## Detailed Findings

### Current Infrastructure Inventory

| Host | Platform | Config Manager | Location | Key Features |
|------|----------|---------------|----------|--------------|
| mahakala | x86_64-linux | Guix System + Guix Home + Nix HM | `~/src/guix-config/` + `~/.config/home-manager/` | LUKS, EXWM, Podman, Tailscale, Nix-inside-Guix |
| paphos | x86_64-linux | NixOS | `/etc/nixos/` + `workspace/paphos-config/` | Forgejo, Forgesync, agenix, LUKS+Dropbear, auto-upgrade |
| google-pixel-fold | aarch64-linux | Nix-on-Droid + HM | `~/.config/nix-on-droid/` | starship, tmux+Catppuccin, SSH matchBlocks |
| M-02877 | aarch64-darwin | nix-darwin + HM | `github:worldofgeese/fleek-nix-darwin` | Lix, homebrew bridge, extensive programs.nix |
| mother | x86_64-linux (Synology) | None (archived) | local `mother-nix-files/` | Historical chemistry Nix packages |

### Shared Concerns (cross-pollination candidates)

- **Git**: signing key `63D28F81460A224A`, user `worldofgeese`, HTTPS protocol
- **Shell tools**: starship, bat, eza, zoxide, direnv, jq, atuin
- **SSH**: GPG agent SSH support, matchBlocks for fleet hosts (paphos, pixel-fold, openclaw)
- **Development**: devenv, uv, claude-code, decapod, opencode
- **Kubernetes**: kubectl, k9s, kubie, krew, kubectl-tree
- **Secrets**: agenix (paphos), gopass/pass (mahakala), GPG key `openpgp:0x708F0CE1`

### Platform Constraints

- **Guix System/Home**: Cannot be managed by Nix/Den. Must remain as Scheme. However, Nix HM runs *on top* of Guix Home via `~/.nix-profile/etc/profile.d/nix.sh` sourcing.
- **Nix-on-Droid**: OOM-prone, needs `nix-on-droid switch` not `home-manager switch`. Limited resources.
- **nix-darwin**: Uses Lix not Nix. macOS-specific services (Karabiner, Homebrew, etc.)
- **paphos NixOS**: Server role — no desktop. Has Dropbear initrd for remote LUKS unlock.

### Den Architecture Mapping

```
den.hosts.x86_64-linux.mahakala.users.worldofgeese = {};  # HM-only (Guix owns system)
den.hosts.x86_64-linux.paphos.users.kypris = {};          # Full NixOS
den.hosts.aarch64-linux.pixel-fold = {};                   # Nix-on-Droid
den.hosts.aarch64-darwin.M-02877.users.dktaohan = {};      # nix-darwin

den.aspects.worldofgeese = { ... };   # Shared user config
den.aspects.workstation = { ... };    # Desktop/dev tools
den.aspects.server = { ... };         # Server hardening, auto-upgrade
den.aspects.mobile = { ... };         # Lightweight, OOM-aware
```

### Key Design Decisions Needed

1. **Den vs pure Dendritic flake-parts?** — Den provides the multi-class aspect framework out of the box. Pure Dendritic requires building this yourself.
2. **Where does Guix fit?** — Guix System/Home stays as-is (Scheme). The Nix HM layer on mahakala becomes a Den-managed homeConfiguration. Guix is a hard boundary.
3. **Mono-repo or poly-repo?** — Dendritic/Den strongly favors mono-repo. One flake, all hosts.
4. **nix-on-droid integration** — Den's shell.nix example already shows `nixOnDroid.base` modules. Natural fit.
5. **Secrets strategy** — agenix for NixOS hosts, sops-nix or agenix for darwin, GPG-agent for HM-only.

## Assessment

Den (vic/den) is the right framework choice:
- Handles all 4 Nix platforms natively (NixOS, darwin, HM standalone, nix-on-droid)
- Aspect-oriented design maps perfectly to shared concerns (git, shell, k8s, etc.)
- Context pipeline gives type-safe host/user topology
- Active community, well-documented, used in production (EU Commission)
- Compatible with flake-parts or standalone

The Guix layer stays separate — it manages the system and the "first layer" of home on mahakala. The Nix HM layer adds developer tools on top. This is already working and shouldn't change.

## Suggested Next Steps

1. **Design** — Architecture document mapping current configs → Den aspects/hosts/users
2. **Scaffold** — `nix flake init -t github:vic/den` with the default template
3. **Implement incrementally**:
   - Phase 1: Shared user aspect (git, shell tools, starship, SSH)
   - Phase 2: mahakala HM standalone (replace current `~/.config/home-manager/`)
   - Phase 3: M-02877 darwin (migrate fleek-nix-darwin)
   - Phase 4: paphos NixOS (migrate from `/etc/nixos/`)
   - Phase 5: pixel-fold nix-on-droid (migrate from `~/.config/nix-on-droid/`)
4. **Harvest** — Review `mother-nix-files/` for reusable patterns/packages

## Decisions

- **Framework**: Den (vic/den) — aspect-oriented dendritic, not raw flake-parts dendritic
- **Scope**: All Nix-managed systems. Guix System/Home remains separate (Scheme, different paradigm)
- **Repo strategy**: Single mono-repo flake containing all hosts
- **Migration order**: Start with shared aspects + mahakala HM (lowest risk, immediate payoff)
