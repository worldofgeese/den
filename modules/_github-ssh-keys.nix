/*
Human SSH keys authorized on servers: a vendored copy of
https://github.com/worldofgeese.keys.

Vendored, not fetched. A hash-pinned builtins.fetchurl of that mutable URL
broke nixos-upgrade on every server each time a key was added on GitHub, as
soon as the cached download was garbage-collected. A path inside the flake
keeps evaluation independent of GitHub and of each host's store.

After adding or removing keys on GitHub, refresh and commit:
  curl -fsSL https://github.com/worldofgeese.keys -o modules/_worldofgeese.keys
*/
./_worldofgeese.keys
