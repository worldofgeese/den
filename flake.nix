{
  description = "Home Manager configuration of worldofgeese";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    devenv = {
      url = "github:cachix/devenv/python-rewrite";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, home-manager, devenv, ... }:
    let
      system = "x86_64-linux";

      decapodOverlay = final: prev: {
        decapod = final.rustPlatform.buildRustPackage {
          pname = "decapod";
          version = "0.47.27";

          src = final.fetchCrate {
            pname = "decapod";
            version = "0.47.27";
            hash = "sha256-u/QFpVFgxLxx0DfMEm/IDFsVss2Y6l4EAAqS24mzcqw=";
          };

          cargoHash = "sha256-sToKcJRnpAiEQ3gmZK5QuO2JX+2VVy9INvhEIhT/LSg=";

          doCheck = false;

          nativeBuildInputs = [ final.pkg-config final.lld final.autoPatchelfHook ];
          nativeCheckInputs = [ final.git ];
          buildInputs = [ final.sqlite final.openssl final.stdenv.cc.cc.lib ];

          meta = {
            description = "Decapod CLI — repo-native governance kernel for AI agents";
            homepage = "https://crates.io/crates/decapod";
            mainProgram = "decapod";
          };
        };
      };

      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        overlays = [
          (self: super: { devenv = devenv.packages.${system}.devenv; })
          (final: prev: {
            _1password-gui = prev._1password-gui.override {
              polkitPolicyOwners = [ "taohansen" ];
            };
          })
          decapodOverlay
        ];
      };
    in {
      homeConfigurations."worldofgeese" =
        home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          modules = [ ./home.nix ];
        };

      packages.${system} = {
        decapod = pkgs.decapod;
        default = pkgs.decapod;
      };
    };
}
