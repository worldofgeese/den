package main

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"maps"
	"net/url"
	"slices"
	"strings"
	"time"

	"dagger/ci/internal/dagger"
)

// GitHub holds each pull_request run of a push or of a pull request that a
// job made with its GITHUB_TOKEN (status action_required) until someone
// approves it. approve-bot-runs approves those runs after the push, so that
// the head gets its checks. It approves no run of a fork: a person approves
// those.

// The waits of the approval loop. The runs appear some seconds after the
// push, and a run of one workflow can start a run of another workflow.
const (
	approvalPoll   = 10 * time.Second
	approvalQuiet  = 30 * time.Second
	approvalGiveUp = 3 * time.Minute
)

// Approve the pull_request runs that GitHub holds for approval
// (action_required) on a head that a job pushed with its GITHUB_TOKEN. Call
// it after the push, with the token of that job. It approves each held run
// of this repository on the head. It looks again every 10 seconds, until no
// run waits 30 seconds after the last approval, or until 3 minutes pass. A
// run of a fork stays held for a person. It fails only when runs waited and
// GitHub approved none of them: then the token needs actions: write. The
// setting approveBotRuns must be true.
// +cache="never"
func (m *Ci) ApproveBotRuns(
	ctx context.Context,
	// A GitHub token with actions: write, for example the GITHUB_TOKEN of
	// the job that pushed.
	token *dagger.Secret,
	// The full SHA of the head commit that the job pushed.
	sha string,
) (string, error) {
	if !m.ApprovesBotRuns {
		return "", errors.New("the approveBotRuns setting is off, so the module approves no run; set approveBotRuns = true in dagger.toml")
	}
	if !commitSHA.MatchString(sha) {
		return "", fmt.Errorf("sha is %q; give the full commit SHA, 40 lowercase hexadecimal digits", sha)
	}
	g, owner, name, err := m.github(ctx, token)
	if err != nil {
		return "", err
	}
	return liveApproval.approve(ctx, g, owner, name, sha)
}

// runApproval is how the approval loop waits. The checks give it a fake
// clock (approve_checks.go).
type runApproval struct {
	poll, quiet, giveUp time.Duration
	now                 func() time.Time
	sleep               func(context.Context, time.Duration) error
}

var liveApproval = runApproval{
	poll: approvalPoll, quiet: approvalQuiet, giveUp: approvalGiveUp,
	now: time.Now, sleep: sleepContext,
}

// sleepContext waits d, or until ctx ends.
func sleepContext(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

// heldRun is a workflow run in the JSON of the REST API. GitHub gives a held
// run the status completed and the conclusion action_required.
type heldRun struct {
	ID             int64  `json:"id"`
	HeadSHA        string `json:"head_sha"`
	Conclusion     string `json:"conclusion"`
	HeadRepository struct {
		FullName string `json:"full_name"`
	} `json:"head_repository"`
}

// approvalReport is what one approval loop did.
type approvalReport struct {
	approved []int64
	// failed has the last error of each run that GitHub did not approve.
	failed map[int64]string
	// foreign has the head repository of each held run of another
	// repository.
	foreign map[int64]string
	// listErrors counts the lists that failed. lastListError is the error of
	// the last one.
	listErrors    int
	lastListError string
	// gaveUp: the give-up time passed before a quiet period.
	gaveUp bool
}

// approve approves each run of owner/name that waits for approval on sha.
// Before each list, it stops when giveUp has passed. After each list, it
// stops when no run of the repository waits and a quiet period has passed
// after the last approval. Before the first approval, it looks until giveUp,
// because the runs can appear late. A run of another head or of another
// repository stays held.
func (a runApproval) approve(ctx context.Context, g *githubClient, owner, name, sha string) (string, error) {
	repo := owner + "/" + name
	list := fmt.Sprintf("/repos/%s/%s/actions/runs?%s", owner, name, url.Values{
		"head_sha": {sha}, "status": {"action_required"}, "per_page": {"100"},
	}.Encode())
	r := approvalReport{failed: map[int64]string{}, foreign: map[int64]string{}}
	start := a.now()
	var last time.Time
	for {
		if a.now().Sub(start) >= a.giveUp {
			r.gaveUp = true
			break
		}
		var page struct {
			Runs []heldRun `json:"workflow_runs"`
		}
		listed := true
		if err := g.rest(ctx, "GET", list, nil, &page); err != nil {
			r.listErrors++
			r.lastListError = err.Error()
			listed = false
		}
		waiting := 0
		for _, run := range page.Runs {
			switch {
			case run.HeadSHA != sha || run.Conclusion != "action_required" || slices.Contains(r.approved, run.ID):
				// Another head, a run that does not wait, or a run that GitHub
				// lists again for a short time after its approval.
			case !strings.EqualFold(run.HeadRepository.FullName, repo):
				r.foreign[run.ID] = cmp.Or(run.HeadRepository.FullName, "a deleted repository")
			default:
				path := fmt.Sprintf("/repos/%s/%s/actions/runs/%d/approve", owner, name, run.ID)
				if err := g.rest(ctx, "POST", path, nil, nil); err != nil {
					r.failed[run.ID] = err.Error()
					waiting++
					continue
				}
				delete(r.failed, run.ID)
				r.approved = append(r.approved, run.ID)
				last = a.now()
			}
		}
		if len(r.approved) > 0 && listed && waiting == 0 && a.now().Sub(last) >= a.quiet {
			break
		}
		if err := a.sleep(ctx, a.poll); err != nil {
			return "", fmt.Errorf("%w\n%s", err, r.text(repo, sha))
		}
	}
	if len(r.approved) == 0 && len(r.failed) > 0 {
		return "", fmt.Errorf("%s waited for approval on %s, and GitHub approved none: the token needs actions: write\n%s",
			countRuns(len(r.failed)), short(sha), r.text(repo, sha))
	}
	return r.text(repo, sha), nil
}

// text says what the loop did, one line for each part.
func (r approvalReport) text(repo, sha string) string {
	var b strings.Builder
	switch {
	case len(r.approved) > 0:
		ids := make([]string, len(r.approved))
		for i, id := range r.approved {
			ids[i] = fmt.Sprint(id)
		}
		fmt.Fprintf(&b, "Approved %s of %s on %s: %s.\n", countRuns(len(r.approved)), repo, short(sha), strings.Join(ids, ", "))
	case len(r.failed) == 0:
		fmt.Fprintf(&b, "No run of %s waited for approval on %s.\n", repo, short(sha))
	}
	for _, id := range slices.Sorted(maps.Keys(r.failed)) {
		fmt.Fprintf(&b, "Could not approve run %d: %s.\n", id, r.failed[id])
	}
	for _, id := range slices.Sorted(maps.Keys(r.foreign)) {
		fmt.Fprintf(&b, "Left run %d of %s held for a person: it is not a run of %s.\n", id, r.foreign[id], repo)
	}
	if r.listErrors > 0 {
		fmt.Fprintf(&b, "%d lists of the held runs failed. The last error: %s.\n", r.listErrors, r.lastListError)
	}
	if r.gaveUp && len(r.approved) > 0 {
		b.WriteString("Stopped at the give-up time, before a quiet period after the last approval.\n")
	}
	return b.String()
}

// countRuns is "1 run" or "<n> runs".
func countRuns(n int) string {
	if n == 1 {
		return "1 run"
	}
	return fmt.Sprintf("%d runs", n)
}
