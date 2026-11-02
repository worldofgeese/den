package main

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"gopkg.in/yaml.v3"
)

// The job kinds give the expected problems for fixed workflows and a fixed
// jobKinds table. The passing fixture has a job of each kind and two LEGACY
// jobs, and it gives no problem. Each rule case breaks one rule, and gives
// that problem. A change to the table changes what the jobs can hold. A table
// that is not valid is refused, and with no table the check is off. No
// network and no token.
// +check
func (m *Ci) WorkflowIsolationRules(ctx context.Context) error {
	var failed []string
	failed = append(failed, isolationCases()...)
	failed = append(failed, kindsTableCases()...)
	failed = append(failed, jobKindsCases(ctx)...)
	if len(failed) > 0 {
		return errors.New(strings.Join(failed, "\n"))
	}
	return nil
}

// pin stands for a commit SHA in the fixtures (@PIN).
var pin = strings.Repeat("0", 40)

// fixtureKinds is the table of the fixtures: the job kinds of a repository
// with a check workflow, a shepherd, a bump, a scan with a GitHub Pages site,
// and an old scan with two LEGACY jobs. The entries for bump.yml allow jobs
// that the fixture does not have.
const fixtureKinds = `
jobs:
  dagger-check.yml/check: CHECK
  shepherd.yml/snapshot: GITHUB
  shepherd.yml/agents: AGENT
  shepherd.yml/verify: CHECK
  shepherd.yml/post: GITHUB
  bump.yml/compute: GITHUB
  bump.yml/verify: CHECK
  bump.yml/post: GITHUB
  scan.yml/scan: SCAN
  scan.yml/post: GITHUB
  scan.yml/deploy: GITHUB
  legacy-scan.yml/scan: LEGACY
  legacy-scan.yml/deploy: LEGACY
secrets:
  AGENT: MODEL_KEY
  SCAN: SCAN_TOKEN
agentEnvironment: agents
actions: [actions/checkout, actions/download-artifact, actions/upload-artifact]
localActions: [$/.github/actions/dagger]
pagesBuild: [scan.yml/scan]
pagesDeploy: [scan.yml/deploy]
legacy:
  # Its own Python and the Pages site, and a push of its reports with the
  # credential that checkout keeps. A dispatch on a branch scans and pushes
  # to that branch.
  legacy-scan.yml/scan:
    permissions: {contents: write, pull-requests: write}
    secrets: [SCAN_TOKEN, GITHUB_TOKEN]
    actions: [actions/setup-python, actions/upload-pages-artifact]
    keepsToken: true
    anyBranch: true
  legacy-scan.yml/deploy:
    permissions: {id-token: write, pages: write}
    actions: [actions/deploy-pages]
    environment: github-pages
    anyBranch: true
`

// fixtureWorkflows is the passing fixture: a job of each kind, and the LEGACY
// jobs with the permissions and secrets that the table records.
var fixtureWorkflows = map[string]string{
	"dagger-check.yml": `
on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
  workflow_dispatch:
permissions: {}
jobs:
  check:
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@PIN
        with:
          persist-credentials: false
      - uses: $/.github/actions/dagger
      - run: dagger check
`,
	"shepherd.yml": `
on:
  workflow_run:
    workflows: [Dagger check]
    types: [completed]
  issues:
    types: [opened, edited]
  issue_comment:
    types: [created]
  schedule:
    - cron: '*/15 * * * *'
  workflow_dispatch:
permissions: {}
jobs:
  snapshot:
    # A condition decides whether the job runs, not what it runs.
    if: github.ref == 'refs/heads/main' && github.event.workflow_run.head_branch != 'gh-pages'
    permissions:
      actions: read
      checks: read
      contents: read
      issues: read
      pull-requests: read
      statuses: read
    steps:
      - uses: actions/checkout@PIN
        with:
          persist-credentials: false
      - uses: $/.github/actions/dagger
      - run: dagger call ci snapshot --token env://GH_TOKEN export --path snapshot.json
        env:
          GH_TOKEN: ${{ github.token }}
      - uses: actions/upload-artifact@PIN
        with:
          name: snapshot
          path: snapshot.json
  agents:
    needs: snapshot
    if: github.ref == 'refs/heads/main'
    environment: agents
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@PIN
        with:
          persist-credentials: false
      - uses: actions/download-artifact@PIN
        with:
          name: snapshot
      - uses: $/.github/actions/dagger
      - run: dagger call ci agents --snapshot snapshot.json --key env://MODEL_KEY export --path agents.json
        env:
          MODEL_KEY: ${{ secrets.MODEL_KEY }}
      - uses: actions/upload-artifact@PIN
        with:
          name: agents
          path: agents.json
  verify:
    needs: agents
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@PIN
        with:
          ref: refs/pull/7/head
          persist-credentials: false
      - uses: actions/download-artifact@PIN
        with:
          name: agents
      - uses: $/.github/actions/dagger
      - run: dagger call ci verify --patches agents.json export --path verify.json
      - uses: actions/upload-artifact@PIN
        with:
          name: verify
          path: verify.json
  post:
    needs: [snapshot, agents, verify]
    if: ${{ github.ref == 'refs/heads/main' }}
    permissions:
      actions: write
      contents: write
      issues: write
      pull-requests: write
      statuses: write
    steps:
      - uses: actions/checkout@PIN
        with:
          persist-credentials: false
      - uses: actions/download-artifact@PIN
      - uses: $/.github/actions/dagger
      - run: dagger call ci post --token env://GH_TOKEN
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
`,
	"scan.yml": `
on:
  schedule:
    - cron: '0 9 * * 1'
  workflow_dispatch:
permissions: {}
jobs:
  scan:
    if: github.ref == 'refs/heads/main'
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@PIN
        with:
          persist-credentials: false
      - uses: $/.github/actions/dagger
      - run: dagger call scan --token env://SCAN_TOKEN export --path site
        env:
          SCAN_TOKEN: ${{ secrets.SCAN_TOKEN }}
      - uses: actions/upload-pages-artifact@PIN
        with:
          path: site/
  deploy:
    needs: scan
    if: github.ref == 'refs/heads/main'
    permissions:
      id-token: write
      pages: write
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - id: deployment
        uses: actions/deploy-pages@PIN
`,
	// The LEGACY jobs, with what the table records for them: no main guard,
	// a checkout that keeps the token, and their own actions.
	"legacy-scan.yml": `
on:
  schedule:
    - cron: '0 9 * * 1'
  workflow_dispatch:
permissions: {}
jobs:
  scan:
    permissions:
      contents: write
      pull-requests: write
    steps:
      - uses: actions/checkout@PIN
      - uses: actions/setup-python@PIN
      - run: python scripts/scan.py
        env:
          GITHUB_TOKEN: ${{ secrets.SCAN_TOKEN }}
      - run: git push origin "HEAD:$GITHUB_REF"
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
      - uses: actions/upload-artifact@PIN
      - uses: actions/upload-pages-artifact@PIN
  deploy:
    needs: scan
    permissions:
      pages: write
      id-token: write
    environment:
      name: github-pages
    steps:
      - uses: actions/deploy-pages@PIN
`,
}

type fixtureWorkflowSet = map[string]yamlMap

// parseFixtureWorkflows parses fixtureWorkflows, with @PIN as a commit SHA.
func parseFixtureWorkflows() (fixtureWorkflowSet, error) {
	out := fixtureWorkflowSet{}
	for file, src := range fixtureWorkflows {
		var doc yamlMap
		if err := yaml.Unmarshal([]byte(strings.ReplaceAll(src, "@PIN", "@"+pin)), &doc); err != nil {
			return nil, fmt.Errorf("%s: %w", file, err)
		}
		out[file] = doc
	}
	return out, nil
}

type isolationCase struct {
	name, want string
	mutate     func(fixtureWorkflowSet) bool
}

// isolationCases checks the passing fixture, then each rule case. 55 of the
// rule cases come from an earlier copy of this check
// (docs:workflow-isolation-rule), with the words of this module and with
// neutral names for secrets, files and actions.
func isolationCases() []string {
	t, err := parseJobKinds(fixtureKinds)
	if err != nil {
		return []string{"the fixture table: " + err.Error()}
	}
	ok, err := parseFixtureWorkflows()
	if err != nil {
		return []string{"the fixture workflows: " + err.Error()}
	}
	if bad := workflowProblems(ok, t); len(bad) > 0 {
		return []string{"the passing fixture failed:\n  " + strings.Join(bad, "\n  ")}
	}
	var failed []string
	for _, c := range ruleIsolationCases() {
		w, _ := parseFixtureWorkflows()
		if !c.mutate(w) {
			failed = append(failed, fmt.Sprintf("isolation case %q: the fixture has nothing to change", c.name))
			continue
		}
		if got := strings.Join(workflowProblems(w, t), "\n"); !strings.Contains(got, c.want) {
			failed = append(failed, fmt.Sprintf("isolation case %q: want a problem with %q, got:\n%s", c.name, c.want, got))
		}
	}
	return failed
}

// ruleIsolationCases are the ways to break the rules: each changes the
// passing fixture, and must give a problem that contains want.
func ruleIsolationCases() []isolationCase {
	type workflows = fixtureWorkflowSet
	job := func(w workflows, file, id string) yamlMap { return asMap(asMap(w[file]["jobs"])[id]) }
	// setTop sets a top-level key of a workflow, or removes it when v is nil.
	setTop := func(file, k string, v any) func(workflows) bool {
		return func(w workflows) bool {
			if w[file] == nil {
				return false
			}
			if v == nil {
				delete(w[file], k)
			} else {
				w[file][k] = v
			}
			return true
		}
	}
	// set sets a key of a job, or removes it when v is nil.
	set := func(file, id, k string, v any) func(workflows) bool {
		return func(w workflows) bool {
			j := job(w, file, id)
			if j == nil {
				return false
			}
			if v == nil {
				delete(j, k)
			} else {
				j[k] = v
			}
			return true
		}
	}
	scope := func(file, id, scope, level string) func(workflows) bool {
		return func(w workflows) bool {
			p := asMap(job(w, file, id)["permissions"])
			if p == nil {
				return false
			}
			p[scope] = level
			return true
		}
	}
	step := func(file, id string, s yamlMap) func(workflows) bool {
		return func(w workflows) bool {
			j := job(w, file, id)
			if j == nil {
				return false
			}
			j["steps"] = append(asList(j["steps"]), s)
			return true
		}
	}
	checkoutRef := func(file, id, ref string) func(workflows) bool {
		return func(w workflows) bool {
			for _, s := range asList(job(w, file, id)["steps"]) {
				if uses, _ := asMap(s)["uses"].(string); strings.HasPrefix(uses, "actions/checkout@") {
					asMap(asMap(s)["with"])["ref"] = ref
					return true
				}
			}
			return false
		}
	}
	trigger := func(file, event string) func(workflows) bool {
		return func(w workflows) bool {
			on := asMap(w[file]["on"])
			if on == nil {
				return false
			}
			on[event] = yamlMap{}
			return true
		}
	}
	env := func(k, v string) yamlMap { return yamlMap{"run": "true", "env": yamlMap{k: v}} }
	const headSHA = "${{ github.event.workflow_run.head_sha }}"
	return []isolationCase{
		// CHECK jobs
		{"a secret in a CHECK job", "job check (CHECK): references secrets.NPM_TOKEN; CHECK jobs hold no secret",
			step("dagger-check.yml", "check", env("NODE_AUTH_TOKEN", "${{ secrets.NPM_TOKEN }}"))},
		{"the job's token in a CHECK job", "job check (CHECK): references secrets.GITHUB_TOKEN; CHECK jobs hold no secret",
			step("dagger-check.yml", "check", env("GH_TOKEN", "${{ github.token }}"))},
		{"a secret in the workflow's env", "job check (CHECK): references secrets.NPM_TOKEN; CHECK jobs hold no secret",
			setTop("dagger-check.yml", "env", yamlMap{"NODE_AUTH_TOKEN": "${{ secrets.NPM_TOKEN }}"})},
		{"a secret after }} in a quoted string", "job check (CHECK): references secrets.NPM_TOKEN; CHECK jobs hold no secret",
			step("dagger-check.yml", "check", env("T", "${{ format('}}{0}', secrets.NPM_TOKEN) }}"))},
		{"a secret in mixed case", "job check (CHECK): references secrets.NPM_TOKEN; CHECK jobs hold no secret",
			step("dagger-check.yml", "check", env("T", "${{ Secrets.npm_token }}"))},
		{"the job's token in mixed case", "job check (CHECK): references secrets.GITHUB_TOKEN; CHECK jobs hold no secret",
			step("dagger-check.yml", "check", env("T", "${{ GitHub.Token }}"))},
		{"the whole github context, which has the token", "job check (CHECK): references secrets.GITHUB_TOKEN; CHECK jobs hold no secret",
			step("dagger-check.yml", "check", env("T", "${{ toJSON(github) }}"))},
		{"a computed property of the github context", "job check (CHECK): references secrets.GITHUB_TOKEN; CHECK jobs hold no secret",
			step("dagger-check.yml", "check", env("T", "${{ github[format('tok{0}', 'en')] }}"))},
		{"a write scope in a CHECK job", "job check (CHECK): holds contents: write; CHECK jobs hold at most {contents: read}",
			scope("dagger-check.yml", "check", "contents", "write")},
		{"a cache action in a CHECK job", "job check (CHECK): uses a cache (actions/cache@",
			step("dagger-check.yml", "check", yamlMap{"uses": "actions/cache@" + pin, "with": yamlMap{"path": "~/.npm", "key": "npm"}})},
		{"a Dagger cache in a CHECK job", "job check (CHECK): uses a cache (_EXPERIMENTAL_DAGGER_CACHE_CONFIG)",
			set("dagger-check.yml", "check", "env", yamlMap{"_EXPERIMENTAL_DAGGER_CACHE_CONFIG": "type=gha"})},

		// AGENT jobs
		{"a scope other than contents: read in an AGENT job", "job agents (AGENT): holds pull-requests: read; AGENT jobs hold at most {contents: read}",
			scope("shepherd.yml", "agents", "pull-requests", "read")},
		{"a write scope in an AGENT job", "job agents (AGENT): holds contents: write",
			scope("shepherd.yml", "agents", "contents", "write")},
		{"an AGENT job that runs a pull request's code", `job agents (AGENT): mentions "refs/pull/"`,
			step("shepherd.yml", "agents", yamlMap{"run": "git fetch origin refs/pull/7/head && git checkout FETCH_HEAD && make"})},
		{"an AGENT job that checks out a pull request", "job agents (AGENT): step 1 checks out {ref: " + headSHA + "}",
			checkoutRef("shepherd.yml", "agents", headSHA)},
		{"a second secret in an AGENT job", "job agents (AGENT): references secrets.OTHER; AGENT jobs reference only secrets.MODEL_KEY",
			step("shepherd.yml", "agents", env("OTHER", "${{ secrets.OTHER }}"))},
		{"an AGENT job outside the environment agents", "job agents (AGENT): runs in no environment",
			set("shepherd.yml", "agents", "environment", nil)},

		// GITHUB jobs
		{"a pull request checkout in a GITHUB job", "job post (GITHUB): step 1 checks out {ref: " + headSHA + "}",
			checkoutRef("shepherd.yml", "post", headSHA)},
		{"a pull request's head read by index in a GITHUB job", `job post (GITHUB): mentions "head.sha"`,
			step("shepherd.yml", "post", yamlMap{"run": `git fetch origin "$SHA" && git checkout FETCH_HEAD && ./x`,
				"env": yamlMap{"SHA": "${{ github.event.workflow_run.pull_requests[0].head['sha'] }}"}})},
		{"a pull request's head in a variable named if", `job post (GITHUB): mentions "head_sha"`,
			step("shepherd.yml", "post", yamlMap{"run": `git fetch origin "$if" && git checkout FETCH_HEAD && ./x`,
				"env": yamlMap{"if": headSHA}})},
		{"no main guard in a workflow that starts on workflow_dispatch", "job snapshot (GITHUB): can run on another branch than main",
			set("shepherd.yml", "snapshot", "if", "github.event.workflow_run.head_branch != 'gh-pages'")},
		{"a main guard that || can skip", "job post (GITHUB): can run on another branch than main",
			set("shepherd.yml", "post", "if", "github.ref == 'refs/heads/main' || github.event_name == 'workflow_dispatch'")},
		{"a negated main guard", "job post (GITHUB): can run on another branch than main",
			set("shepherd.yml", "post", "if", "!(github.ref == 'refs/heads/main')")},
		// Not in the earlier copy: the || comes after a guard and an &&.
		{"a main guard and a condition that a later || can skip", "job post (GITHUB): can run on another branch than main",
			set("shepherd.yml", "post", "if", "github.ref == 'refs/heads/main' && github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'")},
		{"a pull ref built from an expression in a GITHUB job", `job post (GITHUB): mentions "pull/${{ github.event.issue.number }}/head"`,
			step("shepherd.yml", "post", yamlMap{"run": "git fetch origin pull/${{ github.event.issue.number }}/head && git checkout FETCH_HEAD && make"})},
		{"the model key in a GITHUB job", "job post (GITHUB): references secrets.MODEL_KEY; GITHUB jobs reference only secrets.GITHUB_TOKEN",
			step("shepherd.yml", "post", env("KEY", "${{ secrets.MODEL_KEY }}"))},
		{"the whole secrets context in a GITHUB job", "job post (GITHUB): references secrets.*",
			step("shepherd.yml", "post", env("ALL", "${{ toJSON(secrets) }}"))},
		{"the environment agents in a GITHUB job", "job post (GITHUB): runs in the environment agents, which holds the secret of the AGENT jobs",
			set("shepherd.yml", "post", "environment", "agents")},
		{"a scope outside the allowed set in a GITHUB job", "job post (GITHUB): holds packages: write",
			scope("shepherd.yml", "post", "packages", "write")},
		{"pages outside scan/deploy", "job post (GITHUB): holds pages: write; only scan.yml/deploy can hold pages and id-token",
			scope("shepherd.yml", "post", "pages", "write")},
		{"id-token outside scan/deploy", "job snapshot (GITHUB): holds id-token: write; only scan.yml/deploy can hold pages and id-token",
			scope("shepherd.yml", "snapshot", "id-token", "write")},
		{"a reusable workflow", "job snapshot (GITHUB): calls the reusable workflow",
			set("shepherd.yml", "snapshot", "uses", "./.github/workflows/other.yml")},
		{"a container image in a GITHUB job", "job post (GITHUB): runs a container image",
			set("shepherd.yml", "post", "container", "node:24")},

		// Actions
		{"an action outside the allowlist", "uses other/create-pull-request@" + pin + ", which is not on the allowlist",
			step("shepherd.yml", "post", yamlMap{"uses": "other/create-pull-request@" + pin})},
		{"a Pages action outside the scan", "job post (GITHUB): step 5 uses actions/deploy-pages@" + pin + ", which is not on the allowlist",
			step("shepherd.yml", "post", yamlMap{"uses": "actions/deploy-pages@" + pin})},
		{"the Dagger action from the checkout", "uses ./.github/actions/dagger, which is not on the allowlist",
			step("shepherd.yml", "agents", yamlMap{"uses": "./.github/actions/dagger"})},
		{"a checkout that keeps the job's token", "job check (CHECK): step 1 leaves the job's token in the checkout; set persist-credentials: false",
			func(w workflows) bool {
				for _, s := range asList(job(w, "dagger-check.yml", "check")["steps"]) {
					if with := asMap(asMap(s)["with"]); with["persist-credentials"] != nil {
						delete(with, "persist-credentials")
						return true
					}
				}
				return false
			}},
		{"an action not pinned to a commit SHA", "job check (CHECK): step 4 uses actions/upload-artifact@v7; pin it to a commit SHA",
			step("dagger-check.yml", "check", yamlMap{"uses": "actions/upload-artifact@v7"})},

		// Workflows
		{"a job that fits no kind", "dagger-check.yml: job lint fits no kind",
			func(w workflows) bool {
				asMap(w["dagger-check.yml"]["jobs"])["lint"] = yamlMap{"permissions": yamlMap{}, "steps": []any{}}
				return true
			}},
		{"a pull_request trigger on shepherd.yml", "shepherd.yml: starts on pull_request, but it has jobs that are not CHECK jobs",
			trigger("shepherd.yml", "pull_request")},
		{"a pull_request_review trigger on shepherd.yml", "shepherd.yml: starts on pull_request_review, but",
			trigger("shepherd.yml", "pull_request_review")},
		{"pull_request_target on a workflow of CHECK jobs", "dagger-check.yml: starts on pull_request_target",
			trigger("dagger-check.yml", "pull_request_target")},
		{"top-level permissions other than {}", "dagger-check.yml: the top-level permissions are {contents: read}; want {}",
			setTop("dagger-check.yml", "permissions", yamlMap{"contents": "read"})},
		{"no top-level permissions", "dagger-check.yml: the top-level permissions are missing; want {}",
			setTop("dagger-check.yml", "permissions", nil)},
		{"a job that declares no permissions", "job check (CHECK): declares no permissions",
			set("dagger-check.yml", "check", "permissions", nil)},

		// LEGACY jobs
		{"a new scope in a LEGACY job", "job scan (LEGACY): holds {actions: write, contents: write, pull-requests: write}, but",
			scope("legacy-scan.yml", "scan", "actions", "write")},
		{"a new secret in a LEGACY job", "job deploy (LEGACY): references secrets.MODEL_KEY, but",
			step("legacy-scan.yml", "deploy", env("KEY", "${{ secrets.MODEL_KEY }}"))},
		{"a second use of a LEGACY job's secret", "job scan (LEGACY): references secrets.GITHUB_TOKEN, secrets.SCAN_TOKEN, secrets.SCAN_TOKEN, but",
			step("legacy-scan.yml", "scan", env("T", "${{ secrets.SCAN_TOKEN }}"))},
		{"a pull request checkout in a LEGACY job", "job scan (LEGACY): step 1 checks out {ref: refs/pull/7/head}",
			func(w workflows) bool {
				asMap(asList(job(w, "legacy-scan.yml", "scan")["steps"])[0])["with"] = yamlMap{"ref": "refs/pull/7/head"}
				return true
			}},
		{"a pull request fetch in a LEGACY job", `job scan (LEGACY): mentions "pull/${{ github.event.inputs.pr }}/head"`,
			step("legacy-scan.yml", "scan", yamlMap{"run": "git fetch origin pull/${{ github.event.inputs.pr }}/head && git checkout FETCH_HEAD"})},
		{"an action outside the allowlist in a LEGACY job", "job scan (LEGACY): step 7 uses other/create-pull-request@" + pin + ", which is not on the allowlist",
			step("legacy-scan.yml", "scan", yamlMap{"uses": "other/create-pull-request@" + pin})},
		{"an unpinned action in a LEGACY job", "job scan (LEGACY): step 2 uses actions/setup-python@v5; pin it to a commit SHA",
			func(w workflows) bool {
				asMap(asList(job(w, "legacy-scan.yml", "scan")["steps"])[1])["uses"] = "actions/setup-python@v5"
				return true
			}},
		{"a LEGACY job's own action in another job", "job check (CHECK): step 4 uses actions/setup-python@" + pin + ", which is not on the allowlist",
			step("dagger-check.yml", "check", yamlMap{"uses": "actions/setup-python@" + pin})},
		{"a checkout that keeps the token in a LEGACY job that has no push", "job deploy (LEGACY): step 2 leaves the job's token in the checkout",
			step("legacy-scan.yml", "deploy", yamlMap{"uses": "actions/checkout@" + pin})},
		{"another environment for a LEGACY job", "job deploy (LEGACY): runs in the environment agents, but a LEGACY job keeps exactly what the table records for it, the environment github-pages",
			set("legacy-scan.yml", "deploy", "environment", "agents")},
		{"a container in a LEGACY job", "job scan (LEGACY): runs a container image",
			set("legacy-scan.yml", "scan", "container", "python:3.11")},
	}
}

// kindsTableCases change the table, not the workflows: the table decides
// what the jobs can hold.
func kindsTableCases() []string {
	cases := []struct {
		name, table, want string
		// An edit of the passing fixture, or nil.
		edit func(fixtureWorkflowSet)
	}{
		{"no secret for SCAN jobs", strings.Replace(fixtureKinds, "  SCAN: SCAN_TOKEN\n", "", 1),
			"scan.yml: job scan (SCAN): references secrets.SCAN_TOKEN; SCAN jobs hold no secret", nil},
		{"another secret for AGENT jobs", strings.Replace(fixtureKinds, "AGENT: MODEL_KEY", "AGENT: OTHER_KEY", 1),
			"shepherd.yml: job agents (AGENT): references secrets.MODEL_KEY; AGENT jobs reference only secrets.OTHER_KEY", nil},
		{"no actions on the allowlist", strings.Replace(fixtureKinds, "actions: [actions/checkout, actions/download-artifact, actions/upload-artifact]\n", "", 1),
			"dagger-check.yml: job check (CHECK): step 1 uses actions/checkout@" + pin + ", which is not on the allowlist", nil},
		{"no local actions", strings.Replace(fixtureKinds, "localActions: [$/.github/actions/dagger]\n", "", 1),
			"dagger-check.yml: job check (CHECK): step 2 uses $/.github/actions/dagger, which is not on the allowlist", nil},
		{"no pagesDeploy job", strings.Replace(fixtureKinds, "pagesDeploy: [scan.yml/deploy]\n", "", 1),
			"scan.yml: job deploy (GITHUB): holds id-token: write; no job can hold pages and id-token", nil},
		{"no pagesBuild job", strings.Replace(fixtureKinds, "pagesBuild: [scan.yml/scan]\n", "", 1),
			"scan.yml: job scan (SCAN): step 4 uses actions/upload-pages-artifact@" + pin + ", which is not on the allowlist", nil},
		{"another agent environment", strings.Replace(fixtureKinds, "agentEnvironment: agents", "agentEnvironment: models", 1),
			"shepherd.yml: job agents (AGENT): runs in the environment agents; AGENT jobs run in models", nil},
		{"a GITHUB job in another environment", fixtureKinds,
			"shepherd.yml: job post (GITHUB): runs in the environment production; only AGENT jobs (agents) and pagesDeploy jobs (github-pages) run in an environment",
			func(w fixtureWorkflowSet) {
				asMap(asMap(w["shepherd.yml"]["jobs"])["post"])["environment"] = "production"
			}},
		{"a job of another file", strings.Replace(fixtureKinds, "dagger-check.yml/check: CHECK", "other.yml/check: CHECK", 1),
			"dagger-check.yml: job check fits no kind", nil},
		{"a LEGACY job without its record", strings.Replace(fixtureKinds, "  legacy-scan.yml/deploy:\n    permissions: {id-token: write, pages: write}\n    actions: [actions/deploy-pages]\n    environment: github-pages\n    anyBranch: true\n", "", 1),
			"legacy-scan.yml: job deploy (LEGACY): holds {id-token: write, pages: write}, but a LEGACY job keeps exactly what the table records for it, {}", nil},
	}
	var failed []string
	for _, c := range cases {
		t, err := parseJobKinds(c.table)
		if err != nil {
			failed = append(failed, fmt.Sprintf("table case %q: %v", c.name, err))
			continue
		}
		w, err := parseFixtureWorkflows()
		if err != nil {
			return []string{err.Error()}
		}
		if c.edit != nil {
			c.edit(w)
		}
		if got := strings.Join(workflowProblems(w, t), "\n"); !strings.Contains(got, c.want) {
			failed = append(failed, fmt.Sprintf("table case %q: want a problem with %q, got:\n%s", c.name, c.want, got))
		}
	}
	return failed
}

// jobKindsCases: the setting turns the check off when it is empty, and a
// table that is not valid is refused.
func jobKindsCases(ctx context.Context) []string {
	var failed []string
	// With no table, the check reads nothing: its Source is nil.
	for _, off := range []string{"", " \n\t"} {
		if err := (&Ci{JobKinds: off}).WorkflowIsolation(ctx); err != nil {
			failed = append(failed, fmt.Sprintf("jobKinds %q: %v; want the check off", off, err))
		}
	}
	t, err := parseJobKinds(fixtureKinds)
	switch {
	case err != nil:
		failed = append(failed, "the fixture table: "+err.Error())
	case strings.Join(t.Legacy["legacy-scan.yml/scan"].Secrets, ",") != "GITHUB_TOKEN,SCAN_TOKEN":
		failed = append(failed, fmt.Sprintf("the secrets of a LEGACY job are %v; want them sorted", t.Legacy["legacy-scan.yml/scan"].Secrets))
	}
	cases := []struct{ name, table, want string }{
		{"no jobs", "jobs: {}\n", "it names no job"},
		{"only a secret", "secrets: {AGENT: MODEL_KEY}\n", "it names no job"},
		{"a field that the table does not have", "jobs: {a.yml/b: CHECK}\nagentEnviroment: agents\n", "field agentEnviroment not found"},
		{"a kind that does not exist", "jobs: {a.yml/b: BUILD}\n", `the kind "BUILD" of a.yml/b is not CHECK, AGENT, GITHUB, SCAN or LEGACY`},
		{"a job without its workflow file", "jobs: {check: CHECK}\n", `the job "check" is not <workflow file>/<job id>`},
		{"an AGENT job without its environment", "jobs: {a.yml/b: AGENT}\n", "the AGENT job a.yml/b needs agentEnvironment"},
		{"a secret for CHECK jobs", "jobs: {a.yml/b: CHECK}\nsecrets: {CHECK: TOKEN}\n", "secrets names a secret for CHECK jobs"},
		{"a record for a job that is not LEGACY", "jobs: {a.yml/b: GITHUB}\nlegacy: {a.yml/b: {keepsToken: true}}\n", "legacy names a.yml/b, which is not a LEGACY job"},
		{"a list instead of a mapping", "jobs: [a.yml/b]\n", "the jobKinds setting is not a valid table"},
	}
	for _, c := range cases {
		if _, err := parseJobKinds(c.table); err == nil || !strings.Contains(err.Error(), c.want) {
			failed = append(failed, fmt.Sprintf("jobKinds case %q: %v; want an error with %q", c.name, err, c.want))
		}
	}
	return failed
}
