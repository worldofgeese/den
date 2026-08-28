{
  den,
  lib,
  ...
}: {
  den.default.homeManager.home.stateVersion = lib.mkDefault "25.11";
  # hostname derives networking.hostName from the entity name, so a host cannot
  # be called one thing in modules/hosts.nix and another in its own config.
  # Verified on M-02877 before adopting: hostname, HostName, LocalHostName and
  # ComputerName were already M-02877, so this sets what was already true there.
  den.default.includes = [
    den.batteries.define-user
    den.batteries.hostname
  ];
  den.schema.user.classes = lib.mkDefault ["homeManager"];
}
