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
    # agentProviders points the CLI agents installed below at the model
    # gateway. Included here rather than named per entity because every host
    # that gets the agents needs them wired.
    includes = [den.aspects.devtools den.aspects.agentProviders];
    homeManager = {
      pkgs,
      lib,
      config,
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
          agents.pi
          # claude-code comes from den.aspects.agentProviders instead: it ships
          # a --settings-wrapped bin/claude, and two derivations providing that
          # path collide in one profile.
          agents.claude-agent-acp
          agents.copilot-cli
          agents.codex
          # Secret lookups for both hosts, declared in secretspec.toml. Shared so
          # mahakala and M-02877 resolve gateway/API credentials the same way
          # rather than mahakala falling back to gopass for the same secret.
          secretspec
          # age-keygen and age-plugin-pq, for `just secretspec-se-setup` and for
          # inspecting secretspec.age by hand.
          age
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
          # Darwin gets the Homebrew-managed bd from /opt/homebrew/bin.
          beads
          dolt
          rtk
        ];

      # Tool-agnostic user MCP config. pi reads it through pi-mcp-adapter (pi has
      # no MCP client of its own). directTools lists mcp-nixos's tools next to
      # read/bash rather than behind the adapter's search proxy, so agents look
      # up packages and options instead of running slow `nix eval`s.
      xdg.configFile."mcp/mcp.json".text = builtins.toJSON {
        mcpServers.nixos = {
          command = "${pkgs.mcp-nixos}/bin/mcp-nixos";
          args = [];
          directTools = true;
        };
      };

      # secretspec.toml routes every secret through the `personal` alias. Each
      # host defines that alias here, in its user-global secretspec config.
      #
      # On Darwin the secrets live in one age file committed next to
      # secretspec.toml (secretspec.age). It is encrypted to the recipients in
      # secretspec.age.recipients, and both of them are post-quantum because the
      # repo is public:
      #   - this Mac's Secure Enclave key (mlkem768p256tag, age-plugin-se). Its
      #     identity file holds only a handle that is useless on any other
      #     machine, and it is generated with access control `none`. Decryption
      #     therefore raises no dialog at all and never touches the Keychain. A
      #     Keychain read was a dialog on every secretspec rebuild, because macOS
      #     trusts an item only for the exact cdhash of the build that owns it
      #     (cachix/secretspec#438).
      #   - a software backup key (mlkem768x25519), kept only in a password
      #     manager, for a new or rebuilt Mac.
      # The trade: nothing prompts, so any process running as this user can
      # decrypt while it runs here, but it cannot take the key off the machine.
      # `just secretspec-se-setup` creates the key and re-encrypts the file.
      # Linux hosts keep the keyring.
      #
      # force: the file used to be hand-written by `secretspec config init`.
      xdg.configFile."secretspec/config.toml" = {
        force = true;
        source = (pkgs.formats.toml {}).generate "secretspec-config.toml" {
          defaults = {
            provider = "keyring";
            profile = "default";
            providers.personal =
              if pkgs.stdenv.hostPlatform.isDarwin
              then {
                # recipients-file resolves against the project root.
                uri = "age://secretspec.age?identity=${config.xdg.configHome}/secretspec/se-identity.txt&recipients-file=secretspec.age.recipients";
              }
              else "keyring://";
          };
        };
      };

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

        # brush (reubeno/brush) compatibility shim -- MUST precede atuin init.
        #
        # atuin's bash init defines atuin-bind(), which infers the readline
        # keymap when -m is not passed:
        #
        #   [[ $keymap ]] || keymap=$(bind -v | awk '$2 == "keymap" { print $3 }')
        #   case $keymap in emacs*) ... ;; vi*) ... ;;
        #     *) error "unknown keymap $keymap" ;;
        #
        # brush 0.4.0 implements `bind` but its `bind -v` prints NOTHING (verified:
        # `bind -v | grep -c keymap` -> 0, where bash emits "set keymap emacs").
        # So $keymap is empty, the case falls through to *), and every interactive
        # brush start prints:
        #     atuin-bind: unknown keymap <empty>
        # and atuin's keybindings (Ctrl-R, Up) are never installed -- the visible
        # symptom being "atuin isn't wired in".
        #
        # brush documents `bind` as supported with "advanced bind features -- in
        # progress", so this is an upstream gap, not a misconfiguration. Reporting
        # emacs is correct here: brush's line editor (reedline) is emacs-style by
        # default, and nothing in this config sets `set -o vi`.
        #
        # Guarded so bash is completely unaffected: BRUSH_VERSION is set by brush
        # only. Under bash the shim never defines the function, so real readline
        # keymap detection is preserved.
        if [[ -n "$BRUSH_VERSION" ]]; then
          bind() {
            if [[ $1 == -v ]]; then
              printf 'set keymap emacs\n'
              return 0
            fi
            # Swallow failures for bind forms brush has not implemented yet, so a
            # single unsupported keyseq cannot abort the rest of shell init.
            builtin bind "$@" 2>/dev/null || return 0
          }
        fi

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
