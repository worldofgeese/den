{ den, ... }:
{
  den.default = {
    homeManager = { lib, ... }: {
      home.stateVersion = lib.mkDefault "22.11";
    };
    includes = [ den._.define-user ];
  };

  den.aspects.paphos.includes = [
    den.aspects.server
  ];
}
