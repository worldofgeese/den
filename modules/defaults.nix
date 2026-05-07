{ den, ... }:
{
  den.default = {
    homeManager.home.stateVersion = "22.11";
    includes = [ den._.define-user ];
  };
}
