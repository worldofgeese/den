package main

import (
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"slices"
	"strings"
	"time"

	"dagger/ci/internal/dagger"
)

// The review gate (den plan P4, part h of AEC task M). With statusPrefix,
// review-gate posts the commit status <statusPrefix>/review on the head of
// each open pull request: success when the newest review of the exact head by
// the reviewer has no open blocking finding, and failure when it has one. With
// secondPersonApproval, an APPROVE of the exact head by a second person opens
// the gate. With reviewTimeoutHours, a head that nobody reviews gets a
// needs-human action. The merge rules read the gate only with
// requireReviewGate (the rule review-gate). The status of the gate never
// counts as a review of the head.

// gateResult is what the gate decides for the head of a pull request.
type gateResult struct {
	// State is "success" or "failure". With no state, the gate posts nothing.
	State string
	// Reason is the description of the status, or why there is no status.
	Reason string
	// NeedsHuman is the question for a person when the review timeout fires.
	NeedsHuman string
	// Refused names each approval that does not open the gate, with the
	// reason.
	Refused []string
}

// approverFacts is what the REST API tells about an approver.
type approverFacts struct {
	// Permission is admin, write, read or none.
	Permission string
	// Pushed: the activity API lists an activity of the approver on the head
	// branch, other than a deletion of the branch.
	Pushed bool
}

// reviewGate decides the result of the gate for the head of s at now. facts
// has the REST data of the approvers that approvalRefusal does not refuse.
// It is a pure function, so ci:review-gate-rules tests each case.
func reviewGate(s *prSnapshot, p mergePolicy, facts map[string]approverFacts, now time.Time) gateResult {
	var r gateResult
	switch {
	case s.State != "OPEN":
		r.Reason = "the pull request is " + strings.ToLower(s.State)
		return r
	case s.ReviewsIncomplete:
		// A newer review that the query did not read can change the result.
		r.Reason = "it has more reviews than the gate reads; a person reviews"
	default:
		if p.SecondPersonApproval {
			for _, login := range approvers(s) {
				why := approvalRefusal(s, login)
				if why == "" {
					why = factsRefusal(s, login, facts)
				}
				if why == "" {
					r.State, r.Reason = "success", login+" approved head "+short(s.Head)+" as a second person"
					return r
				}
				r.Refused = append(r.Refused, "the approval of "+login+" does not count: "+why)
			}
		}
		switch {
		case p.Reviewer == "":
			// A deleted account has no login, so no login is not a reviewer.
			r.Reason = "no reviewer is set"
		case p.ReviewMarker != "":
			r.State, r.Reason = markerReading(s, p)
		default:
			r.State, r.Reason = denReading(s, p)
		}
		if r.State != "" {
			return r
		}
	}
	// No result. A success of the gate from before does not stand now, so
	// the gate takes it back.
	old, posted := p.gateStatusOf(s)
	if posted && old.State == "SUCCESS" {
		r.State, r.Reason = "failure", "no review or approval of head "+short(s.Head)+" stands"
		return r
	}
	if !posted && p.ReviewTimeout > 0 && !s.Draft {
		if done, ok := checkFinished(s, p); ok && now.Sub(done) >= p.ReviewTimeout {
			r.NeedsHuman = "review by a person: approve head " + short(s.Head) + "?"
		}
	}
	return r
}

// denReading reads the review of the head as the merge rules of den do: the
// rule reviewed (a review of the head by the reviewer, or a clean Codex
// summary of the head) and the rule threads. A completed Codex summary of the
// head with unresolved findings is a review with an open finding.
func denReading(s *prSnapshot, p mergePolicy) (string, string) {
	if why := ruleRefusal("reviewed", s, p); why != "" {
		if c, ok := codexSummary(s.Comments, p.Reviewer, s.Head); ok && c.Unresolved != nil && *c.Unresolved {
			return "failure", p.Reviewer + " has unresolved findings on head " + short(s.Head)
		}
		return "", why
	}
	if r, ok := newestReview(s, p.Reviewer, decisive); ok && r.State == "CHANGES_REQUESTED" {
		return "failure", p.Reviewer + " requested changes on head " + short(s.Head)
	}
	if why := ruleRefusal("threads", s, p); why != "" {
		return "failure", why
	}
	return "success", p.Reviewer + " reviewed head " + short(s.Head) + ": no open finding"
}

// markerReading reads the newest review of the head by the reviewer that has
// the block of reviewMarker. The block lists the open findings, each with an
// ID and a severity. Each severity other than note is blocking.
func markerReading(s *prSnapshot, p mergePolicy) (string, string) {
	r, ok := newestReview(s, p.Reviewer, func(r prReview) bool { return len(markerBlocks(r.Body, p.ReviewMarker)) > 0 })
	if !ok {
		return "", p.Reviewer + " has no " + p.ReviewMarker + " review of head " + short(s.Head)
	}
	blocks := markerBlocks(r.Body, p.ReviewMarker)
	if len(blocks) > 1 {
		return "failure", fmt.Sprintf("the review of head %s has %d %s blocks", short(s.Head), len(blocks), p.ReviewMarker)
	}
	var block struct {
		Open *[]struct {
			ID       string `json:"id"`
			Severity string `json:"severity"`
		} `json:"open"`
	}
	if json.Unmarshal([]byte(blocks[0]), &block) != nil || block.Open == nil {
		return "failure", "cannot read the " + p.ReviewMarker + " block of the review of head " + short(s.Head)
	}
	var blocking []string
	notes := 0
	for _, f := range *block.Open {
		if f.Severity == "note" {
			notes++
			continue
		}
		blocking = append(blocking, cmp.Or(f.ID, "(no id)"))
	}
	if len(blocking) > 0 {
		return "failure", "open blocking findings on head " + short(s.Head) + ": " + strings.Join(blocking, ", ")
	}
	return "success", fmt.Sprintf("%s reviewed head %s: no open blocking finding (notes: %d)", p.Reviewer, short(s.Head), notes)
}

// markerBlocks gives the JSON of each block <!-- <marker> {...} --> in body.
func markerBlocks(body, marker string) []string {
	re := regexp.MustCompile(`(?s)<!--\s*` + regexp.QuoteMeta(marker) + `\s+(\{.*?\})\s*-->`)
	var out []string
	for _, m := range re.FindAllStringSubmatch(body, -1) {
		out = append(out, m[1])
	}
	return out
}

// ruleRefusal gives the reason of the merge rule name, or "" when it passes.
func ruleRefusal(name string, s *prSnapshot, p mergePolicy) string {
	i := slices.IndexFunc(mergeRules, func(r mergeRule) bool { return r.Name == name })
	return mergeRules[i].Refuse(s, p)
}

// codexSummary returns the code review in the Codex summary of the reviewer
// when it records a completed review of head.
func codexSummary(comments []prComment, reviewer, head string) (codexReview, bool) {
	for _, c := range comments {
		if c.Author != reviewer {
			continue
		}
		if r, ok := parseCodexState(c.Body); ok && r.CommitSHA == head && r.Status == "completed" {
			return r, true
		}
	}
	return codexReview{}, false
}

// decisive reports whether a review decides for its author: it approves, it
// requests changes, or a person dismissed it.
func decisive(r prReview) bool {
	return r.State == "APPROVED" || r.State == "CHANGES_REQUESTED" || r.State == "DISMISSED"
}

// newestReview returns the newest review of the head by login that keep
// accepts.
func newestReview(s *prSnapshot, login string, keep func(prReview) bool) (prReview, bool) {
	var newest prReview
	found := false
	for _, r := range s.Reviews {
		if r.Author == login && r.Commit == s.Head && keep(r) && (!found || r.At.After(newest.At)) {
			newest, found = r, true
		}
	}
	return newest, found
}

// approvers returns the logins whose newest decisive review of the head
// approves it, in the order of those approvals.
func approvers(s *prSnapshot) []string {
	newest := map[string]prReview{}
	for _, r := range s.Reviews {
		if old, seen := newest[r.Author]; r.Commit == s.Head && decisive(r) && (!seen || r.At.After(old.At)) {
			newest[r.Author] = r
		}
	}
	var approved []prReview
	for _, r := range newest {
		if r.State == "APPROVED" {
			approved = append(approved, r)
		}
	}
	slices.SortFunc(approved, func(a, b prReview) int {
		return cmp.Or(a.At.Compare(b.At), strings.Compare(a.Author, b.Author))
	})
	logins := make([]string, len(approved))
	for i, r := range approved {
		logins[i] = r.Author
	}
	return logins
}

// approvalRefusal says why the approval of login cannot open the gate, from
// the snapshot alone. With "", the REST API decides (factsRefusal).
func approvalRefusal(s *prSnapshot, login string) string {
	switch {
	case s.Fork:
		return "the pull request comes from a fork, and the activity API of this repository does not show who pushed to it"
	case s.HeadRef == "":
		return "the gate does not know the head branch"
	case strings.HasPrefix(login, "app/"):
		return login + " is a bot, not a person"
	case strings.EqualFold(login, s.Author):
		return login + " is the author"
	}
	return ""
}

// factsRefusal says why the approval of login cannot open the gate, from the
// REST data, or "" when it opens the gate.
func factsRefusal(s *prSnapshot, login string, facts map[string]approverFacts) string {
	f, ok := facts[login]
	switch {
	case !ok:
		return "the gate did not read the access of " + login
	case f.Permission != "admin" && f.Permission != "write":
		return login + " has " + cmp.Or(f.Permission, "no") + " access, not write access"
	case f.Pushed:
		return login + " pushed to " + s.HeadRef
	}
	return ""
}

// checkFinished returns when the check of the head finished: the newest run
// of checkName, or with no checkName, the last of the newest checks when all
// of them are complete. The gate calls it only for a head with no status of
// the gate.
func checkFinished(s *prSnapshot, p mergePolicy) (time.Time, bool) {
	var done time.Time
	found := false
	for _, c := range newestChecks(s.Checks) {
		if p.CheckName != "" && c.Name != p.CheckName {
			continue
		}
		if c.Done.IsZero() {
			return time.Time{}, false
		}
		if c.Done.After(done) {
			done = c.Done
		}
		found = true
	}
	return done, found
}

// The open pull requests, for review-gate.
const openNumbersQuery = `query($o: String!, $r: String!) {
  repository(owner: $o, name: $r) {
    pullRequests(states: OPEN, first: 100, orderBy: {field: CREATED_AT, direction: ASC}) { totalCount nodes { number } }
  }
}`

// For each open pull request, or for one, post the commit status
// <statusPrefix>/review on the head, and print a Markdown table of the
// results. success: the newest review of the exact head by the reviewer has
// no open blocking finding, or a second person approved the head (with
// secondPersonApproval). failure: the review has an open blocking finding. A
// result that the head already has is not posted again. With
// reviewTimeoutHours, a row says when a head waits for a person. The function
// posts no label. The setting statusPrefix must not be empty.
// +cache="never"
func (m *Ci) ReviewGate(
	ctx context.Context,
	// A GitHub token that can read the repository. Without dryRun, it also
	// needs statuses: write.
	token *dagger.Secret,
	// The pull request. With none, each open pull request.
	// +optional
	pr int,
	// Print the results and post nothing.
	// +optional
	dryRun bool,
) (string, error) {
	if m.StatusPrefix == "" {
		return "", errors.New("the statusPrefix setting is empty, so the review gate is off; set statusPrefix in dagger.toml")
	}
	if m.ReviewTimeoutHours < 0 {
		return "", fmt.Errorf("reviewTimeoutHours is %d; use 0 (no timeout) or more", m.ReviewTimeoutHours)
	}
	if pr < 0 {
		return "", fmt.Errorf("pr is %d; give the number of a pull request, or none for each open one", pr)
	}
	g, owner, name, err := m.github(ctx, token)
	if err != nil {
		return "", err
	}
	return m.reviewGates(ctx, g, owner, name, pr, dryRun, time.Now())
}

// reviewGates runs the gate for pull request pr, or for each open pull
// request when pr is 0, at now, and gives the table.
func (m *Ci) reviewGates(ctx context.Context, g *githubClient, owner, name string, pr int, dryRun bool, now time.Time) (string, error) {
	numbers := []int{pr}
	if pr == 0 {
		var out struct {
			Repository struct {
				PullRequests struct {
					TotalCount int
					Nodes      []struct{ Number int }
				}
			}
		}
		if err := g.graphql(ctx, openNumbersQuery, map[string]any{"o": owner, "r": name}, &out); err != nil {
			return "", fmt.Errorf("open pull requests: %w", err)
		}
		prs := out.Repository.PullRequests
		if prs.TotalCount > len(prs.Nodes) {
			return "", fmt.Errorf("%d open pull requests; the review gate reads only %d", prs.TotalCount, len(prs.Nodes))
		}
		numbers = numbers[:0]
		for _, n := range prs.Nodes {
			numbers = append(numbers, n.Number)
		}
	}
	p := m.policy()
	var b strings.Builder
	var failed []string
	b.WriteString("| PR | Head | Review gate | Reason | Action |\n|---|---|---|---|---|\n")
	for _, n := range numbers {
		head, res, action, err := gateOne(ctx, g, owner, name, n, p, dryRun, now)
		if err != nil {
			failed = append(failed, fmt.Sprintf("#%d: %v", n, err))
			action = "error: " + err.Error()
		}
		reason := strings.Join(append([]string{res.Reason}, res.Refused...), "; ")
		fmt.Fprintf(&b, "| #%d | %s | %s | %s | %s |\n", n, short(head), cmp.Or(res.State, "none"),
			strings.ReplaceAll(reason, "|", "\\|"), strings.ReplaceAll(action, "|", "\\|"))
	}
	if dryRun {
		b.WriteString("\nDry run: the review gate posted nothing.\n")
	}
	if len(failed) > 0 {
		return b.String(), fmt.Errorf("review gate: %s", strings.Join(failed, "; "))
	}
	return b.String(), nil
}

// gateOne decides the gate of pull request n and posts a changed result. It
// returns the head, the result and the action.
func gateOne(ctx context.Context, g *githubClient, owner, name string, n int, p mergePolicy, dryRun bool, now time.Time) (string, gateResult, string, error) {
	repo, err := queryPR(ctx, g, owner, name, n)
	if err != nil {
		return "", gateResult{}, "", err
	}
	s := snapshotFrom(repo.PullRequest, repo.DefaultBranchRef.Name, false)
	facts, err := readApprovers(ctx, g, owner, name, &s, p)
	if err != nil {
		return s.Head, gateResult{}, "", err
	}
	res := reviewGate(&s, p, facts, now)
	text := statusText(res.Reason)
	old, posted := p.gateStatusOf(&s)
	switch {
	case res.State == "" && res.NeedsHuman != "":
		return s.Head, res, "needs-human: " + res.NeedsHuman, nil
	case res.State == "":
		return s.Head, res, "none", nil
	case posted && strings.EqualFold(old.State, res.State) && old.Description == text:
		return s.Head, res, "already " + res.State, nil
	case dryRun:
		return s.Head, res, "would post " + res.State, nil
	}
	path := fmt.Sprintf("/repos/%s/%s/statuses/%s", owner, name, s.Head)
	body := map[string]any{"state": res.State, "context": p.gateContext(), "description": text}
	if err := g.rest(ctx, "POST", path, body, nil); err != nil {
		return s.Head, res, "", err
	}
	return s.Head, res, "posted " + res.State, nil
}

// statusText cuts a description to the 140 characters of a commit status.
func statusText(s string) string {
	if r := []rune(s); len(r) > 140 {
		return string(r[:139]) + "…"
	}
	return s
}

// readApprovers reads the REST data of the approvers of the head, in the
// order of their approvals, until one can open the gate. It reads nothing for
// an approval that approvalRefusal refuses, so a fork pull request gets no
// call.
func readApprovers(ctx context.Context, g *githubClient, owner, name string, s *prSnapshot, p mergePolicy) (map[string]approverFacts, error) {
	facts := map[string]approverFacts{}
	if !p.SecondPersonApproval || s.State != "OPEN" || s.ReviewsIncomplete {
		return facts, nil
	}
	for _, login := range approvers(s) {
		if approvalRefusal(s, login) != "" {
			continue
		}
		var perm struct {
			Permission string `json:"permission"`
		}
		path := fmt.Sprintf("/repos/%s/%s/collaborators/%s/permission", owner, name, url.PathEscape(login))
		if err := g.rest(ctx, "GET", path, nil, &perm); err != nil {
			return nil, err
		}
		f := approverFacts{Permission: perm.Permission}
		if f.Permission == "admin" || f.Permission == "write" {
			pushed, err := pushedTo(ctx, g, owner, name, s.HeadRef, login)
			if err != nil {
				return nil, err
			}
			f.Pushed = pushed
		}
		facts[login] = f
		if factsRefusal(s, login, facts) == "" {
			break
		}
	}
	return facts, nil
}

// pushedTo reports whether the activity API lists an activity of login on
// branch, other than a deletion of the branch. The gate reads who pushed
// from the activity API, because a pusher can give a commit any author.
func pushedTo(ctx context.Context, g *githubClient, owner, name, branch, login string) (bool, error) {
	ref := "refs/heads/" + branch
	path := fmt.Sprintf("/repos/%s/%s/activity?%s", owner, name, url.Values{
		"ref": {ref}, "actor": {login}, "per_page": {"100"},
	}.Encode())
	var list []struct {
		Ref          string `json:"ref"`
		ActivityType string `json:"activity_type"`
		Actor        *struct {
			Login string `json:"login"`
		} `json:"actor"`
	}
	if err := g.rest(ctx, "GET", path, nil, &list); err != nil {
		return false, err
	}
	// A full page can hide an activity on the next page.
	if len(list) >= 100 {
		return true, nil
	}
	for _, a := range list {
		if a.Ref == ref && a.Actor != nil && strings.EqualFold(a.Actor.Login, login) && a.ActivityType != "branch_deletion" {
			return true, nil
		}
	}
	return false, nil
}
