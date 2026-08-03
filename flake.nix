{
  description = "Den mono-repo: unified Nix infrastructure for all hosts";

  nixConfig = {
    extra-substituters = ["https://cache.numtide.com"];
    extra-trusted-public-keys = ["niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="];
  };

  inputs = {
    den.url = "github:denful/den";
    flake-parts.url = "github:hercules-ci/flake-parts";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    darwin = {
      url = "github:nix-darwin/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Upstream ships packages.default since DecapodLabs/decapod#1169, so the
    # version and hashes come from flake.lock instead of being re-derived by
    # scripts/update-rust-tools.sh on every release. rust-overlay follows the
    # root nixpkgs so this does not pull a second nixpkgs copy into the lock.
    decapod = {
      url = "github:DecapodLabs/decapod";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    import-tree.url = "github:vic/import-tree";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    devenv = {
      url = "github:cachix/devenv";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    forgesync = {
      url = "github:lukaswrz/forgesync";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    helium = {
      url = "github:oxcl/nix-flake-helium-browser";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # The lock already pinned llm-agents to the root nixpkgs, but nothing here
    # declared it -- so `nix flake update` kept splitting off a second nixpkgs
    # copy (nixpkgs_2). Declare it like every other input.
    llm-agents = {
      url = "github:numtide/llm-agents.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # ewm-core depends on the libdisplay-info-sys crate, whose build script
    # requires libdisplay-info 0.3.x. nixpkgs moved to 0.4.0, so following the
    # root nixpkgs fails with "system library `libdisplay-info` ... not found"
    # even though 0.4.0 sits on PKG_CONFIG_PATH.
    #
    # Dropping `follows` is not enough: `nix flake lock` then resolves
    # ewm/nixpkgs to a *fresh* nixpkgs (0.4.0 again) instead of honoring the
    # nixpkgs ewm committed. Pin ewm's own locked rev explicitly so the
    # dependency is visible here rather than hidden in ewm's lock.
    # Revert to `follows = "nixpkgs"` once libdisplay-info-sys supports 0.4.
    ewm = {
      url = "git+https://codeberg.org/ezemtsov/ewm";
      inputs.nixpkgs.follows = "nixpkgs-ewm";
    };
    nixpkgs-ewm.url = "github:NixOS/nixpkgs/0182a361324364ae3f436a63005877674cf45efb";
    # Use nix-on-droid's own tested nixpkgs + home-manager versions.
    # See: https://github.com/nix-community/nix-on-droid/issues/495
    # Remove these pins once nix-on-droid merges PR #529 (proot-termux update)
    nixpkgs-nod.url = "github:NixOS/nixpkgs/5d874ac46894c896119bce68e758e9e80bdb28f1";
    home-manager-nod = {
      url = "github:nix-community/home-manager/4de84265d7ec7634a69ba75028696d74de9a44a7";
      inputs.nixpkgs.follows = "nixpkgs-nod";
    };
    nix-on-droid = {
      url = "github:nix-community/nix-on-droid/release-24.05";
      inputs.nixpkgs.follows = "nixpkgs-nod";
      inputs.home-manager.follows = "home-manager-nod";
    };
    emacs-tramp-rpc = {
      url = "github:ArthurHeymans/emacs-tramp-rpc";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-doom-emacs-unstraightened = {
      url = "github:marienz/nix-doom-emacs-unstraightened";
      inputs.nixpkgs.follows = "";
    };
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake {inherit inputs;}
    (inputs.import-tree ./modules);
}
