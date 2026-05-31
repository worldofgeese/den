{den, ...}: {
  # Common git settings shared across all hosts.
  # Each host adds identity-specific config (user.name, user.email, signing).
  den.aspects.gitcommon.homeManager = {
    programs.git = {
      enable = true;
      ignores = [".direnv" "result"];
      settings = {
        init.defaultBranch = "main";
        push.autoSetupRemote = true;
        pull.rebase = true;
        rebase.autosquash = true;
        rebase.autostash = true;
        fetch.prune = true;
        diff.colorMoved = "zebra";
      };
    };
  };
}
