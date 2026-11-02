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
// no review event. With merge (plan P4, step 2), it merges at most one pull
// request per run that the merge rules accept.

// The only reviewer that answers a comment: `@codex review`.
const codexReviewer = "app/chatgpt-codex-connector"

const (
	// A new pull request waits this long before the first request, so that
	// the automatic review of Codex can start.
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
// why. self is the login of the shepherd's token: only its own requests
// count, because anyone can comment on a public repository. It is a pure
// function, so ci:shepherd-rules tests each case.
func nextStep(pr shepherdPR, p mergePolicy, self string, now time.Time) (shepherdStep, string) {
	if pr.Draft {
		return stepNone, "draft"
	}
	for _, l := range pr.Labels {
		if slices.Contains(stopLabels, l) {
			return stepNone, "label " + l
		}
	}
	if !p.allowsAuthor(pr.Author) {
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
		if c.Author == self && strings.Contains(c.Body, requestMarker(pr.Head)) {
			n++
			if c.At.After(last) {
				last = c.At
			}
		}
	}
	switch {
	// Codex reviews by itself only when a pull request opens. After its
	// first summary, no review comes without a request.
	case n == 0 && !hasCodexSummary(pr.Comments, p.Reviewer) && now.Sub(pr.HeadAt) < reviewGrace:
		return stepNone, "new pull request; the automatic review can start"
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

// hasCodexSummary reports whether the reviewer posted its summary comment,
// for any head.
func hasCodexSummary(comments []shepherdComment, reviewer string) bool {
	for _, c := range comments {
		if c.Author == reviewer {
			if _, ok := parseCodexState(c.Body); ok {
				return true
			}
		}
	}
	return false
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
  viewer { login }
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
// After 3 requests without a review, add the needs-human label. The table
// also gives the verdict of the merge rules for each pull request (plan P4).
// With merge, it merges the first accepted pull request, pinned to the head
// commit that the rules judged. With forkPolicy review-and-suggest, a fork
// pull request that conflicts gets the needs-human label with a comment
// (fork.go). With dryRun, post and merge nothing.
// +cache="never"
func (m *Ci) Shepherd(
	ctx context.Context,
	// A GitHub token. Without dryRun, it needs write access to issues and
	// pull requests.
	token *dagger.Secret,
	// Print the steps and post nothing.
	// +optional
	dryRun bool,
	// Merge at most one pull request that the merge rules accept (plan P4,
	// step 2). The token then needs write access to contents.
	// +optional
	merge bool,
) (string, error) {
	g, owner, name, err := m.github(ctx, token)
	if err != nil {
		return "", err
	}
	return m.shepherd(ctx, g, owner, name, dryRun, merge, time.Now())
}

// shepherd runs the shepherd at now, and gives the table.
func (m *Ci) shepherd(ctx context.Context, g *githubClient, owner, name string, dryRun, merge bool, now time.Time) (string, error) {
	var out struct {
		Viewer     struct{ Login string }
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
	var b strings.Builder
	var failed []string
	merged := false
	b.WriteString("| PR | Head | Review step | Reason | Merge verdict |\n|---|---|---|---|---|\n")
	for _, n := range prs.Nodes {
		pr := shepherdPRFrom(n)
		step, why := nextStep(pr, m.policy(), out.Viewer.Login, now)
		if !dryRun {
			if err := m.post(ctx, g, owner, name, pr, step); err != nil {
				return b.String(), fmt.Errorf("#%d: %w", pr.Number, err)
			}
		}
		// The shepherd says what the merge rules decide. With merge, it merges
		// the first pull request that they accept. A merge changes the base
		// of the others, so the next run judges them again.
		verdict := ""
		if repo, err := m.fetch(ctx, g, owner, name, pr.Number); err != nil {
			verdict = "error: " + err.Error()
			failed = append(failed, fmt.Sprintf("#%d: %v", pr.Number, err))
		} else {
			ok, text, head, method := m.decision(repo)
			verdict = text
			switch {
			case !ok || !merge || dryRun:
			case merged:
				verdict += "; waits for the next run (one merge per run)"
			default:
				path := fmt.Sprintf("/repos/%s/%s/pulls/%d/merge", owner, name, pr.Number)
				if err := g.rest(ctx, "PUT", path, map[string]any{"sha": head, "merge_method": method}, nil); err != nil {
					verdict = "merge failed: " + err.Error()
					failed = append(failed, fmt.Sprintf("#%d: %v", pr.Number, err))
				} else {
					verdict = fmt.Sprintf("merged head %s with the %s method", short(head), method)
				}
				merged = true
			}
			if action, err := m.forkStep(ctx, g, owner, name, repo, dryRun); err != nil {
				verdict += "; needs-human failed: " + err.Error()
				failed = append(failed, fmt.Sprintf("#%d: %v", pr.Number, err))
			} else if action != "" {
				verdict += "; " + action
			}
		}
		fmt.Fprintf(&b, "| #%d | %s | %s | %s | %s |\n", pr.Number, short(pr.Head), step, why, verdict)
	}
	if dryRun {
		b.WriteString("\nDry run: the shepherd posted nothing.\n")
	}
	if len(failed) > 0 {
		return b.String(), fmt.Errorf("merge verdicts: %s", strings.Join(failed, "; "))
	}
	return b.String(), nil
}

// forkStep takes the action of the fork policy for a pull request, and says
// what it did. With no action, it returns "".
func (m *Ci) forkStep(ctx context.Context, g *githubClient, owner, name string, repo *gqlRepo, dryRun bool) (string, error) {
	s := snapshotFrom(repo.PullRequest, repo.DefaultBranchRef.Name, false)
	why := forkAction(&s, m.policy())
	switch {
	case why == "":
		return "", nil
	case dryRun:
		return "would add needs-human: " + why, nil
	}
	issue := fmt.Sprintf("/repos/%s/%s/issues/%d", owner, name, s.Number)
	if err := g.rest(ctx, "POST", issue+"/labels", map[string]any{"labels": []string{"needs-human"}}, nil); err != nil {
		return "", err
	}
	if err := g.rest(ctx, "POST", issue+"/comments", map[string]any{"body": forkComment(&s)}, nil); err != nil {
		return "", err
	}
	return "added needs-human: " + why, nil
}

// post writes the step of a pull request to GitHub.
func (m *Ci) post(ctx context.Context, g *githubClient, owner, name string, pr shepherdPR, step shepherdStep) error {
	issue := fmt.Sprintf("/repos/%s/%s/issues/%d", owner, name, pr.Number)
	switch step {
	case stepRequest:
		return g.rest(ctx, "POST", issue+"/comments", map[string]any{
			"body": "@codex review\n\n" + requestMarker(pr.Head),
		}, nil)
	case stepNeedsHuman:
		if err := g.rest(ctx, "POST", issue+"/labels", map[string]any{"labels": []string{"needs-human"}}, nil); err != nil {
			return err
		}
		return g.rest(ctx, "POST", issue+"/comments", map[string]any{
			"body": fmt.Sprintf("The shepherd asked %s %d times to review head %s, and no review came. "+
				"A person must review this pull request. Remove the label needs-human to let the automation continue.",
				strings.TrimPrefix(codexReviewer, "app/"), reviewCap, short(pr.Head)),
		}, nil)
	}
	return nil
}

// rest calls the GitHub REST API. A body that is not nil goes as JSON, and
// an out that is not nil gets the JSON of the reply.
func (g *githubClient) rest(ctx context.Context, method, path string, body, out any) error {
	var data []byte
	if body != nil {
		var err error
		if data, err = json.Marshal(body); err != nil {
			return err
		}
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
	if out == nil {
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(out)
}
