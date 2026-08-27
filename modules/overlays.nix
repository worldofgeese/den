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
        # Upstream ships packages.default as of DecapodLabs/decapod#1169, so the
        # version and both hashes now come from flake.lock. This previously was a
        # buildRustPackage here, which meant scripts/update-rust-tools.sh had to
        # re-derive the crate hash and discover cargoHash by building with a fake
        # one and scraping the mismatch out of stderr on every release.
        decapod = inputs.decapod.packages.${pkgs.stdenv.hostPlatform.system}.default;

        # Re-enabled: the fastmcp test flake that motivated disabling this is
        # handled by the python313Packages fastmcp doCheck=false overlay below.
        mcp-agent-mail = final.python313Packages.buildPythonApplication {
          pname = "mcp-agent-mail";
          version = "0.3.2";
          pyproject = true;

          src = final.fetchFromGitHub {
            owner = "Dicklesworthstone";
            repo = "mcp_agent_mail";
            rev = "v0.3.2";
            hash = "sha256-KWxrgC48GmU8KhJ43lLchQL1LqVJc24Weg59jyv8qNk=";
          };

          nativeBuildInputs = [final.makeWrapper] ++ (with final.python313Packages; [hatchling]);
          pythonRelaxDeps = ["authlib"];

          propagatedBuildInputs = with final.python313Packages; [
            aiosqlite
            aiolimiter
            attrs
            authlib
            bleach
            botocore
            fastapi
            fastmcp
            filelock
            gitpython
            httpx
            jinja2
            jsonschema
            litellm
            markdown2
            orjson
            pathspec
            pillow
            psutil
            pynacl
            python-decouple
            pyyaml
            redis
            rich
            ruff
            sqlalchemy
            sqlmodel
            structlog
            tenacity
            tiktoken
            tinycss2
            typer
            uvicorn
          ];

          nativeCheckInputs = with final.python313Packages; [pytestCheckHook];
          doCheck = false;

          nativeInstallCheckInputs = [final.versionCheckHook];
          versionCheckProgramArg = "--version";
          doInstallCheck = false;

          postInstall = ''
            agent_mail_python_path="$out/${final.python313.sitePackages}:${final.python313Packages.makePythonPath (with final.python313Packages; [
              aiosqlite
              aiolimiter
              attrs
              authlib
              bleach
              botocore
              fastapi
              fastmcp
              filelock
              gitpython
              httpx
              jinja2
              jsonschema
              litellm
              markdown2
              orjson
              pathspec
              pillow
              psutil
              pynacl
              python-decouple
              pyyaml
              redis
              rich
              ruff
              sqlalchemy
              sqlmodel
              structlog
              tenacity
              tiktoken
              tinycss2
              typer
              uvicorn
            ])}"
            makeWrapper ${final.python313.interpreter} $out/bin/mcp-agent-mail \
              --prefix PYTHONPATH : "$agent_mail_python_path" \
              --add-flags "-m mcp_agent_mail.cli" \
              --set-default WORKTREES_ENABLED 1 \
              --set-default AGENT_MAIL_GUARD_MODE warn
            makeWrapper $out/bin/mcp-agent-mail $out/bin/am \
              --set-default WORKTREES_ENABLED 1 \
              --set-default AGENT_MAIL_GUARD_MODE warn
          '';

          meta = {
            description = "Mail-like coordination layer for coding agents";
            homepage = "https://github.com/Dicklesworthstone/mcp_agent_mail";
            license = final.lib.licenses.mit;
            mainProgram = "mcp-agent-mail";
          };
        };

        # version is the single source of truth: the git tag is derived from it, so
        # a release bump cannot leave rev pointing at the previous tag.
        br = let
          version = "0.2.11";
        in
          final.rustPlatform.buildRustPackage {
            pname = "br";
            inherit version;

            src = final.fetchFromGitHub {
              owner = "Dicklesworthstone";
              repo = "beads_rust";
              rev = "v${version}";
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

        bv = let
          version = "0.16.4";
        in
          final.buildGoModule {
            pname = "bv";
            inherit version;

            src = final.fetchFromGitHub {
              owner = "Dicklesworthstone";
              repo = "beads_viewer";
              rev = "v${version}";
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
        python313Packages = prev.python313Packages.overrideScope (pyFinal: pyPrev: {
          fastmcp = pyPrev.fastmcp.overridePythonAttrs {doCheck = false;};
        });
      })
    ];
    nixpkgs.config.allowUnfree = true;
  };
}
