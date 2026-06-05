{den, ...}: {
  # Pi coding agent — extensions, settings, MCP servers, agent overrides,
  # skills, chains, and activation hooks.
  # Extracted from shared-devtools.nix to keep pi config self-contained.
  den.aspects.pi = {
    includes = [den.aspects.sharedDevtools];
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

      # Pi settings: model routing uses syncPiUserAgentModelOverrides
      # to mirror model overrides into user-scope agent .md frontmatter.
      #
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
          "agent-mail" = {
            command = "${pkgs.mcp-agent-mail}/bin/mcp-agent-mail";
            args = ["serve-stdio"];
            lifecycle = "lazy";
            directTools = true;
            env = {
              WORKTREES_ENABLED = "1";
              AGENT_MAIL_GUARD_MODE = "warn";
            };
          };
          "context-mode" = {
            command = "context-mode";
            lifecycle = "lazy";
            directTools = true;
          };
        };
      };

      # Tier definitions for agent model routing.
      # Agents declare their tier via `tier:` frontmatter field.
      # Agents without a `tier:` field default to "execution".
      home.file.".pi/agent/tier-defs.json".text = lib.mkDefault (let
        tierDefs = {
          orchestrator = {
            model = "github-copilot/gpt-5.5";
            thinking = "high";
          };
          creative = {
            model = "opencode-go/kimi-k2.6";
            thinking = "high";
          };
          execution = {
            model = "cursor/composer-2.5";
            thinking = "medium";
          };
        };
      in
        builtins.toJSON tierDefs);

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

      # Override builtin agents with CE-enhanced versions.
      # User-scope agents with same name shadow builtins at lowest priority.
      home.file.".pi/agent/agents/worker.md".source = ../pi-extensions/agent-overrides/worker.md;
      home.file.".pi/agent/agents/planner.md".source = ../pi-extensions/agent-overrides/planner.md;
      home.file.".pi/agent/agents/oracle.md".source = ../pi-extensions/agent-overrides/oracle.md;
      home.file.".pi/agent/agents/reviewer.md".source = ../pi-extensions/agent-overrides/reviewer.md;
      home.file.".pi/agent/agents/scout.md".source = ../pi-extensions/agent-overrides/scout.md;
      home.file.".pi/agent/agents/researcher.md".source = ../pi-extensions/agent-overrides/researcher.md;
      home.file.".pi/agent/agents/workstream-compounder.md".source =
        ../pi-extensions/agent-overrides/workstream-compounder.md;
      home.file.".pi/agent/skills/plan-implement/SKILL.md".source =
        ../pi-extensions/skills/plan-implement/SKILL.md;

      # Tier-based agent model sync: reads tier-defs.json and each agent's
      # `tier:` frontmatter field to patch model/thinking.
      # Agents without a `tier:` field default to "execution" tier.
      home.activation.syncPiUserAgentModelOverrides = lib.hm.dag.entryAfter ["writeBoundary"] ''
        run ${pkgs.nodejs}/bin/node <<'NODE'
        const fs = require("fs");
        const path = require("path");

        const tierDefsPath = path.join(process.env.HOME, ".pi", "agent", "tier-defs.json");
        const agentsDir = path.join(process.env.HOME, ".pi", "agent", "agents");
        if (!fs.existsSync(tierDefsPath) || !fs.existsSync(agentsDir)) process.exit(0);

        const tierDefs = JSON.parse(fs.readFileSync(tierDefsPath, "utf8"));
        const fields = ["model", "thinking"];
        let updated = 0;

        for (const fileName of fs.readdirSync(agentsDir).filter((name) => name.endsWith(".md"))) {
          const filePath = path.join(agentsDir, fileName);
          try {
            if (fs.lstatSync(filePath).isSymbolicLink()) {
              console.error("syncPiUserAgentModelOverrides: skipping " + fileName + ": is a symlink");
              continue;
            }
            const lines = fs.readFileSync(filePath, "utf8").split(/\n/);
            if (lines[0] !== "---") continue;

            const frontmatterEnd = lines.indexOf("---", 1);
            if (frontmatterEnd < 0) continue;

            let frontmatter = lines.slice(1, frontmatterEnd);
            let body = lines.slice(frontmatterEnd + 1);

            // Discover tier from frontmatter; default to "execution"
            const tierLine = frontmatter.find((line) => line.startsWith("tier:"));
            const tierName = tierLine ? tierLine.slice(5).trim() : "execution";
            const tier = tierDefs[tierName];
            if (!tier || !tier.model) continue;

            const values = {
              model: tier.model,
              thinking: tier.thinking,
            };

            frontmatter = frontmatter.filter((line) => !fields.some((field) => line.startsWith(field + ":")));
            body = body.filter((line) => !fields.some((field) => values[field] && line === field + ": " + values[field]));

            const inserted = [];
            if (values.model) inserted.push("model: " + values.model);
            if (values.thinking) inserted.push("thinking: " + values.thinking);

            const descriptionIndex = frontmatter.findIndex((line) => line.startsWith("description: "));
            if (descriptionIndex >= 0) {
              frontmatter.splice(descriptionIndex + 1, 0, ...inserted);
            } else {
              frontmatter.push(...inserted);
            }

            const next = ["---", ...frontmatter, "---", ...body].join("\n");
            const previous = lines.join("\n");
            if (next !== previous) {
              fs.writeFileSync(filePath, next);
              updated += 1;
            }
          } catch (e) {
            console.error("syncPiUserAgentModelOverrides: skipping " + fileName + ": " + e.message);
          }
        }

        console.log("synced Pi user agent model overrides (tier-based): " + updated);
        NODE
      '';
    };
  };
}
