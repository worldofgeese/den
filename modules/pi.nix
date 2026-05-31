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
    }: {
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

      # Pi extension: custom provider for Anthropic proxy with full
      # streaming implementation (supports reasoning/thinking blocks)
      home.file.".pi/agent/extensions/anthropic-proxy/index.js".text =
        builtins.readFile ../pi-extensions/anthropic-proxy/index.js;
      home.file.".pi/agent/extensions/anthropic-proxy/message-conversion.js".text =
        builtins.readFile ../pi-extensions/anthropic-proxy/message-conversion.js;
      home.file.".pi/agent/extensions/anthropic-proxy/message-conversion.test.js".text =
        builtins.readFile ../pi-extensions/anthropic-proxy/message-conversion.test.js;
      home.file.".pi/agent/extensions/anthropic-proxy/package.json".text =
        builtins.readFile ../pi-extensions/anthropic-proxy/package.json;
      home.file.".pi/agent/extensions/anthropic-proxy/models.json".text = builtins.toJSON [
        {
          id = "anthropic.claude-opus-4-6-v1";
          name = "Opus 4.6";
          reasoning = true;
          input = [
            "text"
            "image"
          ];
          cost = {
            input = 15;
            output = 75;
            cacheRead = 1.5;
            cacheWrite = 18.75;
          };
          contextWindow = 200000;
          maxTokens = 128000;
        }
        {
          id = "anthropic.claude-sonnet-4-6";
          name = "Sonnet 4.6";
          reasoning = true;
          input = [
            "text"
            "image"
          ];
          cost = {
            input = 3;
            output = 15;
            cacheRead = 0.3;
            cacheWrite = 3.75;
          };
          contextWindow = 200000;
          maxTokens = 128000;
        }
        {
          id = "anthropic.claude-haiku-4-5-20251001-v1:0";
          name = "Haiku 4.5";
          reasoning = false;
          input = [
            "text"
            "image"
          ];
          cost = {
            input = 0.8;
            output = 4;
            cacheRead = 0.08;
            cacheWrite = 1;
          };
          contextWindow = 200000;
          maxTokens = 64000;
        }
      ];

      # Pi settings: parent session uses GitHub Copilot GPT-5.5 while
      # OpenCode Go quota is exhausted. Subagent model routing uses
      # pi-subagents native agentOverrides:
      #   GPT-5.5          → planner/spec/implementation-plan taskmaster
      #   Cursor Composer 2.5 → all implementation/audit/recon subagents
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

      home.file.".pi/agent/settings.json".text = builtins.toJSON {
        provider = "github-copilot";
        model = "gpt-5.5";
        defaultThinkingLevel = "high";
        compaction = {
          enabled = false;
        };
        packages = [
          "npm:context-mode"
          "npm:pi-opencode-bridge"
          "npm:pi-subagents"
          "npm:pi-cursor-sdk"
          "npm:pi-mcp-adapter"
          "npm:pi-intercom"
          "npm:pi-web-access"
          "npm:pi-caveman"
          "npm:pi-rtk-optimizer"
          "npm:@feniix/pi-specdocs"
          "npm:pi-ask-user"
          "npm:pi-agenticoding"
          "npm:pi-paster"
          "git:github.com/dheerapat/pi-kb"
        ];
        subagents = {
          agentOverrides = let
            gpt55 = "github-copilot/gpt-5.5";
            composer = "cursor/composer-2.5";

            mkOverride = model: thinking: fallbackModels: {
              inherit model thinking fallbackModels;
            };
            mkOverrides = names: value: builtins.listToAttrs (builtins.map (name: {inherit name value;}) names);

            planOverride = mkOverride gpt55 "high" [composer];
            composerOverride = mkOverride composer "medium" [gpt55];
          in
            (mkOverrides [
                # Builtins: decision consistency.
                "oracle"
              ]
              composerOverride)
            // (mkOverrides [
                # Builtins: planning and spec writing.
                "planner"
              ]
              planOverride)
            // (mkOverrides [
                # Builtins: Composer-powered subagents.
                "reviewer"
                "context-builder"
                "worker"
                "delegate"
                "scout"
                "researcher"
              ]
              composerOverride)
            // (mkOverrides [
                # Composer: adversarial/security/hard reasoning.
                "artifact-reviewer"
                "ce-adversarial-document-reviewer"
                "ce-adversarial-reviewer"
                "ce-agent-native-reviewer"
                "ce-correctness-reviewer"
                "ce-data-integrity-guardian"
                "ce-data-migrations-reviewer"
                "ce-julik-frontend-races-reviewer"
                "ce-performance-oracle"
                "ce-security-lens-reviewer"
                "ce-security-reviewer"
                "ce-security-sentinel"
                "claim-verifier"
                "codebase-analyzer"
                "slice-verifier"
              ]
              composerOverride)
            // (mkOverrides [
                # Composer: plans, careful review, synthesis.
                "artifact-code-reviewer"
                "artifact-coverage-reviewer"
                "ce-api-contract-reviewer"
                "ce-architecture-strategist"
                "ce-best-practices-researcher"
                "ce-code-simplicity-reviewer"
                "ce-coherence-reviewer"
                "ce-deployment-verification-agent"
                "ce-design-implementation-reviewer"
                "ce-design-lens-reviewer"
                "ce-dhh-rails-reviewer"
                "ce-feasibility-reviewer"
                "ce-framework-docs-researcher"
                "ce-kieran-python-reviewer"
                "ce-kieran-rails-reviewer"
                "ce-kieran-typescript-reviewer"
                "ce-maintainability-reviewer"
                "ce-performance-reviewer"
                "ce-product-lens-reviewer"
                "ce-project-standards-reviewer"
                "ce-reliability-reviewer"
                "ce-scope-guardian-reviewer"
                "ce-slack-researcher"
                "ce-spec-flow-analyzer"
                "ce-swift-ios-reviewer"
                "ce-testing-reviewer"
                "ce-web-researcher"
                "diff-auditor"
                "peer-comparator"
                "web-search-researcher"
              ]
              composerOverride)
            // (mkOverrides [
                # Composer: build/edit/write/fix loops.
                "ce-ankane-readme-writer"
                "ce-data-migration-expert"
                "ce-design-iterator"
                "ce-figma-design-sync"
                "ce-pr-comment-resolver"
              ]
              composerOverride)
            // (mkOverrides [
                # Composer: fast scouting, locating, summarizing context.
                "artifacts-analyzer"
                "artifacts-locator"
                "ce-git-history-analyzer"
                "ce-issue-intelligence-analyst"
                "ce-learnings-researcher"
                "ce-pattern-recognition-specialist"
                "ce-previous-comments-reviewer"
                "ce-repo-research-analyst"
                "ce-schema-drift-detector"
                "ce-session-historian"
                "codebase-locator"
                "codebase-pattern-finder"
                "integration-scanner"
                "precedent-locator"
                "scope-tracer"
                "test-case-locator"
              ]
              composerOverride);
        };
      };

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
      home.file.".pi/agent/chains/ce-review.chain.md".source = ../pi-extensions/chains/ce-review.chain.md;
      home.file.".pi/agent/chains/scout-plan.chain.md".source =
        ../pi-extensions/chains/scout-plan.chain.md;
      home.file.".pi/agent/chains/review-fix.chain.md".source =
        ../pi-extensions/chains/review-fix.chain.md;

      # Repo-managed hotfixes for npm-installed Pi packages (re-applied on activation).
      home.file.".pi/agent/hotfixes/pi-subagents/apply-hotfixes.mjs".text =
        builtins.readFile ../pi-extensions/hotfixes/pi-subagents/apply-hotfixes.mjs;

      # pi-subagents native `agentOverrides` only applies to builtin agents.
      # Our Compound Engineering agents live in ~/.pi/agent/agents (user scope),
      # so stale frontmatter model pins win during discovery. Mirror the same
      # overrides into those user-scope agent files to keep runtime routing on
      # the HM-defined GPT-5.5/Composer flow until these agents move into a
      # package/builtin scope.
      home.activation.syncPiUserAgentModelOverrides = lib.hm.dag.entryAfter ["writeBoundary"] ''
        run ${pkgs.nodejs}/bin/node <<'NODE'
        const fs = require("fs");
        const path = require("path");

        const settingsPath = path.join(process.env.HOME, ".pi", "agent", "settings.json");
        const agentsDir = path.join(process.env.HOME, ".pi", "agent", "agents");
        if (!fs.existsSync(settingsPath) || !fs.existsSync(agentsDir)) process.exit(0);

        const settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
        const overrides = (settings.subagents && settings.subagents.agentOverrides) || {};
        const fields = ["model", "thinking", "fallbackModels"];
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
            const nameLine = frontmatter.find((line) => line.startsWith("name: "));
            const agentName = nameLine ? nameLine.slice(6).trim() : path.basename(fileName, ".md");
            const override = overrides[agentName];
            if (!override || !override.model) continue;

            const values = {
              model: override.model,
              fallbackModels: Array.isArray(override.fallbackModels) ? override.fallbackModels.join(", ") : undefined,
              thinking: override.thinking,
            };

            frontmatter = frontmatter.filter((line) => !fields.some((field) => line.startsWith(field + ":")));
            body = body.filter((line) => !fields.some((field) => values[field] && line === field + ": " + values[field]));

            const inserted = [];
            if (values.model) inserted.push("model: " + values.model);
            if (values.fallbackModels) inserted.push("fallbackModels: " + values.fallbackModels);
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

        console.log("synced Pi user agent model overrides: " + updated);
        NODE
      '';

      # Re-apply pi-subagents hotfixes after Pi npm packages are installed/updated.
      home.activation.applyPiSubagentsHotfixes = lib.hm.dag.entryAfter ["linkGeneration" "installPackages"] ''
        run ${pkgs.nodejs}/bin/node \
          "$HOME/.pi/agent/hotfixes/pi-subagents/apply-hotfixes.mjs"
      '';
    };
  };
}
