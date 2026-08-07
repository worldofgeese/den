{den, ...}: {
  # Pi coding agent — extensions, settings, MCP servers, and skills.
  # Extracted from shared-devtools.nix to keep pi config self-contained.
  # Agent overrides and tier routing are modules/pi-tiers.nix's.
  den.aspects.pi = {
    includes = [
      den.aspects.sharedDevtools
      # Tier routing lives in its own module because it has two callers with
      # different tables. This aspect only opts in; the routing policy is
      # declared per profile as `pi.tiers.tiers`.
      den.aspects.piTiers
    ];
    homeManager = {
      pkgs,
      lib,
      ...
    }: let
      piPackages = import ../pi-packages.nix;
    in {
      # pi-acp: ACP adapter for agent-shell integration in Emacs
      home.packages = [
        (pkgs.writeShellScriptBin "pi-acp" ''
          exec ${pkgs.nodejs}/bin/npx --yes pi-acp "$@"
        '')
        # Caveman Code is forked from an older pi and never emits the
        # `agent_settled` event that pi-acp >= 0.0.33 requires to resolve an
        # ACP turn, so agent-shell stays busy forever after the first reply
        # and cancel cannot free it either. 0.0.32 resolves on `agent_end`,
        # which Caveman does emit. Upstream pi does emit `agent_settled` and
        # wants the newer adapter, so this is a second pinned wrapper rather
        # than a downgrade of `pi-acp` above.
        (pkgs.writeShellScriptBin "pi-acp-caveman" ''
          exec ${pkgs.nodejs}/bin/npx --yes pi-acp@0.0.32 "$@"
        '')
      ];

      # Pi extension: beads-rust — br CLI integration for task tracking,
      # slash commands, status bar, context injection, compaction preservation.
      # Replaces npm:pi-beads-extension (Python bd CLI).
      home.file.".pi/agent/extensions/beads-rust/index.ts".text =
        builtins.readFile ../pi-extensions/beads-rust/index.ts;

      # Pi extension: governance hooks — deterministic enforcement of
      # AGENTS.md rules (orchestrator edit gate, decapod auto-init,
      # beads enforcement via shared state, git-add guard, unpushed commits)
      home.file.".pi/agent/extensions/governance/index.ts".text =
        builtins.readFile ../pi-extensions/governance/index.ts;

      # Note: pi itself is provided by the Nix `pi` package (numtide/llm-agents.nix).
      # Do NOT list `@earendil-works/pi-coding-agent` or `@earendil-works/pi-ai`
      # under `packages` here — `pi update` would install their @latest into
      # ~/.pi/agent/npm and that drags in a pi-coding-agent version that breaks
      # other extensions' peerDependencies (e.g. pi-rtk-optimizer 0.8.1 pins
      # ^0.74 || ^0.75, while npm latest is 0.76.x). Pi version is managed by
      # `just deploy-mahakala-hm` via the llm-agents.nix flake input instead.
      home.file.".pi/agent/mcp.json".text = builtins.toJSON {
        settings = {
          toolPrefix = "server";
          idleTimeout = 10;
        };
        mcpServers = {
          # "agent-mail" disabled: fastmcp test flake
          # "agent-mail" = {
          #   command = "${pkgs.mcp-agent-mail}/bin/mcp-agent-mail";
          #   args = ["serve-stdio"];
          #   lifecycle = "lazy";
          #   directTools = true;
          #   env = {
          #     WORKTREES_ENABLED = "1";
          #     AGENT_MAIL_GUARD_MODE = "warn";
          #   };
          # };
          "context-mode" = {
            command = "context-mode";
            lifecycle = "lazy";
            directTools = true;
          };
        };
      };

      home.file.".pi/agent/settings.json".text = lib.mkDefault (builtins.toJSON {
        provider = "github-copilot";
        model = "gpt-5.5";
        defaultThinkingLevel = "high";
        compaction = {
          enabled = true;
        };
        observational-memory = {
          observeAfterTokens = 10000;
          reflectAfterTokens = 20000;
          compactAfterTokens = 81000;
        };
        packages = piPackages;
      });

      # The CE-enhanced agent overrides that shadow pi's builtins are written by
      # modules/pi-tiers.nix, which has to patch their frontmatter anyway and so
      # is the only thing that can own their content.
      home.file.".pi/agent/skills/plan-implement/SKILL.md".source =
        ../pi-extensions/skills/plan-implement/SKILL.md;
    };
  };
}
