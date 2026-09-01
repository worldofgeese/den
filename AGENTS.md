## Update and Deploy Commands

Use the repository `Justfile` for updates and deployments instead of running the underlying Nix/Guix commands directly.

- `just update` updates all flake inputs. Rust tools no longer need a separate step: `decapod` comes from its upstream flake and `rtk` from nixpkgs, so both track through `flake.lock`.
- `just update-input <input>` updates one flake input only, e.g. `just update-input decapod`.
- `just check` evaluates the NixOS, Home Manager, nix-darwin, and nix-on-droid entrypoints explicitly to avoid known-noise custom-output warnings from `nix flake check`.
- `just deploy-mahakala` updates and deploys Guix System, Guix Home, and Home Manager for mahakala.
- `just deploy-mahakala-hm` updates and applies only the mahakala Home Manager profile.
- `just deploy-mahakala-guix` applies only Guix Home for mahakala.
- `just deploy-mahakala-system` applies only Guix System for mahakala.
- `just deploy-paphos [host]` updates and deploys the paphos NixOS configuration to the target host.
- `just deploy-darwin` updates and applies the nix-darwin configuration for M-02877.
- `just deploy-pixel-fold` updates and applies the nix-on-droid configuration for pixel-fold.
- `just upgrade-kernel` refreshes the CachyOS kernel package metadata.


<!-- decapod-validator-anchors
Stop if
via decapod CLI
interface abstraction boundary
Strict Dependency: You are strictly bound to the Decapod governance kernel
-->
