{
  description = "Den mono-repo: unified Nix infrastructure for all hosts";

  inputs = {
    den.url = "github:vic/den";
    flake-parts.url = "github:hercules-ci/flake-parts";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    darwin = {
      url = "github:nix-darwin/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    import-tree.url = "github:vic/import-tree";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    devenv = {
      url = "github:cachix/devenv/python-rewrite";
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
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; }
    (inputs.import-tree ./modules);
}
