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
          version = "0.52.0";

          src = final.fetchCrate {
            pname = "decapod";
            version = "0.52.0";
            hash = "sha256-3S7K5SRzC052YmW3e+sgrUioC21RoNG9BCLjbhQsIx0=";
          };

          cargoHash = "sha256-8tSEcuBSp6pqOWw25Ur84ge8ZWDuElH6K5ATUjSrEbI=";

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
