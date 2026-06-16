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
          version = "0.58.1";

          src = final.fetchzip {
            url = "https://static.crates.io/crates/decapod/decapod-0.58.1.crate";
            extension = "tar.gz";
            hash = "sha256-AAXeE4ZYYvCLPRT+Alf0EFvK4BWndX9MRG9gm7VESpE=";
          };

          cargoHash = "sha256-mR9WkXC2Z5XNJkw9r5XQONzG6WNItX0kCt5KSF4ORPY=";

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
          version = "0.42.4";

          src = final.fetchFromGitHub {
            owner = "rtk-ai";
            repo = "rtk";
            rev = "v0.42.4";
            hash = "sha256-8nLJ5PVefXmoXQyw6HERfCP06C+l4I+7XLwKFNVNpew=";
          };

          cargoHash = "sha256-YsKOyEZ281ojqiitnvCFGy/MzHMyr4hlxqMnvrQwguQ=";

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
