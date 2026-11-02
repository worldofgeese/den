package main

import (
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"slices"
	"strconv"
	"strings"
	"time"
)

// approve-bot-runs approves the held runs of a head as expected, against a
// fake GitHub API and a fake clock: no runs, runs that appear late, runs
// that GitHub does not approve, the give-up time, and runs of a fork or of
// another head. With the setting off, it sends no request. No network and no
// token.
// +check
func (m *Ci) ApproveBotRunsRules(ctx context.Context) error {
	var failed []string
	for _, c := range approvalCases() {
		failed = append(failed, c.check(ctx)...)
	}
	failed = append(failed, approvalGateCases(ctx)...)
	if len(failed) > 0 {
		return errors.New(strings.Join(failed, "\n"))
	}
	return nil
}

// The repository of the fake API, and the token that it accepts.
const (
	fakeRepo  = "owner/name"
	fakeToken = "fixture-token"
)

// fakeRun is a workflow run that waits for approval in the fake API.
type fakeRun struct {
	id int64
	// The head and the head repository: fixtureHead and fakeRepo when empty.
	sha, repo string
	// When the run appears, after the push.
	at time.Duration
	// Each approval before refuseUntil gets this HTTP status. With no
	// refuseUntil, each approval gets it.
	refuse      int
	refuseUntil time.Duration
	// The API lists the run once more after its approval, as action_required.
	stale bool
	// The API lists the run for any head_sha, as if it did not filter.
	unfiltered bool

	approvals   int
	listedAgain bool
}

func (r *fakeRun) head() string { return cmp.Or(r.sha, fixtureHead) }

func (r *fakeRun) repository() string { return cmp.Or(r.repo, fakeRepo) }

// fakeClock moves only when the loop sleeps.
type fakeClock struct{ t time.Time }

func (c *fakeClock) now() time.Time { return c.t }

func (c *fakeClock) sleep(ctx context.Context, d time.Duration) error {
	c.t = c.t.Add(d)
	return ctx.Err()
}

// fakeActions serves, in process, the two REST endpoints that
// approve-bot-runs uses. It records each request that GitHub refuses or that
// the loop must not send.
type fakeActions struct {
	clock *fakeClock
	start time.Time
	runs  []*fakeRun
	// When listError is not 0, each list from listErrorFrom until
	// listErrorUntil gets this HTTP status. With no listErrorUntil, each list
	// from listErrorFrom gets it.
	listError                     int
	listErrorFrom, listErrorUntil time.Duration
	problems                      []string
}

func (f *fakeActions) RoundTrip(req *http.Request) (*http.Response, error) {
	at := f.clock.now().Sub(f.start)
	if req.URL.Host != "api.github.com" || req.Header.Get("Authorization") != "bearer "+fakeToken {
		f.problems = append(f.problems, "a request without the token: "+req.Method+" "+req.URL.String())
		return reply(http.StatusUnauthorized, `{"message":"Bad credentials"}`), nil
	}
	runs := "/repos/" + fakeRepo + "/actions/runs"
	switch {
	case req.Method == http.MethodGet && req.URL.Path == runs:
		q := req.URL.Query()
		if q.Get("head_sha") != fixtureHead || q.Get("status") != "action_required" {
			f.problems = append(f.problems, "a list without head_sha="+fixtureHead+" and status=action_required: "+req.URL.RawQuery)
		}
		if f.listError != 0 && at >= f.listErrorFrom && (f.listErrorUntil == 0 || at < f.listErrorUntil) {
			return reply(f.listError, `{"message":"Server Error"}`), nil
		}
		var list []map[string]any
		for _, r := range f.runs {
			waits := r.approvals == 0
			if r.stale && r.approvals > 0 && !r.listedAgain {
				waits, r.listedAgain = true, true
			}
			if r.at > at || q.Get("head_sha") != "" && r.head() != q.Get("head_sha") && !r.unfiltered ||
				q.Get("status") == "action_required" && !waits {
				continue
			}
			// As GitHub does: a held run is completed with the conclusion
			// action_required, and an approved run is queued again.
			status, conclusion := "completed", any("action_required")
			if !waits {
				status, conclusion = "queued", nil
			}
			list = append(list, map[string]any{"id": r.id, "head_sha": r.head(), "status": status, "conclusion": conclusion,
				"event": "pull_request", "head_repository": map[string]any{"full_name": r.repository()}})
		}
		body, err := json.Marshal(map[string]any{"total_count": len(list), "workflow_runs": list})
		if err != nil {
			return nil, err
		}
		return reply(http.StatusOK, string(body)), nil
	case req.Method == http.MethodPost && strings.HasPrefix(req.URL.Path, runs+"/") && strings.HasSuffix(req.URL.Path, "/approve"):
		id, _ := strconv.ParseInt(strings.TrimSuffix(strings.TrimPrefix(req.URL.Path, runs+"/"), "/approve"), 10, 64)
		i := slices.IndexFunc(f.runs, func(r *fakeRun) bool { return r.id == id && r.at <= at })
		if i < 0 {
			f.problems = append(f.problems, fmt.Sprintf("an approval of run %d, which the API did not list", id))
			return reply(http.StatusNotFound, `{"message":"Not Found"}`), nil
		}
		r := f.runs[i]
		switch {
		case r.repository() != fakeRepo || r.head() != fixtureHead:
			// GitHub approves such a run too: that is the risk.
			f.problems = append(f.problems, fmt.Sprintf("an approval of run %d of %s on %s", id, r.repository(), short(r.head())))
		case r.approvals > 0:
			f.problems = append(f.problems, fmt.Sprintf("a second approval of run %d", id))
			return reply(http.StatusForbidden, `{"message":"This run is not waiting for approval"}`), nil
		case r.refuse != 0 && (r.refuseUntil == 0 || at < r.refuseUntil):
			return reply(r.refuse, `{"message":"Resource not accessible by integration"}`), nil
		}
		r.approvals++
		return reply(http.StatusCreated, `{}`), nil
	}
	f.problems = append(f.problems, "an unexpected request: "+req.Method+" "+req.URL.String())
	return reply(http.StatusNotFound, `{"message":"Not Found"}`), nil
}

func reply(status int, body string) *http.Response {
	return &http.Response{
		StatusCode: status,
		Status:     fmt.Sprintf("%d %s", status, http.StatusText(status)),
		Header:     http.Header{"Content-Type": {"application/json"}},
		Body:       io.NopCloser(strings.NewReader(body)),
	}
}

type approvalCase struct {
	name                          string
	runs                          []*fakeRun
	listError                     int
	listErrorFrom, listErrorUntil time.Duration
	// The runs that GitHub approved, in the order of runs.
	approved []int64
	// A part of the error, or "" for no error.
	err string
	// Parts of the report (the error text when there is an error), and text
	// that the report must not have.
	text, notText []string
	// When the loop stops, after the start.
	end time.Duration
}

// approvalCases use the waits of the live loop: a list every 10 s, a quiet
// period of 30 s and a give-up time of 3 minutes.
func approvalCases() []approvalCase {
	const other = "fedcba9876543210fedcba9876543210fedcba98"
	every20s := func() []*fakeRun {
		var out []*fakeRun
		for i := range 11 {
			out = append(out, &fakeRun{id: int64(i + 1), at: time.Duration(i) * 20 * time.Second})
		}
		return out
	}
	return []approvalCase{
		{name: "no runs: it looks until the give-up time, and it is not an error",
			text: []string{"No run of owner/name waited for approval on 0123456789ab."},
			end:  3 * time.Minute},
		{name: "runs that appear late are approved, and the loop stops after a quiet period",
			runs: []*fakeRun{{id: 1, at: 25 * time.Second}, {id: 2, at: 45 * time.Second}, {id: 3, at: 2 * time.Minute}},
			// Run 1 at 30 s and run 2 at 50 s; no run waits from 60 s to 80 s.
			approved: []int64{1, 2}, text: []string{"Approved 2 runs of owner/name on 0123456789ab: 1, 2."},
			end: 80 * time.Second},
		{name: "some approved and some failing is not an error",
			runs:     []*fakeRun{{id: 1}, {id: 2, refuse: http.StatusForbidden}},
			approved: []int64{1},
			text: []string{"Approved 1 run of owner/name", "Could not approve run 2: GitHub REST POST /repos/owner/name/actions/runs/2/approve: HTTP 403.",
				"Stopped at the give-up time"},
			// Run 2 waits until the give-up time.
			end: 3 * time.Minute},
		{name: "none approvable is an error: the token needs actions: write",
			runs: []*fakeRun{{id: 1, refuse: http.StatusForbidden}, {id: 2, at: 15 * time.Second, refuse: http.StatusForbidden}},
			err:  "2 runs waited for approval on 0123456789ab, and GitHub approved none: the token needs actions: write",
			text: []string{"Could not approve run 1: GitHub REST POST /repos/owner/name/actions/runs/1/approve: HTTP 403.", "Could not approve run 2"},
			end:  3 * time.Minute},
		{name: "the give-up limit: a new run every 20 s, and no run after 3 minutes is approved",
			runs:     every20s(),
			approved: []int64{1, 2, 3, 4, 5, 6, 7, 8, 9},
			text:     []string{"Approved 9 runs", "Stopped at the give-up time"},
			end:      3 * time.Minute},
		{name: "a refusal that ends is not an error",
			runs:     []*fakeRun{{id: 1, refuse: http.StatusInternalServerError, refuseUntil: 15 * time.Second}},
			approved: []int64{1}, text: []string{"Approved 1 run"}, notText: []string{"Could not approve"},
			end: 50 * time.Second},
		{name: "a run of a fork stays held, and it does not keep the loop going",
			runs:     []*fakeRun{{id: 1}, {id: 2, repo: "someone/fork"}},
			approved: []int64{1},
			text:     []string{"Left run 2 of someone/fork held for a person: it is not a run of owner/name."},
			end:      30 * time.Second},
		{name: "only a run of a fork is not an error",
			runs: []*fakeRun{{id: 2, repo: "someone/fork"}},
			text: []string{"No run of owner/name waited", "Left run 2 of someone/fork held"},
			end:  3 * time.Minute},
		{name: "a run of another head stays held, if the API lists it",
			runs:     []*fakeRun{{id: 1}, {id: 3, sha: other, unfiltered: true}},
			approved: []int64{1}, end: 30 * time.Second},
		{name: "a run that GitHub lists again after its approval gets one approval",
			runs:     []*fakeRun{{id: 1, stale: true}},
			approved: []int64{1}, end: 30 * time.Second},
		{name: "a list that fails after an approval does not end the loop",
			runs:      []*fakeRun{{id: 1}, {id: 2, at: 35 * time.Second}},
			listError: http.StatusInternalServerError, listErrorFrom: 5 * time.Second, listErrorUntil: 45 * time.Second,
			// The lists at 10 s to 40 s fail, so the loop does not know that no
			// run waits. At 50 s it approves run 2.
			approved: []int64{1, 2}, text: []string{"Approved 2 runs", "4 lists of the held runs failed"},
			end: 80 * time.Second},
		{name: "a list that fails is not an error, and the report says it",
			listError: http.StatusInternalServerError,
			text: []string{"No run of owner/name waited",
				"18 lists of the held runs failed. The last error: GitHub REST GET /repos/owner/name/actions/runs?head_sha=" + fixtureHead +
					"&per_page=100&status=action_required: HTTP 500."},
			end: 3 * time.Minute},
	}
}

// check runs the live loop against the fake API.
func (c approvalCase) check(ctx context.Context) []string {
	clock := &fakeClock{t: fixtureTime}
	f := &fakeActions{clock: clock, start: clock.t, runs: c.runs,
		listError: c.listError, listErrorFrom: c.listErrorFrom, listErrorUntil: c.listErrorUntil}
	a := liveApproval
	a.now, a.sleep = clock.now, clock.sleep
	g := &githubClient{token: fakeToken, http: &http.Client{Transport: f}}
	text, err := a.approve(ctx, g, "owner", "name", fixtureHead)
	var failed []string
	fail := func(format string, args ...any) {
		failed = append(failed, fmt.Sprintf("approval case %q: ", c.name)+fmt.Sprintf(format, args...))
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
		text = err.Error()
	}
	var approved []int64
	for _, r := range f.runs {
		if r.approvals > 0 {
			approved = append(approved, r.id)
		}
	}
	if !slices.Equal(approved, c.approved) {
		fail("approved %v, want %v", approved, c.approved)
	}
	if end := clock.t.Sub(f.start); end != c.end {
		fail("stopped after %s, want %s", end, c.end)
	}
	for _, want := range c.text {
		if !strings.Contains(text, want) {
			fail("the report has no %q:\n%s", want, text)
		}
	}
	for _, not := range c.notText {
		if strings.Contains(text, not) {
			fail("the report has %q:\n%s", not, text)
		}
	}
	for _, p := range f.problems {
		fail("%s", p)
	}
	return failed
}

// approvalGateCases: approve-bot-runs refuses before any GitHub call when the
// setting is off or the SHA is not a full commit SHA. The token is nil, so a
// call to GitHub fails the check.
func approvalGateCases(ctx context.Context) []string {
	cases := []struct {
		name string
		m    *Ci
		sha  string
		want string
	}{
		{"the setting off", &Ci{Repository: fakeRepo}, fixtureHead,
			"the approveBotRuns setting is off, so the module approves no run"},
		{"a short SHA", &Ci{Repository: fakeRepo, ApprovesBotRuns: true}, fixtureHead[:12],
			"give the full commit SHA"},
		{"an upper-case SHA", &Ci{Repository: fakeRepo, ApprovesBotRuns: true}, strings.ToUpper(fixtureHead),
			"give the full commit SHA"},
	}
	var failed []string
	for _, c := range cases {
		out, err := gate(ctx, c.m, c.sha)
		if err == nil || !strings.Contains(err.Error(), c.want) {
			failed = append(failed, fmt.Sprintf("approval gate %q: %q, %v; want an error with %q", c.name, out, err, c.want))
		}
	}
	return failed
}

// gate calls approve-bot-runs with a nil token. A call that passes the gate
// reads the token and panics, and gate gives that panic as an error.
func gate(ctx context.Context, m *Ci, sha string) (out string, err error) {
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("it passed the gate and read the token: %v", r)
		}
	}()
	return m.ApproveBotRuns(ctx, nil, sha)
}
