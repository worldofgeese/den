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
      "LEGO/team-friendship-hour"
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

    # The model gateway key the review harness authenticates with.
    #
    # Interactive claude gets its key from the Secure Enclave via the
    # secretspec apiKeyHelper in ~/.claude/settings.json. That key's access
    # control only permits use while the keybag is unlocked, so every review
    # started while the screen is locked failed ("No matching keys found";
    # ctkd: unable to decapsulate shared key, e00002e2). pr-reviewer therefore
    # has its own gateway virtual key in an owner-only file next to its other
    # runtime state, and its claude is pointed at that file.
    gatewayKeyFile = "${home}/Library/Application Support/pr-reviewer/gateway.key";

    # Store-resident, but holds only the *path* to the key, never the key.
    harnessSettings = pkgs.writeText "pr-reviewer-claude-settings.json" (builtins.toJSON {
      apiKeyHelper = "cat ${lib.escapeShellArg gatewayKeyFile}";
    });

    # pr-reviewer spawns `claude` by bare name and offers no way to add flags,
    # so this shim, first on the agent's PATH, adds them. Environment
    # variables cannot do it: a settings apiKeyHelper outranks
    # ANTHROPIC_API_KEY and ANTHROPIC_AUTH_TOKEN, whereas --settings outranks
    # user settings. Everything else in ~/.claude/settings.json (gateway base
    # URL, model aliases) still applies.
    #
    # The real claude is named by absolute path so the shim cannot find itself.
    claudeShim = pkgs.writeShellScriptBin "claude" ''
      exec /etc/profiles/per-user/dktaohan/bin/claude --settings ${harnessSettings} "$@"
    '';

    # Reconcile the declared repo list, then become the daemon.
    #
    # A failed `add` (network down at login, token lacking access) is logged
    # and skipped rather than fatal: one unreachable repo must not stop
    # reviews on all the others. The next deploy or restart retries it.
    prReviewerLaunchd = pkgs.writeShellApplication {
      name = "pr-reviewer-launchd";
      runtimeInputs = [pr-reviewer pkgs.gawk];
      text = ''
        # Fail loudly: without the key every review would fail at the gateway
        # with an auth error that reads like a gateway outage.
        if [ ! -s ${lib.escapeShellArg gatewayKeyFile} ]; then
          echo "pr-reviewer-launchd: ${gatewayKeyFile} is missing or empty" >&2
          exit 1
        fi

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

    # Merges a PR once pr-reviewer has reviewed its current head. The daemon
    # never approves, so GitHub auto-merge cannot key on its COMMENTED
    # reviews, and a merge made with a workflow's GITHUB_TOKEN would not
    # start the deploys on main. So the merge runs here, as the gh identity.
    # The filter prints number, head SHA and the first reason not to merge;
    # an empty reason means merge, once the review threads are checked too.
    automergeFilter = pkgs.writeText "pr-reviewer-automerge.jq" ''
      ($reviewed
        | map(select(.task_kind == "review_pr" and .status == "completed")
          | "\(.pr_number) \(.head_sha)")) as $done
      | .[]
      | . as $p
      | [$p.labels[]?.name | ascii_downcase] as $labels
      | (if $p.isDraft then "draft"
        elif any($labels[]; . == "hold" or . == "do-not-merge") then "labelled hold or do-not-merge"
        elif ($p.author.login | IN("worldofgeese", "app/github-actions", "app/dependabot") | not)
        then "author \($p.author.login) is merged by hand"
        elif (any($done[]; . == "\($p.number) \($p.headRefOid)") | not)
        then "pr-reviewer has not reviewed head \($p.headRefOid[0:12])"
        elif $p.reviewDecision == "CHANGES_REQUESTED" then "changes requested"
        elif (($p.body // "") | test("before you merge"; "i"))
        then "its description lists manual before-you-merge steps"
        elif (all($p.statusCheckRollup[]?;
            if .__typename == "StatusContext" then .state == "SUCCESS"
            else .status == "COMPLETED" and ((.conclusion // "") | IN("SUCCESS", "SKIPPED", "NEUTRAL"))
            end) | not)
        then "checks are not all complete and green"
        elif $p.mergeable != "MERGEABLE" then "mergeable is \($p.mergeable)"
        else "" end) as $why
      | [($p.number | tostring), $p.headRefOid, $why] | @tsv
    '';

    threadsQuery = pkgs.writeText "pr-reviewer-automerge-threads.graphql" ''
      query($o: String!, $r: String!, $n: Int!) {
        repository(owner: $o, name: $r) {
          pullRequest(number: $n) { reviewThreads(first: 100) { nodes { isResolved } } }
        }
      }
    '';

    # One pass over the declared repos; launchd starts it every 120 s and
    # never runs two at once. A gh error is logged and the next PR goes on.
    # A failed merge is remembered per head SHA and not retried until a new
    # push. A skip is logged when its reason changes, not on every pass.
    # PR_AUTOMERGE_DRY_RUN=1 logs "would merge" instead of merging.
    prReviewerAutomerge = pkgs.writeShellApplication {
      name = "pr-reviewer-automerge";
      runtimeInputs = [pr-reviewer pkgs.gh pkgs.jq pkgs.coreutils];
      text = ''
        # stderr, so a log line inside $(...) still reaches the log file.
        log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
        brief() { head -c 300 <<<"$1" | tr '\n' ' '; }
        state=${lib.escapeShellArg "${home}/.local/state/pr-reviewer-automerge"}
        mkdir -p "$state"
        # Off any checkout, so --delete-branch only deletes the remote branch.
        cd /

        # The merge method a repo allows, read once per pass and only when a
        # PR there is ready: merge commits where allowed, else squash, else
        # rebase. LEGO/agentic-engineering-community always squashes.
        merge_method() {
          local allowed m s r
          if [ "$1" = LEGO/agentic-engineering-community ]; then
            echo --squash
            return
          fi
          if ! allowed="$(gh api "repos/$1" --jq '[.allow_merge_commit, .allow_squash_merge, .allow_rebase_merge] | @tsv' 2>&1)"; then
            log "$1: could not read its merge settings: $(brief "$allowed")"
            echo none
            return
          fi
          read -r m s r <<<"$allowed"
          if [ "$m" = true ]; then
            echo --merge
          elif [ "$s" = true ]; then
            echo --squash
          elif [ "$r" = true ]; then
            echo --rebase
          else
            log "$1: allows no merge method"
            echo none
          fi
        }

        for repo in ${lib.escapeShellArgs repos}; do
          key="''${repo//\//_}"
          method=""
          if ! prs="$(gh pr list -R "$repo" --state open --limit 100 \
              --json number,headRefOid,isDraft,author,labels,mergeable,statusCheckRollup,reviewDecision,body 2>&1)"; then
            log "$repo: gh pr list failed: $(brief "$prs")"
            continue
          fi
          if ! reviewed="$(pr-reviewer queue list --repo "$repo" --status completed --limit 200 --json 2>&1)"; then
            log "$repo: pr-reviewer queue list failed: $(brief "$reviewed")"
            continue
          fi
          if ! verdicts="$(jq -r --argjson reviewed "$reviewed" -f ${automergeFilter} <<<"$prs" 2>&1)"; then
            log "$repo: could not evaluate its PRs: $(brief "$verdicts")"
            continue
          fi

          while IFS=$'\t' read -r n sha why; do
            [ -n "$n" ] || continue
            if [ -z "$why" ]; then
              if ! threads="$(gh api graphql -F n="$n" -f o="''${repo%%/*}" -f r="''${repo#*/}" \
                  -F query=@${threadsQuery} \
                  --jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved | not)] | length' 2>&1)"; then
                why="could not read its review threads: $(brief "$threads")"
              elif [ "$threads" != 0 ]; then
                why="$threads unresolved review thread(s)"
              elif [ -e "$state/failed-$key-$n-$sha" ]; then
                why="a merge already failed at this head; waiting for a new push"
              fi
            fi

            if [ -n "$why" ]; then
              if [ "$(cat "$state/last-$key-$n" 2>/dev/null || true)" != "$sha $why" ]; then
                log "$repo#$n: skip: $why"
                printf '%s\n' "$sha $why" >"$state/last-$key-$n"
              fi
              continue
            fi

            if [ -z "$method" ]; then
              method="$(merge_method "$repo")"
            fi
            if [ "$method" = none ]; then
              continue
            fi
            if [ -n "''${PR_AUTOMERGE_DRY_RUN:-}" ]; then
              log "$repo#$n: would merge $sha ($method)"
              continue
            fi
            if out="$(gh pr merge "$n" -R "$repo" --match-head-commit "$sha" --delete-branch "$method" 2>&1)"; then
              log "$repo#$n: merged $sha ($method)"
              rm -f "$state/last-$key-$n"
            else
              log "$repo#$n: merge failed at $sha: $(brief "$out")"
              : >"$state/failed-$key-$n-$sha"
            fi
          done <<<"$verdicts"
        done
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
    #   - the claude shim above, ahead of everything else;
    #   - /etc/profiles/per-user/dktaohan/bin: the real claude, npx/node
    #     (gitnexus code index), git and gh;
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
          (lib.makeBinPath [claudeShim pkgs.git])
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

    # Merges what pr-reviewer has reviewed; see prReviewerAutomerge above.
    launchd.user.agents.pr-reviewer-automerge.serviceConfig = {
      Label = "com.dktaohan.pr-reviewer-automerge";
      ProgramArguments = ["${prReviewerAutomerge}/bin/pr-reviewer-automerge"];
      EnvironmentVariables = {
        HOME = home;
        USER = "dktaohan";
        PATH = lib.concatStringsSep ":" ["/etc/profiles/per-user/dktaohan/bin" "/usr/bin" "/bin" "/usr/sbin" "/sbin"];
      };
      RunAtLoad = true;
      StartInterval = 120;
      ProcessType = "Background";
      StandardOutPath = "${home}/Library/Logs/pr-reviewer-automerge.log";
      StandardErrorPath = "${home}/Library/Logs/pr-reviewer-automerge.log";
    };
  };
}
