package main

import (
	"encoding/json"
	"fmt"
	"maps"
	"slices"
	"strings"
)

// The fixtures of the rules executable-bit and manifest-fields
// (ci:automerge-rules). The manifest settings are those of a plugin
// marketplace: a manifest for each plugin, and the marketplace file with a
// list of plugin entries.

const (
	fixturePlugin = "plugins/a/.claude-plugin/plugin.json"
	fixtureMarket = ".claude-plugin/marketplace.json"
)

func fixtureManifests(p *mergePolicy) {
	p.ManifestFiles = []string{"plugins/*/.claude-plugin/plugin.json", ".claude-plugin/marketplace.json"}
	p.ManifestSafeFields = []string{"name", "description", "version", "keywords", "category", "tags"}
	p.ManifestSourcePrefix = "./plugins/"
}

func fixtureExecutableBit(p *mergePolicy) { p.RiskyExecutableBit = true }

// changed gives a pull request these changed files, as the trees of the
// merge base and the head have them.
func changed(files map[string]prFile) func(*prSnapshot) {
	return func(s *prSnapshot) {
		s.Files = slices.Sorted(maps.Keys(files))
		s.Trees = &prTrees{Files: files}
	}
}

// manifest is a manifest file with this text at the merge base and at the
// head. "" is a file that is not there.
func manifest(base, head string) prFile {
	f := prFile{BaseText: base, HeadText: head}
	if base != "" {
		f.BaseMode = "100644"
	}
	if head != "" {
		f.HeadMode = "100644"
	}
	return f
}

// fixtureMarketBase is a marketplace with one plugin at the merge base.
const fixtureMarketBase = `{"name": "m", "owner": {"name": "O"}, "plugins": [
  {"name": "a", "description": "A.", "source": "./plugins/a", "skills": ["./skills/x"]}]}`

// marketWith is the marketplace of fixtureMarketBase with a second plugin.
func marketWith(entry string) prFile {
	return manifest(fixtureMarketBase, `{"name": "m", "owner": {"name": "O"}, "plugins": [
  {"name": "a", "description": "A.", "source": "./plugins/a", "skills": ["./skills/x"]}, `+entry+`]}`)
}

func filesCases() []string {
	cases := []struct {
		name   string
		policy func(*mergePolicy)
		edit   func(*prSnapshot)
		want   string // the rule that refuses; "" merges
	}{
		// riskyExecutableBit.
		{"a new file with mode 100755", fixtureExecutableBit,
			changed(map[string]prFile{"scripts/new.sh": {HeadMode: "100755"}}), "executable-bit"},
		{"a mode that changes to 100755", fixtureExecutableBit,
			changed(map[string]prFile{"scripts/run.sh": {BaseMode: "100644", HeadMode: "100755"}}), "executable-bit"},
		{"a 100644 file that keeps its mode", fixtureExecutableBit,
			changed(map[string]prFile{"modules/pi.nix": {BaseMode: "100644", HeadMode: "100644"}}), ""},
		{"a 100755 file that keeps its mode", fixtureExecutableBit,
			changed(map[string]prFile{"scripts/run.sh": {BaseMode: "100755", HeadMode: "100755"}}), ""},
		{"a mode that changes from 100755 to 100644", fixtureExecutableBit,
			changed(map[string]prFile{"scripts/run.sh": {BaseMode: "100755", HeadMode: "100644"}}), ""},
		{"riskyExecutableBit off, with a new file of mode 100755", nil,
			changed(map[string]prFile{"scripts/new.sh": {HeadMode: "100755"}}), ""},
		{"a tree that GitHub cut", fixtureExecutableBit,
			func(s *prSnapshot) { s.Trees = &prTrees{Truncated: fixtureHead} }, "executable-bit"},
		{"a tree that GitHub cut, with manifestFiles", fixtureManifests, func(s *prSnapshot) {
			s.Files = []string{fixturePlugin}
			s.Trees = &prTrees{Truncated: fixtureHead}
		}, "manifest-fields"},
		{"trees that fetch did not read", fixtureExecutableBit, nil, "executable-bit"},
		{"a changed file that the trees do not have", fixtureExecutableBit,
			func(s *prSnapshot) { s.Trees = &prTrees{Files: map[string]prFile{}} }, "executable-bit"},
		// manifestFiles, manifestSafeFields and manifestSourcePrefix.
		{"only safe fields change", fixtureManifests, changed(map[string]prFile{fixturePlugin: manifest(
			`{"name": "a", "version": "1.0.0", "author": {"name": "A"}}`,
			`{"name": "a", "version": "1.1.0", "description": "A.", "keywords": ["k"], "author": {"name": "A"}}`)}), ""},
		{"an author that changes", fixtureManifests, changed(map[string]prFile{fixturePlugin: manifest(
			`{"name": "a", "author": {"name": "A"}}`, `{"name": "a", "author": {"name": "M"}}`)}), "manifest-fields"},
		{"hooks that the head adds", fixtureManifests, changed(map[string]prFile{fixturePlugin: manifest(
			`{"name": "a"}`, `{"name": "a", "hooks": "./hooks/hooks.json"}`)}), "manifest-fields"},
		{"mcpServers that change", fixtureManifests, changed(map[string]prFile{fixturePlugin: manifest(
			`{"name": "a", "mcpServers": {"s": {"command": "a"}}}`,
			`{"name": "a", "mcpServers": {"s": {"command": "b"}}}`)}), "manifest-fields"},
		{"hooks that the head removes", fixtureManifests, changed(map[string]prFile{fixturePlugin: manifest(
			`{"name": "a", "hooks": {}}`, `{"name": "a"}`)}), "manifest-fields"},
		{"a new manifest file with an author", fixtureManifests, changed(map[string]prFile{
			"plugins/b/.claude-plugin/plugin.json": manifest("", `{"name": "b", "author": {"name": "M"}}`)}), "manifest-fields"},
		{"a new manifest file with safe fields only", fixtureManifests, changed(map[string]prFile{
			"plugins/b/.claude-plugin/plugin.json": manifest("", `{"name": "b", "version": "1.0.0"}`)}), ""},
		{"a marketplace source that is a relative path under the prefix", fixtureManifests, changed(map[string]prFile{
			fixtureMarket: marketWith(`{"name": "b", "description": "B.", "source": "./plugins/b"}`)}), ""},
		{"a marketplace source that is a URL", fixtureManifests, changed(map[string]prFile{
			fixtureMarket: marketWith(`{"name": "b", "source": "https://example.com/b.git"}`)}), "manifest-fields"},
		{"a marketplace source that is an object", fixtureManifests, changed(map[string]prFile{
			fixtureMarket: marketWith(`{"name": "b", "source": {"source": "github", "repo": "o/b"}}`)}), "manifest-fields"},
		{"a marketplace source outside the prefix", fixtureManifests, changed(map[string]prFile{
			fixtureMarket: marketWith(`{"name": "b", "source": "./other/b"}`)}), "manifest-fields"},
		{"a marketplace source that leaves the prefix with ..", fixtureManifests, changed(map[string]prFile{
			fixtureMarket: marketWith(`{"name": "b", "source": "./plugins/../b"}`)}), "manifest-fields"},
		{"a marketplace entry that changes a field outside the safe fields", fixtureManifests, changed(map[string]prFile{
			fixtureMarket: manifest(fixtureMarketBase, `{"name": "m", "owner": {"name": "O"}, "plugins": [
  {"name": "a", "description": "A.", "source": "./plugins/a", "skills": ["./skills/x", "./skills/y"]}]}`)}), "manifest-fields"},
		{"a marketplace owner that changes", fixtureManifests, changed(map[string]prFile{
			fixtureMarket: manifest(fixtureMarketBase, `{"name": "m", "owner": {"name": "M"}, "plugins": [
  {"name": "a", "description": "A.", "source": "./plugins/a", "skills": ["./skills/x"]}]}`)}), "manifest-fields"},
		{"a marketplace entry without a name", fixtureManifests, changed(map[string]prFile{
			fixtureMarket: marketWith(`{"source": "./plugins/b"}`)}), "manifest-fields"},
		{"a manifest that does not parse", fixtureManifests, changed(map[string]prFile{fixturePlugin: manifest(
			`{"name": "a"}`, `{"name": "a",`)}), "manifest-fields"},
		{"a manifest with text after its object", fixtureManifests, changed(map[string]prFile{fixturePlugin: manifest(
			`{"name": "a"}`, `{"name": "a"} {"hooks": {}}`)}), "manifest-fields"},
		// The text of a link is its target. Here the target parses, and the
		// mode alone refuses.
		{"a manifest that becomes a symbolic link", fixtureManifests, changed(map[string]prFile{
			fixturePlugin: {BaseMode: "100644", BaseText: `{"name": "a"}`, HeadMode: "120000", HeadText: `{"name": "a"}`}}), "manifest-fields"},
		{"manifestFiles off, with an author that changes", nil, changed(map[string]prFile{fixturePlugin: manifest(
			`{"name": "a", "author": {"name": "A"}}`, `{"name": "a", "author": {"name": "M"}}`)}), ""},
		{"a JSON file that no manifest pattern matches", fixtureManifests, changed(map[string]prFile{
			"docs/a.json": manifest(`{}`, `{"author": "M"}`)}), ""},
		{"manifest trees that fetch did not read", fixtureManifests, func(s *prSnapshot) {
			s.Files = []string{fixturePlugin}
		}, "manifest-fields"},
	}
	var failed []string
	for _, c := range cases {
		s := readyPR()
		if c.edit != nil {
			c.edit(&s)
		}
		p := fixturePolicy
		if c.policy != nil {
			c.policy(&p)
		}
		rule, why := judge(&s, p, false)
		// A tree that GitHub cut gives its reason.
		cut := s.Trees != nil && s.Trees.Truncated != "" && !strings.Contains(why, "GitHub cut the Git tree of "+short(fixtureHead))
		if rule != c.want || cut {
			failed = append(failed, fmt.Sprintf("files case %q: rule %q (%s), want %q", c.name, rule, why, c.want))
		}
	}
	return failed
}

// sourceCases tests the source rule of manifest entries with the prefix
// ./plugins/.
func sourceCases() []string {
	cases := []struct {
		source any
		want   bool
	}{
		{"./plugins/a", true},
		{"./plugins/a/b", true},
		{"./plugins", false},
		{"./plugins/", false},
		{"./plugins/./a", false},
		{"./plugins/../a", false},
		{"./plugins/a/../../b", false},
		{"plugins/a", false},
		{"./pluginsx/a", false},
		{"https://example.com/plugins/a", false},
		{`./plugins/a\..\..\b`, false},
		{map[string]any{"source": "github", "repo": "o/a"}, false},
	}
	var failed []string
	for _, c := range cases {
		if got := safeSource(c.source, "./plugins/"); got != c.want {
			failed = append(failed, fmt.Sprintf("source %v under ./plugins/: %t, want %t", c.source, got, c.want))
		}
	}
	if safeSource("./plugins/a", "") {
		failed = append(failed, "source ./plugins/a with no prefix: true, want false")
	}
	return failed
}

// treeCases reads changed files from Git trees and blobs in the JSON of the
// GitHub REST API, and a replay keeps them.
func treeCases() []string {
	var failed []string
	var trees [2]gitTree
	for i, body := range []string{
		`{"sha": "b", "truncated": false, "tree": [
  {"path": "scripts", "mode": "040000", "type": "tree", "sha": "t1"},
  {"path": "scripts/run.sh", "mode": "100644", "type": "blob", "sha": "s1", "size": 3},
  {"path": "plugins/a/.claude-plugin/plugin.json", "mode": "100644", "type": "blob", "sha": "m1", "size": 12}]}`,
		`{"sha": "h", "truncated": false, "tree": [
  {"path": "scripts", "mode": "040000", "type": "tree", "sha": "t2"},
  {"path": "scripts/run.sh", "mode": "100755", "type": "blob", "sha": "s1", "size": 3},
  {"path": "scripts/new.sh", "mode": "100755", "type": "blob", "sha": "s2", "size": 3},
  {"path": "plugins/a/.claude-plugin/plugin.json", "mode": "100644", "type": "blob", "sha": "m2", "size": 34}]}`,
	} {
		if err := json.Unmarshal([]byte(body), &trees[i]); err != nil {
			return append(failed, "tree JSON: "+err.Error())
		}
	}
	// Only the blobs of the manifest files: a read of another blob fails.
	blobs := map[string]string{
		"m1": `{"sha": "m1", "size": 12, "encoding": "base64", "content": "eyJuYW1lIjoiYSJ9\n"}`,
		"m2": `{"sha": "m2", "size": 34, "encoding": "base64", "content": "eyJuYW1lIjoiYSIsImF1\ndGhvciI6eyJuYW1lIjoi\nTSJ9fQ==\n"}`,
	}
	read := func(sha string) (string, error) {
		var blob gitBlob
		if err := json.Unmarshal([]byte(blobs[sha]), &blob); err != nil {
			return "", fmt.Errorf("blob %s: %w", sha, err)
		}
		return blob.text()
	}
	commits := [2]string{"base", fixtureHead}
	var p mergePolicy
	fixtureManifests(&p)
	files := []string{"scripts/run.sh", "scripts/new.sh", fixturePlugin}
	got, err := treeFiles(commits, trees, files, p.ManifestFiles, read)
	if err != nil {
		return append(failed, "tree files: "+err.Error())
	}
	want := map[string]prFile{
		"scripts/run.sh": {BaseMode: "100644", HeadMode: "100755"},
		"scripts/new.sh": {HeadMode: "100755"},
		fixturePlugin:    {BaseMode: "100644", HeadMode: "100644", BaseText: `{"name":"a"}`, HeadText: `{"name":"a","author":{"name":"M"}}`},
	}
	if got.Truncated != "" || !maps.Equal(got.Files, want) {
		failed = append(failed, fmt.Sprintf("tree files: %+v, want %+v", *got, want))
	}
	trees[1].Truncated = true
	if cut, err := treeFiles(commits, trees, files, p.ManifestFiles, read); err != nil || cut.Truncated != fixtureHead || len(cut.Files) != 0 {
		failed = append(failed, fmt.Sprintf("a tree that GitHub cut: %+v (%v), want Truncated %s and no files", cut, err, fixtureHead))
	}
	// A replay keeps the trees of a merged pull request, and the rules judge
	// them.
	pr := &gqlPR{Number: 8, State: "MERGED", BaseRefName: "main", HeadRefOid: fixtureHead,
		Author: &gqlActor{Login: "alice"}, Trees: &prTrees{Files: map[string]prFile{"run.sh": {HeadMode: "100755"}}}}
	pr.Files.Nodes = append(pr.Files.Nodes, struct{ Path string }{"run.sh"})
	s := snapshotFrom(pr, "main", true)
	if s.Trees != pr.Trees {
		failed = append(failed, "replay: the snapshot of a merged pull request drops its trees")
	}
	s.Reviews = []prReview{{Author: fixturePolicy.Reviewer, State: "COMMENTED", Commit: fixtureHead}}
	s.Checks = readyPR().Checks
	ep := fixturePolicy
	fixtureExecutableBit(&ep)
	if rule, why := judge(&s, ep, true); rule != "executable-bit" {
		failed = append(failed, fmt.Sprintf("replay: a new file of mode 100755 gives rule %q (%s), want executable-bit", rule, why))
	}
	return failed
}
