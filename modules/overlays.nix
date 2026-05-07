{ inputs, den, ... }:
{
  den.default.homeManager = { pkgs, ... }: {
    nixpkgs.overlays = [
      (final: prev: {
        devenv = inputs.devenv.packages.${pkgs.stdenv.hostPlatform.system}.devenv;
      })
      (final: prev: {
        _1password-gui = prev._1password-gui.override {
          polkitPolicyOwners = [ "worldofgeese" ];
        };
      })
      (final: prev: {
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
      })
    ];
    nixpkgs.config.allowUnfree = true;
  };
}
