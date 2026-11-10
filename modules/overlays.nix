{
  inputs,
  den,
  ...
}: {
  den.aspects.devtools.homeManager = {pkgs, ...}: {
    nixpkgs.overlays = [
      (final: prev: {
        devenv = inputs.devenv.packages.${pkgs.stdenv.hostPlatform.system}.devenv;
      })
      (final: prev: {
        # The M-02877 `personal` secretspec alias (modules/shared-devtools.nix)
        # is an age file with two post-quantum recipients. SecretSpec's Rust age
        # library handles both only through plugins found on PATH, so every
        # secretspec caller needs them, including contexts with a minimal PATH
        # such as agent key helpers:
        #   - age-plugin-pq, from nixpkgs' age, for the backup key
        #   - age-plugin-se, from Homebrew, for the Secure Enclave key. nixpkgs
        #     builds it with Swift 5 and so without post-quantum support
        #     ("Post-quantum not supported in this build"). Upstream needs Swift
        #     6.2 and the macOS 26 SDK, which Homebrew's Xcode-built bottle has.
        #     See modules/M-02877/secretspec-se.nix.
        # Both paths are suffixed, so they never shadow anything already on PATH.
        secretspec = final.symlinkJoin {
          name = "secretspec-${prev.secretspec.version}";
          inherit (prev.secretspec) version meta;
          paths = [prev.secretspec];
          nativeBuildInputs = [final.makeWrapper];
          postBuild = ''
            wrapProgram $out/bin/secretspec --suffix PATH : ${final.age}/bin${final.lib.optionalString final.stdenv.hostPlatform.isDarwin ":/opt/homebrew/opt/age-plugin-se/bin"}
          '';
        };
      })
      (final: prev: {
        # Upstream ships packages.default as of DecapodLabs/decapod#1169, so the
        # version and both hashes now come from flake.lock. This previously was a
        # buildRustPackage here, which meant scripts/update-rust-tools.sh had to
        # re-derive the crate hash and discover cargoHash by building with a fake
        # one and scraping the mismatch out of stderr on every release.
        decapod = inputs.decapod.packages.${pkgs.stdenv.hostPlatform.system}.default;

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
      (final: prev: {
        # atuin 18.23.0's PTY end-to-end suites (tests/e2e_capture.rs,
        # tests/e2e_pty.rs) time out in the Darwin build sandbox: the shell
        # never draws the expected screen ("captured: []", "waiting for
        # \": exit\" on screen"). Many cases fail, not one, so skip checks on
        # Darwin. Linux still runs them. Drop this once nixpkgs fixes it.
        atuin = prev.atuin.overrideAttrs {
          doCheck = !final.stdenv.hostPlatform.isDarwin;
        };
      })
    ];
    nixpkgs.config.allowUnfree = true;
  };
}
