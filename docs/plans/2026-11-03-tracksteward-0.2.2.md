# tracksteward 0.2.2 plan (2026-11-03)

Baseline: main 806ecb8 (0.2.1). Scope: the README "What is not done" / CHANGELOG 0.2.1 "Known and left"
items that sit in `scripts/coord-{status,set,log,common}.ps1`. No tag, no release. Every slice is red
first (the test row seen failing), then the fix.

## Rulings (Bruno, this window, 2026-11-03)

- Dotted `10.22`: coord-set keeps accepting it (documented, no code).
- Literal `{now}`: `{{now}}` is written as `{now}` (shared `Expand-CoordNow`, so coord-log and coord-set agree).
- coord-log refuses a BOM or bidi mark in its text, as coord-set does (shared `Test-CoordBidiOrBom`).
- coord-status: a row's PR is its PR cell only; a `#<n>` in the Status text is ignored.

## Slices

| Slice | Item | Files | Pinned by |
|---|---|---|---|
| S1 | `{{now}}` literal | coord-common.ps1, coord-log.ps1, coord-set.ps1 (header) | coord-log L36, coord-set S2 row |
| S2 | BOM / bidi in coord-log | coord-common.ps1, coord-log.ps1 | coord-log L37 (12 code points) |
| S3 | PR from the PR cell only | coord-status.ps1 | T5m |
| S4 | repeated finding id once; inline `| outcome: <word>` closes | coord-status.ps1 | T5k, T5l |
| S5 | git floor in coord-set / coord-status | coord-common.ps1 (`Resolve-CoordLedgerArg`, no-`-Ledger` branch only) | F5 rows in both suites |
| S6 | README, CHANGELOG | README.md, CHANGELOG.md | scrub suite |

## Out of scope / left

- Version bump in `.claude-plugin/plugin.json` (outside this track's file scope; asked of the coordinator).
- The other 0.2.1 limits (relative Repo folder, UNC, `Owner:` inside a Queue item, fence encoding, gh stub, 140-char cut).
- The README "No CI workflow ships" line (the cloud track Q28 owns it).

## Verification

Per slice: its suite, new rows seen red first. End: full `tests\run.ps1` on 5.1; review panel
(reviewer + adversary) on the diff, then on the fix diff.
