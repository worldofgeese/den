package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"slices"
	"strings"
	"time"

	"dagger/ci/internal/dagger"
)

// The shepherd of plan P3. For each open pull request, it asks the reviewer
// to review the head when the head has no review. It writes only the request
// comment and, after the cap, the needs-human label with a comment. It sends
// no review event, and it merges nothing: live merges come in plan P4.

// The only reviewer that answers a comment: `@codex review`.
const codexReviewer = "app/chatgpt-codex-connector"

const (
	// A new head waits this long before the first request, so that the
	// automatic review of an opened pull request can start.
	reviewGrace = 10 * time.Minute
	// The shepherd asks again when a request gets no review for this long.
	reviewWait = 20 * time.Minute
	// After this many requests for one head, a person takes over.
	reviewCap = 3
)

// requestMarker names the head in each request, so that the shepherd counts
// its requests for each head.
func requestMarker(head string) string {
	return "<!-- den-shepherd review-request head=" + head + " -->"
}

type shepherdComment struct {
	Author, Body string
	At           time.Time
}

type shepherdPR struct {
	Number   int
	Draft    bool
	Author   string
	Head     string
	HeadAt   time.Time // the commit time of the head
	Labels   []string
	Comments []shepherdComment
	// CommentsIncomplete: the pull request has more comments than one query
	// reads.
	CommentsIncomplete bool
}

type shepherdStep string

const (
	stepNone       shepherdStep = "none"
	stepRequest    shepherdStep = "request review"
	stepNeedsHuman shepherdStep = "needs-human"
)

// nextStep returns what the shepherd does for a pull request at now, and
// why. It is a pure function, so ci:shepherd-rules tests each case.
func nextStep(pr shepherdPR, p mergePolicy, now time.Time) (shepherdStep, string) {
	if pr.Draft {
		return stepNone, "draft"
	}
	for _, l := range pr.Labels {
		if slices.Contains(stopLabels, l) {
			return stepNone, "label " + l
		}
	}
	if !slices.Contains(p.Authors, pr.Author) {
		return stepNone, "author " + pr.Author + " is not in authors, so the pull request gets checks only"
	}
	if p.Reviewer != codexReviewer {
		return stepNone, "the reviewer setting is not " + codexReviewer
	}
	if pr.CommentsIncomplete {
		return stepNone, "more comments than one query reads; a person looks"
	}
	switch status := codexStatus(pr.Comments, p.Reviewer, pr.Head); status {
	case "completed":
		return stepNone, "reviewed"
	case "", "failed", "error", "cancelled":
		// No review of this head yet, or a failed one: ask.
	default:
		return stepNone, "review of the head is " + status
	}
	n, last := 0, time.Time{}
	for _, c := range pr.Comments {
		if strings.Contains(c.Body, requestMarker(pr.Head)) {
			n++
			if c.At.After(last) {
				last = c.At
			}
		}
	}
	switch {
	case n == 0 && now.Sub(pr.HeadAt) < reviewGrace:
		return stepNone, "new head; the automatic review can start"
	case n == 0:
		return stepRequest, "no review of the head"
	case now.Sub(last) < reviewWait:
		return stepNone, fmt.Sprintf("request %d of %d is recent", n, reviewCap)
	case n < reviewCap:
		return stepRequest, fmt.Sprintf("no review %s after request %d", reviewWait, n)
	default:
		return stepNeedsHuman, fmt.Sprintf("no review after %d requests", n)
	}
}

// codexStatus returns the status of the reviewer's review of head, from the
// state in the summary comment of the Codex connector, or "" when the
// summary names another head.
func codexStatus(comments []shepherdComment, reviewer, head string) string {
	for _, c := range comments {
		if c.Author != reviewer {
			continue
		}
		if r, ok := parseCodexState(c.Body); ok && r.CommitSHA == head {
			return r.Status
		}
	}
	return ""
}

const openPRsQuery = `query($o: String!, $r: String!) {
  repository(owner: $o, name: $r) {
    pullRequests(states: OPEN, first: 50, orderBy: {field: CREATED_AT, direction: ASC}) {
      totalCount
      nodes {
        number isDraft headRefOid
        author { __typename login }
        labels(first: 50) { nodes { name } }
        commits(last: 1) { nodes { commit { committedDate } } }
        comments(first: 100) { totalCount nodes { author { __typename login } body createdAt } }
      }
    }
  }
}`

type gqlOpenPR struct {
	Number     int
	IsDraft    bool
	HeadRefOid string
	Author     *gqlActor
	Labels     struct{ Nodes []struct{ Name string } }
	Commits    struct {
		Nodes []struct {
			Commit struct{ CommittedDate time.Time }
		}
	}
	Comments struct {
		TotalCount int
		Nodes      []struct {
			Author    *gqlActor
			Body      string
			CreatedAt time.Time
		}
	}
}

func shepherdPRFrom(n gqlOpenPR) shepherdPR {
	pr := shepherdPR{Number: n.Number, Draft: n.IsDraft, Author: n.Author.name(), Head: n.HeadRefOid}
	for _, l := range n.Labels.Nodes {
		pr.Labels = append(pr.Labels, l.Name)
	}
	if len(n.Commits.Nodes) > 0 {
		pr.HeadAt = n.Commits.Nodes[0].Commit.CommittedDate
	}
	for _, c := range n.Comments.Nodes {
		pr.Comments = append(pr.Comments, shepherdComment{Author: c.Author.name(), Body: c.Body, At: c.CreatedAt})
	}
	pr.CommentsIncomplete = n.Comments.TotalCount > len(n.Comments.Nodes)
	return pr
}

// For each open pull request, ask the reviewer to review the head when the
// head has no review (plan P3), and print a Markdown table of the steps.
// After 3 requests without a review, add the needs-human label. With
// dryRun, post nothing.
// +cache="never"
func (m *Ci) Shepherd(
	ctx context.Context,
	// A GitHub token. Without dryRun, it needs write access to issues and
	// pull requests.
	token *dagger.Secret,
	// Print the steps and post nothing.
	// +optional
	dryRun bool,
) (string, error) {
	g, owner, name, err := m.github(ctx, token)
	if err != nil {
		return "", err
	}
	var out struct {
		Repository struct {
			PullRequests struct {
				TotalCount int
				Nodes      []gqlOpenPR
			}
		}
	}
	if err := g.graphql(ctx, openPRsQuery, map[string]any{"o": owner, "r": name}, &out); err != nil {
		return "", fmt.Errorf("open pull requests: %w", err)
	}
	prs := out.Repository.PullRequests
	if prs.TotalCount > len(prs.Nodes) {
		return "", fmt.Errorf("%d open pull requests; the shepherd reads only %d", prs.TotalCount, len(prs.Nodes))
	}
	now := time.Now()
	var b strings.Builder
	b.WriteString("| PR | Head | Step | Reason |\n|---|---|---|---|\n")
	for _, n := range prs.Nodes {
		pr := shepherdPRFrom(n)
		step, why := nextStep(pr, m.policy(), now)
		if !dryRun {
			if err := m.post(ctx, g, owner, name, pr, step); err != nil {
				return b.String(), fmt.Errorf("#%d: %w", pr.Number, err)
			}
		}
		fmt.Fprintf(&b, "| #%d | %s | %s | %s |\n", pr.Number, short(pr.Head), step, why)
	}
	if dryRun {
		b.WriteString("\nDry run: the shepherd posted nothing.\n")
	}
	return b.String(), nil
}

// post writes the step of a pull request to GitHub.
func (m *Ci) post(ctx context.Context, g *githubClient, owner, name string, pr shepherdPR, step shepherdStep) error {
	issue := fmt.Sprintf("/repos/%s/%s/issues/%d", owner, name, pr.Number)
	switch step {
	case stepRequest:
		return g.rest(ctx, "POST", issue+"/comments", map[string]any{
			"body": "@codex review\n\n" + requestMarker(pr.Head),
		})
	case stepNeedsHuman:
		if err := g.rest(ctx, "POST", issue+"/labels", map[string]any{"labels": []string{"needs-human"}}); err != nil {
			return err
		}
		return g.rest(ctx, "POST", issue+"/comments", map[string]any{
			"body": fmt.Sprintf("The shepherd asked %s %d times to review head %s, and no review came. "+
				"A person must review this pull request. Remove the label needs-human to let the automation continue.",
				strings.TrimPrefix(codexReviewer, "app/"), reviewCap, short(pr.Head)),
		})
	}
	return nil
}

// rest calls the GitHub REST API with a JSON body.
func (g *githubClient) rest(ctx context.Context, method, path string, body any) error {
	data, err := json.Marshal(body)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, method, "https://api.github.com"+path, bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "bearer "+g.token)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	resp, err := g.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("GitHub REST %s %s: HTTP %d", method, path, resp.StatusCode)
	}
	return nil
}
