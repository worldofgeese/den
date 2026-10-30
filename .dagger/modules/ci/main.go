// Checks for this repository. Run them with `dagger check` from the
// repository root.
//
// The module is thin. Each check runs a Justfile recipe or a script of the
// repository in a pinned container, so `just check` on a host and
// `dagger check` run the same commands. The module names no host, account or
// company: a repository gives those as settings in its dagger.toml (plan
// docs/plans/2026-10-30-001-dagger-ci-autonomous-merge-plan.md, D6).
package main

import (
	"context"
	"fmt"
	"regexp"
	"strings"

	"dagger/ci/internal/dagger"
)

// The Nix image. ghcr.io has the same image as Docker Hub, without the pull
// limit of Docker Hub. dagger.lock pins the digest of this tag.
const nixImage = "ghcr.io/nixos/nix:2.35.4"

// The Nix settings of each Nix check. The checks evaluate and download, and
// they build nothing that needs a sandbox. A container cannot nest a sandbox.
const nixConfig = "experimental-features = nix-command flakes\n" +
	"warn-dirty = false\n" +
	"sandbox = false\n" +
	"filter-syscalls = false\n"

// The tools that each Nix check gets from the nixpkgs input of flake.lock.
var nixTools = []string{"nixpkgs#bash", "nixpkgs#just", "nixpkgs#jq"}

// The Decapod image is the one that .decapod/managed/Dockerfile.decapod pins,
// so that the release stays in one file.
var decapodImageArg = regexp.MustCompile(`(?m)^ARG DECAPOD_IMAGE=(\S+)\s*$`)

// No check calls the Dagger engine from its container.
var noNest = dagger.ContainerWithExecOpts{DisableDaggerInDagger: true}

type Ci struct {
	// +private
	Source *dagger.Directory
}

func New(
	// The current workspace. Dagger gives it.
	ws *dagger.Workspace,
) *Ci {
	return &Ci{
		// The files that a clone has: the .gitignore files leave out local
		// state, for example .decapod/workspaces. In a linked worktree .git
		// is a file that names a path on the host, so it stays out, and the
		// flake loads as a path flake. .dagger stays in: Decapod's
		// repo_signal_fingerprint counts its files, and without them
		// ci:decapod-validate reports drift.
		Source: ws.Directory("/", dagger.WorkspaceDirectoryOpts{
			Gitignore: true,
			Exclude:   []string{".git"},
		}),
	}
}

// nix is a Nix container with the repository in /src. The Nix store and the
// fetcher cache are cache volumes, so a second run reuses the flake inputs
// and the tools. The volume names contain the image tag: a new Nix release
// starts from its own store.
func (m *Ci) nix() *dagger.Container {
	tag := nixImage[strings.LastIndex(nixImage, ":")+1:]
	base := dag.Container().From(nixImage)
	return base.
		WithMountedCache("/nix", dag.CacheVolume("ci-nix-store-"+tag),
			dagger.ContainerWithMountedCacheOpts{Source: base.Directory("/nix")}).
		WithMountedCache("/root/.cache/nix", dag.CacheVolume("ci-nix-fetchers-"+tag)).
		WithEnvVariable("NIX_CONFIG", nixConfig).
		WithDirectory("/src", m.Source).
		WithWorkdir("/src")
}

// inNix runs args in the Nix container, with nixTools on PATH.
func (m *Ci) inNix(ctx context.Context, args ...string) error {
	cmd := append([]string{"nix", "shell", "--inputs-from", "."}, nixTools...)
	cmd = append(cmd, "--command")
	_, err := m.nix().WithExec(append(cmd, args...), noNest).Sync(ctx)
	return err
}

// decapod is the Decapod image with jq, which the image does not have, and
// a copy of the repository in /work. The engine can store identical files as
// hard links of one file, and Decapod refuses to write a state file that has
// more than one link (STORAGE_UNSAFE_PERMISSIONS). cp -R does not keep links.
func (m *Ci) decapod(ctx context.Context) (*dagger.Container, error) {
	dockerfile, err := m.Source.File(".decapod/managed/Dockerfile.decapod").Contents(ctx)
	if err != nil {
		return nil, err
	}
	match := decapodImageArg.FindStringSubmatch(dockerfile)
	if match == nil {
		return nil, fmt.Errorf(".decapod/managed/Dockerfile.decapod has no ARG DECAPOD_IMAGE line")
	}
	return dag.Container().From(match[1]).
		WithExec([]string{"sh", "-c", "apt-get update -qq && " +
			"apt-get install -y -qq --no-install-recommends jq >/dev/null"}, noNest).
		WithDirectory("/src", m.Source).
		WithExec([]string{"cp", "-R", "/src/.", "/work"}, noNest).
		WithWorkdir("/work"), nil
}

// The Nix files are formatted (`just check-fmt`).
// +check
func (m *Ci) Fmt(ctx context.Context) error {
	return m.inNix(ctx, "just", "check-fmt")
}

// The derivation of each check under .#checks evaluates
// (scripts/check-drvpaths.sh). A check that needs a builder that the engine
// does not have, for example a Darwin build, is skipped, as on a host.
// +check
func (m *Ci) NixEval(ctx context.Context) error {
	return m.inNix(ctx, "./scripts/check-drvpaths.sh")
}

// ShellCheck passes on scripts/*.sh (`just check-shellcheck`).
// +check
func (m *Ci) Shellcheck(ctx context.Context) error {
	return m.inNix(ctx, "just", "check-shellcheck")
}

// Decapod loads the overrides in .decapod/OVERRIDE.md
// (scripts/check-decapod-overrides.sh).
// +check
func (m *Ci) DecapodOverrides(ctx context.Context) error {
	c, err := m.decapod(ctx)
	if err != nil {
		return err
	}
	_, err = c.WithExec([]string{"bash", "scripts/check-decapod-overrides.sh"}, noNest).Sync(ctx)
	return err
}

// A CI-local `decapod validate` passes, and it leaves no spec or entrypoint
// drift (scripts/decapod-validate-ci.sh).
// +check
func (m *Ci) DecapodValidate(ctx context.Context) error {
	c, err := m.decapod(ctx)
	if err != nil {
		return err
	}
	_, err = c.WithExec([]string{"bash", "scripts/decapod-validate-ci.sh"}, noNest).Sync(ctx)
	return err
}
