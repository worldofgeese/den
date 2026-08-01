{
  inputs,
  den,
  ...
}: {
  den.aspects.devtools.homeManager = {pkgs, ...}: {
    nixpkgs.overlays = [
      (final: prev: {
        devenv = inputs.devenv.packages.${pkgs.stdenv.hostPlatform.system}.devenv;
        pi = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.pi;
      })
      (final: prev: {
        decapod = final.rustPlatform.buildRustPackage {
          pname = "decapod";
          version = "0.72.13";

          src = final.fetchzip {
            url = "https://static.crates.io/crates/decapod/decapod-0.72.13.crate";
            extension = "tar.gz";
            hash = "sha256-cAwOgoM2aCHHaIiu+QVtxb44MWXCITEqhF0Uskje4bs=";
          };

          cargoHash = "sha256-2Y1wHyXU0PhqRIHGlvnIWOTpIbLcdt6Gtbbnlu1HACU=";

          doCheck = false;

          nativeBuildInputs = with final;
            [pkg-config]
            ++ final.lib.optionals final.stdenv.hostPlatform.isLinux [lld autoPatchelfHook];
          nativeCheckInputs = [final.git];
          buildInputs =
            [final.sqlite]
            ++ final.lib.optionals final.stdenv.hostPlatform.isLinux [final.openssl final.stdenv.cc.cc.lib];

          meta = {
            description = "Decapod CLI — repo-native governance kernel for AI agents";
            homepage = "https://crates.io/crates/decapod";
            mainProgram = "decapod";
          };
        };

        # mcp-agent-mail disabled: fastmcp test flake — re-enable later

        br = final.rustPlatform.buildRustPackage {
          pname = "br";
          version = "0.2.11";

          src = final.fetchFromGitHub {
            owner = "Dicklesworthstone";
            repo = "beads_rust";
            rev = "v0.2.11";
            hash = "sha256-XfxO1gDt51CWv6T/wEX97uLm89Px0rEmCZEcofeWZG0=";
          };

          cargoHash = "sha256-3u7GMriV2ZG0mjjGYLXGcUDQrs83uRYDMy5NKXTdaTI=";

          RUSTC_BOOTSTRAP = "1";
          doCheck = false;

          nativeBuildInputs = with final; [pkg-config];
          buildInputs = final.lib.optionals final.stdenv.hostPlatform.isLinux [final.openssl];

          meta = {
            description = "Fast Rust port of Beads issue tracker";
            homepage = "https://github.com/Dicklesworthstone/beads_rust";
            license = final.lib.licenses.mit;
            mainProgram = "br";
          };
        };

        bv = final.buildGoModule {
          pname = "bv";
          version = "0.16.4";

          src = final.fetchFromGitHub {
            owner = "Dicklesworthstone";
            repo = "beads_viewer";
            rev = "v0.16.4";
            hash = "sha256-rKwrtbJ7PBo951BA35oeiuc+49R3vrj2Owz31jPc9uk=";
          };

          vendorHash = null;
          subPackages = ["cmd/bv"];
          doCheck = false;

          meta = {
            description = "Graph-aware TUI and robot-mode viewer for Beads";
            homepage = "https://github.com/Dicklesworthstone/beads_viewer";
            license = final.lib.licenses.mit;
            mainProgram = "bv";
          };
        };

        rtk = final.rustPlatform.buildRustPackage {
          pname = "rtk";
          version = "0.43.0";

          src = final.fetchFromGitHub {
            owner = "rtk-ai";
            repo = "rtk";
            rev = "v0.43.0";
            hash = "sha256-n5bkPPsrdM4fE5ltocTjlq+JwRgp39yib6S79fci4m4=";
          };

          cargoHash = "sha256-XKUKdhxfnwUCOx9slqx4oUFa09HcosPLVh5Xkh87oSk=";

          doCheck = false;

          meta = {
            description = "CLI proxy that reduces LLM token consumption by 60-90%";
            homepage = "https://github.com/rtk-ai/rtk";
            license = final.lib.licenses.mit;
            mainProgram = "rtk";
          };
        };

        agent-token-dashboard = final.buildGoModule {
          pname = "agent-token-dashboard";
          version = "0-unstable-2026-06-19";

          src = final.fetchFromGitHub {
            owner = "LEGO";
            repo = "agent-token-dashboard";
            rev = "d8324ea0daaaa55aca805daf561801abb59b0618";
            hash = "sha256-QAohsCSt/3wOtiL9YpXMxy6InFTHmy3YtEr4wtUY1DM=";
          };

          vendorHash = "sha256-Bo4gPp5QzAs29QDE7ahsnSfq9ZLUbM+/ImZ0jAawBnE=";
          env.CGO_ENABLED = "1";
          doCheck = false;

          patches = [];
          postPatch = ''
            substituteInPlace go.mod --replace-warn "go 1.26.4" "go 1.26.3"
          '';

          overrideModAttrs = _: {
            postPatch = ''
              substituteInPlace go.mod --replace-warn "go 1.26.4" "go 1.26.3"
            '';
          };

          meta = {
            description = "Single-binary dashboard for AI agent token usage";
            homepage = "https://github.com/LEGO/agent-token-dashboard";
            mainProgram = "ai-dashboard";
          };
        };
      })
    ];
    nixpkgs.config.allowUnfree = true;
  };
}
