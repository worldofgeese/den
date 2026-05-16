{ den, ... }:
{
  # Shared developer tooling aspect — packages and programs used on both
  # mahakala (Linux workstation) and M-02877 (macOS work machine).
  # Host-specific additions go in workstation.nix or dktaohan.nix.
  den.aspects.sharedDevtools = {
    includes = [ den.aspects.devtools ];
    homeManager = { pkgs, lib, ... }: {
      home.packages = with pkgs; [
        nodejs
        bun
        uv
        kubectl
        shellcheck
        yq-go
        glab
        just
        claude-code
        pi-coding-agent
        decapod
      ];

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

      programs.k9s.enable = true;

      # Pi extension: custom provider for Anthropic proxy with full
      # streaming implementation (supports reasoning/thinking blocks)
      home.file.".pi/agent/extensions/anthropic-proxy/index.js".text =
        builtins.readFile ../pi-extensions/anthropic-proxy/index.js;
      home.file.".pi/agent/extensions/anthropic-proxy/package.json".text =
        builtins.readFile ../pi-extensions/anthropic-proxy/package.json;
      home.file.".pi/agent/extensions/anthropic-proxy/models.json".text = builtins.toJSON [
        {
          id = "anthropic.claude-opus-4-6-v1";
          name = "Opus 4.6";
          reasoning = true;
          input = [ "text" "image" ];
          cost = { input = 15; output = 75; cacheRead = 1.5; cacheWrite = 18.75; };
          contextWindow = 200000;
          maxTokens = 128000;
        }
        {
          id = "anthropic.claude-sonnet-4-6";
          name = "Sonnet 4.6";
          reasoning = true;
          input = [ "text" "image" ];
          cost = { input = 3; output = 15; cacheRead = 0.3; cacheWrite = 3.75; };
          contextWindow = 200000;
          maxTokens = 128000;
        }
        {
          id = "anthropic.claude-haiku-4-5-20251001-v1:0";
          name = "Haiku 4.5";
          reasoning = false;
          input = [ "text" "image" ];
          cost = { input = 0.8; output = 4; cacheRead = 0.08; cacheWrite = 1; };
          contextWindow = 200000;
          maxTokens = 64000;
        }
      ];

      # Pi settings: default to the proxy provider with Opus
      home.file.".pi/agent/settings.json".text = builtins.toJSON {
        provider = "anthropic-proxy";
        model = "anthropic.claude-opus-4-6-v1";
      };
    };
  };
}
