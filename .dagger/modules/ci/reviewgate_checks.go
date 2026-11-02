package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"slices"
	"strings"
	"time"
)

// review-gate posts the expected commit status for fixed pull requests,
// against a fake GitHub API: both ways to read the reviewer, a review of an
// older head, second-person approvals and their refusals, the review
// timeout, and the posting rules. With statusPrefix empty, it refuses before
// any GitHub call. No network and no token.
// +check
func (m *Ci) ReviewGateRules(ctx context.Context) error {
	var failed []string
	for _, c := range gateCases() {
		failed = append(failed, c.check(ctx)...)
	}
	failed = append(failed, gateCallCases(ctx)...)
	failed = append(failed, fetchCases(ctx)...)
	if len(failed) > 0 {
		return errors.New(strings.Join(failed, "\n"))
	}
	return nil
}

// fakeActivity is an item of the activity API.
type fakeActivity struct{ ref, actor, kind string }

// fakeStatus is a commit status that the gate posted.
type fakeStatus struct{ sha, state, context, description string }

// fakeGate serves, in process, the GitHub API that review-gate uses: the two
// GraphQL queries, the permission and the activity of a login, and the
// commit statuses. It records each status that the gate posts, each request,
// and each request that the gate must not send.
type fakeGate struct {
	prs  map[int]*gqlPR
	open []int
	// openTotal: the count of open pull requests, when it is more than open.
	openTotal int
	// A login with no permission gets HTTP 404. With permissionError, each
	// permission request gets that HTTP status.
	permissions     map[string]string
	permissionError int
	activities      []fakeActivity
	// unfiltered: the activity API gives each activity, as if it did not
	// filter by ref and actor.
	unfiltered bool
	posted     []fakeStatus
	requests   []string
	problems   []string
}

func (f *fakeGate) RoundTrip(req *http.Request) (*http.Response, error) {
	if req.URL.Host != "api.github.com" || req.Header.Get("Authorization") != "bearer "+fakeToken {
		f.problems = append(f.problems, "a request without the token: "+req.Method+" "+req.URL.String())
		return reply(http.StatusUnauthorized, `{"message":"Bad credentials"}`), nil
	}
	f.requests = append(f.requests, req.Method+" "+req.URL.Path)
	repo := "/repos/" + fakeRepo
	path := req.URL.Path
	switch {
	case req.Method == http.MethodPost && path == "/graphql":
		var q struct {
			Query     string
			Variables struct {
				O, R string
				N    int
			}
		}
		if err := json.NewDecoder(req.Body).Decode(&q); err != nil {
			return nil, err
		}
		if q.Variables.O+"/"+q.Variables.R != fakeRepo {
			f.problems = append(f.problems, "a query of another repository: "+q.Variables.O+"/"+q.Variables.R)
		}
		var data any
		switch q.Query {
		case openNumbersQuery:
			var nodes []map[string]int
			for _, n := range f.open {
				nodes = append(nodes, map[string]int{"number": n})
			}
			data = map[string]any{"repository": map[string]any{
				"pullRequests": map[string]any{"totalCount": max(len(f.open), f.openTotal), "nodes": nodes}}}
		case prQuery:
			pr, ok := f.prs[q.Variables.N]
			if !ok {
				f.problems = append(f.problems, fmt.Sprintf("a query of pull request %d, which does not exist", q.Variables.N))
			}
			data = map[string]any{"repository": gqlRepo{DefaultBranchRef: struct{ Name string }{"main"},
				MergeCommitAllowed: true, PullRequest: pr}}
		default:
			f.problems = append(f.problems, "an unexpected query")
		}
		body, err := json.Marshal(map[string]any{"data": data})
		if err != nil {
			return nil, err
		}
		return reply(http.StatusOK, string(body)), nil
	case req.Method == http.MethodGet && strings.HasPrefix(path, repo+"/collaborators/") && strings.HasSuffix(path, "/permission"):
		login := strings.TrimSuffix(strings.TrimPrefix(path, repo+"/collaborators/"), "/permission")
		if f.permissionError != 0 {
			return reply(f.permissionError, `{"message":"Server Error"}`), nil
		}
		perm, ok := f.permissions[login]
		if !ok {
			return reply(http.StatusNotFound, `{"message":"Not Found"}`), nil
		}
		return reply(http.StatusOK, fmt.Sprintf(`{"permission":%q,"role_name":%q,"user":{"login":%q}}`, perm, perm, login)), nil
	case req.Method == http.MethodGet && path == repo+"/activity":
		q := req.URL.Query()
		if q.Get("ref") == "" || q.Get("actor") == "" || q.Get("per_page") != "100" {
			f.problems = append(f.problems, "an activity list without ref, actor and per_page=100: "+req.URL.RawQuery)
		}
		list := []map[string]any{}
		for _, a := range f.activities {
			// As GitHub does: the filters, and the case of the actor does not
			// count.
			if !f.unfiltered && (a.ref != q.Get("ref") || !strings.EqualFold(a.actor, q.Get("actor"))) {
				continue
			}
			list = append(list, map[string]any{"ref": a.ref, "activity_type": a.kind, "actor": map[string]any{"login": a.actor}})
		}
		body, err := json.Marshal(list)
		if err != nil {
			return nil, err
		}
		return reply(http.StatusOK, string(body)), nil
	case req.Method == http.MethodGet && strings.HasPrefix(path, repo+"/compare/"):
		return reply(http.StatusOK, `{"merge_base_commit":{"sha":"b0"}}`), nil
	case req.Method == http.MethodGet && path == repo+"/git/trees/b0":
		return reply(http.StatusOK, `{"sha":"b0","truncated":false,"tree":[]}`), nil
	case req.Method == http.MethodGet && path == repo+"/git/trees/"+fixtureHead:
		return reply(http.StatusOK, `{"sha":"h","truncated":false,"tree":[{"path":"run.sh","mode":"100755","type":"blob","sha":"s1"}]}`), nil
	case req.Method == http.MethodPost && strings.HasPrefix(path, repo+"/statuses/"):
		var s struct{ State, Context, Description string }
		if err := json.NewDecoder(req.Body).Decode(&s); err != nil {
			return nil, err
		}
		f.posted = append(f.posted, fakeStatus{sha: strings.TrimPrefix(path, repo+"/statuses/"),
			state: s.State, context: s.Context, description: s.Description})
		return reply(http.StatusCreated, `{}`), nil
	}
	f.problems = append(f.problems, "an unexpected request: "+req.Method+" "+req.URL.String())
	return reply(http.StatusNotFound, `{"message":"Not Found"}`), nil
}

// gatePR is an open pull request by alice from the branch feature of the
// repository, with the head fixtureHead and the check validate, which
// completed 3 hours before fixtureTime. It has no review and no comment.
func gatePR() *gqlPR {
	pr := &gqlPR{Number: 1, State: "OPEN", BaseRefName: "main", HeadRefOid: fixtureHead, HeadRefName: "feature",
		Author: &gqlActor{Typename: "User", Login: "alice"}, Mergeable: "MERGEABLE", MergeStateStatus: "CLEAN"}
	pr.Commits.Nodes = []gqlCommitNode{{}}
	pr.Commits.Nodes[0].Commit.StatusCheckRollup = &gqlRollup{}
	addContext(pr, checkRun("validate", "COMPLETED", -4*time.Hour, -3*time.Hour))
	return pr
}

// actor is the GraphQL author of a login: app/<login> is a bot.
func actor(login string) *gqlActor {
	if bot, ok := strings.CutPrefix(login, "app/"); ok {
		return &gqlActor{Typename: "Bot", Login: bot}
	}
	return &gqlActor{Typename: "User", Login: login}
}

func addContext(pr *gqlPR, c gqlContext) {
	contexts := &pr.Commits.Nodes[0].Commit.StatusCheckRollup.Contexts
	contexts.Nodes = append(contexts.Nodes, c)
	contexts.TotalCount = len(contexts.Nodes)
}

// checkRun is a check run that started and completed at these times after
// fixtureTime. With done 0, it is still running.
func checkRun(name, status string, started, done time.Duration) gqlContext {
	start := fixtureTime.Add(started)
	c := gqlContext{Typename: "CheckRun", Name: name, Status: status, StartedAt: &start}
	if done != 0 {
		end := fixtureTime.Add(done)
		c.Conclusion, c.CompletedAt = "SUCCESS", &end
	}
	return c
}

// review adds a review of sha by login at this time after fixtureTime.
func review(login, state, sha, body string, at time.Duration) func(*gqlPR) {
	return func(pr *gqlPR) {
		t := fixtureTime.Add(at)
		pr.Reviews.Nodes = append(pr.Reviews.Nodes, gqlReview{Author: actor(login), State: state, SubmittedAt: &t,
			Commit: &struct{ Oid string }{sha}, Body: body})
		pr.Reviews.TotalCount = len(pr.Reviews.Nodes)
	}
}

func comment(login, body string) func(*gqlPR) {
	return func(pr *gqlPR) {
		pr.Comments.Nodes = append(pr.Comments.Nodes, struct {
			Author *gqlActor
			Body   string
		}{actor(login), body})
	}
}

// summary adds the Codex summary of a review of sha. unresolved is the JSON
// of has_unresolved_findings: true, false or null.
func summary(sha, status, unresolved string) func(*gqlPR) {
	return comment(codexReviewer, fmt.Sprintf(
		`<!-- codex-pull-request-review-summary -->`+"\n"+
			`<!-- codex-review-state:v1 {"code_review":{"commit_sha":%q,"has_any_findings":%s,"has_unresolved_findings":%s,"status":%q}} -->`,
		sha, unresolved, unresolved, status))
}

func thread(resolved bool) func(*gqlPR) {
	return func(pr *gqlPR) {
		pr.ReviewThreads.Nodes = append(pr.ReviewThreads.Nodes, struct{ IsResolved bool }{resolved})
	}
}

// status adds a commit status that was posted 30 minutes before fixtureTime.
func status(context, state, description string) func(*gqlPR) {
	return func(pr *gqlPR) {
		t := fixtureTime.Add(-30 * time.Minute)
		addContext(pr, gqlContext{Typename: "StatusContext", Context: context, State: state, Description: description, CreatedAt: &t})
	}
}

// marker is a review body with an aec-review:v1 block.
func marker(open string) string {
	return "Two findings are open.\n\n<!-- aec-review:v1 {\"open\":" + open + "} -->"
}

type gateCase struct {
	name string
	// The settings on top of gateSettings: statusPrefix den and the Codex
	// connector as the reviewer.
	settings func(*Ci)
	edits    []func(*gqlPR)
	// The REST data of the fake API.
	permissions     map[string]string
	permissionError int
	activities      []fakeActivity
	unfiltered      bool
	dryRun          bool
	// all: review-gate for each open pull request, with a second pull
	// request (number 2). openTotal: the count that GitHub gives.
	all       bool
	openTotal int
	// The state of the one status that the gate posts, or "" for none.
	post string
	// Parts of the output (the table, or the error), and text that it must
	// not have.
	text, notText []string
	// A part of the error, or "" for no error.
	err string
	// Parts of request paths that the gate must not send.
	noCall []string
}

func gateSettings(m *Ci) {
	m.Repository, m.Reviewer, m.StatusPrefix = fakeRepo, codexReviewer, "den"
}

func markerSettings(m *Ci) { m.Reviewer, m.ReviewMarker = "app/github-actions", "aec-review:v1" }

func approvalSettings(m *Ci) { m.SecondPersonApproval = true }

func timeoutSettings(m *Ci) { m.ReviewTimeoutHours = 2 }

func gateCases() []gateCase {
	const old = "fedcba9876543210fedcba9876543210fedcba98"
	head := short(fixtureHead)
	people := map[string]string{"alice": "admin", "bob": "write", "carol": "read", "dave": "admin"}
	clean := summary(fixtureHead, "completed", "false")
	withCodexFinding := summary(fixtureHead, "completed", "true")
	approvedByBob := review("bob", "APPROVED", fixtureHead, "", -time.Hour)
	pushBy := func(login, kind string) []fakeActivity {
		return []fakeActivity{{"refs/heads/feature", login, kind}}
	}
	running := func(pr *gqlPR) {
		contexts := pr.Commits.Nodes[0].Commit.StatusCheckRollup.Contexts.Nodes
		contexts[0].Status, contexts[0].Conclusion, contexts[0].CompletedAt = "IN_PROGRESS", "", nil
	}
	checkDone := func(ago time.Duration) func(*gqlPR) {
		return func(pr *gqlPR) {
			end := fixtureTime.Add(-ago)
			pr.Commits.Nodes[0].Commit.StatusCheckRollup.Contexts.Nodes[0].CompletedAt = &end
		}
	}
	return []gateCase{
		// den's reading: the rules reviewed and threads, and the Codex summary.
		{name: "a clean Codex summary of the head: success", edits: []func(*gqlPR){clean}, post: "success",
			text: []string{"| #1 | " + head + " | success | app/chatgpt-codex-connector reviewed head " + head + ": no open finding | posted success |"}},
		{name: "a Codex summary with a null findings flag and no unresolved thread: success",
			edits: []func(*gqlPR){summary(fixtureHead, "completed", "null")}, post: "success"},
		{name: "a Codex summary of the head with unresolved findings: failure", edits: []func(*gqlPR){withCodexFinding},
			post: "failure", text: []string{"app/chatgpt-codex-connector has unresolved findings on head " + head}},
		{name: "a Codex review of the head and an unresolved thread: failure",
			edits: []func(*gqlPR){review(codexReviewer, "COMMENTED", fixtureHead, "", -time.Hour), thread(false)},
			post:  "failure", text: []string{"1 unresolved review thread(s)"}},
		{name: "a Codex review of the head and resolved threads: success, as for the merge rules",
			edits: []func(*gqlPR){review(codexReviewer, "COMMENTED", fixtureHead, "", -time.Hour), withCodexFinding, thread(true)},
			post:  "success"},
		{name: "a clean summary and an unresolved thread of a person: failure",
			edits: []func(*gqlPR){clean, thread(false)}, post: "failure"},
		{name: "a review and a summary of an older head: no status",
			edits: []func(*gqlPR){review(codexReviewer, "COMMENTED", old, "", -time.Hour), summary(old, "completed", "false")},
			text:  []string{"| none | app/chatgpt-codex-connector has not reviewed head " + head + " | none |"}},
		{name: "a running review of the head: no status", edits: []func(*gqlPR){summary(fixtureHead, "running", "null")},
			text: []string{"| none |"}},
		{name: "a running review of the head with unresolved findings from before: no status",
			edits: []func(*gqlPR){summary(fixtureHead, "running", "true")}, text: []string{"| none |"}},
		{name: "a Codex summary of an older head with unresolved findings: no status for the new head",
			edits: []func(*gqlPR){summary(old, "completed", "true")}, text: []string{"| none |"}},
		{name: "a summary with unresolved findings from another login: no status", edits: []func(*gqlPR){
			comment("mallory", `<!-- codex-review-state:v1 {"code_review":{"commit_sha":"`+fixtureHead+`","has_unresolved_findings":true,"status":"completed"}} -->`)},
			text: []string{"| none |"}},
		{name: "a clean summary from another login: no status", edits: []func(*gqlPR){
			comment("mallory", `<!-- codex-review-state:v1 {"code_review":{"commit_sha":"`+fixtureHead+`","has_unresolved_findings":false,"status":"completed"}} -->`)},
			text: []string{"| none |"}},
		{name: "the newest decisive review of a person reviewer requests changes: failure",
			settings: func(m *Ci) { m.Reviewer = "bob" },
			edits: []func(*gqlPR){review("bob", "APPROVED", fixtureHead, "", -3*time.Hour),
				review("bob", "CHANGES_REQUESTED", fixtureHead, "", -2*time.Hour), review("bob", "COMMENTED", fixtureHead, "", -time.Hour)},
			post: "failure", text: []string{"bob requested changes on head " + head}},
		{name: "a later approval of a person reviewer replaces its request for changes: success",
			settings: func(m *Ci) { m.Reviewer = "bob" },
			edits: []func(*gqlPR){review("bob", "CHANGES_REQUESTED", fixtureHead, "", -2*time.Hour),
				review("bob", "APPROVED", fixtureHead, "", -time.Hour)},
			post: "success"},
		{name: "no reviewer is set: no status", settings: func(m *Ci) { m.Reviewer = "" },
			edits: []func(*gqlPR){clean}, text: []string{"| none | no reviewer is set | none |"}},
		{name: "with no reviewer, a review by a deleted account does not count",
			settings: func(m *Ci) { markerSettings(m); m.Reviewer = "" },
			edits:    []func(*gqlPR){review("", "COMMENTED", fixtureHead, marker(`[]`), -time.Hour)},
			text:     []string{"| none | no reviewer is set | none |"}},

		// The marker of AEC.
		{name: "a marker review with only notes: success", settings: markerSettings,
			edits: []func(*gqlPR){review("app/github-actions", "COMMENTED", fixtureHead, marker(`[{"id":"F2","severity":"note"}]`), -time.Hour)},
			post:  "success", text: []string{"app/github-actions reviewed head " + head + ": no open blocking finding (notes: 1)"}},
		{name: "a marker review with a blocking finding: failure that names it", settings: markerSettings,
			edits: []func(*gqlPR){review("app/github-actions", "COMMENTED", fixtureHead,
				marker(`[{"id":"F1","severity":"blocking"},{"id":"F2","severity":"note"}]`), -time.Hour)},
			post: "failure", text: []string{"open blocking findings on head " + head + ": F1 |"}},
		{name: "an unknown severity is blocking", settings: markerSettings,
			edits: []func(*gqlPR){review("app/github-actions", "COMMENTED", fixtureHead, marker(`[{"id":"F3","severity":"major"}]`), -time.Hour)},
			post:  "failure", text: []string{": F3"}},
		{name: "a marker review with no open finding: success", settings: markerSettings,
			edits: []func(*gqlPR){review("app/github-actions", "COMMENTED", fixtureHead, marker(`[]`), -time.Hour)},
			post:  "success", text: []string{"(notes: 0)"}},
		{name: "the newest marker review of the head counts", settings: markerSettings,
			edits: []func(*gqlPR){review("app/github-actions", "COMMENTED", fixtureHead, marker(`[{"id":"F1","severity":"blocking"}]`), -2*time.Hour),
				review("app/github-actions", "COMMENTED", fixtureHead, marker(`[]`), -time.Hour)},
			post: "success"},
		{name: "a newer review without the block does not count", settings: markerSettings,
			edits: []func(*gqlPR){review("app/github-actions", "COMMENTED", fixtureHead, marker(`[{"id":"F1","severity":"blocking"}]`), -2*time.Hour),
				review("app/github-actions", "COMMENTED", fixtureHead, "Looks good.", -time.Hour)},
			post: "failure", text: []string{": F1"}},
		{name: "a marker review of an older head: no status", settings: markerSettings,
			edits: []func(*gqlPR){review("app/github-actions", "COMMENTED", old, marker(`[]`), -time.Hour)},
			text:  []string{"| none | app/github-actions has no aec-review:v1 review of head " + head + " | none |"}},
		{name: "a marker block that does not parse: failure", settings: markerSettings,
			edits: []func(*gqlPR){review("app/github-actions", "COMMENTED", fixtureHead, marker(`[oops]`), -time.Hour)},
			post:  "failure", text: []string{"cannot read the aec-review:v1 block of the review of head " + head}},
		{name: "a marker block with no open list: failure", settings: markerSettings,
			edits: []func(*gqlPR){review("app/github-actions", "COMMENTED", fixtureHead,
				"<!-- aec-review:v1 {\"findings\":[]} -->", -time.Hour)},
			post: "failure", text: []string{"cannot read the aec-review:v1 block"}},
		{name: "a malformed block after a clean review of the same head: failure", settings: markerSettings,
			edits: []func(*gqlPR){review("app/github-actions", "COMMENTED", fixtureHead, marker(`[]`), -2*time.Hour),
				review("app/github-actions", "COMMENTED", fixtureHead, "<!-- aec-review:v1 {\"open\":[] -->", -time.Hour)},
			post: "failure", text: []string{"cannot read the aec-review:v1 block of the review of head " + head}},
		{name: "a clean block and a malformed second block: failure", settings: markerSettings,
			edits: []func(*gqlPR){review("app/github-actions", "COMMENTED", fixtureHead,
				marker(`[]`)+"\n<!-- aec-review:v1 {\"open\": -->", -time.Hour)},
			post: "failure", text: []string{"has 2 aec-review:v1 blocks"}},
		{name: "a marker block with no JSON: failure", settings: markerSettings,
			edits: []func(*gqlPR){review("app/github-actions", "COMMENTED", fixtureHead, "<!-- aec-review:v1 -->", -time.Hour)},
			post:  "failure", text: []string{"cannot read the aec-review:v1 block"}},
		{name: "a block with no space after the marker is a block", settings: markerSettings,
			edits: []func(*gqlPR){review("app/github-actions", "COMMENTED", fixtureHead, marker(`[]`), -2*time.Hour),
				review("app/github-actions", "COMMENTED", fixtureHead, `<!--aec-review:v1{"open":[{"id":"F1","severity":"blocking"}]}-->`, -time.Hour)},
			post: "failure", text: []string{": F1"}},
		{name: "a longer marker name is another marker", settings: markerSettings,
			edits: []func(*gqlPR){review("app/github-actions", "COMMENTED", fixtureHead, "<!-- aec-review:v10 {\"open\":[]} -->", -time.Hour)},
			text:  []string{"| none | app/github-actions has no aec-review:v1 review of head"}},
		{name: "two marker blocks in one review: failure", settings: markerSettings,
			edits: []func(*gqlPR){review("app/github-actions", "COMMENTED", fixtureHead, marker(`[]`)+"\n"+marker(`[]`), -time.Hour)},
			post:  "failure", text: []string{"has 2 aec-review:v1 blocks"}},
		{name: "a marker review by another login: no status", settings: markerSettings,
			edits: []func(*gqlPR){review("mallory", "COMMENTED", fixtureHead, marker(`[]`), -time.Hour)},
			text:  []string{"| none |"}},
		{name: "with a marker, a clean Codex summary is not the review", settings: func(m *Ci) { m.ReviewMarker = "aec-review:v1" },
			edits: []func(*gqlPR){clean}, text: []string{"| none | app/chatgpt-codex-connector has no aec-review:v1 review of head"}},
		{name: "a marker name with a character that a regular expression reads",
			settings: func(m *Ci) { markerSettings(m); m.ReviewMarker = "den+review:v1" },
			edits: []func(*gqlPR){review("app/github-actions", "COMMENTED", fixtureHead,
				"<!-- den+review:v1 {\"open\":[]} -->", -time.Hour)},
			post: "success"},

		// Second-person approval.
		{name: "an approval by a second person opens the gate over a Codex finding", settings: approvalSettings,
			edits: []func(*gqlPR){withCodexFinding, approvedByBob}, permissions: people, post: "success",
			text: []string{"| success | bob approved head " + head + " as a second person | posted success |"}},
		{name: "an approval by the author does not count, and the gate does not read the author's access",
			settings: approvalSettings, edits: []func(*gqlPR){review("alice", "APPROVED", fixtureHead, "", -time.Hour)},
			permissions: people, text: []string{"the approval of alice does not count: alice is the author"},
			noCall: []string{"/collaborators/", "/activity"}},
		{name: "an approval by a person who pushed a commit does not count", settings: approvalSettings,
			edits: []func(*gqlPR){approvedByBob}, permissions: people, activities: pushBy("bob", "push"),
			text: []string{"| none |", "the approval of bob does not count: bob pushed to feature"}},
		{name: "a force push by the approver is a push", settings: approvalSettings,
			edits: []func(*gqlPR){approvedByBob}, permissions: people, activities: pushBy("Bob", "force_push"),
			text: []string{"bob pushed to feature"}},
		{name: "the approver created the branch", settings: approvalSettings,
			edits: []func(*gqlPR){approvedByBob}, permissions: people, activities: pushBy("bob", "branch_creation"),
			text: []string{"bob pushed to feature"}},
		{name: "a deletion of the branch by the approver is not a push", settings: approvalSettings,
			edits: []func(*gqlPR){approvedByBob}, permissions: people, activities: pushBy("bob", "branch_deletion"),
			post: "success"},
		{name: "a push by the approver to another branch does not count", settings: approvalSettings,
			edits: []func(*gqlPR){approvedByBob}, permissions: people,
			activities: []fakeActivity{{"refs/heads/other", "bob", "push"}, {"refs/heads/feature", "carol", "push"}},
			post:       "success"},
		{name: "the gate checks the ref and the actor of each activity", settings: approvalSettings,
			edits: []func(*gqlPR){approvedByBob}, permissions: people, unfiltered: true,
			activities: []fakeActivity{{"refs/heads/other", "bob", "push"}, {"refs/heads/feature", "carol", "push"}},
			post:       "success"},
		{name: "a full page of activities refuses, because the next page can have a push", settings: approvalSettings,
			edits: []func(*gqlPR){approvedByBob}, permissions: people, unfiltered: true,
			activities: slices.Repeat([]fakeActivity{{"refs/heads/feature", "carol", "push"}}, 100),
			text:       []string{"bob pushed to feature"}},
		{name: "an approval on a fork pull request does not count, and the gate reads no access or activity",
			settings: approvalSettings, edits: []func(*gqlPR){approvedByBob, func(pr *gqlPR) { pr.IsCrossRepository = true }},
			permissions: people, text: []string{"the approval of bob does not count: the pull request comes from a fork"},
			noCall: []string{"/collaborators/", "/activity"}},
		{name: "an approval by a person with read access does not count", settings: approvalSettings,
			edits: []func(*gqlPR){review("carol", "APPROVED", fixtureHead, "", -time.Hour)}, permissions: people,
			text: []string{"carol has read access, not write access"}, noCall: []string{"/activity"}},
		{name: "an approval by a deleted account does not count, and the gate reads the next approver", settings: approvalSettings,
			edits: []func(*gqlPR){review("", "APPROVED", fixtureHead, "", -2*time.Hour), approvedByBob}, permissions: people,
			post: "success", text: []string{"bob approved head " + head + " as a second person; the approval of a deleted account does not count: the approver has no login"},
			noCall: []string{"/collaborators//"}},
		{name: "an approval by a bot does not count", settings: approvalSettings,
			edits: []func(*gqlPR){review("app/helper", "APPROVED", fixtureHead, "", -time.Hour)}, permissions: people,
			text: []string{"app/helper is a bot, not a person"}, noCall: []string{"/collaborators/"}},
		{name: "an approval of an older head does not count", settings: approvalSettings,
			edits: []func(*gqlPR){review("bob", "APPROVED", old, "", -time.Hour)}, permissions: people,
			text: []string{"| none |"}, noCall: []string{"/collaborators/"}},
		{name: "a request for changes after the approval takes it back", settings: approvalSettings,
			edits:       []func(*gqlPR){approvedByBob, review("bob", "CHANGES_REQUESTED", fixtureHead, "", -time.Minute)},
			permissions: people, text: []string{"| none |"}, noCall: []string{"/collaborators/"}},
		{name: "a dismissed approval does not count", settings: approvalSettings,
			edits: []func(*gqlPR){review("bob", "DISMISSED", fixtureHead, "", -time.Hour)}, permissions: people,
			text: []string{"| none |"}, noCall: []string{"/collaborators/"}},
		{name: "a comment after the approval keeps it", settings: approvalSettings,
			edits:       []func(*gqlPR){approvedByBob, review("bob", "COMMENTED", fixtureHead, "", -time.Minute)},
			permissions: people, post: "success"},
		{name: "the first approval that passes opens the gate, the table names the earlier ones, and the gate reads no later one",
			settings: approvalSettings,
			edits: []func(*gqlPR){review("alice", "APPROVED", fixtureHead, "", -3*time.Hour),
				review("carol", "APPROVED", fixtureHead, "", -2*time.Hour), review("dave", "APPROVED", fixtureHead, "", -time.Hour),
				review("erin", "APPROVED", fixtureHead, "", -30*time.Minute)},
			permissions: people, post: "success",
			text:   []string{"dave approved head " + head + " as a second person; the approval of alice does not count: alice is the author; the approval of carol does not count: carol has read access"},
			noCall: []string{"/collaborators/erin"}},
		{name: "an approval with no head branch does not count", settings: approvalSettings,
			edits: []func(*gqlPR){approvedByBob, func(pr *gqlPR) { pr.HeadRefName = "" }}, permissions: people,
			text: []string{"the gate does not know the head branch"}, noCall: []string{"/collaborators/"}},
		{name: "with the setting off, an approval does not open the gate, and the gate reads no access",
			edits: []func(*gqlPR){approvedByBob}, permissions: people, text: []string{"| none |"},
			notText: []string{"approval"}, noCall: []string{"/collaborators/", "/activity"}},
		{name: "an error of the permission API gives an error row, posts nothing, and fails", settings: approvalSettings,
			edits: []func(*gqlPR){clean, approvedByBob}, permissionError: http.StatusInternalServerError,
			err:  "review gate: #1: GitHub REST GET /repos/owner/name/collaborators/bob/permission: HTTP 500",
			text: []string{"| #1 | " + head + " | none |  | error: GitHub REST GET"}},

		// The review timeout.
		{name: "the timeout fires 3 hours after the check", settings: timeoutSettings,
			text:   []string{"| none | app/chatgpt-codex-connector has not reviewed head " + head + " | needs-human: review by a person: approve head " + head + "? |"},
			noCall: []string{"/labels", "/comments"}},
		{name: "the timeout fires 2 hours after the check", settings: timeoutSettings,
			edits: []func(*gqlPR){checkDone(2 * time.Hour)}, text: []string{"needs-human: review by a person"}},
		{name: "the timeout does not fire 1 hour after the check", settings: timeoutSettings,
			edits: []func(*gqlPR){checkDone(time.Hour)}, notText: []string{"needs-human"}},
		{name: "no timeout with a status of the gate on the head", settings: timeoutSettings,
			edits: []func(*gqlPR){func(pr *gqlPR) {
				t := fixtureTime.Add(-150 * time.Minute)
				addContext(pr, gqlContext{Typename: "StatusContext", Context: "den/review", State: "FAILURE", CreatedAt: &t})
			}}, notText: []string{"needs-human"}},
		{name: "no timeout while the check runs", settings: timeoutSettings,
			edits: []func(*gqlPR){running}, notText: []string{"needs-human"}},
		{name: "no timeout while another check runs, with no checkName", settings: timeoutSettings,
			edits:   []func(*gqlPR){func(pr *gqlPR) { addContext(pr, checkRun("lint", "IN_PROGRESS", -3*time.Hour, 0)) }},
			notText: []string{"needs-human"}},
		{name: "with checkName, only that check counts for the timeout",
			settings: func(m *Ci) { m.ReviewTimeoutHours, m.CheckName = 2, "validate" },
			edits:    []func(*gqlPR){func(pr *gqlPR) { addContext(pr, checkRun("lint", "IN_PROGRESS", -3*time.Hour, 0)) }},
			text:     []string{"needs-human: review by a person"}},
		{name: "the timeout counts from the last check", settings: timeoutSettings,
			edits:   []func(*gqlPR){func(pr *gqlPR) { addContext(pr, checkRun("lint", "COMPLETED", -3*time.Hour, -time.Hour)) }},
			notText: []string{"needs-human"}},
		{name: "a pending commit status is not finished", settings: timeoutSettings,
			edits: []func(*gqlPR){status("build", "PENDING", "")}, notText: []string{"needs-human"}},
		{name: "no timeout on a draft", settings: timeoutSettings,
			edits: []func(*gqlPR){func(pr *gqlPR) { pr.IsDraft = true }}, notText: []string{"needs-human"}},
		{name: "no timeout when no check ran", settings: timeoutSettings,
			edits:   []func(*gqlPR){func(pr *gqlPR) { pr.Commits.Nodes[0].Commit.StatusCheckRollup = &gqlRollup{} }},
			notText: []string{"needs-human"}},
		{name: "no timeout with the setting off", notText: []string{"needs-human"}},

		// When the gate posts.
		{name: "an unchanged result is not posted again", edits: []func(*gqlPR){clean,
			status("den/review", "SUCCESS", "app/chatgpt-codex-connector reviewed head "+head+": no open finding")},
			text: []string{"| already success |"}},
		{name: "a context in another case is the status of the gate", edits: []func(*gqlPR){clean,
			status("DEN/review", "SUCCESS", "app/chatgpt-codex-connector reviewed head "+head+": no open finding")},
			text: []string{"| already success |"}},
		{name: "a changed description is posted", edits: []func(*gqlPR){clean, status("den/review", "SUCCESS", "bob approved head")},
			post: "success"},
		{name: "a changed state is posted", edits: []func(*gqlPR){withCodexFinding, status("den/review", "SUCCESS", "anything")},
			post: "failure", text: []string{"has unresolved findings"}},
		{name: "a dry run posts nothing", edits: []func(*gqlPR){clean}, dryRun: true,
			text: []string{"| would post success |", "Dry run: the review gate posted nothing."}},
		{name: "a success that does not stand now is taken back",
			edits: []func(*gqlPR){status("den/review", "SUCCESS", "bob approved head "+head+" as a second person")},
			post:  "failure", text: []string{"no review or approval of head " + head + " stands"}},
		{name: "a failure of the gate stays when no review stands", edits: []func(*gqlPR){status("den/review", "FAILURE", "anything")},
			text: []string{"| none |"}},
		{name: "a merged pull request gets no status", edits: []func(*gqlPR){clean, func(pr *gqlPR) { pr.State = "MERGED" }},
			text: []string{"| none | the pull request is merged | none |"}},
		{name: "more reviews than the query reads: the gate decides nothing, and reads no access",
			settings: approvalSettings, edits: []func(*gqlPR){clean, approvedByBob, func(pr *gqlPR) { pr.Reviews.TotalCount = 101 }},
			permissions: people, text: []string{"| none | it has more reviews than the gate reads; a person reviews | none |"},
			noCall: []string{"/collaborators/"}},
		{name: "each open pull request, in order", all: true, edits: []func(*gqlPR){clean},
			text: []string{"| #1 | " + head + " | success |", "| #2 | fedcba987654 | failure |"}},
		{name: "more open pull requests than the query reads is an error", all: true, openTotal: 101,
			err: "101 open pull requests; the review gate reads only 2", noCall: []string{"/statuses/"}},
		{name: "a long description is cut to 140 characters", settings: markerSettings,
			edits: []func(*gqlPR){review("app/github-actions", "COMMENTED", fixtureHead, marker(`[`+strings.Repeat(`{"id":"FINDING-0001","severity":"blocking"},`, 12)+
				`{"id":"LAST","severity":"blocking"}]`), -time.Hour)},
			post: "failure"},
	}
}

func (c gateCase) check(ctx context.Context) []string {
	m := &Ci{}
	gateSettings(m)
	if c.settings != nil {
		c.settings(m)
	}
	pr := gatePR()
	for _, edit := range c.edits {
		edit(pr)
	}
	f := &fakeGate{prs: map[int]*gqlPR{1: pr}, open: []int{1}, openTotal: c.openTotal, permissions: c.permissions,
		permissionError: c.permissionError, activities: c.activities, unfiltered: c.unfiltered}
	n := 1
	if c.all {
		// A second pull request with another head and a Codex finding.
		second := gatePR()
		second.Number, second.HeadRefOid = 2, "fedcba9876543210fedcba9876543210fedcba98"
		summary(second.HeadRefOid, "completed", "true")(second)
		f.prs[2], f.open, n = second, []int{1, 2}, 0
	}
	g := &githubClient{token: fakeToken, http: &http.Client{Transport: f}}
	text, err := m.reviewGates(ctx, g, "owner", "name", n, c.dryRun, fixtureTime)
	var failed []string
	fail := func(format string, args ...any) {
		failed = append(failed, fmt.Sprintf("gate case %q: ", c.name)+fmt.Sprintf(format, args...))
	}
	switch {
	case c.err == "" && err != nil:
		fail("error %v", err)
	case c.err != "" && err == nil:
		fail("no error, want one with %q", c.err)
	case c.err != "" && !strings.Contains(err.Error(), c.err):
		fail("error %q, want one with %q", err, c.err)
	}
	if err != nil {
		text += err.Error()
	}
	for _, want := range c.text {
		if !strings.Contains(text, want) {
			fail("the output has no %q:\n%s", want, text)
		}
	}
	for _, not := range c.notText {
		if strings.Contains(text, not) {
			fail("the output has %q:\n%s", not, text)
		}
	}
	switch {
	case c.all && c.err == "":
		if len(f.posted) != 2 || f.posted[0].state != "success" || f.posted[1].state != "failure" ||
			f.posted[1].sha != "fedcba9876543210fedcba9876543210fedcba98" {
			fail("posted %v, want success on #1 and failure on #2", f.posted)
		}
	case c.post == "" && len(f.posted) > 0:
		fail("posted %v, want no status", f.posted)
	case c.post != "" && len(f.posted) != 1:
		fail("posted %v, want one %s status", f.posted, c.post)
	case c.post != "":
		s := f.posted[0]
		if s.state != c.post || s.context != "den/review" || s.sha != fixtureHead {
			fail("posted %+v, want %s den/review on %s", s, c.post, fixtureHead)
		}
		if n := len([]rune(s.description)); n == 0 || n > 140 || !strings.Contains(text, strings.TrimSuffix(s.description, "…")) {
			fail("the description %q is empty, longer than 140 characters, or not in the table", s.description)
		}
	}
	for _, call := range c.noCall {
		if i := slices.IndexFunc(f.requests, func(r string) bool { return strings.Contains(r, call) }); i >= 0 {
			fail("the gate sent %s", f.requests[i])
		}
	}
	for _, p := range f.problems {
		fail("%s", p)
	}
	return failed
}

// fetchCases: fetch reads the Git trees only when a file rule is on, and the
// review gate reads no tree.
func fetchCases(ctx context.Context) []string {
	var failed []string
	for _, c := range []struct {
		name  string
		m     *Ci
		trees bool
	}{
		{"with riskyExecutableBit, fetch reads the trees", &Ci{Repository: fakeRepo, RiskyExecutableBit: true}, true},
		{"with no file rule, fetch reads no tree", &Ci{Repository: fakeRepo}, false},
	} {
		pr := gatePR()
		pr.BaseRefOid = "b0"
		pr.Files.Nodes = append(pr.Files.Nodes, struct{ Path string }{"run.sh"})
		f := &fakeGate{prs: map[int]*gqlPR{1: pr}}
		g := &githubClient{token: fakeToken, http: &http.Client{Transport: f}}
		repo, err := c.m.fetch(ctx, g, "owner", "name", 1)
		switch {
		case err != nil:
			failed = append(failed, fmt.Sprintf("fetch case %q: %v", c.name, err))
		case c.trees && (repo.PullRequest.Trees == nil || repo.PullRequest.Trees.Files["run.sh"].HeadMode != "100755"):
			failed = append(failed, fmt.Sprintf("fetch case %q: trees %+v, want run.sh with mode 100755", c.name, repo.PullRequest.Trees))
		case !c.trees && repo.PullRequest.Trees != nil:
			failed = append(failed, fmt.Sprintf("fetch case %q: trees %+v, want none", c.name, repo.PullRequest.Trees))
		}
		for _, p := range f.problems {
			failed = append(failed, fmt.Sprintf("fetch case %q: %s", c.name, p))
		}
	}
	m := &Ci{RiskyExecutableBit: true}
	gateSettings(m)
	f := &fakeGate{prs: map[int]*gqlPR{1: gatePR()}}
	g := &githubClient{token: fakeToken, http: &http.Client{Transport: f}}
	if _, err := m.reviewGates(ctx, g, "owner", "name", 1, true, fixtureTime); err != nil {
		failed = append(failed, fmt.Sprintf("fetch case: the gate with riskyExecutableBit: %v", err))
	}
	if i := slices.IndexFunc(f.requests, func(r string) bool { return strings.Contains(r, "/git/") || strings.Contains(r, "/compare/") }); i >= 0 {
		failed = append(failed, "fetch case: the gate read "+f.requests[i])
	}
	return failed
}

// gateCallCases: review-gate refuses before any GitHub call when the gate is
// off or an argument is not valid. The token is nil, so a call to GitHub
// fails the case.
func gateCallCases(ctx context.Context) []string {
	on := func(edit func(*Ci)) *Ci {
		m := &Ci{}
		gateSettings(m)
		edit(m)
		return m
	}
	cases := []struct {
		name string
		m    *Ci
		pr   int
		want string
	}{
		{"statusPrefix empty: the gate is off", on(func(m *Ci) { m.StatusPrefix = "" }), 1,
			"the statusPrefix setting is empty, so the review gate is off"},
		{"settings without statusPrefix, as in den's dagger.toml: the gate is off", &Ci{Repository: fakeRepo,
			Authors: []string{"alice"}, Reviewer: codexReviewer, RiskyPaths: []string{"secrets/"}}, 0,
			"the statusPrefix setting is empty"},
		{"a negative timeout", on(func(m *Ci) { m.ReviewTimeoutHours = -1 }), 1, "reviewTimeoutHours is -1"},
		{"a negative pull request", on(func(*Ci) {}), -2, "pr is -2"},
	}
	var failed []string
	for _, c := range cases {
		out, err := gateCall(ctx, c.m, c.pr)
		if err == nil || !strings.Contains(err.Error(), c.want) {
			failed = append(failed, fmt.Sprintf("gate call %q: %q, %v; want an error with %q", c.name, out, err, c.want))
		}
	}
	return failed
}

// gateCall calls review-gate with a nil token. A call that passes the checks
// reads the token and panics, and gateCall gives that panic as an error.
func gateCall(ctx context.Context, m *Ci, pr int) (out string, err error) {
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("it passed the checks and read the token: %v", r)
		}
	}()
	return m.ReviewGate(ctx, nil, pr, false)
}
