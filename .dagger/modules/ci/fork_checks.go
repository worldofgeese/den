package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"slices"
	"strings"
	"time"
)

// fakeShepherd serves, in process, the GitHub API that the shepherd uses: the
// two GraphQL queries, the label and comment of an issue, and the merge. It
// records each request, and each request that the shepherd must not send,
// for example an update of a branch.
type fakeShepherd struct {
	pr *gqlPR
	// labelError: each label request gets HTTP 500.
	labelError bool
	requests   []string
	// The labels, the comment bodies and the merge bodies that the shepherd
	// posted.
	labels, comments, merges []string
	problems                 []string
}

func (f *fakeShepherd) RoundTrip(req *http.Request) (*http.Response, error) {
	if req.URL.Host != "api.github.com" || req.Header.Get("Authorization") != "bearer "+fakeToken {
		f.problems = append(f.problems, "a request without the token: "+req.Method+" "+req.URL.String())
		return reply(http.StatusUnauthorized, `{"message":"Bad credentials"}`), nil
	}
	f.requests = append(f.requests, req.Method+" "+req.URL.Path)
	issue := fmt.Sprintf("/repos/%s/issues/%d", fakeRepo, f.pr.Number)
	var body struct {
		Query     string
		Variables struct{ N int }
		Labels    []string
		Body      string
		Sha       string
		Method    string `json:"merge_method"`
	}
	if req.Body != nil {
		if err := json.NewDecoder(req.Body).Decode(&body); err != nil && req.Method != http.MethodGet {
			return nil, err
		}
	}
	switch path := req.URL.Path; {
	case req.Method == http.MethodPost && path == "/graphql":
		var data any
		switch body.Query {
		case openPRsQuery:
			data = map[string]any{"viewer": map[string]any{"login": "den-shepherd"},
				"repository": map[string]any{"pullRequests": map[string]any{"totalCount": 1, "nodes": []any{openPRFrom(f.pr)}}}}
		case prQuery:
			if body.Variables.N != f.pr.Number {
				f.problems = append(f.problems, fmt.Sprintf("a query of pull request %d, which does not exist", body.Variables.N))
			}
			data = map[string]any{"repository": gqlRepo{DefaultBranchRef: struct{ Name string }{"main"},
				MergeCommitAllowed: true, PullRequest: f.pr}}
		default:
			f.problems = append(f.problems, "an unexpected query")
		}
		out, err := json.Marshal(map[string]any{"data": data})
		if err != nil {
			return nil, err
		}
		return reply(http.StatusOK, string(out)), nil
	case req.Method == http.MethodPost && path == issue+"/labels":
		if f.labelError {
			return reply(http.StatusInternalServerError, `{"message":"Server Error"}`), nil
		}
		f.labels = append(f.labels, body.Labels...)
		return reply(http.StatusOK, `[]`), nil
	case req.Method == http.MethodPost && path == issue+"/comments":
		f.comments = append(f.comments, body.Body)
		return reply(http.StatusCreated, `{}`), nil
	case req.Method == http.MethodPut && path == fmt.Sprintf("/repos/%s/pulls/%d/merge", fakeRepo, f.pr.Number):
		f.merges = append(f.merges, body.Sha+" "+body.Method)
		return reply(http.StatusOK, `{"merged":true}`), nil
	}
	f.problems = append(f.problems, "an unexpected request: "+req.Method+" "+req.URL.String())
	return reply(http.StatusNotFound, `{"message":"Not Found"}`), nil
}

// openPRFrom gives a pull request in the shape of openPRsQuery. The head
// commit is from one hour before fixtureTime, and so are the comments.
func openPRFrom(pr *gqlPR) gqlOpenPR {
	at := fixtureTime.Add(-time.Hour)
	n := gqlOpenPR{Number: pr.Number, IsDraft: pr.IsDraft, HeadRefOid: pr.HeadRefOid, Author: pr.Author, Labels: pr.Labels}
	n.Commits.Nodes = append(n.Commits.Nodes, struct {
		Commit struct{ CommittedDate time.Time }
	}{struct{ CommittedDate time.Time }{at}})
	for _, c := range pr.Comments.Nodes {
		n.Comments.Nodes = append(n.Comments.Nodes, struct {
			Author    *gqlActor
			Body      string
			CreatedAt time.Time
		}{c.Author, c.Body, at})
	}
	n.Comments.TotalCount = len(n.Comments.Nodes)
	return n
}

// forkPR is gatePR with a clean Codex review of the head: the merge rules
// accept it with forkSettings. fork moves its head branch to a fork.
func forkPR(fork bool) *gqlPR {
	pr := gatePR()
	pr.IsCrossRepository = fork
	summary(fixtureHead, "completed", "false")(pr)
	return pr
}

func conflict(pr *gqlPR) { pr.Mergeable, pr.MergeStateStatus = "CONFLICTING", "DIRTY" }

func label(name string) func(*gqlPR) {
	return func(pr *gqlPR) { pr.Labels.Nodes = append(pr.Labels.Nodes, struct{ Name string }{name}) }
}

// forkSettings are den's settings with the author alice and a fork policy.
func forkSettings(policy string) *Ci {
	return &Ci{Repository: fakeRepo, Authors: []string{"alice"}, Reviewer: codexReviewer,
		RiskyPaths: []string{"secrets/"}, ForkPolicy: policy}
}

type forkCase struct {
	name   string
	policy string
	fork   bool
	edits  []func(*gqlPR)
	dryRun bool
	// labelError: the label API fails. err: a part of the wanted error.
	labelError bool
	err        string
	// noMerge: the shepherd runs without --merge.
	noMerge bool
	// The wanted needs-human label and comment, and the wanted merge.
	needsHuman, merge bool
	// Parts of the table that it must have and must not have.
	text, notText []string
}

func forkCases() []forkCase {
	head := short(fixtureHead)
	conflicts := "fork head " + head + " conflicts with main; the token cannot update a fork, so a person resolves the conflict"
	refused := "would not merge (mergeable): mergeable is CONFLICTING"
	merged := "merged head " + head + " with the merge method"
	return []forkCase{
		// As written: review-and-suggest.
		{name: "review-and-suggest: a fork that conflicts gets needs-human", policy: forkReviewAndSuggest, fork: true,
			edits: []func(*gqlPR){conflict}, needsHuman: true, text: []string{refused + "; added needs-human: " + conflicts}},
		{name: "review-and-suggest: without --merge, a fork that conflicts also gets needs-human", policy: forkReviewAndSuggest, fork: true,
			edits: []func(*gqlPR){conflict}, noMerge: true, needsHuman: true, text: []string{refused + "; added needs-human: " + conflicts}},
		{name: "review-and-suggest: a dry run only reports the action", policy: forkReviewAndSuggest, fork: true,
			edits: []func(*gqlPR){conflict}, dryRun: true, text: []string{refused + "; would add needs-human: " + conflicts}},
		{name: "review-and-suggest: a fork that passes each rule merges", policy: forkReviewAndSuggest, fork: true,
			merge: true, text: []string{merged}, notText: []string{"needs-human"}},
		{name: "review-and-suggest: a fork behind main without a conflict merges as it is", policy: forkReviewAndSuggest, fork: true,
			edits: []func(*gqlPR){func(pr *gqlPR) { pr.BaseRefOid = "b0" }}, merge: true, text: []string{merged}},
		{name: "review-and-suggest: a fork that a rule refuses does not merge", policy: forkReviewAndSuggest, fork: true,
			edits: []func(*gqlPR){func(pr *gqlPR) { pr.Files.Nodes = append(pr.Files.Nodes, struct{ Path string }{"secrets/a.age"}) }},
			text:  []string{"would not merge (risky-paths)"}, notText: []string{"needs-human"}},
		{name: "review-and-suggest: a fork from an author outside authors does not merge", policy: forkReviewAndSuggest, fork: true,
			edits: []func(*gqlPR){func(pr *gqlPR) { pr.Author = actor("mallory") }},
			text:  []string{"would not merge (author)"}, notText: []string{"needs-human"}},
		{name: "review-and-suggest: a fork with needs-human gets no second label", policy: forkReviewAndSuggest, fork: true,
			edits: []func(*gqlPR){conflict, label("needs-human")}, text: []string{"would not merge (labels): labelled needs-human"},
			notText: []string{"added needs-human"}},
		{name: "review-and-suggest: a stop label in another case stops the action", policy: forkReviewAndSuggest, fork: true,
			edits: []func(*gqlPR){conflict, label("Hold")}, notText: []string{"added needs-human"}},
		{name: "review-and-suggest: a draft fork that conflicts gets no action", policy: forkReviewAndSuggest, fork: true,
			edits: []func(*gqlPR){conflict, func(pr *gqlPR) { pr.IsDraft = true }}, notText: []string{"needs-human"}},
		{name: "review-and-suggest: a failed label fails the run and posts no comment", policy: forkReviewAndSuggest, fork: true,
			edits: []func(*gqlPR){conflict}, labelError: true, err: "#1: GitHub REST POST /repos/owner/name/issues/1/labels: HTTP 500",
			text: []string{refused + "; needs-human failed: GitHub REST POST"}},
		{name: "review-and-suggest: a fork that merged after the list gets no action", policy: forkReviewAndSuggest, fork: true,
			edits: []func(*gqlPR){conflict, func(pr *gqlPR) { pr.State = "MERGED" }},
			text:  []string{"would not merge (open): the pull request is merged"}, notText: []string{"needs-human"}},
		{name: "review-and-suggest: a fork whose mergeable state is unknown gets no action", policy: forkReviewAndSuggest, fork: true,
			edits: []func(*gqlPR){func(pr *gqlPR) { pr.Mergeable, pr.MergeStateStatus = "UNKNOWN", "UNKNOWN" }},
			text:  []string{"would not merge (mergeable): mergeable is UNKNOWN"}, notText: []string{"needs-human"}},
		// Switched off: no setting, and checks-only, are den's behavior.
		{name: "no forkPolicy: a fork that conflicts gets no action", fork: true,
			edits: []func(*gqlPR){conflict}, text: []string{refused + " |"}, notText: []string{"needs-human"}},
		{name: "checks-only: a fork that conflicts gets no action", policy: forkChecksOnly, fork: true,
			edits: []func(*gqlPR){conflict}, text: []string{refused + " |"}, notText: []string{"needs-human"}},
		{name: "no forkPolicy: a fork that passes each rule merges, as in den", fork: true,
			merge: true, text: []string{merged}},
		// Inverted: the action is only for a fork, and only for a conflict.
		{name: "review-and-suggest: a branch of the repository that conflicts gets no action", policy: forkReviewAndSuggest,
			edits: []func(*gqlPR){conflict}, text: []string{refused + " |"}, notText: []string{"needs-human"}},
		{name: "review-and-suggest: a branch of the repository merges", policy: forkReviewAndSuggest,
			merge: true, text: []string{merged}},
	}
}

func (c forkCase) check(ctx context.Context) []string {
	pr := forkPR(c.fork)
	for _, edit := range c.edits {
		edit(pr)
	}
	f := &fakeShepherd{pr: pr, labelError: c.labelError}
	g := &githubClient{token: fakeToken, http: &http.Client{Transport: f}}
	text, err := forkSettings(c.policy).shepherd(ctx, g, "owner", "name", c.dryRun, !c.noMerge, fixtureTime)
	var failed []string
	fail := func(format string, args ...any) {
		failed = append(failed, fmt.Sprintf("fork case %q: ", c.name)+fmt.Sprintf(format, args...))
	}
	switch {
	case c.err == "" && err != nil:
		fail("error %v", err)
	case c.err != "" && (err == nil || !strings.Contains(err.Error(), c.err)):
		fail("error %v, want one with %q", err, c.err)
	}
	for _, want := range c.text {
		if !strings.Contains(text, want) {
			fail("the table has no %q:\n%s", want, text)
		}
	}
	for _, not := range c.notText {
		if strings.Contains(text, not) {
			fail("the table has %q:\n%s", not, text)
		}
	}
	switch {
	case c.needsHuman && (!slices.Equal(f.labels, []string{"needs-human"}) || len(f.comments) != 1 ||
		!strings.Contains(f.comments[0], "Head "+short(fixtureHead)+" of this pull request conflicts with main") ||
		!strings.Contains(f.comments[0], "remove the label needs-human")):
		fail("labels %q and comments %q, want needs-human with the conflict comment", f.labels, f.comments)
	case !c.needsHuman && (len(f.labels) > 0 || len(f.comments) > 0):
		fail("labels %q and comments %q, want none", f.labels, f.comments)
	}
	switch {
	case c.merge && !slices.Equal(f.merges, []string{fixtureHead + " merge"}):
		fail("merges %q, want one of head %s", f.merges, fixtureHead)
	case !c.merge && len(f.merges) > 0:
		fail("merges %q, want none", f.merges)
	}
	// The shepherd never writes to the head branch: no update of the branch,
	// no push and no change of a ref.
	for _, r := range f.requests {
		if strings.Contains(r, "update-branch") || strings.Contains(r, "/git/") || strings.Contains(r, "/contents/") {
			fail("the shepherd sent %s", r)
		}
	}
	for _, p := range f.problems {
		fail("%s", p)
	}
	return failed
}

// forkTableCases: with each fork policy, the table of a pull request with
// no action is the same, so a policy changes only the action.
func forkTableCases(ctx context.Context) []string {
	var failed []string
	for _, fork := range []bool{false, true} {
		for _, edit := range []func(*gqlPR){func(*gqlPR) {}, conflict, label("hold")} {
			tables := map[string]string{}
			for _, policy := range []string{"", forkChecksOnly, forkReviewAndSuggest} {
				pr := forkPR(fork)
				edit(pr)
				f := &fakeShepherd{pr: pr}
				g := &githubClient{token: fakeToken, http: &http.Client{Transport: f}}
				text, err := forkSettings(policy).shepherd(ctx, g, "owner", "name", true, false, fixtureTime)
				if err != nil {
					failed = append(failed, fmt.Sprintf("fork table case: policy %q: %v", policy, err))
				}
				tables[policy] = text
			}
			if tables[""] != tables[forkChecksOnly] {
				failed = append(failed, fmt.Sprintf("fork table case: fork %t: checks-only gives\n%s\nand no policy gives\n%s", fork, tables[forkChecksOnly], tables[""]))
			}
			action := strings.Contains(tables[forkReviewAndSuggest], "would add needs-human")
			if want := fork && conflictsWithoutStop(edit); action != want {
				failed = append(failed, fmt.Sprintf("fork table case: fork %t: review-and-suggest action %t, want %t:\n%s", fork, action, want, tables[forkReviewAndSuggest]))
			}
			if !action && tables[forkReviewAndSuggest] != tables[""] {
				failed = append(failed, fmt.Sprintf("fork table case: fork %t: review-and-suggest gives\n%s\nand no policy gives\n%s", fork, tables[forkReviewAndSuggest], tables[""]))
			}
		}
	}
	return failed
}

// conflictsWithoutStop reports whether edit makes a pull request that
// conflicts and has no stop label.
func conflictsWithoutStop(edit func(*gqlPR)) bool {
	pr := forkPR(true)
	edit(pr)
	return pr.Mergeable == "CONFLICTING" && len(pr.Labels.Nodes) == 0
}

// forkCallCases: a forkPolicy that the module does not know refuses before
// any GitHub call. The token is nil, so a call to GitHub fails the case.
func forkCallCases(ctx context.Context) []string {
	var failed []string
	for _, policy := range []string{"review-and-fix", "Checks-Only", "suggest"} {
		out, err := shepherdCall(ctx, forkSettings(policy))
		if err == nil || !strings.Contains(err.Error(), fmt.Sprintf("forkPolicy is %q", policy)) {
			failed = append(failed, fmt.Sprintf("fork call %q: %q, %v; want the forkPolicy error", policy, out, err))
		}
	}
	return failed
}

// shepherdCall calls the shepherd with a nil token. A call that passes the
// checks reads the token and panics, and shepherdCall gives that panic as an
// error.
func shepherdCall(ctx context.Context, m *Ci) (out string, err error) {
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("it passed the checks and read the token: %v", r)
		}
	}()
	return m.Shepherd(ctx, nil, true, false)
}
