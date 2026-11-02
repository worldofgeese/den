package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"
)

// release-age chooses the expected bump target for fixed candidates and a
// fixed time: the rule as written (7 days), switched off (0) and inverted
// (the newest candidate is old enough). No network.
// +check
func (m *Ci) ReleaseAgeRules(_ context.Context) error {
	var failed []string
	failed = append(failed, releaseCases()...)
	failed = append(failed, releaseInputCases()...)
	if len(failed) > 0 {
		return errors.New(strings.Join(failed, "\n"))
	}
	return nil
}

// ago is a candidate that was published d before fixtureTime.
func ago(version string, d time.Duration) releaseCandidate {
	return releaseCandidate{Version: version, Published: fixtureTime.Add(-d)}
}

const day = 24 * time.Hour

func releaseCases() []string {
	// Newest first: a release of 1 day, of 5 days and of 10 days.
	releases := []releaseCandidate{ago("v3.0.0", day), ago("v2.1.0", 5*day), ago("v2.0.0", 10*day)}
	// The commits of the default branch upstream, newest first, with their
	// committer dates.
	commits := []releaseCandidate{ago("c3c3c3c", 2*time.Hour), ago("b2b2b2b", 6*day+23*time.Hour), ago("a1a1a1a", 8*day)}
	cases := []struct {
		name       string
		candidates []releaseCandidate
		days       int
		chosen     string
		// Each skipped version and a part of its reason.
		skipped [][2]string
	}{
		// As written.
		{"7 days: the newest release of 7 days or more", releases, 7, "v2.0.0",
			[][2]string{{"v3.0.0", "it is 1 days 0 hours old, younger than minReleaseAgeDays (7 days)"},
				{"v2.1.0", "it is 5 days 0 hours old"}}},
		{"7 days: the commit by its committer date", commits, 7, "a1a1a1a",
			[][2]string{{"c3c3c3c", "it is 0 days 2 hours old"}, {"b2b2b2b", "it is 6 days 23 hours old"}}},
		{"7 days: exactly 7 days old is old enough", []releaseCandidate{ago("v1", 7*day)}, 7, "v1", nil},
		{"7 days: one second less is too young", []releaseCandidate{ago("v2", 7*day-time.Second), ago("v1", 30*day)}, 7, "v1",
			[][2]string{{"v2", "it is 6 days 23 hours old"}}},
		{"7 days: no candidate is old enough", releases[:2], 7, "",
			[][2]string{{"v3.0.0", "younger than"}, {"v2.1.0", "younger than"}}},
		{"7 days: no publish time", []releaseCandidate{{Version: "v4"}, ago("v1", 9*day)}, 7, "v1",
			[][2]string{{"v4", "it has no publish time, so its age is not known"}}},
		{"7 days: a publish time after now", []releaseCandidate{ago("v4", -time.Hour), ago("v1", 9*day)}, 7, "v1",
			[][2]string{{"v4", "its publish time is after now"}}},
		{"7 days: the order of the list decides, not the time", []releaseCandidate{ago("v2.0.0", 10*day), ago("v1.9.9", 8*day)}, 7, "v2.0.0", nil},
		{"7 days: no candidates", nil, 7, "", nil},
		{"1 day: the release of 1 day", releases, 1, "v3.0.0", nil},
		// Switched off.
		{"0 days: the newest release", releases, 0, "v3.0.0", nil},
		{"0 days: the newest commit", commits, 0, "c3c3c3c", nil},
		{"0 days: a candidate with no publish time", []releaseCandidate{{Version: "v4"}}, 0, "v4", nil},
		// Inverted: the newest candidate is old enough, so nothing is skipped.
		{"7 days: the newest release is old enough", []releaseCandidate{ago("v3.0.0", 20*day), ago("v2.0.0", 30*day)}, 7, "v3.0.0", nil},
		{"30 days: each release is too young", releases, 30, "",
			[][2]string{{"v3.0.0", "(30 days)"}, {"v2.1.0", "(30 days)"}, {"v2.0.0", "it is 10 days 0 hours old"}}},
	}
	var failed []string
	for _, c := range cases {
		got := chooseRelease(c.candidates, c.days, fixtureTime)
		fail := func(format string, args ...any) {
			failed = append(failed, fmt.Sprintf("release case %q: ", c.name)+fmt.Sprintf(format, args...))
		}
		chosen := ""
		if got.Chosen != nil {
			chosen = got.Chosen.Version
		}
		if chosen != c.chosen {
			fail("chose %q, want %q", chosen, c.chosen)
		}
		if got.MinReleaseAgeDays != c.days {
			fail("minReleaseAgeDays %d, want %d", got.MinReleaseAgeDays, c.days)
		}
		if len(got.Skipped) != len(c.skipped) {
			fail("skipped %+v, want %d", got.Skipped, len(c.skipped))
			continue
		}
		for i, s := range got.Skipped {
			if s.Version != c.skipped[i][0] || !strings.Contains(s.Reason, c.skipped[i][1]) {
				fail("skipped %d is %q (%s), want %q with %q", i, s.Version, s.Reason, c.skipped[i][0], c.skipped[i][1])
			}
		}
	}
	return failed
}

// releaseInputCases: release-age reads the JSON list and gives JSON, and it
// refuses input that it cannot read.
func releaseInputCases() []string {
	var failed []string
	list := `[{"version":"v3.0.0","published":"2026-10-29T12:00:00Z"},{"version":"v2.0.0","published":"2026-10-20T12:00:00Z"}]`
	out, err := releaseAge(list, 7, fixtureTime)
	var got releaseChoice
	switch {
	case err != nil:
		failed = append(failed, fmt.Sprintf("release input: %v", err))
	case json.Unmarshal([]byte(out), &got) != nil || got.Chosen == nil:
		failed = append(failed, "release input: the output is not a choice:\n"+out)
	case got.Chosen.Version != "v2.0.0" || !got.Chosen.Published.Equal(fixtureTime.Add(-10*day)) ||
		len(got.Skipped) != 1 || got.Skipped[0].Version != "v3.0.0" || got.MinReleaseAgeDays != 7:
		failed = append(failed, "release input: the wrong choice:\n"+out)
	}
	if out, err := releaseAge(list, 30, fixtureTime); err != nil || !strings.Contains(out, `"chosen": null`) {
		failed = append(failed, fmt.Sprintf("release input: no choice gives %q, %v; want chosen null", out, err))
	}
	if out, err := releaseAge(`[]`, 0, fixtureTime); err != nil || !strings.Contains(out, `"skipped": []`) {
		failed = append(failed, fmt.Sprintf("release input: an empty list gives %q, %v; want an empty skipped list", out, err))
	}
	for _, c := range []struct {
		name, input string
		days        int
		want        string
	}{
		{"a negative age", list, -1, "minReleaseAgeDays is -1"},
		{"not JSON", "v1", 7, "candidates:"},
		{"an object", `{"version":"v1"}`, 7, "candidates:"},
		{"null", `null`, 7, "give a JSON list"},
		{"text after the list", list + ` []`, 7, "text after the JSON list"},
		{"an unknown field", `[{"version":"v1","date":"2026-10-20T12:00:00Z"}]`, 7, "unknown field"},
		{"a time that is not RFC 3339", `[{"version":"v1","published":"2026-10-20"}]`, 7, "candidates:"},
		{"no version", `[{"published":"2026-10-20T12:00:00Z"}]`, 7, "item 0 has no version"},
	} {
		if out, err := releaseAge(c.input, c.days, fixtureTime); err == nil || !strings.Contains(err.Error(), c.want) {
			failed = append(failed, fmt.Sprintf("release input %q: %q, %v; want an error with %q", c.name, out, err, c.want))
		}
	}
	// The function reads the setting.
	m := &Ci{MinReleaseAgeDays: -2}
	if _, err := m.ReleaseAge(list); err == nil || !strings.Contains(err.Error(), "minReleaseAgeDays is -2") {
		failed = append(failed, fmt.Sprintf("release input: release-age with minReleaseAgeDays -2: %v", err))
	}
	if out, err := (&Ci{}).ReleaseAge(list); err != nil || !slices.Contains(strings.Fields(out), `"v3.0.0",`) {
		failed = append(failed, fmt.Sprintf("release input: release-age with no setting gives %q, %v; want v3.0.0", out, err))
	}
	return failed
}
