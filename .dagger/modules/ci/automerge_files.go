// The changed files that the rules executable-bit and manifest-fields read.
// GitHub's list of changed files has no file modes and no file text, so the
// rules read the Git trees of the merge base and the head, and the blobs of
// the changed manifest files. fetch reads them only when riskyExecutableBit
// or manifestFiles is set.
package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"reflect"
	"slices"
	"sort"
	"strings"
)

// prTrees holds each changed file of a pull request as the Git trees of the
// merge base and the head have it.
type prTrees struct {
	// Truncated names a commit whose tree GitHub cut, because the tree is too
	// big for one call. Files is then empty, and the rules refuse.
	Truncated string
	Files     map[string]prFile
}

// prFile is a changed file at the merge base and at the head.
type prFile struct {
	// The git mode, for example "100644" or "100755". "" is a file that is
	// not there.
	BaseMode, HeadMode string
	// The text of a manifest file (manifestFiles) that is a regular file.
	BaseText, HeadText string
}

// gitTree is a Git tree as GET /repos/{owner}/{repo}/git/trees/{sha} with
// recursive=1 gives it.
type gitTree struct {
	Truncated bool
	Tree      []gitTreeEntry
}

type gitTreeEntry struct{ Path, Mode, Sha string }

// gitBlob is a blob as GET /repos/{owner}/{repo}/git/blobs/{sha} gives it.
type gitBlob struct{ Content, Encoding string }

func (t gitTree) byPath() map[string]gitTreeEntry {
	out := make(map[string]gitTreeEntry, len(t.Tree))
	for _, e := range t.Tree {
		out[e.Path] = e
	}
	return out
}

// text decodes the content of a blob.
func (b gitBlob) text() (string, error) {
	switch b.Encoding {
	case "base64":
		// GitHub breaks the base64 text into lines.
		data, err := base64.StdEncoding.DecodeString(strings.ReplaceAll(b.Content, "\n", ""))
		return string(data), err
	case "utf-8":
		return b.Content, nil
	}
	return "", fmt.Errorf("blob encoding %q", b.Encoding)
}

// regular reports whether a git mode is a regular file. A symbolic link
// (120000) or a submodule (160000) is not.
func regular(mode string) bool { return mode == "100644" || mode == "100755" }

// readTrees reads each changed file of a pull request from the Git trees of
// the merge base and the head, and the text of each changed manifest file.
// GitHub compares the head with the merge base of the base commit and the
// head when it lists the changed files, so the rules read the same commits.
func (m *Ci) readTrees(ctx context.Context, g *githubClient, owner, name string, pr *gqlPR) (*prTrees, error) {
	repo := "/repos/" + owner + "/" + name
	var compare struct {
		MergeBaseCommit struct{ Sha string } `json:"merge_base_commit"`
	}
	if err := g.rest(ctx, "GET", repo+"/compare/"+pr.BaseRefOid+"..."+pr.HeadRefOid+"?per_page=1", nil, &compare); err != nil {
		return nil, err
	}
	if compare.MergeBaseCommit.Sha == "" {
		return nil, fmt.Errorf("GitHub gives no merge base of %s and %s", short(pr.BaseRefOid), short(pr.HeadRefOid))
	}
	commits := [2]string{compare.MergeBaseCommit.Sha, pr.HeadRefOid}
	var trees [2]gitTree
	for i, sha := range commits {
		if err := g.rest(ctx, "GET", repo+"/git/trees/"+sha+"?recursive=1", nil, &trees[i]); err != nil {
			return nil, err
		}
	}
	var files []string
	for _, f := range pr.Files.Nodes {
		files = append(files, f.Path)
	}
	return treeFiles(commits, trees, files, m.ManifestFiles, func(sha string) (string, error) {
		var blob gitBlob
		if err := g.rest(ctx, "GET", repo+"/git/blobs/"+sha, nil, &blob); err != nil {
			return "", err
		}
		return blob.text()
	})
}

// treeFiles keeps the changed files of a pull request from the trees of its
// merge base and its head (commits, in that order). A tree that GitHub cut
// gives no files. read gives the text of a blob. treeFiles reads only the
// manifest files that are regular files.
func treeFiles(commits [2]string, trees [2]gitTree, files, manifests []string, read func(sha string) (string, error)) (*prTrees, error) {
	for i := range trees {
		if trees[i].Truncated {
			return &prTrees{Truncated: commits[i]}, nil
		}
	}
	base, head := trees[0].byPath(), trees[1].byPath()
	out := &prTrees{Files: map[string]prFile{}}
	for _, f := range files {
		b, h := base[f], head[f]
		file := prFile{BaseMode: b.Mode, HeadMode: h.Mode}
		if isManifest(manifests, f) {
			var err error
			if file.BaseText, err = regularText(b, read); err != nil {
				return nil, fmt.Errorf("%s: %w", f, err)
			}
			if file.HeadText, err = regularText(h, read); err != nil {
				return nil, fmt.Errorf("%s: %w", f, err)
			}
		}
		out.Files[f] = file
	}
	return out, nil
}

// regularText reads the text of a tree entry that is a regular file. Another
// entry, or a file that is not there, gives "".
func regularText(e gitTreeEntry, read func(sha string) (string, error)) (string, error) {
	if !regular(e.Mode) {
		return "", nil
	}
	return read(e.Sha)
}

func isManifest(patterns []string, name string) bool {
	return slices.ContainsFunc(patterns, func(p string) bool { return matchRiskyPath(p, name) })
}

// unread returns why the rules cannot judge the changed files, or "" when
// fetch read the trees.
func (t *prTrees) unread() string {
	switch {
	case t == nil:
		return "the rules did not read the Git trees of the pull request; a person merges"
	case t.Truncated != "":
		return "GitHub cut the Git tree of " + short(t.Truncated) +
			" because it is too big for one call, so the rules cannot read the changed files; a person merges"
	}
	return ""
}

// file returns a changed file, or why the rules did not read it.
func (t *prTrees) file(name string) (prFile, string) {
	f, ok := t.Files[name]
	if !ok {
		return prFile{}, "the rules did not read " + name + " from the Git trees; a person merges"
	}
	return f, ""
}

// executableBit returns why a person merges a pull request that adds a file
// with git mode 100755, or that changes the mode of a file to 100755, or "".
// A file that stays at 100755 needs no person.
func executableBit(s *prSnapshot) string {
	if why := s.Trees.unread(); why != "" {
		return why
	}
	for _, name := range s.Files {
		f, why := s.Trees.file(name)
		switch {
		case why != "":
			return why
		case f.HeadMode != "100755" || f.BaseMode == "100755":
		case f.BaseMode == "":
			return "it adds " + name + " with mode 100755, which a person merges"
		default:
			return "it changes the mode of " + name + " from " + f.BaseMode + " to 100755, which a person merges"
		}
	}
	return ""
}

// manifestFields returns why a person merges a pull request that changes a
// manifest file outside its safe fields, or "".
func manifestFields(s *prSnapshot, p mergePolicy) string {
	if why := s.Trees.unread(); why != "" {
		return why
	}
	for _, name := range s.Files {
		if !isManifest(p.ManifestFiles, name) {
			continue
		}
		f, why := s.Trees.file(name)
		if why != "" {
			return why
		}
		if why := manifestChange(f, p); why != "" {
			return "manifest " + name + " " + why + "; a person merges"
		}
	}
	return ""
}

// manifestChange compares a manifest file at the merge base and at the head.
// A file that is not there is an empty object, so a new file adds each of
// its fields.
func manifestChange(f prFile, p mergePolicy) string {
	base, why := manifestObject(f.BaseMode, f.BaseText)
	if why != "" {
		return why + " at the merge base"
	}
	head, why := manifestObject(f.HeadMode, f.HeadText)
	if why != "" {
		return why
	}
	return fieldsChange(base, head, p)
}

// manifestObject reads a manifest file as one JSON object.
func manifestObject(mode, text string) (map[string]any, string) {
	if mode == "" {
		return map[string]any{}, ""
	}
	if !regular(mode) {
		return nil, "is not a regular file (mode " + mode + ")"
	}
	dec := json.NewDecoder(strings.NewReader(text))
	// Compare numbers as they are written: a float64 can lose digits.
	dec.UseNumber()
	var object map[string]any
	if err := dec.Decode(&object); err != nil || object == nil {
		return nil, "does not parse as a JSON object"
	}
	// Text after the object does not parse either.
	if _, err := dec.Token(); err != io.EOF {
		return nil, "does not parse as a JSON object"
	}
	return object, ""
}

// fieldsChange returns the first top-level field outside manifestSafeFields
// that the head adds, removes or changes, or "". A list of entries, for
// example the plugins of a marketplace, is compared entry by entry
// (entriesChange).
func fieldsChange(base, head map[string]any, p mergePolicy) string {
	for _, k := range keys(base, head) {
		if slices.Contains(p.ManifestSafeFields, k) {
			continue
		}
		b, inBase := base[k]
		h, inHead := head[k]
		if inBase == inHead && reflect.DeepEqual(b, h) {
			continue
		}
		be, baseOK := entries(b, inBase)
		he, headOK := entries(h, inHead)
		if baseOK && headOK {
			if why := entriesChange(k, be, he, p); why != "" {
				return why
			}
			continue
		}
		return change(k, inBase, inHead)
	}
	return ""
}

// entriesChange compares two lists of entries. The name of an entry pairs it
// with the entry of the same name in the other list, so each entry needs a
// unique name. In an entry, the fields of manifestSafeFields can change, and
// source can change only to a relative path under manifestSourcePrefix. An
// entry that the head adds or removes adds or removes each of its fields.
func entriesChange(list string, base, head []map[string]any, p mergePolicy) string {
	b, ok := byName(base)
	if !ok {
		return "has entries in " + list + " without a unique name at the merge base"
	}
	h, ok := byName(head)
	if !ok {
		return "has entries in " + list + " without a unique name"
	}
	for _, name := range keys(b, h) {
		be, he := b[name], h[name]
		for _, k := range keys(be, he) {
			bv, inBase := be[k]
			hv, inHead := he[k]
			if inBase == inHead && reflect.DeepEqual(bv, hv) {
				continue
			}
			at := fmt.Sprintf(" of entry %q in %s", name, list)
			if k == "source" {
				if inHead && safeSource(hv, p.ManifestSourcePrefix) {
					continue
				}
				if !inHead {
					return "removes the field source" + at
				}
				return fmt.Sprintf("sets the field source%s to %s, which is not a relative path under %q", at, value(hv), p.ManifestSourcePrefix)
			}
			if slices.Contains(p.ManifestSafeFields, k) {
				continue
			}
			return change(k, inBase, inHead) + at
		}
	}
	return ""
}

// entries reads a field as a list of entries: an array of objects. A field
// that is not there is an empty list.
func entries(v any, present bool) ([]map[string]any, bool) {
	if !present {
		return nil, true
	}
	list, ok := v.([]any)
	if !ok {
		return nil, false
	}
	out := make([]map[string]any, 0, len(list))
	for _, e := range list {
		object, ok := e.(map[string]any)
		if !ok {
			return nil, false
		}
		out = append(out, object)
	}
	return out, true
}

// byName maps each entry to its name. An entry without a string name, or
// two entries with the same name, give false.
func byName(list []map[string]any) (map[string]map[string]any, bool) {
	out := map[string]map[string]any{}
	for _, e := range list {
		name, ok := e["name"].(string)
		if !ok {
			return nil, false
		}
		if _, seen := out[name]; seen {
			return nil, false
		}
		out[name] = e
	}
	return out, true
}

// safeSource reports whether the source of an entry is a relative path under
// prefix, for example ./plugins/a under ./plugins/. Each level after the
// prefix must be a name: not empty, not "." and not "..". A URL, an object
// or a path with "\" is not safe. With no prefix, no source is safe.
func safeSource(source any, prefix string) bool {
	s, ok := source.(string)
	if !ok || prefix == "" || strings.Contains(s, `\`) {
		return false
	}
	want := strings.Split(strings.TrimSuffix(prefix, "/"), "/")
	got := strings.Split(s, "/")
	if len(got) <= len(want) || !slices.Equal(got[:len(want)], want) {
		return false
	}
	for _, level := range got[len(want):] {
		if level == "" || level == "." || level == ".." {
			return false
		}
	}
	return true
}

// change says what the head does to a field.
func change(field string, inBase, inHead bool) string {
	switch {
	case !inBase:
		return "adds the field " + field
	case !inHead:
		return "removes the field " + field
	}
	return "changes the field " + field
}

// value quotes a string of a manifest for a verdict, and cuts a long one.
func value(v any) string {
	if s, ok := v.(string); ok {
		return fmt.Sprintf("%.80q", s)
	}
	return "a value that is not a string"
}

// keys returns the keys of two maps, sorted, each one time.
func keys[V any](a, b map[string]V) []string {
	out := make([]string, 0, len(a)+len(b))
	for k := range a {
		out = append(out, k)
	}
	for k := range b {
		if _, ok := a[k]; !ok {
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out
}
