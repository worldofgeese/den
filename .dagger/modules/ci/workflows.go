package main

import (
	"cmp"
	"context"
	"fmt"
	"maps"
	"regexp"
	"slices"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// The job kinds of ci:workflow-isolation. The kind of a job in
// .github/workflows decides what the job can hold, so that no job both runs
// the code of a pull request and holds a secret or a write scope. The
// jobKinds setting gives each job its kind, and what the kinds hold in the
// repository. With no jobKinds, the check is off.
type jobKind string

const (
	// Runs the code of a pull request, for example dagger check on a head.
	// It holds at most contents: read, no secret (not even the token of the
	// job) and no cache that a later job can restore.
	checkKind jobKind = "CHECK"
	// Runs agents from the module of main, in agentEnvironment, which holds
	// the secret of the AGENT jobs. It holds at most contents: read. It reads
	// the text of pull requests as data, and never gets their code.
	agentKind jobKind = "AGENT"
	// Reads and writes GitHub with the GITHUB_TOKEN of the job and the scopes
	// of kindScopes. It holds no other secret, and never gets the code of a
	// pull request.
	githubKind jobKind = "GITHUB"
	// Reads with the secret of the SCAN jobs, and holds at most
	// contents: read. It never gets the code of a pull request.
	scanKind jobKind = "SCAN"
	// A job from before the kinds. Until a person replaces it, it keeps
	// exactly what the legacy part of the table records for it: its scopes,
	// its secrets, the actions beyond the allowlist, its environment, whether
	// its checkout keeps the token, and whether it runs on any branch. Each
	// other rule of a GITHUB job applies to it: no code of a pull request,
	// actions pinned to a commit SHA, no container and no reusable workflow.
	legacyKind jobKind = "LEGACY"
)

var allKinds = []jobKind{checkKind, agentKind, githubKind, scanKind, legacyKind}

// jobKinds is the table of the jobKinds setting, in YAML.
type jobKinds struct {
	// The kind of each job, as <workflow file>/<job id>. A job that is not
	// here fits no kind, and fails the check. An entry for a job that does
	// not exist allows that job; it does not require it.
	Jobs map[string]jobKind `yaml:"jobs"`
	// The one secret that the AGENT jobs, and the one secret that the SCAN
	// jobs, can reference. A GITHUB job references only GITHUB_TOKEN, and a
	// CHECK job no secret.
	Secrets map[jobKind]string `yaml:"secrets"`
	// The environment that holds the secret of the AGENT jobs. Each AGENT
	// job runs in it, and no other job does.
	AgentEnvironment string `yaml:"agentEnvironment"`
	// The actions that each job can use, each pinned to a commit SHA.
	Actions []string `yaml:"actions"`
	// The uses values of local actions, which need no pin, for example
	// $/.github/actions/dagger. A ./ path loads the action from the
	// checkout.
	LocalActions []string `yaml:"localActions"`
	// The jobs that build a GitHub Pages site: they can use
	// actions/upload-pages-artifact.
	PagesBuild []string `yaml:"pagesBuild"`
	// The jobs that deploy it: they can hold pages: write and
	// id-token: write, use actions/deploy-pages and run in the environment
	// github-pages.
	PagesDeploy []string `yaml:"pagesDeploy"`
	// What each LEGACY job keeps until a person replaces it.
	Legacy map[string]legacyJob `yaml:"legacy"`
}

type legacyJob struct {
	// Its scopes, exactly.
	Permissions map[string]string `yaml:"permissions"`
	// Each secret that it references, once for each reference.
	Secrets []string `yaml:"secrets"`
	// The actions that it uses besides the allowlist.
	Actions []string `yaml:"actions"`
	// The environment that it runs in, or none.
	Environment string `yaml:"environment"`
	// Its checkout keeps the token of the job, for a later push.
	KeepsToken bool `yaml:"keepsToken"`
	// It runs on each branch that a workflow_dispatch picks.
	AnyBranch bool `yaml:"anyBranch"`
}

// The GitHub Pages actions and environment.
const (
	pagesUpload      = "actions/upload-pages-artifact"
	pagesDeployment  = "actions/deploy-pages"
	pagesEnvironment = "github-pages"
)

// The scopes that each kind can hold, at most at the level given. A scope
// set to none counts as not held. A LEGACY job holds what the table records.
var kindScopes = map[jobKind]map[string]string{
	checkKind: {"contents": "read"},
	agentKind: {"contents": "read"},
	scanKind:  {"contents": "read"},
	githubKind: {
		"actions": "write", "checks": "write", "contents": "write",
		"issues": "write", "pull-requests": "write", "statuses": "write",
	},
}

// The events that run the copy of a workflow on main, never the copy of a
// pull request. A workflow with a job of another kind than CHECK starts only
// on these.
var mainEvents = []string{"issue_comment", "issues", "schedule", "workflow_dispatch", "workflow_run"}

var (
	// A full commit SHA, as GitHub writes it.
	commitSHA = regexp.MustCompile(`^[0-9a-f]{40}$`)
	// <workflow file>/<job id>.
	jobKeyPattern = regexp.MustCompile(`^[^/]+\.ya?ml/[A-Za-z_][A-Za-z0-9_-]*$`)
	cacheUse      = regexp.MustCompile(`(?i)\S*cache\S*`)
	// x['name'] in an expression, which reads the same as x.name.
	indexRead = regexp.MustCompile(`\[\s*'([^']*)'\s*\]`)
	// What reaches the code of a pull request, after indexRead: its refs,
	// the head of the run or pull request that started a workflow, and the
	// checkout of gh. Case-insensitive, as the expressions of GitHub are.
	prRef = regexp.MustCompile(`(?i)refs/pull/|\bpull/(?:\$\{\{.*?\}\}|[^/\s]+)/(?:head|merge)\b|head_(?:ref|sha|branch|commit|repository)|\bhead\s*(?:\.\s*(?:ref|sha)\b|\[)|merge_commit_sha|gh\s+pr\s+checkout`)
)

type yamlMap = map[string]any

func asMap(v any) yamlMap { m, _ := v.(yamlMap); return m }

func asList(v any) []any { l, _ := v.([]any); return l }

// parseJobKinds reads the jobKinds setting. An empty setting turns the check
// off, and gives nil.
func parseJobKinds(text string) (*jobKinds, error) {
	if strings.TrimSpace(text) == "" {
		return nil, nil
	}
	var t jobKinds
	dec := yaml.NewDecoder(strings.NewReader(text))
	dec.KnownFields(true)
	if err := dec.Decode(&t); err != nil {
		return nil, fmt.Errorf("the jobKinds setting is not a valid table: %w", err)
	}
	var bad []string
	if len(t.Jobs) == 0 {
		bad = append(bad, "it names no job; to turn the check off, leave the setting empty")
	}
	for _, key := range slices.Sorted(maps.Keys(t.Jobs)) {
		kind := t.Jobs[key]
		if !jobKeyPattern.MatchString(key) {
			bad = append(bad, fmt.Sprintf("the job %q is not <workflow file>/<job id>", key))
		}
		if !slices.Contains(allKinds, kind) {
			bad = append(bad, fmt.Sprintf("the kind %q of %s is not CHECK, AGENT, GITHUB, SCAN or LEGACY", kind, key))
		}
		if kind == agentKind && t.AgentEnvironment == "" {
			bad = append(bad, fmt.Sprintf("the AGENT job %s needs agentEnvironment, the environment that holds its secret", key))
		}
	}
	for _, kind := range slices.Sorted(maps.Keys(t.Secrets)) {
		if kind != agentKind && kind != scanKind {
			bad = append(bad, fmt.Sprintf("secrets names a secret for %s jobs; it names the secrets of AGENT and SCAN jobs only", kind))
		}
	}
	for _, key := range slices.Sorted(maps.Keys(t.Legacy)) {
		if t.Jobs[key] != legacyKind {
			bad = append(bad, fmt.Sprintf("legacy names %s, which is not a LEGACY job in jobs", key))
		}
		slices.Sort(t.Legacy[key].Secrets)
	}
	if len(bad) > 0 {
		return nil, fmt.Errorf("the jobKinds setting is not a valid table: %s", strings.Join(bad, "; "))
	}
	return &t, nil
}

// secret is the one secret that a job of kind can reference: none for CHECK,
// GITHUB_TOKEN for GITHUB, and the secret in the table for AGENT and SCAN.
func (t *jobKinds) secret(kind jobKind) string {
	if kind == githubKind {
		return "GITHUB_TOKEN"
	}
	return t.Secrets[kind]
}

// Each job in .github/workflows holds only what its kind allows. The jobKinds
// setting gives each job its kind, and a job that it does not name fails.
// Each workflow sets `permissions: {}`, and each job its own scopes. No
// workflow starts on pull_request_target. A workflow with a job of another
// kind than CHECK starts only on events that run the copy of the workflow on
// main. If one of those events is workflow_dispatch, which can pick a branch,
// the condition of that job requires github.ref == 'refs/heads/main'. A CHECK
// job holds at most contents: read, no secret and no cache. An AGENT job runs
// in agentEnvironment and holds at most contents: read and the secret of the
// AGENT jobs. A GITHUB job holds only the token of the job and the scopes
// that it can have. Only the pagesDeploy jobs hold pages and id-token. AGENT,
// GITHUB, SCAN and LEGACY jobs never check out or fetch the code of a pull
// request. Each job uses only the allowed actions, pinned to a commit SHA,
// and no checkout keeps the token of the job. A LEGACY job keeps exactly what
// the table records for it, and the other rules apply to it. With no
// jobKinds, the check is off: it reads no workflow.
// +check
func (m *Ci) WorkflowIsolation(ctx context.Context) error {
	t, err := parseJobKinds(m.JobKinds)
	if err != nil || t == nil {
		return err
	}
	dir := m.Source.Directory(".github/workflows")
	names, err := dir.Entries(ctx)
	if err != nil {
		return err
	}
	workflows := map[string]yamlMap{}
	var bad []string
	for _, name := range names {
		if !strings.HasSuffix(name, ".yml") && !strings.HasSuffix(name, ".yaml") {
			continue
		}
		src, err := dir.File(name).Contents(ctx)
		if err != nil {
			return err
		}
		var doc yamlMap
		if err := yaml.Unmarshal([]byte(src), &doc); err != nil {
			bad = append(bad, fmt.Sprintf("%s: not valid YAML: %v", name, err))
			continue
		}
		workflows[name] = doc
	}
	bad = append(bad, workflowProblems(workflows, t)...)
	if len(bad) > 0 {
		return fmt.Errorf("%d job kind problem(s); see the jobKinds setting in dagger.toml:\n  %s",
			len(bad), strings.Join(bad, "\n  "))
	}
	return nil
}

// workflowProblems lists, sorted, how the workflows break the job kinds of
// the table t. workflows maps each file name in .github/workflows to its
// parsed YAML.
func workflowProblems(workflows map[string]yamlMap, t *jobKinds) []string {
	var out []string
	for file, doc := range workflows {
		add := func(format string, a ...any) { out = append(out, file+": "+fmt.Sprintf(format, a...)) }
		if p, ok := doc["permissions"].(yamlMap); !ok || len(p) != 0 {
			add("the top-level permissions are %s; want {}, and the scopes on each job", show(doc["permissions"]))
		}
		events := triggers(doc["on"])
		if len(events) == 0 {
			add("has no trigger (on)")
		}
		if slices.Contains(events, "pull_request_target") {
			add("starts on pull_request_target, which gives the run of a pull request a write token: no workflow can use it")
		}
		onlyChecks := true
		all := asMap(doc["jobs"])
		if len(all) == 0 {
			add("has no jobs")
		}
		for _, id := range slices.Sorted(maps.Keys(all)) {
			key := file + "/" + id
			kind, ok := t.Jobs[key]
			if !ok {
				add("job %s fits no kind: give it one in the jobKinds setting", id)
				continue
			}
			onlyChecks = onlyChecks && kind == checkKind
			for _, p := range jobProblems(t, key, kind, asMap(all[id]), doc["env"], slices.Contains(events, "workflow_dispatch")) {
				add("job %s (%s): %s", id, kind, p)
			}
		}
		if onlyChecks {
			continue
		}
		for _, e := range events {
			if !slices.Contains(mainEvents, e) && e != "pull_request_target" {
				add("starts on %s, but it has jobs that are not CHECK jobs, which start only on %s (the copy of the workflow on main)",
					e, strings.Join(mainEvents, ", "))
			}
		}
	}
	sort.Strings(out)
	return out
}

// jobProblems lists how one job breaks the rules of its kind. key is
// <workflow file>/<job id>, env is the env of the workflow, which the job
// inherits, and dispatch is whether the workflow starts on
// workflow_dispatch, which can run it on any branch.
func jobProblems(t *jobKinds, key string, kind jobKind, job yamlMap, env any, dispatch bool) []string {
	var out []string
	add := func(format string, a ...any) { out = append(out, fmt.Sprintf(format, a...)) }
	// The zero value for each kind but LEGACY.
	legacy := t.Legacy[key]

	perms, ok := job["permissions"].(yamlMap)
	if !ok {
		add("declares no permissions (%s); every job lists the scopes it needs", show(job["permissions"]))
	}
	scopes := map[string]string{}
	for scope, level := range perms {
		if l := fmt.Sprint(level); l != "none" {
			scopes[scope] = l
		}
	}
	inherited := yamlMap{"env": env, "job": job}
	secrets := secretRefs(texts(inherited))
	if _, ok := job["secrets"]; ok {
		secrets = append(secrets, "*")
		sort.Strings(secrets)
	}

	if kind == legacyKind {
		if show(scopes) != show(legacy.Permissions) {
			add("holds %s, but a LEGACY job keeps exactly what the table records for it, %s, until a person replaces it",
				show(scopes), show(legacy.Permissions))
		}
		if !slices.Equal(secrets, legacy.Secrets) {
			add("references %s, but a LEGACY job keeps exactly what the table records for it, %s, until a person replaces it",
				showSecrets(secrets), showSecrets(legacy.Secrets))
		}
	} else {
		allowed := kindScopes[kind]
		for _, scope := range slices.Sorted(maps.Keys(scopes)) {
			level := scopes[scope]
			switch most, ok := allowed[scope]; {
			case slices.Contains(t.PagesDeploy, key) && (scope == "pages" || scope == "id-token") && level == "write":
			case ok && (level == most || level == "read" && most == "write"):
			case scope == "pages" || scope == "id-token":
				add("holds %s: %s; %s can hold pages and id-token, to deploy the site", scope, level, onlyJobs(t.PagesDeploy))
			default:
				add("holds %s: %s; %s jobs hold at most %s", scope, level, kind, show(allowed))
			}
		}

		want := t.secret(kind)
		for _, s := range slices.Compact(secrets) {
			switch {
			case s == want:
			case want == "":
				add("references %s; %s jobs hold no secret", showSecrets([]string{s}), kind)
			default:
				add("references %s; %s jobs reference only secrets.%s", showSecrets([]string{s}), kind, want)
			}
		}
	}

	inEnvironment := func(name string) string {
		if name == "" {
			return "no environment"
		}
		return "the environment " + name
	}
	envName := ""
	switch e := job["environment"].(type) {
	case string:
		envName = e
	case yamlMap:
		envName = fmt.Sprint(e["name"])
	}
	environment := inEnvironment(envName)
	switch {
	case kind == legacyKind:
		if envName != legacy.Environment {
			add("runs in %s, but a LEGACY job keeps exactly what the table records for it, %s, until a person replaces it",
				environment, inEnvironment(legacy.Environment))
		}
	case kind == agentKind && envName != t.AgentEnvironment:
		add("runs in %s; AGENT jobs run in %s, the only environment with their secret", environment, t.AgentEnvironment)
	case kind != agentKind && t.AgentEnvironment != "" && envName == t.AgentEnvironment:
		add("runs in %s, which holds the secret of the AGENT jobs: only AGENT jobs can run in it", environment)
	case kind != agentKind && envName != "" && !(slices.Contains(t.PagesDeploy, key) && envName == pagesEnvironment):
		add("runs in %s; only AGENT jobs (%s) and pagesDeploy jobs (%s) run in an environment",
			environment, cmp.Or(t.AgentEnvironment, "none"), pagesEnvironment)
	}

	if uses, ok := job["uses"]; ok {
		add("calls the reusable workflow %v; no kind allows one: give the job its own steps", uses)
	}
	if job["container"] != nil || job["services"] != nil {
		add("runs a container image (container or services); no kind allows one: the work runs in Dagger")
	}
	for i, s := range asList(job["steps"]) {
		uses, _ := asMap(s)["uses"].(string)
		if uses == "" || slices.Contains(t.LocalActions, uses) {
			continue
		}
		name, ref := uses, ""
		if at := strings.LastIndex(uses, "@"); at >= 0 {
			name, ref = uses[:at], uses[at+1:]
		}
		switch {
		case !slices.Contains(t.Actions, name) && !slices.Contains(legacy.Actions, name) &&
			!(slices.Contains(t.PagesBuild, key) && name == pagesUpload) &&
			!(slices.Contains(t.PagesDeploy, key) && name == pagesDeployment):
			add("step %d uses %s, which is not on the allowlist: the actions and localActions of the jobKinds setting, "+
				"%s for pagesBuild jobs and %s for pagesDeploy jobs", i+1, uses, pagesUpload, pagesDeployment)
		case !commitSHA.MatchString(ref):
			add("step %d uses %s; pin it to a commit SHA", i+1, uses)
		}
		// Without it, checkout writes the token of the job into .git/config,
		// where each later step, and the code of a pull request, can read it.
		if name == "actions/checkout" && !legacy.KeepsToken && fmt.Sprint(asMap(asMap(s)["with"])["persist-credentials"]) != "false" {
			add("step %d leaves the job's token in the checkout; set persist-credentials: false", i+1)
		}
	}

	if kind == checkKind {
		for _, s := range texts(inherited) {
			if c := cacheUse.FindString(s); c != "" {
				add("uses a cache (%s): CHECK jobs run the code of a pull request, so they leave nothing that a later job restores", c)
				break
			}
		}
		return out
	}
	// AGENT, GITHUB, SCAN and LEGACY jobs: never the code of a pull request.
	for i, s := range asList(job["steps"]) {
		step := asMap(s)
		if uses, _ := step["uses"].(string); !strings.HasPrefix(uses, "actions/checkout@") {
			continue
		}
		with, other := asMap(step["with"]), yamlMap{}
		for _, k := range []string{"ref", "repository"} {
			if with[k] != nil {
				other[k] = with[k]
			}
		}
		if len(other) > 0 {
			add("step %d checks out %s; %s jobs check out only the commit that started the run, never the code of a pull request",
				i+1, show(other), kind)
		}
	}
	if dispatch && !legacy.AnyBranch && !onMain(job["if"]) {
		add("can run on another branch than main: the workflow starts on workflow_dispatch, so the condition of the job " +
			"must start with github.ref == 'refs/heads/main', joined to the rest with && only")
	}
	for _, s := range texts(yamlMap{"env": env, "job": withoutConditions(job)}) {
		if r := prRef.FindString(indexRead.ReplaceAllString(s, ".$1")); r != "" {
			add("mentions %q, which reaches the code of a pull request; %s jobs never fetch or run it", r, kind)
			break
		}
	}
	return out
}

// onlyJobs is "only <job>, <job>", or "no job".
func onlyJobs(keys []string) string {
	if len(keys) == 0 {
		return "no job"
	}
	return "only " + strings.Join(keys, ", ")
}

// triggers returns the events of the `on` of a workflow, sorted.
func triggers(on any) []string {
	var out []string
	switch on := on.(type) {
	case string:
		out = append(out, on)
	case []any:
		for _, e := range on {
			out = append(out, fmt.Sprint(e))
		}
	case yamlMap:
		out = slices.Collect(maps.Keys(on))
	}
	sort.Strings(out)
	return out
}

// onMain reports whether the condition of a job requires the ref main: it
// starts with github.ref == 'refs/heads/main' (in ${{ }} or not), and it
// joins that to the rest with && only, so that no ! or || can undo it. As the
// == of GitHub on strings, it ignores case.
func onMain(cond any) bool {
	c, _ := cond.(string)
	c = strings.ToLower(strings.Join(strings.Fields(c), ""))
	c = strings.TrimSuffix(strings.TrimPrefix(c, "${{"), "}}")
	const guard = "github.ref=='refs/heads/main'"
	return (c == guard || strings.HasPrefix(c, guard+"&&")) && !strings.Contains(c, "||")
}

// withoutConditions is job without its `if` and the `if` of its steps: a
// condition decides whether a job or a step runs, not what it runs. Other
// keys named if, for example an environment variable, stay.
func withoutConditions(job yamlMap) yamlMap {
	if job == nil {
		return nil
	}
	out := maps.Clone(job)
	delete(out, "if")
	if steps := asList(job["steps"]); steps != nil {
		clean := make([]any, len(steps))
		for i, s := range steps {
			step := maps.Clone(asMap(s))
			delete(step, "if")
			clean[i] = step
		}
		out["steps"] = clean
	}
	return out
}

// texts returns each key and each scalar in v as text, sorted.
func texts(v any) []string {
	var out []string
	var walk func(any)
	walk = func(v any) {
		switch v := v.(type) {
		case yamlMap:
			for k, x := range v {
				out = append(out, k)
				walk(x)
			}
		case []any:
			for _, x := range v {
				walk(x)
			}
		case nil:
		default:
			out = append(out, fmt.Sprint(v))
		}
	}
	walk(v)
	sort.Strings(out)
	return out
}

// secretRefs returns each secret that an expression in the texts references,
// once for each reference, sorted: secrets.NAME as NAME, and each other use
// of the secrets context (toJSON(secrets), secrets[expr]) as "*".
// github.token, the whole github context and a computed property of it count
// as GITHUB_TOKEN.
func secretRefs(texts []string) []string {
	var out []string
	for _, t := range texts {
		for _, e := range expressions(t) {
			for _, p := range contextReads(e, "secrets") {
				out = append(out, cmp.Or(p, "*"))
			}
			for _, p := range contextReads(e, "github") {
				if p == "" || p == "TOKEN" {
					out = append(out, "GITHUB_TOKEN")
				}
			}
		}
	}
	sort.Strings(out)
	return out
}

// expressions returns the text in each ${{ }} of s. As in the parser of
// GitHub, a }} in a string in single quotes does not end an expression, and
// an expression that does not end runs to the end of s.
func expressions(s string) []string {
	var out []string
	for {
		start := strings.Index(s, "${{")
		if start < 0 {
			return out
		}
		s = s[start+3:]
		end, quoted := len(s), false
		for i := 0; i < len(s); i++ {
			if s[i] == '\'' {
				quoted = !quoted
			} else if !quoted && strings.HasPrefix(s[i:], "}}") {
				end = i
				break
			}
		}
		out = append(out, s[:end])
		s = s[min(end+2, len(s)):]
	}
}

// exprToken is a token of an expression: an identifier ('i'), the text of a
// string literal ('s'), or one other character ('p').
type exprToken struct {
	kind byte
	text string
}

func exprTokens(e string) []exprToken {
	identChar := func(c byte, first bool) bool {
		letter := 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' || c == '_'
		return letter || !first && (c == '-' || '0' <= c && c <= '9')
	}
	var out []exprToken
	for i := 0; i < len(e); {
		switch c := e[i]; {
		case c == ' ' || c == '\t' || c == '\n' || c == '\r':
			i++
		case c == '\'':
			var lit strings.Builder
			for i++; i < len(e); i++ {
				if e[i] == '\'' {
					if i+1 < len(e) && e[i+1] == '\'' {
						i++
					} else {
						i++
						break
					}
				}
				lit.WriteByte(e[i])
			}
			out = append(out, exprToken{'s', lit.String()})
		case identChar(c, true):
			j := i + 1
			for j < len(e) && identChar(e[j], false) {
				j++
			}
			out = append(out, exprToken{'i', e[i:j]})
			i = j
		default:
			out = append(out, exprToken{'p', string(c)})
			i++
		}
	}
	return out
}

// contextReads returns what each use of the context name (secrets or github)
// in the expression e reads, in upper case: PROP for name.PROP and
// name['PROP'], or "" for the whole context or a computed property. Names
// ignore case, as in the expressions of GitHub, and x.secrets is not a
// context.
func contextReads(e, name string) []string {
	toks := exprTokens(e)
	at := func(i int, kind byte, text string) bool {
		return 0 <= i && i < len(toks) && toks[i].kind == kind && (text == "" || toks[i].text == text)
	}
	var out []string
	for i, t := range toks {
		if t.kind != 'i' || !strings.EqualFold(t.text, name) || at(i-1, 'p', ".") {
			continue
		}
		prop := ""
		switch {
		case at(i+1, 'p', ".") && at(i+2, 'i', ""):
			prop = toks[i+2].text
		case at(i+1, 'p', "[") && at(i+2, 's', "") && at(i+3, 'p', "]"):
			prop = toks[i+2].text
		}
		out = append(out, strings.ToUpper(prop))
	}
	return out
}

// show is v on one line: a mapping as {key: value, ...} with sorted keys, or
// "missing" when v is nil.
func show(v any) string {
	switch v := v.(type) {
	case nil:
		return "missing"
	case map[string]string:
		m := make(yamlMap, len(v))
		for k, x := range v {
			m[k] = x
		}
		return show(m)
	case yamlMap:
		pairs := make([]string, 0, len(v))
		for _, k := range slices.Sorted(maps.Keys(v)) {
			pairs = append(pairs, k+": "+show(v[k]))
		}
		return "{" + strings.Join(pairs, ", ") + "}"
	}
	return fmt.Sprint(v)
}

// showSecrets is "secrets.A, secrets.B", or "no secret".
func showSecrets(names []string) string {
	if len(names) == 0 {
		return "no secret"
	}
	out := make([]string, len(names))
	for i, n := range names {
		out[i] = "secrets." + n
	}
	return strings.Join(out, ", ")
}
