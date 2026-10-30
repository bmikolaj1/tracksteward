# tracksteward 0.2.1 plan (2026-10-30)

Baseline: main 8d47b42 (0.2.0). Scope: port standards #140 (640e520) and fix the open items of
`2026-10-18-script-port.md` section 9 (items 4-20, "All to 0.2.1"). No tag, no release, no announcement
(the fresh-install check by someone else is still owed). Every slice is red first: the test row is written and seen failing, then the fix.

## Slices (one commit each, suites run with `tests\run.ps1 -Filter <name>*` then the full run at the end)

| Slice | Items | Files | Pinned by |
|---|---|---|---|
| S1 | 13 (#140: tagged finding id, `F<n>:` colon form, Queue id/outcome `(yyyy-MM-dd)` tag) | scripts/coord-status.ps1 (header, Findings 229-235, Queue 263-265) | new rows T5d, T5e, T5g, T5h, T5i copied from the standards test, coord-status.test.ps1 |
| S2 | 10 (owner anchor `\s+owner\s*:` ignore case), 17 (indented unticked Owed check listed / counted), 18 (single ledger read) | scripts/coord-status.ps1 | T18 extended, T6 extended, a one-read row |
| S3 | 4, 5, 6, 7, 8 (repo-snapshot) | scripts/repo-snapshot.ps1, repo-snapshot.test.ps1 | one row per item |
| S4 | 9 (invisible-char deny list), 12 (coord-log uses `Resolve-CoordLedgerArg`, expands `{now}`), 19 (typed time, U+FEFF/bidi in Status, same-name bare Repo) | scripts/coord-handoff.ps1, coord-log.ps1, coord-set.ps1, coord-common.ps1 | coord-handoff / coord-log / coord-set suites |
| S5 | 11 (fixture fence) | tests/fixtures/coord-test-fixture.ps1 and the six suites | a row that appends to the real-index stand-in mid-run |
| S6 | 14, 15, 16: PORT of the standards status-board fix, written by Q3+Q13 (no second fix here) | scripts/coord-status.ps1 | the rows that track lands |
| S7 | 20 (documented, no code change), version 0.2.1, CHANGELOG, README | .claude-plugin/plugin.json, README.md, CHANGELOG.md | n/a |

S6 waits on the Q3+Q13 merge. If it has not landed when S1-S5 and S7 are done, 0.2.1 ships without 14-16
only on Bruno's word; otherwise the PR waits.

## Decisions to take (recommendation first)

- Item 8 (git 2.38 floor): refuse at start with a one-line error and a non-zero exit, in a shared helper
  in coord-common.ps1 called by each script; alternative: warn only. Recommendation: refuse.
- Item 11: hash only a scratch index (the suites point the scripts at a scratch folder) rather than
  tolerate appended lines; alternative: tolerate appended lines.
- Item 20: document the intended difference from the source in the script header and CHANGELOG; no code.
- Item 19: fix the three sub-points; for same-name bare-Repo rows, `-Repo` matches a bare name against
  the Repo cell text when no full path resolves.

## Verification

Per slice: its suite green and its new rows seen red before the fix. End: full `tests\run.ps1` on 5.1.
Heavy-run requests go to the coordinator first (house rules). Review panel (reviewer + adversary) on the
whole diff, then again on the fix diff; Codex only if Bruno picks model and effort. WIP lines go to the
notes folder.
