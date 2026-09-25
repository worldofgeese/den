{
  # Homebrew reads /etc/homebrew/brew.env on every invocation. That includes
  # the `brew bundle` that nix-darwin activation runs through
  # `sudo --preserve-env=PATH`, which drops any variable exported in the shell.
  # So these can only take effect here, not in home.sessionVariables.
  #   NO_ENV_HINTS: drop the "Hide these hints with ..." lines.
  #   SERVICES_NO_DOMAIN_WARNING: drop "running through sudo, using user/*
  #     instead of gui/* domain", which activation triggers by design.
  den.aspects.M-02877.darwin.environment.etc."homebrew/brew.env".text = ''
    HOMEBREW_NO_ENV_HINTS=1
    HOMEBREW_SERVICES_NO_DOMAIN_WARNING=1
  '';
}
