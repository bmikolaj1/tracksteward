# tracksteward 0.2.6: the pre-push gate prints no path or ref name, takes its range on stdin, and has a worktree row

Baseline: `main` at `b6a332d` (0.2.5, #29, tag `v0.2.5`). Branch `claude/q37-tracksteward-026`.
Source: three findings deferred from the 0.2.5 Codex review (F4, F5, F6), scheduled as their own slice.

## Findings

| Id | What | Where |
|----|------|-------|
| F4 | The scrub suite's diagnostics name a file by its path (NUL, unreadable, skipped and index-failed lists; the label of a content hit), and the pre-push hook names a ref by its name (deletion and refusal lines) and prints the absolute path of its checkout. A path or ref name that holds a private name is then printed on the console the gate runs on. | `tests/scrub.test.ps1` (SG5 and SG6 real-run rows, `Invoke-ScrubScan`, `Invoke-ScrubHistory`), `.githooks/pre-push` |
| F5 | The hook passes the whole range (every advertised commit as `^<sha>`) on the command line, to `git rev-list --count` and to `powershell.exe -History`. A remote that advertises about 760 commits passes the Windows command-line limit, and every push is then refused. | `.githooks/pre-push`, `tests/scrub.test.ps1` (`-History`, `Invoke-ScrubHistory`, `Invoke-ScrubGit`) |
| F6 | No prepush row pushes from a linked worktree under an absolute `core.hooksPath` (the README setup); the fixture uses a relative `.githooks` in one checkout. | `tests/hooks/prepush.test.ps1` |

## Design

**F4.** Decided with the maintainer before coding (see "Decisions").
- Hook: a ref is named by its position in the push (`pushed ref <n>`, counted over the refs that are not deletions,
  in order; a deletion is `deletion <n>`), never by its name, in the deletion line and in both refusal lines. The closing refusal line names the
  checkout ("the checkout this hook's suite lives in"), not its absolute path. (Panel rounds 1-2:) of a failed run
  the hook shows only FAIL lines and the indented detail right after each, never an error record, and nothing at
  all when there is no FAIL line (rows P24, P25).
- Suite: a path is printed only when the path itself has no hit (denylist and pattern rules, the same check that
  decides whether it ships) and holds no U+FFFD (panel round 1: an undecodable byte). Otherwise it is named as the
  file-name rows already name it: `listed entry <n>` in the work tree, `blob <sha7>` in the history. This covers
  the NUL, unreadable, skipped and index-failed lists and the label of every content hit.

**F5.**
- `Invoke-ScrubGit` takes an optional stdin text (written as UTF-8, with no BOM).
- `Invoke-ScrubHistory` hands the revisions to `git rev-list --stdin` instead of the command line.
- The suite gets `-HistoryStdin`: it reads the revisions from its own stdin, one per line (or parted by white space).
  `-History <range>` stays for the release gate.
- The hook pipes the range to `git rev-list --count --stdin` and to `powershell.exe ... -HistoryStdin`, and prints
  no range: not on a `rev-list` failure, and not in the SG6 discovery label or a discovery reason. Those labels name
  the count of revisions, not each one, and a revision by its position (Codex round 1: also for a short range). git's own stderr, quoted in a reason, can still name a ref typed into the range.

**F6.** A row (P20) that adds a linked worktree of the fixture copy, points `core.hooksPath` at the copy's
absolute `.githooks` path, and pushes from the worktree: a dirty commit is refused, a clean one is pushed. Per the
brief, a real defect it shows is reported as a FINDING before it is fixed.

## Order (TDD per finding, RED first)

1. F6 row first (it pins the setup the other two change): RED or GREEN as found. If it is RED, raise a FINDING.
2. F5: RED row P21: the remote advertises more than 1000 commits, and a clean push is refused today. Then GREEN.
   Also add an SG6 row: `Invoke-ScrubHistory` with a range of more than 1000 revisions.
3. F4: RED rows:
   - SG4/SG6: a NUL file, an unreadable file, a skipped entry and a content hit whose path holds the entry are
     named without the path, and a clean path is still printed.
   - Prepush rows: a deletion of, and a refusal of, a ref whose name holds the entry print no name.
   Then GREEN. Panel fixes added the U+FFFD rows and P24 (round 1), and P25 (round 2).
4. Panel: reviewer and adversary on the diff. Re-run the panel on each fix diff, prose included. Apply the
   round-three rule.
5. Version 0.2.6 in `.claude-plugin/plugin.json`, a CHANGELOG entry (take F5 out of "Not covered"), and the README
   gate paragraph. Then the PR.

## Verification

- `tests\scrub.test.ps1` and `tests\hooks\prepush.test.ps1` run singly.
- `tests\run.ps1` runs only on HOST GO.
- Mutations seen red for each fix.
- The first real push of this branch is the first live run of the gate with the denylist and the allowed-identity
  file both set, and its result goes into the report.

## Decisions

- 2026-11-21, F4: the maintainer picked "Print only clean paths": a path is printed only when it has no hit itself;
  otherwise it is named by its position in the listing or by its blob.
- 2026-11-21, process: the maintainer picked "Inline TDD + panel": the main session writes RED and GREEN and runs every
  suite; reviewer and adversary subagents review each diff and each fix diff.
