---
title: "Dagger P0: the merge rules replayed over den's last 30 merges"
date: 2026-10-30
status: done
plan: docs/plans/2026-10-30-001-dagger-ci-autonomous-merge-plan.md
---

# Dagger P0: the merge rules replayed over den's last 30 merges

The merge rules are in `.dagger/modules/ci/automerge.go`. They are the automerge filter of `modules/M-02877/pr-reviewer.nix`, in its order, with the stops of plan D4: the `needs-human` label and the risky paths. A replay judges each merged pull request as of its merge:
- the labels come from the label events before the merge;
- only the reviews and the check runs from before the merge count;
- the rules for "open" and "mergeable" are skipped.

The settings are den's, from `dagger.toml`: the authors of the automerger, the Codex connector as the reviewer of record, and the denied paths of D4. Run the replay again with:

```
GH_TOKEN=$(gh auth token) dagger call ci automerge-replay --token env://GH_TOKEN --count 30
```

## Result (measured 2026-10-30 18:58 UTC)

| PR | Merged (UTC) | Head | Verdict | Rule | Reason |
| #72 | 2026-10-30 17:53 | `e5c7ac95cc0a` | accept | - | - |
| #71 | 2026-10-30 16:01 | `48390ba5c812` | accept | - | - |
| #70 | 2026-10-30 17:25 | `0d35821284c4` | refuse | reviewed | app/chatgpt-codex-connector has not reviewed head 0d35821284c4 |
| #69 | 2026-10-30 14:35 | `bb0d06b12556` | refuse | risky-paths | it changes .decapod/OVERRIDE.md, which a person merges |
| #68 | 2026-10-30 14:20 | `74914b3a723a` | refuse | reviewed | app/chatgpt-codex-connector has not reviewed head 74914b3a723a |
| #67 | 2026-10-30 14:10 | `87780678b50d` | accept | - | - |
| #66 | 2026-10-23 16:45 | `89ceff34ff3f` | refuse | threads | 1 unresolved review thread(s) |
| #65 | 2026-10-23 11:48 | `a4fdcff8a965` | refuse | reviewed | app/chatgpt-codex-connector has not reviewed head a4fdcff8a965 |
| #64 | 2026-10-23 11:30 | `6a1748bc31a1` | accept | - | - |
| #52 | 2026-10-23 16:21 | `369c9b5dde27` | refuse | reviewed | app/chatgpt-codex-connector has not reviewed head 369c9b5dde27 |
| #51 | 2026-10-21 11:16 | `0c3ce2efdaff` | refuse | reviewed | app/chatgpt-codex-connector has not reviewed head 0c3ce2efdaff |
| #50 | 2026-10-21 10:13 | `78fa8ab3ef3c` | refuse | threads | 4 unresolved review thread(s) |
| #48 | 2026-10-15 07:49 | `a366dd76a338` | refuse | reviewed | app/chatgpt-codex-connector has not reviewed head a366dd76a338 |
| #47 | 2026-10-14 18:39 | `2c39c8d7b76a` | refuse | reviewed | app/chatgpt-codex-connector has not reviewed head 2c39c8d7b76a |
| #46 | 2026-10-14 18:20 | `66320b722755` | refuse | risky-paths | it changes .decapod/OVERRIDE.md, which a person merges |
| #45 | 2026-10-14 17:59 | `bc14f2dae5ae` | refuse | reviewed | app/chatgpt-codex-connector has not reviewed head bc14f2dae5ae |
| #44 | 2026-10-09 09:05 | `ca9729c2e4a9` | refuse | reviewed | app/chatgpt-codex-connector has not reviewed head ca9729c2e4a9 |
| #43 | 2026-10-09 08:29 | `c22838efb44c` | refuse | reviewed | app/chatgpt-codex-connector has not reviewed head c22838efb44c |
| #40 | 2026-10-08 12:24 | `5c59a3a263ba` | refuse | reviewed | app/chatgpt-codex-connector has not reviewed head 5c59a3a263ba |
| #39 | 2026-10-07 15:35 | `c77ebdab6369` | refuse | reviewed | app/chatgpt-codex-connector has not reviewed head c77ebdab6369 |
| #38 | 2026-10-07 14:39 | `b5955cf24970` | refuse | reviewed | app/chatgpt-codex-connector has not reviewed head b5955cf24970 |
| #37 | 2026-10-07 08:15 | `63296d5f5f99` | refuse | risky-paths | it changes modules/_host-keys.nix, which a person merges |
| #36 | 2026-10-07 07:53 | `355022ed834f` | refuse | reviewed | app/chatgpt-codex-connector has not reviewed head 355022ed834f |
| #35 | 2026-10-07 05:51 | `0ab69121b0ce` | refuse | risky-paths | it changes modules/_github-ssh-keys.nix, which a person merges |
| #34 | 2026-10-07 03:16 | `6078597d79bb` | refuse | reviewed | app/chatgpt-codex-connector has not reviewed head 6078597d79bb |
| #33 | 2026-10-06 23:36 | `d831be9e955b` | refuse | reviewed | app/chatgpt-codex-connector has not reviewed head d831be9e955b |
| #32 | 2026-10-06 21:49 | `8ce398f9dbab` | refuse | reviewed | app/chatgpt-codex-connector has not reviewed head 8ce398f9dbab |
| #31 | 2026-10-06 20:38 | `71c643687034` | refuse | reviewed | app/chatgpt-codex-connector has not reviewed head 71c643687034 |
| #30 | 2026-10-06 20:16 | `8fa6c83efb7e` | refuse | reviewed | app/chatgpt-codex-connector has not reviewed head 8fa6c83efb7e |
| #29 | 2026-10-06 13:49 | `1f8096ae2802` | refuse | reviewed | app/chatgpt-codex-connector has not reviewed head 1f8096ae2802 |
4 accepted, 26 refused, of 30 merged pull requests.
The unresolved threads, the review decision and the Codex summary are read as they are now, not as of the merge.

## What the table shows

- **4 merges pass the rules: #72, #71, #67 and #64.** Each had a clean Codex review of its exact head, green checks and no risky path.
- **20 refusals are `reviewed`.** These pull requests merged on a head that the reviewer did not review. Some merges came after a rebase and a force-push, without a new review: #68 merged on `74914b3`, but Codex reviewed `c41cd74`. Older pull requests have no Codex summary that names a commit. The rules wait for a review of the head, so they would not have merged these.
- **4 refusals are `risky-paths`: #69, #46, #37 and #35.** They change `.decapod/OVERRIDE.md`, `modules/_host-keys.nix` or `modules/_github-ssh-keys.nix`. A person decided each of them, as D4 requires.
- **2 refusals are `threads`: #66 (1 thread) and #50 (4 threads).** The replay reads the threads as they are now. A thread that was resolved after the merge does not show.

No refusal is wrong for the rules as written. The live merger (P4) must ask for a new review after each force-push, because a rebase changes the head.

## Limits

- The unresolved threads, the review decision and the Codex summary comment are read as they are now. GitHub keeps no history of them.
- A reaction (for example the Codex connector's 👍) names no commit, so the rules do not count it.
