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
    agenix.url = "github:ryantm/agenix";
    forgesync.url = "github:lukaswrz/forgesync";
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; }
    (inputs.import-tree ./modules);
}
