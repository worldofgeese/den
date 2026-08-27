# Pinned fetch of https://github.com/worldofgeese.keys for human SSH auth.
# Update hash after adding/removing keys on GitHub.
pkgs:
/*
builtins.fetchurl is system-independent, unlike pkgs.fetchurl. This file
is consumed while evaluating cross-system configurations.
*/
builtins.fetchurl {
  url = "https://github.com/worldofgeese.keys";
  sha256 = "1v3kxh74bbyblv1lg1bljaic1zv9qliqkwiz5r6rrvlj5vinqad7";
}
