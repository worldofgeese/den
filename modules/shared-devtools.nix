{
  den,
  inputs,
  ...
}: {
  # Shared developer tooling aspect — packages and programs used on both
  # mahakala (Linux workstation) and M-02877 (macOS work machine). Which entities
  # receive it is declared in modules/hosts.nix: worldofgeese takes it through
  # den.aspects.workstation, dktaohan names it directly. Host-specific additions
  # go in workstation.nix or M-02877/dktaohan.nix.
  den.aspects.sharedDevtools = {
    includes = [den.aspects.devtools];
    homeManager = {
      pkgs,
      lib,
      ...
    }: let
      agents = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system};
    in {
      home.packages = with pkgs;
        [
          nodejs
          bun
          kubectl
          shellcheck
          yq-go
          glab
          just
          bash-preexec
          agents.omp
          agents.claude-code
          agents.claude-agent-acp
          agents.copilot-cli
          # Secret lookups for both hosts, declared in secretspec.toml. Shared so
          # mahakala and M-02877 resolve gateway/API credentials the same way
          # rather than mahakala falling back to gopass for the same secret.
          secretspec
          # Pushes to the worldofgeese binary cache via `just cachix-push`.
          cachix
          herdr
          # ACP agents query current NixOS, Home Manager, and nix-darwin data.
          mcp-nixos
          mcp-agent-mail
          # Governance kernel, used on every host. Was Darwin-excluded and
          # installed there by `cargo install decapod` in an activation hook,
          # which failed silently and left the version unpinned.
          decapod
        ]
        ++ lib.optionals (!pkgs.stdenv.hostPlatform.isDarwin) [
          rtk
        ];

      # uv, plus the tools it manages. Declarative replacement for
      # `uv tool install`: entries are installed and upgraded on activation.
      #
      # crucible-llm is not on PyPI in a usable state (PyPI 0.1.0 is stale), so
      # it is installed from git. The `name @ git+url` form is required rather
      # than a bare `git+...` URL for two reasons: `uv tool upgrade` rejects a
      # bare URL ("URL requirement must be preceded by a package name"), and
      # `tool.prune` derives the keep-list by regex from the leading name, which
      # for a bare URL yields "git" and would uninstall the tool on every
      # activation.
      programs.uv = {
        enable = true;

        # uv's own CPython builds come from python-build-standalone, which are
        # FHS binaries requesting /lib64/ld-linux-x86-64.so.2. Guix System has
        # no /lib64, so they cannot execute at all:
        #   $ ~/.local/share/uv/python/cpython-3.14.6-*/bin/python3.14 --version
        #   cannot execute: required file not found
        # uv reports that as "Python interpreter not found", which is misleading
        # since the file is present; the missing piece is the loader. When uv had
        # pinned a tool to one of those, `uv tool upgrade` failed and took the
        # whole activation with it.
        #
        # only-system keeps uv off those downloads, but it does not by itself
        # give uv something to run: activation uses a fixed PATH of Nix store
        # paths, so neither ~/.guix-home/profile/bin nor home.packages is
        # visible and uv fails with "No interpreter found in search path".
        # home.extraActivationPath below puts python3 on that PATH; uv resolves
        # an interpreter by searching PATH, so UV_PYTHON with an absolute path
        # does not work here (uv treats it as a version request and resolves it
        # back to the unusable managed install).
        settings.python-preference = "only-system";

        tool = {
          packages = [
            "crucible-llm @ git+https://github.com/jkitchin/crucible"
          ];
          prune = true;
        };
      };

      # uv resolves its interpreter from PATH during activation, and activation
      # does not inherit the login PATH. See programs.uv above. git is needed for
      # the same reason: uv shells out to it for `git+` tool requirements and
      # otherwise fails with "Git executable not found".
      #
      # python313, not python3: crucible-llm depends on libsql, whose newest
      # release (0.1.11) ships macOS arm64 wheels only up to cp313. On 3.14 uv
      # falls back to building it from source, which needs a Rust toolchain and a
      # linker that the store-only activation PATH does not have. Bump this when
      # libsql publishes a cp314 wheel.
      home.extraActivationPath = [pkgs.python313 pkgs.git];

      # `uv tool install` warns "`~/.local/bin` is not on your PATH" on every
      # activation. The directory is on the *login* PATH via home.sessionPath;
      # it is only missing from the store-only activation PATH described above,
      # so the warning is noise. Prepending it here silences it. Activation
      # entries share one bash process, so this export also reaches later
      # entries -- harmless, since the login shell has the same directory.
      home.activation.uvToolBinOnPath = lib.hm.dag.entryBefore ["uvTool"] ''
        export PATH="$HOME/.local/bin:$PATH"
      '';

      programs.direnv = {
        enable = true;
        nix-direnv.enable = true;
      };

      programs.eza.enable = true;
      programs.bat.enable = true;
      programs.zoxide.enable = true;
      programs.jq.enable = true;

      programs.atuin = {
        enable = true;
        settings = {
          auto_sync = lib.mkDefault true;
          sync_frequency = "5m";
          search_mode = "fuzzy";
        };
      };

      # Guix Home owns ~/.bashrc on mahakala, so Home Manager cannot inject
      # Bash init snippets directly. Export one sourceable fragment instead.
      # bash-preexec must load before Atuin/Starship; zoxide stays last.
      home.file.".config/bash/home-manager-integrations.bash".text = ''
        # Generated by Home Manager. Sourced from Guix Home's ~/.bashrc.
        # shellcheck shell=bash
        [[ $- == *i* ]] || return

        if command -v direnv >/dev/null 2>&1; then
          eval "$(direnv hook bash)"
        fi

        _hm_bash_preexec="${pkgs.bash-preexec}/share/bash/bash-preexec.sh"
        # shellcheck source=/dev/null
        [[ -r "$_hm_bash_preexec" ]] && source "$_hm_bash_preexec"
        unset _hm_bash_preexec

        if command -v atuin >/dev/null 2>&1; then
          eval "$(atuin init bash)"
        fi

        if command -v starship >/dev/null 2>&1; then
          eval "$(starship init bash)"
        fi

        if command -v fzf >/dev/null 2>&1; then
          eval "$(fzf --bash)"
        fi

        # Host-specific additions live in their own file so this one stays
        # shared. modules/workstation.nix writes openclaw.bash, which only
        # mahakala gets.
        for extra in "$HOME"/.config/bash/extras.d/*.bash; do
          [[ -r "$extra" ]] && source "$extra"
        done
        unset extra

        if command -v zoxide >/dev/null 2>&1; then
          eval "$(zoxide init bash)"
        fi
      '';
    };
  };
}
