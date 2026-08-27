{...}: {
  # paphos's only user. Was a stowaway at the bottom of system.nix, after ~48
  # lines of unrelated boot and sudo config; dktaohan and worldofgeese each get a
  # file, so this one does too. Its include edge lives in modules/hosts.nix.
  den.aspects.kypris.homeManager = {...}: {
    home.username = "kypris";
    home.homeDirectory = "/home/kypris";
    home.stateVersion = "25.11";
    programs.home-manager.enable = true;
  };
}
