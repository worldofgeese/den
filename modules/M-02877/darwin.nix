{ den, inputs, ... }:
{
  den.aspects.M-02877 = {
    darwin = { config, lib, pkgs, ... }: {
      nix.enable = true;
      nixpkgs.config.allowUnfree = true;
      nixpkgs.overlays = [
        (final: prev: {
          inherit (prev.lixPackageSets.latest)
            nixpkgs-review
            nix-eval-jobs
            nix-fast-build
            colmena
            ;
          direnv = prev.direnv.overrideAttrs { doCheck = false; };
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
            nativeBuildInputs = [ final.pkg-config ];
            nativeCheckInputs = [ final.git ];
            buildInputs = [ final.sqlite ];
            meta = {
              description = "Decapod CLI — repo-native governance kernel for AI agents";
              homepage = "https://crates.io/crates/decapod";
              mainProgram = "decapod";
            };
          };
        })
      ];

      nix.package = pkgs.lixPackageSets.latest.lix;
      nix.channel.enable = false;
      nix.settings = {
        experimental-features = [ "nix-command" "flakes" "auto-allocate-uids" ];
        extra-platforms = [ ];
        warn-dirty = false;
        auto-optimise-store = true;
        extra-deprecated-features = [ "or-as-identifier" ];
      };

      users.users.dktaohan.home = "/Users/dktaohan";
      system.primaryUser = "dktaohan";

      programs.zsh = {
        enable = true;
        enableCompletion = true;
        enableAutosuggestions = true;
        enableSyntaxHighlighting = true;
        interactiveShellInit = ''
          autoload -Uz compinit && compinit
          eval "$(saml2aws --completion-script-zsh)"
          eval "$(eksctl completion zsh)"
        '';
      };

      security.pam.services.sudo_local.touchIdAuth = true;
      security.pam.services.sudo_local.reattach = true;
      security.sudo.extraConfig = ''
        Defaults env_keep += "HOMEBREW_GITHUB_API_TOKEN"
      '';

      system.stateVersion = 5;
      system.defaults = {
        CustomUserPreferences = {
          "com.apple.desktopservices" = {
            DSDontWriteNetworkStores = true;
            DSDontWriteUSBStores = true;
          };
        };
        screencapture.location = "~/Downloads";
        finder.AppleShowAllFiles = true;
      };

      system.activationScripts.preActivation.text = ''
        if [ -z "''${HOMEBREW_GITHUB_API_TOKEN:-}" ]; then
          if token="$(sudo --user=${lib.escapeShellArg config.homebrew.user} --set-home sh -lc 'cd ${inputs.self} && ${pkgs.secretspec}/bin/secretspec get HOMEBREW_GITHUB_API_TOKEN' 2>/dev/null)"; then
            export HOMEBREW_GITHUB_API_TOKEN="$token"
          elif token="$(sudo --user=${lib.escapeShellArg config.homebrew.user} --set-home ${pkgs.github-cli}/bin/gh auth token 2>/dev/null)"; then
            export HOMEBREW_GITHUB_API_TOKEN="$token"
          fi
        fi
      '';

      homebrew = {
        enable = true;
        global.autoUpdate = true;
        onActivation.autoUpdate = true;
        onActivation.upgrade = true;
        onActivation.cleanup = "zap";
        masApps = {
          "Microsoft To Do" = 1274495053;
          "Flow" = 1423210932;
        };
        brews = [
          "podman"
          "aws-nuke"
          "azure-cli"
          "pulumi"
          "container"
          "jira-cli"
          "atlassian/acli/acli"
          "lego/tap/bob-cli"
          "lego/tap/mdc"
        ];
        casks = [
          "jordanbaird-ice"
          "alt-tab"
          "loop"
          "neardrop"
          "raycast"
          "logseq"
          "notunes"
          "fork"
          "keycastr"
          "devpod"
          "dotnet-sdk"
          "adobe-acrobat-reader"
          "jetbrains-toolbox"
          "background-music"
          "secretive"
          "aerospace"
          "cursor"
          "chatgpt"
          "visual-studio-code"
          "visual-studio-code@insiders"
          "monokle"
          "codex-app"
        ];
        taps = [
          "atlassian/homebrew-acli"
          "grishka/grishka"
          "mrkai77/cask"
          "nikitabobko/tap"
          "pulumi/tap"
          "ankitpokhrel/jira-cli"
          {
            name = "lego/tap";
            clone_target = "git@github.com:LEGO/homebrew-tap.git";
          }
        ];
      };
    };
  };
}
