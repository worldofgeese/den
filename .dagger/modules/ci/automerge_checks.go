package main

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"
)

// The merge rules give the expected verdict for fixed pull requests and
// settings, the risky-path patterns match the expected paths, and a replay
// reads a merged pull request as of its merge. The rules read file modes and
// manifests from Git trees and blobs in the JSON of the GitHub REST API. No
// network and no token.
// +check
func (m *Ci) AutomergeRules(_ context.Context) error {
	var failed []string
	failed = append(failed, ruleCases()...)
	failed = append(failed, policyCases()...)
	failed = append(failed, riskyPathCases()...)
	failed = append(failed, replayCases()...)
	failed = append(failed, filesCases()...)
	failed = append(failed, sourceCases()...)
	failed = append(failed, treeCases()...)
	if len(failed) > 0 {
		return errors.New(strings.Join(failed, "\n"))
	}
	return nil
}

const fixtureHead = "0123456789abcdef0123456789abcdef01234567"

var fixtureTime = time.Date(2026, 10, 30, 12, 0, 0, 0, time.UTC)

var fixturePolicy = mergePolicy{
	Authors:    []string{"alice", "app/dependabot"},
	Reviewer:   "app/chatgpt-codex-connector",
	RiskyPaths: []string{"secrets/", "secretspec."},
}

func codexComment(sha string, unresolved bool) prComment {
	return prComment{Author: fixturePolicy.Reviewer, Body: fmt.Sprintf(
		`<!-- codex-review-state:v1 {"code_review":{"commit_sha":%q,"has_any_findings":%t,"has_unresolved_findings":%t,"status":"completed"}} -->`,
		sha, unresolved, unresolved)}
}

func readyPR() prSnapshot {
	return prSnapshot{
		Number: 1, State: "OPEN", Base: "main", Trunk: "main", Author: "alice",
		Head: fixtureHead, Mergeable: "MERGEABLE", MergeState: "CLEAN",
		Checks:  []prCheck{{Name: "validate", Workflow: "Decapod Validate", Status: "COMPLETED", Conclusion: "SUCCESS", At: fixtureTime}},
		Reviews: []prReview{{Author: fixturePolicy.Reviewer, State: "COMMENTED", Commit: fixtureHead}},
		Files:   []string{"modules/pi.nix"},
	}
}

func ruleCases() []string {
	cases := []struct {
		name   string
		edit   func(*prSnapshot)
		replay bool
		want   string // the rule that refuses; "" merges
	}{
		{"a ready pull request merges", nil, false, ""},
		{"a closed pull request", func(s *prSnapshot) { s.State = "CLOSED" }, false, "open"},
		{"draft", func(s *prSnapshot) { s.Draft = true }, false, "draft"},
		{"stacked on another branch", func(s *prSnapshot) { s.Base = "feature" }, false, "stacked"},
		{"labelled Hold", func(s *prSnapshot) { s.Labels = []string{"Hold"} }, false, "labels"},
		{"labelled needs-human", func(s *prSnapshot) { s.Labels = []string{"needs-human"} }, false, "labels"},
		{"a label history longer than the rules read", func(s *prSnapshot) { s.LabelsIncomplete = true }, true, "labels"},
		{"an author outside the list", func(s *prSnapshot) { s.Author = "mallory" }, false, "author"},
		{"a bot in the list", func(s *prSnapshot) { s.Author = "app/dependabot" }, false, ""},
		{"a risky path", func(s *prSnapshot) { s.Files = []string{"secretspec.age"} }, false, "risky-paths"},
		{"more changed files than the rules read", func(s *prSnapshot) { s.ChangedFiles = 150 }, false, "risky-paths"},
		{"a review of an earlier head", func(s *prSnapshot) { s.Reviews[0].Commit = "feed" }, false, "reviewed"},
		{"a review by someone else", func(s *prSnapshot) { s.Reviews[0].Author = "bob" }, false, "reviewed"},
		{"a clean Codex summary of the head", func(s *prSnapshot) {
			s.Reviews = nil
			s.Comments = []prComment{codexComment(fixtureHead, false)}
		}, false, ""},
		{"a Codex summary with a null findings flag", func(s *prSnapshot) {
			s.Reviews = nil
			s.Comments = []prComment{{Author: fixturePolicy.Reviewer, Body: fmt.Sprintf(
				`<!-- codex-review-state:v1 {"code_review":{"commit_sha":%q,"has_any_findings":null,"has_unresolved_findings":null,"status":"completed"}} -->`, fixtureHead)}}
		}, false, ""},
		{"a null findings flag with an unresolved thread", func(s *prSnapshot) {
			s.Reviews = nil
			s.Comments = []prComment{{Author: fixturePolicy.Reviewer, Body: fmt.Sprintf(
				`<!-- codex-review-state:v1 {"code_review":{"commit_sha":%q,"has_any_findings":null,"has_unresolved_findings":null,"status":"completed"}} -->`, fixtureHead)}}
			s.Unresolved = 1
		}, false, "threads"},
		{"a Codex summary with unresolved findings", func(s *prSnapshot) {
			s.Reviews = nil
			s.Comments = []prComment{codexComment(fixtureHead, true)}
		}, false, "reviewed"},
		{"a clean Codex summary of an earlier head", func(s *prSnapshot) {
			s.Reviews = nil
			s.Comments = []prComment{codexComment("feed", false)}
		}, false, "reviewed"},
		{"a Codex summary from another login", func(s *prSnapshot) {
			s.Reviews = nil
			c := codexComment(fixtureHead, false)
			c.Author = "mallory"
			s.Comments = []prComment{c}
		}, false, "reviewed"},
		{"changes requested", func(s *prSnapshot) { s.ReviewDecision = "CHANGES_REQUESTED" }, false, "changes-requested"},
		{"manual steps in the description", func(s *prSnapshot) { s.Body = "Before you merge: rotate the key." }, false, "manual-steps"},
		{"a failed check", func(s *prSnapshot) { s.Checks[0].Conclusion = "FAILURE" }, false, "checks"},
		{"a pending check", func(s *prSnapshot) { s.Checks[0].Status, s.Checks[0].Conclusion = "IN_PROGRESS", "" }, false, "checks"},
		{"no check", func(s *prSnapshot) { s.Checks = nil }, false, "checks"},
		{"more checks than the rules read", func(s *prSnapshot) { s.ChecksIncomplete = true }, false, "checks"},
		{"a queued rerun after a success", func(s *prSnapshot) {
			queued := s.Checks[0]
			queued.Status, queued.Conclusion, queued.At = "QUEUED", "", time.Time{}
			s.Checks = append(s.Checks, queued)
		}, false, "checks"},
		{"a failed commit status", func(s *prSnapshot) {
			s.Checks = append(s.Checks, prCheck{Name: "den/dagger-check", Workflow: "status", State: "FAILURE", At: fixtureTime})
		}, false, "checks"},
		{"a cancelled run that a newer run replaces", func(s *prSnapshot) {
			old := s.Checks[0]
			old.Conclusion, old.At = "CANCELLED", fixtureTime.Add(-time.Hour)
			s.Checks = append([]prCheck{old}, s.Checks...)
		}, false, ""},
		{"not mergeable", func(s *prSnapshot) { s.Mergeable = "CONFLICTING" }, false, "mergeable"},
		{"branch protection blocks the head", func(s *prSnapshot) { s.MergeState = "BLOCKED" }, false, "protected"},
		{"GitHub has not computed the merge state", func(s *prSnapshot) { s.MergeState = "UNKNOWN" }, false, "protected"},
		{"an unresolved thread", func(s *prSnapshot) { s.Unresolved = 1 }, false, "threads"},
		{"a replay skips the open, mergeable and protected rules", func(s *prSnapshot) {
			s.State, s.Mergeable, s.MergeState = "MERGED", "UNKNOWN", "UNKNOWN"
		}, true, ""},
	}
	var failed []string
	for _, c := range cases {
		s := readyPR()
		if c.edit != nil {
			c.edit(&s)
		}
		if rule, why := judge(&s, fixturePolicy, c.replay); rule != c.want {
			failed = append(failed, fmt.Sprintf("rule case %q: rule %q (%s), want %q", c.name, rule, why, c.want))
		}
	}
	return failed
}

// policyCases judges a ready pull request with other settings than
// fixturePolicy.
func policyCases() []string {
	globs := func(p *mergePolicy) { p.RiskyPaths = []string{"secrets/", "**/*.sh", ".github/**"} }
	checkName := func(name string) func(*mergePolicy) {
		return func(p *mergePolicy) { p.CheckName = name }
	}
	cases := []struct {
		name   string
		policy func(*mergePolicy)
		edit   func(*prSnapshot)
		want   string // the rule that refuses; "" merges
	}{
		{"no reviewer is set", func(p *mergePolicy) { p.Reviewer = "" }, nil, "reviewed"},
		// ruleCases has an author in the list and an author outside it.
		{"no authors refuses each author", func(p *mergePolicy) { p.Authors = nil }, nil, "author"},
		{"authors * accepts each author", func(p *mergePolicy) { p.Authors = []string{"*"} },
			func(s *prSnapshot) { s.Author = "mallory" }, ""},
		{"a path that a glob matches", globs, func(s *prSnapshot) { s.Files = []string{"modules/pi.nix", "scripts/a/run.sh"} }, "risky-paths"},
		{"paths that no glob matches", globs, func(s *prSnapshot) { s.Files = []string{"scripts/run.shx", "docs/.github/a.yml"} }, ""},
		{"a path that a prefix matches, next to globs", globs, func(s *prSnapshot) { s.Files = []string{"secrets/a.age"} }, "risky-paths"},
		{"a prefix matches only at the start of a path", globs, func(s *prSnapshot) { s.Files = []string{"modules/secrets/a.age"} }, ""},
		{"with no riskyPaths, no path needs a person", func(p *mergePolicy) { p.RiskyPaths = nil },
			func(s *prSnapshot) { s.Files = []string{"secrets/a.age", ".github/workflows/check.yml"} }, ""},
		{"no checkName needs no named check", nil, func(s *prSnapshot) { s.Checks[0].Name = "lint" }, ""},
		{"checkName with a run that succeeded", checkName("validate"), nil, ""},
		{"checkName with a run that failed", checkName("validate"), func(s *prSnapshot) { s.Checks[0].Conclusion = "FAILURE" }, "checks"},
		{"checkName with no run", checkName("build"), nil, "required-check"},
		{"checkName with a skipped run", checkName("validate"), func(s *prSnapshot) { s.Checks[0].Conclusion = "SKIPPED" }, "required-check"},
		{"checkName with a commit status that succeeded", checkName("build"), func(s *prSnapshot) {
			s.Checks = append(s.Checks, prCheck{Name: "build", Workflow: "status", State: "SUCCESS", At: fixtureTime})
		}, ""},
	}
	var failed []string
	for _, c := range cases {
		s := readyPR()
		if c.edit != nil {
			c.edit(&s)
		}
		p := fixturePolicy
		if c.policy != nil {
			c.policy(&p)
		}
		if rule, why := judge(&s, p, false); rule != c.want {
			failed = append(failed, fmt.Sprintf("policy case %q: rule %q (%s), want %q", c.name, rule, why, c.want))
		}
	}
	return failed
}

// riskyPathCases matches risky-path patterns to paths: prefixes, and a glob
// for each kind of risky path. Each pattern has a path that it matches and a
// path that it does not match.
func riskyPathCases() []string {
	cases := []struct {
		pattern, path string
		want          bool
	}{
		// A pattern without "*" is a prefix.
		{"secrets/", "secrets/a.age", true},
		{"secrets/", "modules/secrets/a.age", false},
		{"secretspec.", "secretspec.age", true},
		{"secretspec.", "docs/secretspec.md", false},
		// Scripts and executables, in each level.
		{"**/*.sh", "run.sh", true},
		{"**/*.sh", "scripts/a/run.sh", true},
		{"**/*.sh", "scripts/run.shx", false},
		{"**/Dockerfile", "images/Dockerfile", true},
		{"**/Dockerfile", "images/Dockerfile.md", false},
		// Dependency manifests and lockfiles, in each level.
		{"**/requirements*.txt", "scan/requirements-dev.txt", true},
		{"**/requirements*.txt", "scan/requirements.txt.orig", false},
		// The check and its configuration.
		{".github/**", ".github/workflows/check.yml", true},
		{".github/**", "docs/.github/check.yml", false},
		{".prettierrc*", ".prettierrc.json", true},
		{".prettierrc*", "docs/.prettierrc", false},
		// Hooks and MCP configuration, in each level.
		{"**/hooks/**", "plugins/a/hooks/pre-commit", true},
		{"**/hooks/**", "plugins/a/git-hooks/pre-commit", false},
		{"**/.mcp.json", "plugins/a/.mcp.json", true},
		{"**/.mcp.json", "plugins/a/.mcp.json.example", false},
		// "*" matches in one level only.
		{"docs/*.md", "docs/a.md", true},
		{"docs/*.md", "docs/guides/a.md", false},
		// Only "*" is special: "?", "[" and "\" match themselves.
		{"**/[id]*.ts", "app/[id]page.ts", true},
		{"**/[id]*.ts", "app/ipage.ts", false},
		{"**/?.sh", "a.sh", false},
		{`**/a\*.sh`, `b/a\x.sh`, true},
	}
	var failed []string
	for _, c := range cases {
		if got := matchRiskyPath(c.pattern, c.path); got != c.want {
			failed = append(failed, fmt.Sprintf("risky path %q on %q: %t, want %t", c.pattern, c.path, got, c.want))
		}
	}
	return failed
}

func replayCases() []string {
	merged := fixtureTime
	early, late := merged.Add(-time.Hour), merged.Add(time.Hour)
	pr := &gqlPR{Number: 7, State: "MERGED", BaseRefName: "main", HeadRefOid: fixtureHead, MergedAt: &merged,
		Author: &gqlActor{Typename: "Bot", Login: "dependabot"}}
	add := func(kind, label string, at time.Time) {
		pr.TimelineItems.Nodes = append(pr.TimelineItems.Nodes, struct {
			Typename  string `json:"__typename"`
			CreatedAt time.Time
			Label     struct{ Name string }
		}{kind, at, struct{ Name string }{label}})
	}
	add("LabeledEvent", "hold", early.Add(-time.Hour))
	add("UnlabeledEvent", "hold", early)
	add("LabeledEvent", "released", late)
	pr.Reviews.Nodes = append(pr.Reviews.Nodes, struct {
		Author      *gqlActor
		State       string
		SubmittedAt *time.Time
		Commit      *struct{ Oid string }
	}{&gqlActor{Typename: "Bot", Login: "chatgpt-codex-connector"}, "COMMENTED", &late, &struct{ Oid string }{fixtureHead}})
	pr.Commits.Nodes = append(pr.Commits.Nodes, gqlCommitNode{})
	rollup := &gqlRollup{}
	earlier := early.Add(-time.Hour)
	rollup.Contexts.Nodes = []gqlContext{
		// Complete before the merge: it counts as it is.
		{Typename: "CheckRun", Name: "validate", Status: "COMPLETED", Conclusion: "SUCCESS", StartedAt: &earlier, CompletedAt: &early},
		// Started after the merge, by the push to main: it does not count.
		{Typename: "CheckRun", Name: "deploy", Status: "COMPLETED", Conclusion: "FAILURE", StartedAt: &late, CompletedAt: &late},
	}
	pr.Commits.Nodes[0].Commit.StatusCheckRollup = rollup

	s := snapshotFrom(pr, "main", true)
	var failed []string

	// Started before the merge and complete after it: it was running at the
	// merge, so the checks were not all complete.
	running := *pr
	runningRollup := *rollup
	runningRollup.Contexts.Nodes = append([]gqlContext{}, rollup.Contexts.Nodes...)
	runningRollup.Contexts.Nodes = append(runningRollup.Contexts.Nodes,
		gqlContext{Typename: "CheckRun", Name: "lint", Status: "COMPLETED", Conclusion: "SUCCESS", StartedAt: &early, CompletedAt: &late})
	running.Commits.Nodes = append(running.Commits.Nodes[:0:0], pr.Commits.Nodes...)
	running.Commits.Nodes[0].Commit.StatusCheckRollup = &runningRollup
	rs := snapshotFrom(&running, "main", true)
	// This case tests the checks; give it a review of the head.
	rs.Reviews = []prReview{{Author: fixturePolicy.Reviewer, State: "COMMENTED", Commit: fixtureHead}}
	if rule, _ := judge(&rs, fixturePolicy, true); rule != "checks" {
		failed = append(failed, fmt.Sprintf("replay: a run that was running at the merge gives rule %q, want checks", rule))
	}
	// checkName counts only the runs from before the merge: validate
	// succeeded before it, and deploy started after it.
	for _, c := range []struct{ check, want string }{{"validate", ""}, {"deploy", "required-check"}} {
		cs := s
		cs.Reviews = []prReview{{Author: fixturePolicy.Reviewer, State: "COMMENTED", Commit: fixtureHead}}
		p := fixturePolicy
		p.CheckName = c.check
		if rule, why := judge(&cs, p, true); rule != c.want {
			failed = append(failed, fmt.Sprintf("replay: checkName %s gives rule %q (%s), want %q", c.check, rule, why, c.want))
		}
	}
	if len(s.Labels) != 0 {
		failed = append(failed, fmt.Sprintf("replay: labels %v, want none at the merge", s.Labels))
	}
	if len(s.Reviews) != 0 {
		failed = append(failed, "replay: a review from after the merge counts")
	}
	if len(s.Checks) != 1 || s.Checks[0].Name != "validate" {
		failed = append(failed, fmt.Sprintf("replay: checks %v, want only validate", s.Checks))
	}
	if s.Author != "app/dependabot" {
		failed = append(failed, fmt.Sprintf("replay: author %q, want app/dependabot", s.Author))
	}
	return failed
}
