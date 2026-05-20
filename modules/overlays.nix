{ inputs, den, ... }:
{
  den.aspects.devtools.homeManager = { pkgs, ... }: {
    nixpkgs.overlays = [
      (final: prev: {
        devenv = inputs.devenv.packages.${pkgs.stdenv.hostPlatform.system}.devenv;
      })
      (final: prev: {
        decapod = final.rustPlatform.buildRustPackage {
          pname = "decapod";
          version = "0.48.6";

          src = final.fetchCrate {
            pname = "decapod";
            version = "0.48.6";
            hash = "sha256-RcclT5sK250IbGMRPL0oo119gKEVmXfQjIHQ85Eydhk=";
          };

          cargoHash = "sha256-0h4uNldMp9KZvPoMBkqWkWRXJ0mu98StY8d/F9ZOFM0=";

          doCheck = false;

          nativeBuildInputs = with final; [ pkg-config ]
            ++ final.lib.optionals final.stdenv.hostPlatform.isLinux [ lld autoPatchelfHook ];
          nativeCheckInputs = [ final.git ];
          buildInputs = [ final.sqlite ]
            ++ final.lib.optionals final.stdenv.hostPlatform.isLinux [ final.openssl final.stdenv.cc.cc.lib ];

          meta = {
            description = "Decapod CLI — repo-native governance kernel for AI agents";
            homepage = "https://crates.io/crates/decapod";
            mainProgram = "decapod";
          };
        };

        rtk = final.rustPlatform.buildRustPackage {
          pname = "rtk";
          version = "0.40.0";

          src = final.fetchFromGitHub {
            owner = "rtk-ai";
            repo = "rtk";
            rev = "v0.40.0";
            hash = "sha256-xWHIOZRpSyyOPQe/db9dxoODcnheBlpXrnKET010vVg=";
          };

          cargoHash = "sha256-DJazpSx1FCt9pjFjqsoL3MLEQLdFvLwEj3UsP0aYHmc=";

          doCheck = false;

          meta = {
            description = "CLI proxy that reduces LLM token consumption by 60-90%";
            homepage = "https://github.com/rtk-ai/rtk";
            license = final.lib.licenses.mit;
            mainProgram = "rtk";
          };
        };
      })
    ];
    nixpkgs.config.allowUnfree = true;
  };
}
