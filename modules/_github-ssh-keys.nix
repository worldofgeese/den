# Pinned fetch of https://github.com/worldofgeese.keys for human SSH auth.
# Update hash after adding/removing keys on GitHub.
pkgs:
pkgs.fetchurl {
  url = "https://github.com/worldofgeese.keys";
  hash = "sha256-uQwtMFPw2USgq3uOuBFqqvJ4JgkIgkvoA4bmGaf+kUg=";
}
