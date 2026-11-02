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
	// The merge rules (automerge.go). A repository sets them in its
	// dagger.toml.
	// +private
	Repository string
	// +private
	Authors []string
	// +private
	Reviewer string
	// +private
	RiskyPaths []string
	// +private
	CheckName string
	// +private
	RiskyExecutableBit bool
	// +private
	ManifestFiles []string
	// +private
	ManifestSafeFields []string
	// +private
	ManifestSourcePrefix string
	// approve-bot-runs (approve.go).
	// +private
	ApprovesBotRuns bool
	// The job-kinds table of ci:workflow-isolation (workflows.go).
	// +private
	JobKinds string
	// The review gate (reviewgate.go).
	// +private
	StatusPrefix string
	// +private
	ReviewMarker string
	// +private
	SecondPersonApproval bool
	// +private
	ReviewTimeoutHours int
	// +private
	RequireReviewGate bool
}

func New(
	// The current workspace. Dagger gives it.
	ws *dagger.Workspace,
	// The GitHub repository, owner/name, that the merge rules read.
	// +optional
	repository string,
	// Logins whose pull requests can merge without a person. A bot is
	// app/<login>, and "*" is every author. With none, every pull request
	// needs a person.
	// +optional
	authors []string,
	// The login whose review of the head counts. With none, nothing merges.
	// +optional
	reviewer string,
	// Path patterns. A pull request that changes a matching path is merged
	// by a person. A pattern without "*" is a path prefix. A pattern with
	// "*" must match the whole path: "*" matches in one level, and "**" as a
	// level matches zero or more levels.
	// +optional
	riskyPaths []string,
	// A check whose newest run on the head must succeed. With none, branch
	// protection names the checks that must pass.
	// +optional
	checkName string,
	// A pull request that adds a file with git mode 100755, or that changes
	// the mode of a file to 100755, is merged by a person. The rules read
	// the modes from the Git trees of the merge base and the head.
	// +optional
	riskyExecutableBit bool,
	// Path patterns of JSON manifest files, as for riskyPaths. A pull
	// request that adds, removes or changes a top-level field of a matching
	// file outside manifestSafeFields, or a file that does not parse, is
	// merged by a person. With none, the rules read no manifest.
	// +optional
	manifestFiles []string,
	// The top-level fields of a manifest, and the fields of its entries,
	// that can change without a person.
	// +optional
	manifestSafeFields []string,
	// In a list of entries of a manifest, for example the plugins of a
	// marketplace, source can change only to a relative path under this
	// prefix, for example ./plugins/. With none, a change of source needs a
	// person.
	// +optional
	manifestSourcePrefix string,
	// With true, approve-bot-runs approves the pull_request runs that GitHub
	// holds (action_required) on a head that a job pushed with its
	// GITHUB_TOKEN. With false, the module approves no run.
	// +optional
	approveBotRuns bool,
	// The job-kinds table of ci:workflow-isolation, in YAML: the kind of each
	// job in .github/workflows (CHECK, AGENT, GITHUB, SCAN or LEGACY), and
	// what the kinds can hold in this repository. With none, the check is
	// off.
	// +optional
	jobKinds string,
	// review-gate posts the commit status <statusPrefix>/review on the head of
	// each open pull request: success when the newest review of the head by
	// the reviewer has no open blocking finding, and failure when it has one.
	// With none, the review gate is off.
	// +optional
	statusPrefix string,
	// The name of the block in the review body of the reviewer that lists the
	// open findings, for example aec-review:v1 for the block
	// <!-- aec-review:v1 {"open":[{"id":"F1","severity":"blocking"}]} -->.
	// With none, the gate reads the reviewer as the merge rules do: the rules
	// reviewed and threads, and the Codex summary.
	// +optional
	reviewMarker string,
	// With true, an APPROVE of the exact head opens the review gate when the
	// approver is a person with write access, is not the author, and pushed
	// none of the commits (the activity API). Never on a fork pull request.
	// +optional
	secondPersonApproval bool,
	// A head with no review gate status this many hours after its check
	// finished gets the needs-human action "review by a person: approve head
	// X?". With 0, there is no timeout.
	// +optional
	reviewTimeoutHours int,
	// With true, the merge rules require the success of the review gate on the
	// head (the rule review-gate).
	// +optional
	requireReviewGate bool,
) *Ci {
	return &Ci{
		Repository:           repository,
		Authors:              authors,
		Reviewer:             reviewer,
		RiskyPaths:           riskyPaths,
		CheckName:            checkName,
		RiskyExecutableBit:   riskyExecutableBit,
		ManifestFiles:        manifestFiles,
		ManifestSafeFields:   manifestSafeFields,
		ManifestSourcePrefix: manifestSourcePrefix,
		ApprovesBotRuns:      approveBotRuns,
		JobKinds:             jobKinds,
		StatusPrefix:         statusPrefix,
		ReviewMarker:         reviewMarker,
		SecondPersonApproval: secondPersonApproval,
		ReviewTimeoutHours:   reviewTimeoutHours,
		RequireReviewGate:    requireReviewGate,
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
