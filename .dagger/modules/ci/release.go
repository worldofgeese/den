package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"
)

// The age rule of the bump targets (part f of AEC task M, PRD R6). With
// minReleaseAgeDays, a bump moves a pin only to a release or a commit that is
// at least that many days old, so that upstream has time to find a bad
// release. The module has no bump yet: den's nightly bump is
// scripts/bump-flake-inputs.sh, and `nix flake update` chooses its targets.
// release-age is the rule that a bump calls with its candidates.

// releaseCandidate is a version that a bump can move a pin to. Published is
// the publish time of a release, or the committer date of a commit on the
// default branch of the upstream repository.
type releaseCandidate struct {
	Version   string    `json:"version"`
	Published time.Time `json:"published"`
}

// skippedRelease is a candidate that is newer than the chosen one, and why
// the rule did not choose it.
type skippedRelease struct {
	Version   string    `json:"version"`
	Published time.Time `json:"published"`
	Reason    string    `json:"reason"`
}

// releaseChoice is what the rule chooses. With no candidate that is old
// enough, Chosen is nil, and the bump keeps the pin.
type releaseChoice struct {
	MinReleaseAgeDays int               `json:"minReleaseAgeDays"`
	Chosen            *releaseCandidate `json:"chosen"`
	Skipped           []skippedRelease  `json:"skipped"`
}

// chooseRelease chooses the first candidate, in the order of the list, that
// is at least days old at now. The caller gives the candidates newest first,
// in the order of upstream: for releases the newest version first, and for
// commits the newest commit first. Each candidate before the chosen one is
// skipped, with the reason. With days 0 the rule is off: it chooses the
// first candidate. It is a pure function, so ci:release-age-rules tests each
// case.
func chooseRelease(candidates []releaseCandidate, days int, now time.Time) releaseChoice {
	choice := releaseChoice{MinReleaseAgeDays: days, Skipped: []skippedRelease{}}
	minAge := time.Duration(days) * 24 * time.Hour
	for _, c := range candidates {
		why := ""
		switch age := now.Sub(c.Published); {
		case days == 0:
		case c.Published.IsZero():
			why = "it has no publish time, so its age is not known"
		case age < 0:
			why = "its publish time is after now"
		case age < minAge:
			why = fmt.Sprintf("it is %s old, younger than minReleaseAgeDays (%d days)", ageText(age), days)
		}
		if why == "" {
			chosen := c
			choice.Chosen = &chosen
			return choice
		}
		choice.Skipped = append(choice.Skipped, skippedRelease{Version: c.Version, Published: c.Published, Reason: why})
	}
	return choice
}

// ageText gives an age in whole days and hours, rounded down.
func ageText(d time.Duration) string {
	h := int(d / time.Hour)
	return fmt.Sprintf("%d days %d hours", h/24, h%24)
}

// releaseAge reads the candidates as JSON, applies the rule at now, and gives
// the choice as JSON.
func releaseAge(candidates string, days int, now time.Time) (string, error) {
	if days < 0 {
		return "", fmt.Errorf("minReleaseAgeDays is %d; use 0 (no minimum age) or more", days)
	}
	dec := json.NewDecoder(strings.NewReader(candidates))
	dec.DisallowUnknownFields()
	var list []releaseCandidate
	if err := dec.Decode(&list); err != nil {
		return "", fmt.Errorf("candidates: %w", err)
	}
	if list == nil {
		return "", errors.New("candidates: give a JSON list")
	}
	if _, err := dec.Token(); err != io.EOF {
		return "", errors.New("candidates: text after the JSON list")
	}
	for i, c := range list {
		if c.Version == "" {
			return "", fmt.Errorf("candidates: item %d has no version", i)
		}
	}
	out, err := json.MarshalIndent(chooseRelease(list, days, now), "", "  ")
	if err != nil {
		return "", err
	}
	return string(out) + "\n", nil
}

// Choose the bump target by the age rule. candidates is a JSON list, newest
// first, of {"version": "...", "published": "<RFC 3339 time>"}. For a commit,
// published is the committer date of the commit on the default branch of the
// upstream repository. The function chooses the first candidate that is at
// least minReleaseAgeDays old, and lists each newer candidate that it skipped
// with the reason. With no candidate that is old enough, chosen is null. It
// reads no network and changes nothing.
// +cache="never"
func (m *Ci) ReleaseAge(
	// The candidates, as a JSON list, newest first.
	candidates string,
) (string, error) {
	return releaseAge(candidates, m.MinReleaseAgeDays, time.Now())
}
