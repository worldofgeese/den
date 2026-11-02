package main

import (
	"fmt"
	"strings"
)

// The fork policy (part g of AEC task M). A fork pull request has its head
// branch in another repository. The token of the module cannot push to that
// branch, and it cannot update that branch from the base.
//
// checks-only (the default, and an empty setting) is the behavior of den: the
// merge rules and the shepherd judge a fork pull request as each pull
// request. The rule author decides who merges without a person.
//
// review-and-suggest (AEC) adds one action: a fork pull request that
// conflicts with its base gets the needs-human action, because an update of
// the branch would write to the fork. A fork pull request that is behind its
// base without a conflict merges as it is, as each pull request does: no
// function of the module updates a branch. The merge rules do not change. A
// fix for a fork pull request is a suggestion comment and never a push. The
// module has no fixer yet, so that part applies when a fixer comes.
const (
	forkChecksOnly       = "checks-only"
	forkReviewAndSuggest = "review-and-suggest"
)

// checkForkPolicy refuses a forkPolicy setting that the module does not know.
func checkForkPolicy(policy string) error {
	switch policy {
	case "", forkChecksOnly, forkReviewAndSuggest:
		return nil
	}
	return fmt.Errorf("forkPolicy is %q; use %s (the default) or %s", policy, forkChecksOnly, forkReviewAndSuggest)
}

// forkAction returns why an open fork pull request needs a person under the
// fork policy, or "" when it needs no action. Only review-and-suggest has an
// action: a conflict with the base. A draft and a pull request with a stop
// label get no action, as the shepherd leaves them alone. It is a pure
// function, so ci:shepherd-rules tests each case.
func forkAction(s *prSnapshot, p mergePolicy) string {
	if p.ForkPolicy != forkReviewAndSuggest || !s.Fork || s.State != "OPEN" || s.Draft || s.Mergeable != "CONFLICTING" {
		return ""
	}
	for _, l := range s.Labels {
		for _, stop := range stopLabels {
			if strings.EqualFold(l, stop) {
				return ""
			}
		}
	}
	return "fork head " + short(s.Head) + " conflicts with " + s.Base + "; the token cannot update a fork, so a person resolves the conflict"
}

// forkComment is the comment that goes with the label needs-human.
func forkComment(s *prSnapshot) string {
	return fmt.Sprintf("Head %s of this pull request conflicts with %s. The branch is in a fork, "+
		"and the token of the shepherd cannot push to a fork, so the shepherd does not update the branch. "+
		"The author or a person must resolve the conflict. Then remove the label needs-human to let the automation continue.",
		short(s.Head), s.Base)
}
