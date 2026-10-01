{
  # pr-reviewer: a self-hosted daemon that polls GitHub and reviews PRs with
  # the local claude CLI. It used to be `cargo install`ed from a /tmp checkout
  # and started by hand, so it silently stopped whenever the terminal or the
  # login session that started it went away -- and nothing recorded which
  # repositories it was meant to cover.
  #
  # Ownership is split on purpose:
  #   - this file owns the binary, how it starts, and *which repos* it covers;
  #   - ~/Library/Application Support/pr-reviewer owns the mutable runtime
  #     state: config.toml (with the machine-bound encrypted GitHub token),
  #     keyfile, state.db and the managed clones. That holds a credential, so
  #     it is never written from Nix (every string here lands world-readable
  #     in /nix/store).
  den.aspects.M-02877.darwin = {
    config,
    lib,
    pkgs,
    ...
  }: let
    home = config.users.users.dktaohan.home;

    # The repositories the daemon must cover. Adding one here is the whole
    # procedure: the agent's start wrapper registers any missing entry with
    # `pr-reviewer add` (which clones it as a managed repo) before the daemon
    # starts, and the changed wrapper changes the plist, so deploy reloads it.
    #
    # Add-only by design: a configured repo that is *not* listed here is
    # reported in the log but left alone, because `remove` discards its
    # per-repo settings (auto_fix and so on) and that should be a human act.
    repos = [
      "LEGO/conference-dashboard"
      "LEGO/devrel-infra"
      "LEGO/agentic-engineering-community"
      "LEGO/ai-daily-assistant"
    ];

    # Upstream ships no flake, no tags, and is absent from nixpkgs, so this is
    # a buildRustPackage against a pinned revision; `version` tracks Cargo.toml.
    #
    # Tests are skipped: the suite binds loopback sockets, which the Nix
    # sandbox refuses, and it shells out to git.
    pr-reviewer = pkgs.rustPlatform.buildRustPackage {
      pname = "pr-reviewer";
      version = "0.1.0-unstable-2026-05-01";

      src = pkgs.fetchFromGitHub {
        owner = "NicholaiVogel";
        repo = "pr-reviewer";
        rev = "4d27724c09bc242444a6946bf9f39b85819689a3";
        hash = "sha256-Z6z3UovEM0Eqs8Di9Am4+oTtWIEdbU3tSP8Yudf40Mk=";
      };

      # Upstream sends the token to git as `Authorization: Bearer`, which
      # GitHub's git smart-HTTP endpoint rejects for PATs and OAuth tokens
      # ("remote: invalid credentials"). So `pr-reviewer add owner/repo` could
      # never clone anything, and every managed clone so far was made by hand
      # over SSH. The patch sends HTTP Basic with the token as the password,
      # for both clone and the authenticated fetch/push helper.
      patches = [./pr-reviewer-git-basic-auth.patch];

      cargoHash = "sha256-XpFZLDgppAkIPmj95ihi5hkd+k5pgnKDa3c74xUJBuQ=";
      doCheck = false;

      meta = {
        description = "Self-hosted PR review daemon that drives local AI CLI tools";
        homepage = "https://github.com/NicholaiVogel/pr-reviewer";
        mainProgram = "pr-reviewer";
        platforms = lib.platforms.unix;
      };
    };

    # Reconcile the declared repo list, then become the daemon.
    #
    # A failed `add` (network down at login, token lacking access) is logged
    # and skipped rather than fatal: one unreachable repo must not stop
    # reviews on all the others. The next deploy or restart retries it.
    prReviewerLaunchd = pkgs.writeShellApplication {
      name = "pr-reviewer-launchd";
      runtimeInputs = [pr-reviewer pkgs.gawk];
      text = ''
        declared=(${lib.escapeShellArgs repos})
        configured="$(pr-reviewer list | awk '{print $1}')"

        for repo in "''${declared[@]}"; do
          if ! grep -qxF "$repo" <<<"$configured"; then
            echo "pr-reviewer-launchd: registering $repo" >&2
            pr-reviewer add "$repo" \
              || echo "pr-reviewer-launchd: could not add $repo; continuing without it" >&2
          fi
        done

        while IFS= read -r repo; do
          [ -n "$repo" ] || continue
          printf '%s\n' "''${declared[@]}" | grep -qxF "$repo" \
            || echo "pr-reviewer-launchd: $repo is configured but not declared in modules/M-02877/pr-reviewer.nix" >&2
        done <<<"$configured"

        exec pr-reviewer start
      '';
    };
  in {
    # The CLI on PATH is the same build the agent runs, so `pr-reviewer
    # status`/`queue`/`logs` talk about the daemon that is actually running.
    environment.systemPackages = [pr-reviewer];

    # `start`, not `start --daemon`: --daemon forks and detaches, so launchd
    # would see its child exit at once and, with KeepAlive, keep relaunching
    # while orphaned daemons piled up. launchd owns the process lifetime.
    #
    # The pidfile is *not* a lock -- `start` overwrites it unconditionally --
    # so a second, hand-started instance would run alongside this one and
    # review every PR twice. Do not `pr-reviewer start` by hand.
    # `pr-reviewer stop` exits cleanly, which SuccessfulExit = false leaves
    # stopped until the next login or `launchctl kickstart`.
    #
    # PATH is explicit because a LaunchAgent inherits almost nothing:
    #   - /etc/profiles/per-user/dktaohan/bin: claude (the review harness),
    #     npx/node (gitnexus code index), git and gh;
    #   - /usr/sbin: ioreg, from which the daemon derives the machine identity
    #     that decrypts its token. Without it every start fails with "failed
    #     to run ioreg: No such file or directory" -- which never reproduces in
    #     an interactive shell, where /usr/sbin is always present.
    launchd.user.agents.pr-reviewer.serviceConfig = {
      Label = "com.dktaohan.pr-reviewer";
      ProgramArguments = ["${prReviewerLaunchd}/bin/pr-reviewer-launchd"];
      EnvironmentVariables = {
        HOME = home;
        USER = "dktaohan";
        PATH = lib.concatStringsSep ":" [
          (lib.makeBinPath [pkgs.git])
          "/etc/profiles/per-user/dktaohan/bin"
          "/usr/bin"
          "/bin"
          "/usr/sbin"
          "/sbin"
        ];
      };
      RunAtLoad = true;
      KeepAlive = {SuccessfulExit = false;};
      ProcessType = "Background";
      ThrottleInterval = 30;
      StandardOutPath = "${home}/Library/Logs/pr-reviewer.log";
      StandardErrorPath = "${home}/Library/Logs/pr-reviewer.log";
    };
  };
}
