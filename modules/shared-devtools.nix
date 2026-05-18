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
    };
  };
}
