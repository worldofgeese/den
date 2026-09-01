# Den mono-repo deploy recipes

# Explicit Guix substituters (matches guix/system.scm + official defaults).
# Passing --substitute-urls overrides daemon config until reconfigure applies new settings.
guix-substitute-urls := "https://substitutes.nonguix.org https://cache-cdn.guix.moe https://guix.tobias.gr/substitutes/ https://bordeaux.guix.gnu.org https://ci.guix.gnu.org"

# GC root for the built CachyOS kernel. Keeps a kernel alive between
# `just kernel-build` and the `guix system reconfigure` that adopts it.
kernel-gc-root := "/var/guix/gcroots/cachyos-bore-kernel"

# Closure `just cachix-push` uploads by default. Cache entries are per system,
# so each host pushes its own: mahakala the Home Manager activation package,
# M-02877 the nix-darwin system.
default-cachix-attr := if os() == "macos" {
  ".#darwinConfigurations.M-02877.system"
} else {
  ".#homeConfigurations.worldofgeese.activationPackage"
}

default:
    @just --list

# Deploy everything on mahakala (Guix System + Guix Home + Home Manager)
deploy-mahakala:
    just guix-pull-system
    just deploy-mahakala-system
    just guix-pull-home
    just deploy-mahakala-guix-only
    just update
    just deploy-mahakala-hm-only

# Deploy only Home Manager on mahakala (refreshes flake inputs first)
deploy-mahakala-hm:
    just update
    just deploy-mahakala-hm-only

# Switch Home Manager against the CURRENT flake.lock -- no input refresh.
# Split from deploy-mahakala-hm so an unattended runner can treat the input
# refresh and the switch as independently-failing steps: a forge outage during
# `just update` then leaves the already-locked closure deployable.

# Switch Home Manager without touching flake.lock
deploy-mahakala-hm-only:
    NIX_CONFIG='warn-dirty = false' home-manager switch --flake .#worldofgeese
    update-desktop-database ~/.local/share/applications

# Deploy only Guix Home on mahakala (pulls user channels first)
deploy-mahakala-guix:
    just guix-pull-home
    just deploy-mahakala-guix-only

# Pull the user's Guix channels. Uses the repo channels.scm and the same
# substituters as every other recipe; a bare `guix pull` inherited neither.

# Pull the user's Guix channels only (no reconfigure)
guix-pull-home:
    guix pull --substitute-urls="{{guix-substitute-urls}}" -C guix/channels.scm

# Reconfigure Guix Home against the user's CURRENT channels (no pull)
deploy-mahakala-guix-only:
    guix home reconfigure guix/home-configuration.scm

# Split out from reconfigure because a pull can bump nonguix's kernel base config
# (e.g. 7.0-x86_64.conf -> 7.1-x86_64.conf), which changes the
# linux-cachyos-bore derivation hash and silently orphans an already-built
# kernel. Pull deliberately, then check, then reconfigure.

# Pull root's Guix channels only (no reconfigure)
guix-pull-system:
    sudo bash -c 'source /root/.config/guix/current/etc/profile && guix pull --substitute-urls="{{guix-substitute-urls}}" -C /home/worldofgeese/.config/home-manager/guix/channels.scm'

# No pull: reconfigures against root's CURRENT channels. If the kernel derivation
# is not already in the store this builds it inline (~3h on 4 cores). Run
# `just kernel-status` first, or `just kernel-build` to do it detached.

# Reconfigure Guix System against root's current channels (requires sudo)
deploy-mahakala-system:
    sudo bash -c 'source /root/.config/guix/current/etc/profile && guix system reconfigure --substitute-urls="{{guix-substitute-urls}}" --fallback -L /home/worldofgeese/.config/home-manager/guix-packages /home/worldofgeese/.config/home-manager/guix/system.scm'

# The occasional "I accept a multi-hour kernel build" path.

# Full enchilada: pull channels, build kernel, then reconfigure Guix System
deploy-mahakala-system-full:
    just guix-pull-system
    just kernel-build
    just deploy-mahakala-system

# Evaluates with root's guix on purpose: your user profile is usually a different
# generation and resolves a DIFFERENT derivation, so a user-side build is wasted.

# Report whether the kernel root's Guix wants is already built
kernel-status:
    #!/usr/bin/env bash
    set -euo pipefail
    # -n as well as -d: a bare `guix build -d` blocks on the build lock whenever a
    # kernel build is already running, and a status probe must never hang.
    # -n prints prose rather than a bare path, so scrape the .drv out of it.
    drv=$(sudo bash -c 'source /root/.config/guix/current/etc/profile && guix build -n -d -L /home/worldofgeese/.config/home-manager/guix-packages -e "(@ (linux-cachyos) linux-cachyos-bore)"' 2>&1 \
        | grep -ao '/gnu/store/[a-z0-9]\{32\}-linux-cachyos-bore-[0-9.]*\.drv' | head -1)
    if [[ -z "$drv" || ! -e "$drv" ]]; then
        echo "kernel-status: could not evaluate kernel derivation" >&2
        exit 1
    fi
    out=$(grep -ao '/gnu/store/[a-z0-9]\{32\}-linux-cachyos-bore-[0-9.]*' "$drv" | head -1)
    echo "derivation: $drv"
    echo "output:     $out"
    if [[ -n "$out" && -e "$out" ]]; then
        echo "status:     BUILT (reconfigure will reuse it)"
    else
        echo "status:     NOT BUILT (reconfigure would build it inline, ~3h)"
    fi
    # -e, not just readlink: readlink -f on a missing path echoes the path back,
    # which would misreport "stale" when no root has ever been created.
    if [[ -L {{kernel-gc-root}} ]] && root=$(readlink -f {{kernel-gc-root}}) && [[ -e "$root" ]]; then
        if [[ "$root" == "$out" ]]; then
            echo "gc-root:    pinned (survives guix gc)"
        else
            echo "gc-root:    STALE, points at $root"
        fi
    else
        echo "gc-root:    none (a built kernel is GC-eligible immediately)"
    fi
    echo "running:    $(uname -r)"
    echo "system gen: $(sudo guix system describe 2>/dev/null | sed -n 's/^  label: //p' | head -1)"

# Registers a GC root at {{kernel-gc-root}}. Without one, a freshly built kernel
# has zero referrers and `guix gc` (which topgrade runs) deletes it before any
# reconfigure can adopt it -- burning a ~3h build every single time.
# Safe to re-run: if it is already built this returns in seconds.

# Build the kernel root's Guix wants and pin it against GC
kernel-build:
    #!/usr/bin/env bash
    set -euo pipefail
    log="/tmp/cachyos-bore-build-$(date +%Y%m%d-%H%M%S).log"
    echo "kernel-build: logging to $log"
    echo "kernel-build: follow with  tail -f $log"
    sudo bash -c 'source /root/.config/guix/current/etc/profile && guix build --substitute-urls="{{guix-substitute-urls}}" --fallback --root={{kernel-gc-root}} -L /home/worldofgeese/.config/home-manager/guix-packages -e "(@ (linux-cachyos) linux-cachyos-bore)"' >"$log" 2>&1
    echo "kernel-build: done -> $(readlink -f {{kernel-gc-root}})"

# Deploy NixOS on paphos (remote server; build on target by default)
deploy-paphos host="paphos" build-host="paphos" user="kypris":
    just update
    NIX_CONFIG='warn-dirty = false' nix run nixpkgs#nixos-rebuild -- switch --flake .#paphos --target-host {{user}}@{{host}} --build-host {{user}}@{{build-host}} --use-remote-sudo

# Deploy Paphos against current flake.lock without refreshing inputs.
deploy-paphos-locked host="paphos" build-host="paphos" user="kypris":
    NIX_CONFIG='warn-dirty = false' nix run nixpkgs#nixos-rebuild -- switch --flake .#paphos --target-host {{user}}@{{host}} --build-host {{user}}@{{build-host}} --use-remote-sudo

# Deploy NixOS on oracle (Oracle Cloud aarch64; build on target by default).
# The address comes from oracle.json, the same file modules/oracle/facts.nix reads,
# so the deploy default and the tailscale relay endpoint cannot disagree. Override
# for a one-off: just deploy-oracle host=nixos@NEW_IP build-host=nixos@NEW_IP
deploy-oracle host="" build-host="":
    #!/usr/bin/env bash
    set -euo pipefail
    default="$(python3 -c 'import json; f = json.load(open("oracle.json")); print(f["deployUser"] + "@" + f["publicIp"])')"
    target="{{host}}"
    build="{{build-host}}"
    [[ -n "$target" ]] || target="$default"
    [[ -n "$build" ]] || build="$default"
    NIX_CONFIG='warn-dirty = false' nix run nixpkgs#nixos-rebuild -- switch --flake .#oracle --target-host "$target" --build-host "$build" --use-remote-sudo

# Deliberately does NOT run `just update`: coupling deploy to a 15-input flake
# update means any single forge outage (codeberg 503, github stall) blocks a
# deploy whose closure is already locked. topgrade runs `just update` as its
# own step, so input refreshes still happen — they just fail independently.
#
# Deploy nix-darwin on M-02877 (macOS)
# `--option warn-dirty false`, not `env NIX_CONFIG=...`: the sudoers rule in
# modules/M-02877/darwin.nix whitelists `darwin-rebuild switch *`, and wrapping
# it in env makes /usr/bin/env the command sudo matches, which is denied.
deploy-darwin:
    sudo -H /run/current-system/sw/bin/darwin-rebuild switch --option warn-dirty false --flake .#M-02877

# Deploy nix-on-droid on pixel-fold (Android/Termux)
deploy-pixel-fold:
    just update
    NIX_CONFIG='warn-dirty = false' nix-on-droid switch --flake .#pixel-fold

# Force every registry-derived entity's check, without known-noise custom-output
# warnings. Coverage is defined in modules/checks.nix, so adding a host or home
# to modules/hosts.nix extends this gate with no edit here.
#
# Forces drvPaths rather than running `nix flake check`: the checks for the four
# non-darwin entities cannot be BUILT here, only evaluated, and evaluating them is
# what catches the regression class. `nix flake check` remains valid on a machine
# that can build them.
#
# Depends on install-hooks so a fresh clone arms the pre-commit gate the first
# time it runs the gate manually, instead of relying on someone remembering.
check: install-hooks
    nix eval --no-warn-dirty --json .#checks --apply 'ss: builtins.mapAttrs (_: cs: builtins.mapAttrs (_: c: c.drvPath) cs) ss' >/dev/null
    if [[ "$(uname -s)" == Darwin ]]; then just check-doom-darwin; fi
    just check-guix
    just check-fmt
    just check-decapod-overrides

# Prove the project overrides in .decapod/OVERRIDE.md are actually loaded.
#
# Decapod applies an override only from the four-backtick source block of a
# current generated directive section. Prose written under the same heading but
# outside that block is inert: it reads like policy, it validates, and Decapod
# never loads a byte of it. This repository sat in exactly that state - every
# override written, none applied - and nothing reported it, because an unapplied
# override is indistinguishable from an empty one without asking the binary.
#
# `context.resolve` is the only honest source: it returns a resolved_authority
# entry per applied override. Zero means the file is decorative again.
check-decapod-overrides:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v decapod >/dev/null 2>&1; then
        echo "check-decapod-overrides: decapod not found, skipping"
        exit 0
    fi
    applied=$(decapod rpc --op context.resolve 2>/dev/null \
        | jq '[..|objects|select(has("directive_id"))]|length')
    if [[ "${applied:-0}" -lt 1 ]]; then
        echo "check-decapod-overrides: 0 overrides applied - OVERRIDE.md is inert." >&2
        echo "  Each authored body must sit inside a bare four-backtick block:" >&2
        echo "  a tagged opener such as '\`\`\`\`markdown' is not recognised and" >&2
        echo "  fails with OVERRIDE_UNCLOSED_BODY_FENCE." >&2
        exit 1
    fi
    echo "check-decapod-overrides: $applied override(s) applied"

# Syntax- and load-check the Guix modules. Skips cleanly where guix is absent:
# it only exists on mahakala, and a check that fails on darwin for a missing
# interpreter is worse than no check. Loading each file evaluates the record it
# defines (operating-system, home-environment, package), so this catches the
# unbound-variable and bad-field class without building anything.
check-guix:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v guix >/dev/null 2>&1; then
        echo "check-guix: guix not found, skipping"
        exit 0
    fi
    for scm in guix/system.scm guix/home-configuration.scm guix-packages/linux-cachyos.scm; do
        echo "check-guix: loading $scm"
        guix repl -L guix-packages "$scm" >/dev/null
    done

# Everything `just check` covers, plus the checks that need extra tooling or
# provider state and so must stay out of the pre-commit path.
check-all: check
    just check-oracle-image
    just oracle-tofu-fmt-check
    just oracle-tofu-validate

# Build Darwin Doom wrapper and verify generated CLI and GUI launchers
check-doom-darwin:
    #!/usr/bin/env bash
    set -euo pipefail
    wrapper=$(nix build --no-link --print-out-paths --impure --expr '
      let
        flake = builtins.getFlake (toString ./.);
        packages = flake.darwinConfigurations.M-02877.config.home-manager.users.dktaohan.home.packages;
      in
        builtins.head (builtins.filter
          (package: flake.inputs.nixpkgs.lib.getName package == "doom-emacs-wrapped")
          packages)')
    test -x "$wrapper/bin/emacs"
    test -x "$wrapper/bin/emacsclient"
    test -x "$wrapper/Applications/Doom Emacs.app/Contents/MacOS/Doom Emacs"
    test -f "$wrapper/Applications/Doom Emacs.app/Contents/Resources/DoomEmacs.icns"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$wrapper/Applications/Doom Emacs.app/Contents/Info.plist")" == DoomEmacs ]]
    [[ "$(<"$wrapper/bin/emacs")" == *'/Users/dktaohan/Applications/Emacs.app/Contents/MacOS/Emacs'* ]]
    [[ "$(<"$wrapper/bin/emacsclient")" == *'/Users/dktaohan/Applications/Emacs.app/Contents/MacOS/bin/emacsclient'* ]]
    [[ "$(<"$wrapper/bin/emacs")" == *'DOOMPROFILE="nix"'* ]]
    [[ "$(<"$wrapper/bin/emacs")" == *'libemutls_w.a'* ]]
    [[ "$(<"$wrapper/bin/emacs")" == *'/opt/homebrew/bin'* ]]
    [[ "$(<"$wrapper/bin/emacs")" == *'/etc/profiles/per-user/dktaohan/bin'* ]]
    package_names=$(nix eval --no-warn-dirty --json .#darwinConfigurations.M-02877.config.home-manager.users.dktaohan.home.packages \
      --apply 'ps: map (p: p.pname or p.name) ps')
    [[ "$package_names" == *'"omp"'* ]]
    [[ "$package_names" == *'"claude-code"'* ]]
    [[ "$package_names" == *'"claude-agent-acp"'* ]]
    [[ "$package_names" == *'"copilot-cli"'* ]]
    echo "Darwin Doom launchers validated: $wrapper"

# Build worldofgeese Doom under amd64 Linux emulation and validate agent wiring
# through emacsclient. Reuses a named Nix volume across runs.
check-doom-linux-image:
    #!/usr/bin/env bash
    set -euo pipefail
    podman run --rm --arch amd64 --privileged --security-opt label=disable \
      -v doom-linux-nix:/nix -v "{{justfile_directory()}}:/work:ro" -w /work \
      docker.io/nixos/nix:2.31.2 sh -lc '
        set -euo pipefail
        git config --global --add safe.directory /work
        export NIX_CONFIG="extra-experimental-features = nix-command flakes
        sandbox = false
        filter-syscalls = false
        max-jobs = 2
        cores = 2"
        wrapper=$(nix build --no-link --print-out-paths --impure --expr '\''
          let
            flake = builtins.getFlake (toString /work);
            packages = flake.homeConfigurations.worldofgeese.config.home.packages;
          in
            builtins.head (builtins.filter
              (package: flake.inputs.nixpkgs.lib.getName package == "doom-emacs-wrapped")
              packages)'\'')
        socket=doom-linux-image-test
        cleanup() {
          "$wrapper/bin/emacsclient" --socket-name="$socket" --eval "(kill-emacs)" >/dev/null 2>&1 || true
        }
        trap cleanup EXIT
        "$wrapper/bin/emacs" --daemon="$socket"
        "$wrapper/bin/emacsclient" --socket-name="$socket" --eval '\''
          (progn
            (require (quote agent-shell))
            (require (quote agent-shell-anthropic))
            (require (quote agent-shell-github))
            (let ((mcp-names
                   (lambda ()
                     (mapcar (lambda (server) (alist-get (quote name) server))
                             agent-shell-mcp-servers))))
              (unless (and
                       (fboundp (quote agent-shell-anthropic-start-claude-code))
                       (fboundp (quote agent-shell-github-start-copilot))
                       (fboundp (quote agent-shell-omp-start))
                       (equal agent-shell-github-acp-command (quote ("copilot" "--acp")))
                       (equal agent-shell-omp-acp-command (quote ("omp" "acp")))
                       (equal (funcall mcp-names) (quote ("nixos")))
                       (progn
                         (lego-agent-shell-toggle-mcp)
                         (equal (funcall mcp-names) (quote ("nixos" "emacs" "emcp"))))
                       (eq lego-agent-shell-emcp-profile (quote inspect)))
                (error "agent-shell image validation failed: copilot=%S omp=%S mcp=%S profile=%S"
                       agent-shell-github-acp-command agent-shell-omp-acp-command
                       (funcall mcp-names) lego-agent-shell-emcp-profile))
              (format "agent-shell image validation passed: Claude Code, Copilot, OMP; opt-in MCP %S"
                      (funcall mcp-names))))'\''
      '


# Update all flake inputs
update:
    nix flake update --no-warn-dirty

# Push this machine's closure to the worldofgeese Cachix cache so other hosts
# fetch instead of rebuilding. Reads CACHIX_AUTH_TOKEN from secretspec
# (keyring) so the token never lands in a file, argv, or shell history.
#
# Each host must push its own builds: a cache entry is per system, and mahakala
# is x86_64-linux with no aarch64-darwin capability, so it cannot populate
# anything M-02877 would consume. Run this on both.
#
# Push the current closure to Cachix
cachix-push flake-attr=default-cachix-attr:
    secretspec run -- sh -c '\
      nix build --no-link --print-out-paths --no-warn-dirty {{flake-attr}} \
      | cachix push worldofgeese'

# Update a single flake input
update-input input:
    nix flake update --no-warn-dirty {{input}}

# Bump the pinned CachyOS kernel version/hashes in guix-packages/linux-cachyos.scm.
# Edits the file only -- builds nothing. Follow with `just kernel-build`.
upgrade-kernel:
    ./scripts/upgrade-cachyos-kernel.sh

# Show flake outputs
show:
    nix flake show

# Format all Nix files with alejandra
fmt:
    nix run nixpkgs#alejandra -- flake.nix modules/ secrets/ guix/ guix-packages/ pkgs/

# Check Nix formatting (fails if unformatted)
check-fmt:
    nix run nixpkgs#alejandra -- --check flake.nix modules/ secrets/ guix/ guix-packages/ pkgs/

# Install git hooks (pre-commit runs 'just check'). Also runs as a `just check`
# prerequisite, so this is idempotent and safe to re-run.
install-hooks:
    cp .githooks/pre-commit .git/hooks/pre-commit
    chmod +x .git/hooks/pre-commit

# Build Oracle Cloud NixOS OCI qcow2 (aarch64-linux; cross-build needs binfmt)
build-oracle-image:
    #!/usr/bin/env bash
    set -euo pipefail
    nix build .#packages.aarch64-linux.oracle-image -L --out-link result/oracle-image
    qcow="$(find -L result/oracle-image -maxdepth 1 -name '*.qcow2' -print -quit)"
    if [[ -z "$qcow" ]]; then
        echo "build-oracle-image: no .qcow2 found under result/oracle-image" >&2
        exit 1
    fi
    ln -sfn "$(readlink -f "$qcow")" result/nixos.qcow2
    echo "build-oracle-image: linked result/nixos.qcow2 -> $qcow"

# Evaluate Oracle image package without building
check-oracle-image:
    nix eval --no-warn-dirty .#packages.aarch64-linux.oracle-image.drvPath

oracle-tofu-init:
    cd terraform/oracle && nix run nixpkgs#opentofu -- init

oracle-tofu-validate:
    cd terraform/oracle && nix run nixpkgs#opentofu -- validate

oracle-tofu-fmt-check:
    cd terraform/oracle && nix run nixpkgs#opentofu -- fmt -check -recursive

oracle-tofu-fmt:
    cd terraform/oracle && nix run nixpkgs#opentofu -- fmt -recursive

oracle-tofu-plan:
    cd terraform/oracle && nix run nixpkgs#opentofu -- plan

oracle-tofu-apply:
	cd terraform/oracle && nix run nixpkgs#opentofu -- apply -auto-approve

oracle-tofu-output output:
    cd terraform/oracle && nix run nixpkgs#opentofu -- output -raw {{output}}

# Back up local OpenTofu state to gopass (never commit state to git)
oracle-tofu-backup-state:
    #!/usr/bin/env bash
    set -euo pipefail
    cd /home/worldofgeese/.config/home-manager
    state="terraform/oracle/terraform.tfstate"
    backup="terraform/oracle/terraform.tfstate.backup"
    secret="dev/oci/oracle-cloud-nixos/terraform-state"
    backup_secret="dev/oci/oracle-cloud-nixos/terraform-state.backup"
    if [[ ! -f "$state" ]]; then
        echo "oracle-tofu-backup-state: missing $state" >&2
        exit 1
    fi
    if ! command -v gopass >/dev/null 2>&1; then
        echo "oracle-tofu-backup-state: gopass not found" >&2
        exit 1
    fi
    gopass insert -f "$secret" < "$state"
    if [[ -f "$backup" ]]; then
        gopass insert -f "$backup_secret" < "$backup"
    fi
    echo "oracle-tofu-backup-state: stored $secret"

# Restore OpenTofu state from gopass (overwrites local terraform.tfstate)
oracle-tofu-restore-state:
    #!/usr/bin/env bash
    set -euo pipefail
    cd /home/worldofgeese/.config/home-manager
    state="terraform/oracle/terraform.tfstate"
    backup="terraform/oracle/terraform.tfstate.backup"
    secret="dev/oci/oracle-cloud-nixos/terraform-state"
    backup_secret="dev/oci/oracle-cloud-nixos/terraform-state.backup"
    if ! command -v gopass >/dev/null 2>&1; then
        echo "oracle-tofu-restore-state: gopass not found" >&2
        exit 1
    fi
    gopass show -o "$secret" > "$state"
    if gopass show -o "$backup_secret" > /dev/null 2>&1; then
        gopass show -o "$backup_secret" > "$backup"
    fi
    echo "oracle-tofu-restore-state: restored $secret -> $state"
