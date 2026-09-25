{
  # secretspec.age (modules/shared-devtools.nix) is decrypted on this Mac by a
  # post-quantum Secure Enclave age key, through age-plugin-se. The plugin comes
  # from Homebrew, not nixpkgs: nixpkgs builds it with Swift 5, which reports
  # "Post-quantum not supported in this build". Post-quantum
  # (mlkem768p256tag) support needs Swift 6.2 and the macOS 26 SDK, which the
  # Xcode-built bottle has. The secretspec wrapper (modules/overlays.nix)
  # finds it at /opt/homebrew/opt/age-plugin-se/bin.
  den.aspects.M-02877.darwin.homebrew.brews = ["age-plugin-se"];
}
