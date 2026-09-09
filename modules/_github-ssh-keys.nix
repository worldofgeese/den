# Pinned fetch of https://github.com/worldofgeese.keys for human SSH auth.
# Update hash after adding/removing keys on GitHub.
pkgs:
/*
builtins.fetchurl is system-independent, unlike pkgs.fetchurl. This file
is consumed while evaluating cross-system configurations.
*/
builtins.fetchurl {
  url = "https://github.com/worldofgeese.keys";
  sha256 = "0515dw3bygk240b0bhwa7kjha0fdmy4gbf5kx4spbm7jl2qw7j9w";
}
