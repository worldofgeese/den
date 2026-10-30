package main

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"
)

// The merge rules give the expected verdict for fixed pull requests, and a
// replay reads a merged pull request as of its merge. No network and no
// token.
// +check
func (m *Ci) AutomergeRules(_ context.Context) error {
	var failed []string
	failed = append(failed, ruleCases()...)
	failed = append(failed, replayCases()...)
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
		Head: fixtureHead, Mergeable: "MERGEABLE",
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
		{"a failed commit status", func(s *prSnapshot) {
			s.Checks = append(s.Checks, prCheck{Name: "den/dagger-check", Workflow: "status", State: "FAILURE", At: fixtureTime})
		}, false, "checks"},
		{"a cancelled run that a newer run replaces", func(s *prSnapshot) {
			old := s.Checks[0]
			old.Conclusion, old.At = "CANCELLED", fixtureTime.Add(-time.Hour)
			s.Checks = append([]prCheck{old}, s.Checks...)
		}, false, ""},
		{"not mergeable", func(s *prSnapshot) { s.Mergeable = "CONFLICTING" }, false, "mergeable"},
		{"an unresolved thread", func(s *prSnapshot) { s.Unresolved = 1 }, false, "threads"},
		{"a replay skips the open and mergeable rules", func(s *prSnapshot) {
			s.State, s.Mergeable = "MERGED", "UNKNOWN"
		}, true, ""},
		{"no reviewer is set", nil, false, "reviewed"},
	}
	var failed []string
	for _, c := range cases {
		s := readyPR()
		if c.edit != nil {
			c.edit(&s)
		}
		p := fixturePolicy
		if c.name == "no reviewer is set" {
			p.Reviewer = ""
		}
		if rule, why := judge(&s, p, c.replay); rule != c.want {
			failed = append(failed, fmt.Sprintf("rule case %q: rule %q (%s), want %q", c.name, rule, why, c.want))
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
	pr.Commits.Nodes = append(pr.Commits.Nodes, struct {
		Commit struct {
			StatusCheckRollup *struct {
				Contexts struct{ Nodes []gqlContext }
			}
		}
	}{})
	rollup := &struct {
		Contexts struct{ Nodes []gqlContext }
	}{}
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
