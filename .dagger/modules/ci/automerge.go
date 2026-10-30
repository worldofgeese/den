// Merge rules for pull requests, and a replay of them over merged pull
// requests (plan P0). The rules are the automerge filter of
// modules/M-02877/pr-reviewer.nix, in its order, with the stops of plan D4.
// The first rule that refuses gives the reason. These functions merge
// nothing: live merges come in plan P4.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"time"

	"dagger/ci/internal/dagger"
)

// mergePolicy is the part of the rules that a repository sets in its
// dagger.toml. An empty value refuses: with no authors, no pull request
// merges without a person.
type mergePolicy struct {
	// Logins whose pull requests can merge without a person. A bot is
	// "app/<login>", as gh prints it.
	Authors []string
	// The login whose review of the head counts. For the Codex connector, a
	// summary comment of a clean, completed review of the head counts too.
	Reviewer string
	// Path prefixes. A pull request that changes one is merged by a person.
	RiskyPaths []string
}

// stopLabels stop all automation (plan D4).
var stopLabels = []string{"hold", "do-not-merge", "needs-human"}

// manualSteps finds a description that asks a person to act before the merge.
var manualSteps = regexp.MustCompile(`(?i)before you merge`)

// codexState finds the state that the Codex connector keeps in its summary
// comment. It posts no review when it finds nothing.
var codexState = regexp.MustCompile(`codex-review-state:v1 (\{.*\})\s*-->`)

type prCheck struct {
	// A check run has a status and a conclusion. A commit status has only a
	// state.
	Name, Workflow, Status, Conclusion, State string
	At                                        time.Time
}

type prReview struct{ Author, State, Commit string }

type prComment struct{ Author, Body string }

type prSnapshot struct {
	Number         int
	State          string // OPEN, MERGED or CLOSED
	Draft          bool
	Base, Trunk    string
	Author         string
	Head           string
	Labels         []string
	Body           string
	ReviewDecision string
	Mergeable      string
	MergedAt       time.Time
	Checks         []prCheck
	Reviews        []prReview
	Comments       []prComment
	Files          []string
	// ChangedFiles is GitHub's count. A query reads at most 100 paths, so
	// fewer Files than ChangedFiles means the list is incomplete.
	ChangedFiles int
	Unresolved   int
}

type mergeRule struct {
	Name string
	// A live rule judges only an open pull request, so a replay skips it.
	Live   bool
	Refuse func(s *prSnapshot, p mergePolicy) string
}

var mergeRules = []mergeRule{
	{"open", true, func(s *prSnapshot, _ mergePolicy) string {
		if s.State != "OPEN" {
			return "the pull request is " + strings.ToLower(s.State)
		}
		return ""
	}},
	{"draft", false, func(s *prSnapshot, _ mergePolicy) string {
		if s.Draft {
			return "draft"
		}
		return ""
	}},
	{"stacked", false, func(s *prSnapshot, _ mergePolicy) string {
		// A merge would land the pull request in the other branch.
		if s.Base != s.Trunk {
			return "stacked on " + s.Base + "; merge the stack from its bottom pull request"
		}
		return ""
	}},
	{"labels", false, func(s *prSnapshot, _ mergePolicy) string {
		for _, l := range s.Labels {
			for _, stop := range stopLabels {
				if strings.EqualFold(l, stop) {
					return "labelled " + stop
				}
			}
		}
		return ""
	}},
	{"author", false, func(s *prSnapshot, p mergePolicy) string {
		for _, a := range p.Authors {
			if a == s.Author {
				return ""
			}
		}
		return "author " + s.Author + " is merged by a person"
	}},
	{"risky-paths", false, func(s *prSnapshot, p mergePolicy) string {
		// A path that the query did not read can be a risky one.
		if s.ChangedFiles > len(s.Files) {
			return fmt.Sprintf("it changes %d files, more than the %d that the rules read; a person merges", s.ChangedFiles, len(s.Files))
		}
		for _, f := range s.Files {
			for _, r := range p.RiskyPaths {
				if strings.HasPrefix(f, r) {
					return "it changes " + f + ", which a person merges"
				}
			}
		}
		return ""
	}},
	{"reviewed", false, func(s *prSnapshot, p mergePolicy) string {
		if p.Reviewer == "" {
			return "no reviewer is set"
		}
		// A submitted review of this exact commit. The next rule judges a
		// review that requests changes.
		for _, r := range s.Reviews {
			if r.Author == p.Reviewer && r.Commit == s.Head &&
				(r.State == "COMMENTED" || r.State == "APPROVED" || r.State == "CHANGES_REQUESTED") {
				return ""
			}
		}
		if cleanCodexReview(s.Comments, p.Reviewer, s.Head) {
			return ""
		}
		return p.Reviewer + " has not reviewed head " + short(s.Head)
	}},
	{"changes-requested", false, func(s *prSnapshot, _ mergePolicy) string {
		if s.ReviewDecision == "CHANGES_REQUESTED" {
			return "changes requested"
		}
		return ""
	}},
	{"manual-steps", false, func(s *prSnapshot, _ mergePolicy) string {
		if manualSteps.MatchString(s.Body) {
			return "its description lists manual before-you-merge steps"
		}
		return ""
	}},
	{"checks", false, func(s *prSnapshot, _ mergePolicy) string {
		newest := newestChecks(s.Checks)
		if len(newest) == 0 {
			return "no check ran on head " + short(s.Head)
		}
		for _, c := range newest {
			if !c.green() {
				return "checks are not all complete and green"
			}
		}
		return ""
	}},
	{"mergeable", true, func(s *prSnapshot, _ mergePolicy) string {
		if s.Mergeable != "MERGEABLE" {
			return "mergeable is " + s.Mergeable
		}
		return ""
	}},
	{"threads", false, func(s *prSnapshot, _ mergePolicy) string {
		if s.Unresolved > 0 {
			return fmt.Sprintf("%d unresolved review thread(s)", s.Unresolved)
		}
		return ""
	}},
}

// judge returns the name and the reason of the first rule that refuses, or
// two empty strings when the pull request can merge.
func judge(s *prSnapshot, p mergePolicy, replay bool) (string, string) {
	for _, r := range mergeRules {
		if replay && r.Live {
			continue
		}
		if why := r.Refuse(s, p); why != "" {
			return r.Name, why
		}
	}
	return "", ""
}

func (c prCheck) green() bool {
	if c.Status == "" {
		return c.State == "SUCCESS"
	}
	return c.Status == "COMPLETED" &&
		(c.Conclusion == "SUCCESS" || c.Conclusion == "SKIPPED" || c.Conclusion == "NEUTRAL")
}

// newestChecks keeps the newest entry of each check (its name and workflow).
// A new run of a check replaces the older entry, which a concurrency group
// can leave CANCELLED.
func newestChecks(all []prCheck) []prCheck {
	newest := map[string]prCheck{}
	var order []string
	for _, c := range all {
		key := c.Name + "\x00" + c.Workflow
		old, seen := newest[key]
		if !seen {
			order = append(order, key)
		}
		if !seen || c.At.After(old.At) {
			newest[key] = c
		}
	}
	out := make([]prCheck, 0, len(order))
	for _, key := range order {
		out = append(out, newest[key])
	}
	return out
}

// cleanCodexReview reports whether a comment of the reviewer records a
// completed review of head with no unresolved finding.
func cleanCodexReview(comments []prComment, reviewer, head string) bool {
	for _, c := range comments {
		if c.Author != reviewer {
			continue
		}
		m := codexState.FindStringSubmatch(c.Body)
		if m == nil {
			continue
		}
		var state struct {
			CodeReview struct {
				CommitSHA  string `json:"commit_sha"`
				Status     string `json:"status"`
				Unresolved *bool  `json:"has_unresolved_findings"`
			} `json:"code_review"`
		}
		if json.Unmarshal([]byte(m[1]), &state) != nil {
			continue
		}
		r := state.CodeReview
		if r.CommitSHA == head && r.Status == "completed" && r.Unresolved != nil && !*r.Unresolved {
			return true
		}
	}
	return false
}

func short(sha string) string {
	if len(sha) > 12 {
		return sha[:12]
	}
	return sha
}

// The GitHub GraphQL API. The token is a Dagger secret; read access is
// enough for these functions.
type githubClient struct {
	token string
	http  *http.Client
}

func (g *githubClient) graphql(ctx context.Context, query string, vars map[string]any, out any) error {
	body, err := json.Marshal(map[string]any{"query": query, "variables": vars})
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://api.github.com/graphql", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "bearer "+g.token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := g.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	var reply struct {
		Data   json.RawMessage
		Errors []struct{ Message string }
	}
	if err := json.NewDecoder(resp.Body).Decode(&reply); err != nil {
		return fmt.Errorf("GitHub GraphQL: HTTP %d: %w", resp.StatusCode, err)
	}
	if len(reply.Errors) > 0 {
		return fmt.Errorf("GitHub GraphQL: %s", reply.Errors[0].Message)
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("GitHub GraphQL: HTTP %d", resp.StatusCode)
	}
	return json.Unmarshal(reply.Data, out)
}

const prQuery = `query($o: String!, $r: String!, $n: Int!) {
  repository(owner: $o, name: $r) {
    defaultBranchRef { name }
    mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed
    pullRequest(number: $n) {
      number state isDraft baseRefName headRefOid body reviewDecision mergeable mergedAt changedFiles
      author { __typename login }
      labels(first: 50) { nodes { name } }
      timelineItems(first: 100, itemTypes: [LABELED_EVENT, UNLABELED_EVENT]) {
        nodes {
          __typename
          ... on LabeledEvent { createdAt label { name } }
          ... on UnlabeledEvent { createdAt label { name } }
        }
      }
      reviews(first: 100) { nodes { author { __typename login } state submittedAt commit { oid } } }
      comments(last: 50) { nodes { author { __typename login } body } }
      reviewThreads(first: 100) { nodes { isResolved } }
      files(first: 100) { nodes { path } }
      commits(last: 1) {
        nodes { commit { statusCheckRollup { contexts(first: 100) { nodes {
          __typename
          ... on CheckRun { name status conclusion startedAt completedAt checkSuite { workflowRun { workflow { name } } } }
          ... on StatusContext { context state createdAt }
        } } } } }
      }
    }
  }
}`

type gqlActor struct {
	Typename string `json:"__typename"`
	Login    string
}

// name is the login as gh prints it: a bot is "app/<login>".
func (a *gqlActor) name() string {
	if a == nil {
		return ""
	}
	if a.Typename == "Bot" {
		return "app/" + a.Login
	}
	return a.Login
}

type gqlPR struct {
	Number         int
	State          string
	IsDraft        bool
	BaseRefName    string
	HeadRefOid     string
	Body           string
	ReviewDecision string
	Mergeable      string
	MergedAt       *time.Time
	ChangedFiles   int
	Author         *gqlActor
	Labels         struct{ Nodes []struct{ Name string } }
	TimelineItems  struct {
		Nodes []struct {
			Typename  string `json:"__typename"`
			CreatedAt time.Time
			Label     struct{ Name string }
		}
	}
	Reviews struct {
		Nodes []struct {
			Author      *gqlActor
			State       string
			SubmittedAt *time.Time
			Commit      *struct{ Oid string }
		}
	}
	Comments struct {
		Nodes []struct {
			Author *gqlActor
			Body   string
		}
	}
	ReviewThreads struct{ Nodes []struct{ IsResolved bool } }
	Files         struct{ Nodes []struct{ Path string } }
	Commits       struct {
		Nodes []struct {
			Commit struct {
				StatusCheckRollup *struct {
					Contexts struct{ Nodes []gqlContext }
				}
			}
		}
	}
}

type gqlContext struct {
	Typename                 string `json:"__typename"`
	Name, Status, Conclusion string
	StartedAt, CompletedAt   *time.Time
	CheckSuite               *struct {
		WorkflowRun *struct{ Workflow struct{ Name string } }
	}
	Context, State string
	CreatedAt      *time.Time
}

type gqlRepo struct {
	DefaultBranchRef   struct{ Name string }
	MergeCommitAllowed bool
	SquashMergeAllowed bool
	RebaseMergeAllowed bool
	PullRequest        *gqlPR
}

// snapshotFrom turns a pull request into what the rules read. A replay judges
// a merged pull request as of its merge: the labels from the label events
// before the merge, and only the reviews and checks from before it.
func snapshotFrom(pr *gqlPR, trunk string, replay bool) prSnapshot {
	s := prSnapshot{
		Number: pr.Number, State: pr.State, Draft: pr.IsDraft, Base: pr.BaseRefName,
		Trunk: trunk, Author: pr.Author.name(), Head: pr.HeadRefOid, Body: pr.Body,
		ReviewDecision: pr.ReviewDecision, Mergeable: pr.Mergeable, ChangedFiles: pr.ChangedFiles,
	}
	var cutoff time.Time
	if replay && pr.MergedAt != nil {
		cutoff = *pr.MergedAt
		s.MergedAt = cutoff
	}
	before := func(t *time.Time) bool {
		return cutoff.IsZero() || (t != nil && !t.After(cutoff))
	}
	if replay {
		on := map[string]bool{}
		var order []string
		for _, e := range pr.TimelineItems.Nodes {
			if e.CreatedAt.After(cutoff) {
				continue
			}
			switch e.Typename {
			case "LabeledEvent":
				if _, seen := on[e.Label.Name]; !seen {
					order = append(order, e.Label.Name)
				}
				on[e.Label.Name] = true
			case "UnlabeledEvent":
				on[e.Label.Name] = false
			}
		}
		for _, l := range order {
			if on[l] {
				s.Labels = append(s.Labels, l)
			}
		}
	} else {
		for _, l := range pr.Labels.Nodes {
			s.Labels = append(s.Labels, l.Name)
		}
	}
	for _, r := range pr.Reviews.Nodes {
		if r.Commit != nil && r.SubmittedAt != nil && before(r.SubmittedAt) {
			s.Reviews = append(s.Reviews, prReview{Author: r.Author.name(), State: r.State, Commit: r.Commit.Oid})
		}
	}
	for _, c := range pr.Comments.Nodes {
		s.Comments = append(s.Comments, prComment{Author: c.Author.name(), Body: c.Body})
	}
	for _, t := range pr.ReviewThreads.Nodes {
		if !t.IsResolved {
			s.Unresolved++
		}
	}
	for _, f := range pr.Files.Nodes {
		s.Files = append(s.Files, f.Path)
	}
	for _, n := range pr.Commits.Nodes {
		if n.Commit.StatusCheckRollup == nil {
			continue
		}
		for _, c := range n.Commit.StatusCheckRollup.Contexts.Nodes {
			switch c.Typename {
			case "CheckRun":
				check := prCheck{Name: c.Name, Status: c.Status, Conclusion: c.Conclusion}
				if replay {
					// After a merge, the push to main adds runs to the same
					// commit: a run that started after the merge does not
					// count. A run that was still running at the merge was not
					// complete then.
					if c.StartedAt != nil && c.StartedAt.After(cutoff) {
						continue
					}
					if c.CompletedAt == nil || c.CompletedAt.After(cutoff) {
						check.Status, check.Conclusion = "IN_PROGRESS", ""
					}
				}
				if c.CheckSuite != nil && c.CheckSuite.WorkflowRun != nil {
					check.Workflow = c.CheckSuite.WorkflowRun.Workflow.Name
				}
				// A new run of a check replaces the older one: order by start.
				if at := c.StartedAt; at != nil {
					check.At = *at
				} else if at := c.CompletedAt; at != nil {
					check.At = *at
				}
				s.Checks = append(s.Checks, check)
			case "StatusContext":
				if !before(c.CreatedAt) {
					continue
				}
				check := prCheck{Name: c.Context, Workflow: "status", State: c.State}
				if c.CreatedAt != nil {
					check.At = *c.CreatedAt
				}
				s.Checks = append(s.Checks, check)
			}
		}
	}
	return s
}

// mergeMethod is the method that den's automerger uses: a merge commit where
// the repository allows it, else squash, else rebase.
func mergeMethod(r *gqlRepo) string {
	switch {
	case r.MergeCommitAllowed:
		return "merge"
	case r.SquashMergeAllowed:
		return "squash"
	case r.RebaseMergeAllowed:
		return "rebase"
	}
	return "none"
}

func (m *Ci) github(ctx context.Context, token *dagger.Secret) (*githubClient, string, string, error) {
	owner, name, ok := strings.Cut(m.Repository, "/")
	if !ok || owner == "" || name == "" {
		return nil, "", "", fmt.Errorf("set the repository setting to owner/name, not %q", m.Repository)
	}
	plain, err := token.Plaintext(ctx)
	if err != nil {
		return nil, "", "", err
	}
	return &githubClient{token: plain, http: &http.Client{Timeout: 60 * time.Second}}, owner, name, nil
}

func (m *Ci) policy() mergePolicy {
	return mergePolicy{Authors: m.Authors, Reviewer: m.Reviewer, RiskyPaths: m.RiskyPaths}
}

func (m *Ci) fetch(ctx context.Context, g *githubClient, owner, name string, n int) (*gqlRepo, error) {
	var out struct{ Repository gqlRepo }
	if err := g.graphql(ctx, prQuery, map[string]any{"o": owner, "r": name, "n": n}, &out); err != nil {
		return nil, fmt.Errorf("pull request %d: %w", n, err)
	}
	if out.Repository.PullRequest == nil {
		return nil, fmt.Errorf("pull request %d does not exist", n)
	}
	return &out.Repository, nil
}

// Judge an open pull request by the merge rules, and say what a merge would
// do. It merges nothing.
// +cache="never"
func (m *Ci) AutomergeDryRun(
	ctx context.Context,
	// A GitHub token that can read the repository.
	token *dagger.Secret,
	// The pull request.
	pr int,
) (string, error) {
	g, owner, name, err := m.github(ctx, token)
	if err != nil {
		return "", err
	}
	repo, err := m.fetch(ctx, g, owner, name, pr)
	if err != nil {
		return "", err
	}
	s := snapshotFrom(repo.PullRequest, repo.DefaultBranchRef.Name, false)
	if rule, why := judge(&s, m.policy(), false); rule != "" {
		return fmt.Sprintf("#%d: would not merge (%s): %s\n", pr, rule, why), nil
	}
	return fmt.Sprintf("#%d: would merge head %s with the %s method\n", pr, short(s.Head), mergeMethod(repo)), nil
}

// Judge the newest merged pull requests as of their merge, and print a
// Markdown table of the verdicts.
// +cache="never"
func (m *Ci) AutomergeReplay(
	ctx context.Context,
	// A GitHub token that can read the repository.
	token *dagger.Secret,
	// How many merged pull requests to judge, newest first.
	// +default=30
	count int,
) (string, error) {
	g, owner, name, err := m.github(ctx, token)
	if err != nil {
		return "", err
	}
	if count < 1 || count > 100 {
		return "", fmt.Errorf("count is %d; use 1 to 100", count)
	}
	var list struct {
		Repository struct {
			PullRequests struct {
				Nodes []struct {
					Number   int
					MergedAt time.Time
				}
			}
		}
	}
	// GitHub cannot order pull requests by their merge, so read the 100
	// newest merged ones and sort them by the time of the merge.
	const listQuery = `query($o: String!, $r: String!) {
  repository(owner: $o, name: $r) {
    pullRequests(states: MERGED, last: 100, orderBy: {field: CREATED_AT, direction: ASC}) { nodes { number mergedAt } }
  }
}`
	if err := g.graphql(ctx, listQuery, map[string]any{"o": owner, "r": name}, &list); err != nil {
		return "", err
	}
	nodes := list.Repository.PullRequests.Nodes
	sort.Slice(nodes, func(i, j int) bool { return nodes[i].MergedAt.After(nodes[j].MergedAt) })
	if len(nodes) > count {
		nodes = nodes[:count]
	}
	var b strings.Builder
	b.WriteString("| PR | Merged (UTC) | Head | Verdict | Rule | Reason |\n|---|---|---|---|---|---|\n")
	accepted := 0
	for _, node := range nodes {
		repo, err := m.fetch(ctx, g, owner, name, node.Number)
		if err != nil {
			return "", err
		}
		s := snapshotFrom(repo.PullRequest, repo.DefaultBranchRef.Name, true)
		rule, why := judge(&s, m.policy(), true)
		verdict := "refuse"
		if rule == "" {
			verdict, rule, why = "accept", "-", "-"
			accepted++
		}
		fmt.Fprintf(&b, "| #%d | %s | `%s` | %s | %s | %s |\n", s.Number,
			s.MergedAt.UTC().Format("2006-01-02 15:04"), short(s.Head), verdict, rule,
			strings.ReplaceAll(why, "|", "\\|"))
	}
	fmt.Fprintf(&b, "\n%d accepted, %d refused, of %d merged pull requests.\n", accepted, len(nodes)-accepted, len(nodes))
	b.WriteString("The unresolved threads, the review decision and the Codex summary are read as they are now, not as of the merge.\n")
	return b.String(), nil
}
