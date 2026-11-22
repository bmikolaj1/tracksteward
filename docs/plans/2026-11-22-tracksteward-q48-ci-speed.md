# Q48: tracksteward CI speed (F10) and the stale workflow header (F11)

## Measured (run 44933428634, the green 50m46s run of the 0.2.8 PR, per suite from the log's line stamps)

| suite | minutes |
| --- | --- |
| hooks\prepush | 15.5 |
| scripts\prune-scan | 12.3 |
| hooks\coord-scope-guard | 6.8 |
| scripts\merge-verify | 6.1 |
| scripts\slot-check | 3.2 |
| scripts\repo-snapshot | 1.5 |
| scripts\coord-handoff | 1.2 |
| the other six suites together | about 4 |

The suites run one after another in one job, so wall time is the sum. prepush runs the
scrub suite once per push row (about 20 s each), so it is slow by design; its rows stay.

## Change

- `tests\run.ps1` gets `-Group <name>` and `-List`. A table in run.ps1 names three
  groups (prepush; prune; guard-merge); every other suite is in `rest`, so a new suite
  runs without anyone editing a table.
- `test.yml` runs one parallel job per group (`strategy.matrix`, `fail-fast: false`).
  Expected wall time is the slowest group (prepush, about 15.5 min) plus job set-up,
  against about 50 min now. No row is dropped: the same suites run, in four jobs.
- `tests\run.test.ps1` rows R5: the groups test.yml names cover every suite exactly
  once; an unknown group exits 1. Mutation seen red: a group removed from the matrix.
- F11: the header states that the repository is public and claims no billing rule.

## Not changed

- The job name changes (`tests\run.ps1 <group> (Windows PowerShell 5.1)`). No branch
  protection or ruleset exists on the repo (the API returns 404), so no required check
  is renamed.
- No suite content, timeout or timing row is touched. `tests\scrub.test.ps1` is Q47's.
