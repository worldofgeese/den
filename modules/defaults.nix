{
  den,
  lib,
  ...
}: {
  den.default.homeManager.home.stateVersion = lib.mkDefault "25.11";
  den.default.includes = [den.batteries.define-user];
  den.schema.user.classes = lib.mkDefault ["homeManager"];

  den.aspects.paphos.includes = [
    den.aspects.server
  ];
}
