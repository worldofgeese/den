{ inputs, den, ... }:
{
  den.aspects.devtools.homeManager = { pkgs, ... }: {
    nixpkgs.overlays = [
      (final: prev: {
        devenv = inputs.devenv.packages.${pkgs.stdenv.hostPlatform.system}.devenv;
        pi = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.pi;
      })
      (final: prev: {
        decapod = final.rustPlatform.buildRustPackage {
          pname = "decapod";
          version = "0.53.1";

          src = final.fetchCrate {
            pname = "decapod";
            version = "0.53.1";
            hash = "sha256-tAUWQ8OhVpcjNaY3dVE3PHdllwVHLU3wSY/uoTOCovQ=";
          };

          cargoHash = "sha256-tlu8X/oZ8doANxNVtwWaE4Or4ZwnmXbwb8LZNMC307Q=";

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
          version = "0.42.0";

          src = final.fetchFromGitHub {
            owner = "rtk-ai";
            repo = "rtk";
            rev = "v0.42.0";
            hash = "sha256-ZCDVS/AFljljMac+cAzQztYPQgvQrcEhKIHHRhkMsv8=";
          };

          cargoHash = "sha256-CFhKBzJc2/+gZDfHq7wxBWEbtHV8EF3OYa+t1b9aL8k=";

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
