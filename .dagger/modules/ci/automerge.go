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
	"path"
	"regexp"
	"slices"
	"sort"
	"strings"
	"time"

	"dagger/ci/internal/dagger"
)

// mergePolicy is the part of the rules that a repository sets in its
// dagger.toml. With no authors or no reviewer, no pull request merges
// without a person.
type mergePolicy struct {
	// Logins whose pull requests can merge without a person. A bot is
	// "app/<login>", as gh prints it. "*" is every author.
	Authors []string
	// The login whose review of the head counts. For the Codex connector, a
	// summary comment of a clean, completed review of the head counts too.
	Reviewer string
	// Path patterns (matchRiskyPath). A pull request that changes a matching
	// path is merged by a person.
	RiskyPaths []string
	// A check whose newest run on the head must succeed. With none, the rule
	// protected leaves the required checks to branch protection.
	CheckName string
	// A pull request that adds a file with git mode 100755, or that changes
	// the mode of a file to 100755, is merged by a person.
	RiskyExecutableBit bool
	// Path patterns of JSON manifest files (matchRiskyPath). With none, the
	// rules read no manifest.
	ManifestFiles []string
	// The fields of a manifest that can change without a person. A change of
	// another field is merged by a person.
	ManifestSafeFields []string
	// In a list of entries of a manifest, source can change only to a
	// relative path under this prefix, for example ./plugins/.
	ManifestSourcePrefix string
	// The review gate (reviewgate.go) posts the commit status
	// <StatusPrefix>/review. With none, the gate is off, and no status is the
	// status of the gate.
	StatusPrefix string
	// The name of the block in the review body of the reviewer that lists the
	// open findings. With none, the gate reads the reviewer the den way.
	ReviewMarker string
	// An APPROVE of the exact head by a second person opens the gate.
	SecondPersonApproval bool
	// A head with no status of the gate this long after its check finished
	// needs a person. With none, there is no timeout.
	ReviewTimeout time.Duration
	// The rule review-gate requires the success of the gate on the head.
	RequireReviewGate bool
}

// allowsAuthor reports whether the pull requests of login can merge without
// a person. "*" is every author, and an empty list refuses each author.
func (p mergePolicy) allowsAuthor(login string) bool {
	return slices.Contains(p.Authors, "*") || slices.Contains(p.Authors, login)
}

// gateContext is the context of the commit status of the review gate.
func (p mergePolicy) gateContext() string {
	return p.StatusPrefix + "/review"
}

// gateStatus reports whether c is the commit status of the review gate.
// GitHub compares the contexts of statuses without case. With no
// statusPrefix, no status is the status of the gate.
func (p mergePolicy) gateStatus(c prCheck) bool {
	return p.StatusPrefix != "" && c.Workflow == "status" && strings.EqualFold(c.Name, p.gateContext())
}

// gateStatusOf returns the newest status of the review gate on the head.
func (p mergePolicy) gateStatusOf(s *prSnapshot) (prCheck, bool) {
	for _, c := range newestChecks(s.Checks) {
		if p.gateStatus(c) {
			return c, true
		}
	}
	return prCheck{}, false
}

// matchRiskyPath reports whether the path name matches a risky-path pattern.
// A pattern without "*" is a prefix of the path. A pattern with "*" is a glob
// that must match the whole path. "*" matches in one level, and "**" as a
// whole level matches zero or more levels. "?", "[" and "\" match only
// themselves.
func matchRiskyPath(pattern, name string) bool {
	if !strings.Contains(pattern, "*") {
		return strings.HasPrefix(name, pattern)
	}
	return matchLevels(strings.Split(pattern, "/"), strings.Split(name, "/"))
}

// matchLevels matches the levels of a path to the levels of a glob.
func matchLevels(pattern, name []string) bool {
	for len(pattern) > 0 && pattern[0] != "**" {
		if len(name) == 0 {
			return false
		}
		// literalGlob leaves only "*" special, so path.Match cannot return
		// an error.
		if ok, _ := path.Match(literalGlob.Replace(pattern[0]), name[0]); !ok {
			return false
		}
		pattern, name = pattern[1:], name[1:]
	}
	if len(pattern) == 0 {
		return len(name) == 0
	}
	// "**" matches zero or more levels.
	for i := 0; i <= len(name); i++ {
		if matchLevels(pattern[1:], name[i:]) {
			return true
		}
	}
	return false
}

// literalGlob escapes each character other than "*" that path.Match reads
// as special.
var literalGlob = strings.NewReplacer(`\`, `\\`, `?`, `\?`, `[`, `\[`)

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
	// Done is when a check run completed, or when a commit status that is
	// not pending was posted.
	Done time.Time
	// The description of a commit status.
	Description string
}

type prReview struct {
	Author, State, Commit string
	// The text of the review, and when the reviewer submitted it.
	Body string
	At   time.Time
}

type prComment struct{ Author, Body string }

type prSnapshot struct {
	Number      int
	State       string // OPEN, MERGED or CLOSED
	Draft       bool
	Base, Trunk string
	Author      string
	Head        string
	// HeadRef is the name of the head branch. Fork: the head branch is in
	// another repository.
	HeadRef        string
	Fork           bool
	Labels         []string
	Body           string
	ReviewDecision string
	Mergeable      string
	// MergeState is GitHub's mergeStateStatus. GitHub computes it from the
	// branch protection of the base, so it names the checks that must pass.
	MergeState string
	MergedAt   time.Time
	Checks     []prCheck
	Reviews    []prReview
	Comments   []prComment
	Files      []string
	// ChangedFiles is GitHub's count. A query reads at most 100 paths, so
	// fewer Files than ChangedFiles means the list is incomplete.
	ChangedFiles int
	// ChecksIncomplete: GitHub has more check contexts than the query read.
	ChecksIncomplete bool
	// LabelsIncomplete: a replay did not read the whole label history.
	LabelsIncomplete bool
	// ReviewsIncomplete: GitHub has more reviews than the query read.
	ReviewsIncomplete bool
	Unresolved        int
	// Trees has each changed file in the Git trees of the merge base and the
	// head (automerge_files.go). fetch reads them only for
	// riskyExecutableBit and manifestFiles.
	Trees *prTrees
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
		if s.LabelsIncomplete {
			return "its label history is longer than the rules read; a person decides"
		}
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
		if p.allowsAuthor(s.Author) {
			return ""
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
				if matchRiskyPath(r, f) {
					return "it changes " + f + ", which a person merges"
				}
			}
		}
		return ""
	}},
	// A new executable file, a file that becomes executable, and a change of
	// a manifest file outside its safe fields are merged by a person.
	// automerge_files.go reads the changed files.
	{"executable-bit", false, func(s *prSnapshot, p mergePolicy) string {
		if !p.RiskyExecutableBit {
			return ""
		}
		return executableBit(s)
	}},
	{"manifest-fields", false, func(s *prSnapshot, p mergePolicy) string {
		if len(p.ManifestFiles) == 0 {
			return ""
		}
		return manifestFields(s, p)
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
	// With requireReviewGate, the review gate (reviewgate.go) must have
	// posted success on the head. The status of the gate is not a review: the
	// rule reviewed still needs the review of the reviewer.
	{"review-gate", false, func(s *prSnapshot, p mergePolicy) string {
		if !p.RequireReviewGate {
			return ""
		}
		if p.StatusPrefix == "" {
			return "requireReviewGate is set, but statusPrefix is empty, so the review gate is off"
		}
		c, ok := p.gateStatusOf(s)
		if !ok {
			return "head " + short(s.Head) + " has no " + p.gateContext() + " status"
		}
		if c.State != "SUCCESS" {
			return p.gateContext() + " is " + strings.ToLower(c.State) + " on head " + short(s.Head)
		}
		return ""
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
	{"checks", false, func(s *prSnapshot, p mergePolicy) string {
		if s.ChecksIncomplete {
			return "head " + short(s.Head) + " has more checks than the rules read; a person merges"
		}
		newest := newestChecks(s.Checks)
		// The status of the review gate is not a check that ran on the head.
		// Its failure refuses below, as the failure of each status does.
		if !slices.ContainsFunc(newest, func(c prCheck) bool { return !p.gateStatus(c) }) {
			return "no check ran on head " + short(s.Head)
		}
		for _, c := range newest {
			if !c.green() {
				return "checks are not all complete and green"
			}
		}
		return ""
	}},
	// A repository with no required check in branch protection can be CLEAN
	// before a check runs. With checkName, the newest run of that check on
	// the head must succeed. A skipped or a neutral run is green for the
	// checks rule, but it did not succeed.
	{"required-check", false, func(s *prSnapshot, p mergePolicy) string {
		if p.CheckName == "" {
			return ""
		}
		ran := false
		for _, c := range newestChecks(s.Checks) {
			// The status of the review gate is never the named check.
			if c.Name != p.CheckName || p.gateStatus(c) {
				continue
			}
			if !c.succeeded() {
				return "check " + p.CheckName + " did not succeed on head " + short(s.Head)
			}
			ran = true
		}
		if !ran {
			return "check " + p.CheckName + " has no run on head " + short(s.Head)
		}
		return ""
	}},
	{"mergeable", true, func(s *prSnapshot, _ mergePolicy) string {
		if s.Mergeable != "MERGEABLE" {
			return "mergeable is " + s.Mergeable
		}
		return ""
	}},
	// The checks rule judges only the checks that ran. Branch protection names
	// the checks that must run, so a check that has not started yet also
	// refuses. An admin can pass branch protection, so the rules do not leave
	// this to GitHub.
	{"protected", true, func(s *prSnapshot, _ mergePolicy) string {
		if s.MergeState != "CLEAN" && s.MergeState != "HAS_HOOKS" {
			return "merge state is " + s.MergeState + "; branch protection does not let head " + short(s.Head) + " merge"
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
	return c.succeeded() ||
		(c.Status == "COMPLETED" && (c.Conclusion == "SKIPPED" || c.Conclusion == "NEUTRAL"))
}

// succeeded reports whether the check passed. A skipped or a neutral check
// run is green, but it did not pass.
func (c prCheck) succeeded() bool {
	if c.Status == "" {
		return c.State == "SUCCESS"
	}
	return c.Status == "COMPLETED" && c.Conclusion == "SUCCESS"
}

// newestChecks keeps the newest entry of each check (its name and workflow).
// A new run of a check replaces the older entry, which a concurrency group
// can leave CANCELLED. An entry with no time is a queued run, and a queued
// run is newer than each run that has started.
func newestChecks(all []prCheck) []prCheck {
	newest := map[string]prCheck{}
	var order []string
	for _, c := range all {
		key := c.Name + "\x00" + c.Workflow
		old, seen := newest[key]
		if !seen {
			order = append(order, key)
		}
		if !seen || c.At.IsZero() || (!old.At.IsZero() && c.At.After(old.At)) {
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
// completed review of head with no unresolved finding. A review that a
// comment requests can leave the findings flag null. Codex posts each
// finding as a review thread, so the threads rule decides then, as it does
// for a review of the head.
func cleanCodexReview(comments []prComment, reviewer, head string) bool {
	for _, c := range comments {
		if c.Author != reviewer {
			continue
		}
		r, ok := parseCodexState(c.Body)
		if ok && r.CommitSHA == head && r.Status == "completed" && (r.Unresolved == nil || !*r.Unresolved) {
			return true
		}
	}
	return false
}

// codexReview is the code review in the state of a Codex summary comment.
type codexReview struct {
	CommitSHA  string `json:"commit_sha"`
	Status     string `json:"status"`
	Unresolved *bool  `json:"has_unresolved_findings"`
}

// parseCodexState reads the code review from the state that the Codex
// connector keeps in its summary comment.
func parseCodexState(body string) (codexReview, bool) {
	m := codexState.FindStringSubmatch(body)
	if m == nil {
		return codexReview{}, false
	}
	var state struct {
		CodeReview codexReview `json:"code_review"`
	}
	if json.Unmarshal([]byte(m[1]), &state) != nil {
		return codexReview{}, false
	}
	return state.CodeReview, true
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
      number state isDraft baseRefName baseRefOid headRefOid headRefName isCrossRepository body reviewDecision mergeable mergeStateStatus mergedAt changedFiles
      author { __typename login }
      labels(first: 50) { nodes { name } }
      timelineItems(first: 100, itemTypes: [LABELED_EVENT, UNLABELED_EVENT]) {
        pageInfo { hasNextPage }
        nodes {
          __typename
          ... on LabeledEvent { createdAt label { name } }
          ... on UnlabeledEvent { createdAt label { name } }
        }
      }
      reviews(first: 100) { totalCount nodes { author { __typename login } state submittedAt commit { oid } body } }
      comments(last: 50) { nodes { author { __typename login } body } }
      reviewThreads(first: 100) { nodes { isResolved } }
      files(first: 100) { nodes { path } }
      commits(last: 1) {
        nodes { commit { statusCheckRollup { contexts(first: 100) { totalCount nodes {
          __typename
          ... on CheckRun { name status conclusion startedAt completedAt checkSuite { workflowRun { workflow { name } } } }
          ... on StatusContext { context state description createdAt }
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
	Number            int
	State             string
	IsDraft           bool
	BaseRefName       string
	BaseRefOid        string
	HeadRefOid        string
	HeadRefName       string
	IsCrossRepository bool
	Body              string
	ReviewDecision    string
	Mergeable         string
	MergeStateStatus  string
	MergedAt          *time.Time
	ChangedFiles      int
	Author            *gqlActor
	Labels            struct{ Nodes []struct{ Name string } }
	TimelineItems     struct {
		PageInfo struct{ HasNextPage bool }
		Nodes    []struct {
			Typename  string `json:"__typename"`
			CreatedAt time.Time
			Label     struct{ Name string }
		}
	}
	Reviews struct {
		TotalCount int
		Nodes      []gqlReview
	}
	Comments struct {
		Nodes []struct {
			Author *gqlActor
			Body   string
		}
	}
	ReviewThreads struct{ Nodes []struct{ IsResolved bool } }
	Files         struct{ Nodes []struct{ Path string } }
	Commits       struct{ Nodes []gqlCommitNode }
	// Not from GraphQL: fetch reads the Git trees (readTrees).
	Trees *prTrees `json:"-"`
}

type gqlReview struct {
	Author      *gqlActor
	State       string
	SubmittedAt *time.Time
	Commit      *struct{ Oid string }
	Body        string
}

type gqlCommitNode struct {
	Commit struct{ StatusCheckRollup *gqlRollup }
}

type gqlRollup struct {
	Contexts struct {
		TotalCount int
		Nodes      []gqlContext
	}
}

type gqlContext struct {
	Typename                 string `json:"__typename"`
	Name, Status, Conclusion string
	StartedAt, CompletedAt   *time.Time
	CheckSuite               *struct {
		WorkflowRun *struct{ Workflow struct{ Name string } }
	}
	Context, State, Description string
	CreatedAt                   *time.Time
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
		ReviewDecision: pr.ReviewDecision, Mergeable: pr.Mergeable, MergeState: pr.MergeStateStatus,
		ChangedFiles: pr.ChangedFiles, Trees: pr.Trees,
		HeadRef: pr.HeadRefName, Fork: pr.IsCrossRepository,
		ReviewsIncomplete: pr.Reviews.TotalCount > len(pr.Reviews.Nodes),
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
		// A later page can hold a stop label from before the merge.
		s.LabelsIncomplete = pr.TimelineItems.PageInfo.HasNextPage
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
			s.Reviews = append(s.Reviews, prReview{Author: r.Author.name(), State: r.State, Commit: r.Commit.Oid,
				Body: r.Body, At: *r.SubmittedAt})
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
		contexts := n.Commit.StatusCheckRollup.Contexts
		if contexts.TotalCount > len(contexts.Nodes) {
			s.ChecksIncomplete = true
		}
		for _, c := range contexts.Nodes {
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
				if check.Status == "COMPLETED" && c.CompletedAt != nil {
					check.Done = *c.CompletedAt
				}
				s.Checks = append(s.Checks, check)
			case "StatusContext":
				if !before(c.CreatedAt) {
					continue
				}
				check := prCheck{Name: c.Context, Workflow: "status", State: c.State, Description: c.Description}
				if c.CreatedAt != nil {
					check.At = *c.CreatedAt
					if c.State != "PENDING" && c.State != "EXPECTED" {
						check.Done = *c.CreatedAt
					}
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
	return mergePolicy{Authors: m.Authors, Reviewer: m.Reviewer, RiskyPaths: m.RiskyPaths, CheckName: m.CheckName,
		RiskyExecutableBit: m.RiskyExecutableBit, ManifestFiles: m.ManifestFiles,
		ManifestSafeFields: m.ManifestSafeFields, ManifestSourcePrefix: m.ManifestSourcePrefix,
		StatusPrefix: m.StatusPrefix, ReviewMarker: m.ReviewMarker, SecondPersonApproval: m.SecondPersonApproval,
		ReviewTimeout: time.Duration(m.ReviewTimeoutHours) * time.Hour, RequireReviewGate: m.RequireReviewGate}
}

// queryPR reads pull request n with prQuery.
func queryPR(ctx context.Context, g *githubClient, owner, name string, n int) (*gqlRepo, error) {
	var out struct{ Repository gqlRepo }
	if err := g.graphql(ctx, prQuery, map[string]any{"o": owner, "r": name, "n": n}, &out); err != nil {
		return nil, fmt.Errorf("pull request %d: %w", n, err)
	}
	if out.Repository.PullRequest == nil {
		return nil, fmt.Errorf("pull request %d does not exist", n)
	}
	return &out.Repository, nil
}

// fetch reads pull request n for the merge rules: prQuery, and the Git trees
// when a file rule is on.
func (m *Ci) fetch(ctx context.Context, g *githubClient, owner, name string, n int) (*gqlRepo, error) {
	repo, err := queryPR(ctx, g, owner, name, n)
	if err != nil {
		return nil, err
	}
	if m.RiskyExecutableBit || len(m.ManifestFiles) > 0 {
		trees, err := m.readTrees(ctx, g, owner, name, repo.PullRequest)
		if err != nil {
			return nil, fmt.Errorf("pull request %d: %w", n, err)
		}
		repo.PullRequest.Trees = trees
	}
	return repo, nil
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
	return fmt.Sprintf("#%d: %s\n", pr, m.verdict(repo)), nil
}

// decision judges an open pull request by the merge rules. It returns whether
// the rules accept the pull request, the verdict text, the full head commit
// that was judged, and the merge method.
func (m *Ci) decision(repo *gqlRepo) (bool, string, string, string) {
	s := snapshotFrom(repo.PullRequest, repo.DefaultBranchRef.Name, false)
	if rule, why := judge(&s, m.policy(), false); rule != "" {
		return false, fmt.Sprintf("would not merge (%s): %s", rule, why), s.Head, ""
	}
	method := mergeMethod(repo)
	if method == "none" {
		return false, "would not merge (method): the repository allows no merge method", s.Head, ""
	}
	return true, fmt.Sprintf("would merge head %s with the %s method", short(s.Head), method), s.Head, method
}

// verdict judges an open pull request by the merge rules, and says what a
// merge would do.
func (m *Ci) verdict(repo *gqlRepo) string {
	_, text, _, _ := m.decision(repo)
	return text
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
