package main

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"
)

// The shepherd takes the expected step for fixed pull requests, and the
// action of each fork policy against a fake GitHub API. No network and no
// token.
// +check
func (m *Ci) ShepherdRules(ctx context.Context) error {
	now := fixtureTime
	old := now.Add(-time.Hour)
	summary := func(sha, status string) shepherdComment {
		return shepherdComment{Author: fixturePolicy.Reviewer, Body: fmt.Sprintf(
			`<!-- codex-review-state:v1 {"code_review":{"commit_sha":%q,"has_any_findings":false,"has_unresolved_findings":false,"status":%q}} -->`,
			sha, status)}
	}
	requestBy := func(login, sha string, at time.Time) shepherdComment {
		return shepherdComment{Author: login, Body: "@codex review\n\n" + requestMarker(sha), At: at}
	}
	// The shepherd's own login in these cases is alice.
	request := func(sha string, at time.Time) shepherdComment { return requestBy("alice", sha, at) }
	cases := []struct {
		name   string
		edit   func(*shepherdPR)
		policy func(*mergePolicy)
		want   shepherdStep
	}{
		{"a head with no review gets a request", nil, nil, stepRequest},
		{"a draft waits", func(p *shepherdPR) { p.Draft = true }, nil, stepNone},
		{"a stop label stops the shepherd", func(p *shepherdPR) { p.Labels = []string{"hold"} }, nil, stepNone},
		{"an author outside the list gets checks only", func(p *shepherdPR) { p.Author = "mallory" }, nil, stepNone},
		{"with no authors, each author gets checks only", nil, func(p *mergePolicy) { p.Authors = nil }, stepNone},
		{"authors * gets a request for each author", func(p *shepherdPR) { p.Author = "mallory" },
			func(p *mergePolicy) { p.Authors = []string{"*"} }, stepRequest},
		{"only the Codex connector can be asked", nil, func(p *mergePolicy) { p.Reviewer = "bob" }, stepNone},
		{"incomplete comments stop the shepherd", func(p *shepherdPR) { p.CommentsIncomplete = true }, nil, stepNone},
		{"a completed review of the head needs nothing", func(p *shepherdPR) {
			p.Comments = []shepherdComment{summary(fixtureHead, "completed")}
		}, nil, stepNone},
		{"a running review of the head waits", func(p *shepherdPR) {
			p.Comments = []shepherdComment{summary(fixtureHead, "running")}
		}, nil, stepNone},
		{"a failed review of the head gets a request", func(p *shepherdPR) {
			p.Comments = []shepherdComment{summary(fixtureHead, "failed")}
		}, nil, stepRequest},
		{"a review of an older head does not count", func(p *shepherdPR) {
			p.Comments = []shepherdComment{summary("feedface", "completed")}
		}, nil, stepRequest},
		{"a new pull request waits for the automatic review", func(p *shepherdPR) { p.HeadAt = now.Add(-time.Minute) }, nil, stepNone},
		{"a new head after a summary gets a request at once", func(p *shepherdPR) {
			p.HeadAt = now.Add(-time.Minute)
			p.Comments = []shepherdComment{summary("feedface", "completed")}
		}, nil, stepRequest},
		{"requests from another login do not count", func(p *shepherdPR) {
			p.Comments = []shepherdComment{requestBy("mallory", fixtureHead, old), requestBy("mallory", fixtureHead, old), requestBy("mallory", fixtureHead, old)}
		}, nil, stepRequest},
		{"a recent request waits", func(p *shepherdPR) {
			p.Comments = []shepherdComment{request(fixtureHead, now.Add(-5*time.Minute))}
		}, nil, stepNone},
		{"an old request gets a second request", func(p *shepherdPR) {
			p.Comments = []shepherdComment{request(fixtureHead, old)}
		}, nil, stepRequest},
		{"a request for an older head does not count", func(p *shepherdPR) {
			p.Comments = []shepherdComment{request("feedface", old), request("feedface", old), request("feedface", old)}
		}, nil, stepRequest},
		{"the cap gives the pull request to a person", func(p *shepherdPR) {
			p.Comments = []shepherdComment{request(fixtureHead, old), request(fixtureHead, old), request(fixtureHead, old)}
		}, nil, stepNeedsHuman},
		{"a recent last request waits at the cap", func(p *shepherdPR) {
			p.Comments = []shepherdComment{request(fixtureHead, old), request(fixtureHead, old), request(fixtureHead, now.Add(-time.Minute))}
		}, nil, stepNone},
	}
	var failed []string
	for _, c := range cases {
		pr := shepherdPR{Number: 1, Author: "alice", Head: fixtureHead, HeadAt: old}
		p := fixturePolicy
		if c.edit != nil {
			c.edit(&pr)
		}
		if c.policy != nil {
			c.policy(&p)
		}
		if got, why := nextStep(pr, p, "alice", now); got != c.want {
			failed = append(failed, fmt.Sprintf("shepherd case %q: step %q (%s), want %q", c.name, got, why, c.want))
		}
	}
	for _, c := range forkCases() {
		failed = append(failed, c.check(ctx)...)
	}
	failed = append(failed, forkTableCases(ctx)...)
	failed = append(failed, forkCallCases(ctx)...)
	if len(failed) > 0 {
		return errors.New(strings.Join(failed, "\n"))
	}
	return nil
}
