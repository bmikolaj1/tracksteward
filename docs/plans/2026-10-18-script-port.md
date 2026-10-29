# Script port: the coordinator's verdict scripts and the scope guard

**Status:** APPROVED 2026-10-18, D1-D8 as recommended. Open: the `pwsh` install (D1 sub-question),
probe P1 (before S6), the section 9 questions (before the slices they affect).
**Baseline:** `main` = `d9c5d83` (0.1.2, docs only: one skill, four templates, the plugin manifests).
**Goal:** tracksteward ships the scripts the private version already runs, so the mechanical checks
the skill now describes as hand-run `git`/`gh` recipes become one call with one verdict line, and the
edit-time scope guard the README promises exists. This is the "catch up" step before a public
release review; the review itself, a fresh install by someone else, and polish (demo, tag) are not
part of this plan.

## 1. What exists in the private source

About 2,900 lines of Windows PowerShell 5.1 plus a 1,325-line hook, all with tests (a custom harness,
not Pester, about 5,800 lines of tests plus a 1,429-line guard suite).

| Script | Lines | What it does | Writes |
|---|---|---|---|
| `coord-common.ps1` | 1,020 | Shared library, 38 functions: bounded git calls (time budget, kill on timeout), ledger path and index, bounded ledger reads, lock + temp-file swap writes, scope globs, `gh` JSON and check rollups | nothing itself |
| `coord-log.ps1` | 208 | Appends `HH:mm <text>` to a ledger section, time from the clock, refuses typed times; `-Register` adds today's ledger to the index the guard reads | the ledger, the index |
| `coord-brief.ps1` | 373 | Renders the brief template for one live Tracks row into `briefs/`; `-Check` refuses an unfilled brief and prints the `BRIEF:` pointer line | the briefs folder |
| `slot-check.ps1` | 205 | `READY \| WAIT \| HOLD` for one PR: full head sha, files outside scope, contains newest main, checks, conflict preview | a temp ref, deleted |
| `repo-snapshot.ps1` | 356 | Start-of-window status per repo: origin/main, local state, open PRs, ledger tracks against scope, worktrees, stale merged branches, newest handover | fetch only |
| `merge-verify.ps1` | 292 | After a merge: merge commit on origin, deletes the branch only while its tip is the merged head, fast-forwards the launch checkout, config sanity, NOTIFY lines | **remote branch delete**, ff |
| `coord-handoff.ps1` | 442 | Mid-day coordinator handoff: rewrites the Coordinator line and logs it in one swap, prints the per-track messages and the checklist | the ledger |
| `coord-scope-guard.ps1` (hook) | 1,325 | `PreToolUse` on Edit/Write/MultiEdit/NotebookEdit: blocks an edit outside the bound track's FILE SCOPE (exit 2); `SessionStart`: records a session anchor | anchor files |

Dependency order: `coord-common` → `coord-log` (owns the index writer) → `coord-brief` and
`coord-handoff` (lock/swap helpers) → `repo-snapshot`, `slot-check` (independent) → `merge-verify`
(destructive, last of the scripts) → the guard (reads what `coord-log -Register` writes).

**The guard without the index writer is dead code:** with no index the guard allows every edit,
silently. So the guard can only ship in or after the slice that ships `coord-log -Register`, and the
skill must tell the coordinator to register the ledger at day start.

## 2. Decisions for the author (recommendation first)

**D1. Runtime.**
(a) **Recommended:** one PowerShell codebase that runs on both Windows PowerShell 5.1 and PowerShell 7,
Windows verified in this port; macOS/Linux made to work behind a small platform layer but marked
*unverified* until something runs it there. The code already has no 7-only syntax, so 5.1 + 7 is
mostly a test matrix.
(b) PowerShell 7 only. Simpler claims, but this host has no `pwsh` installed today, so nothing could
be verified here without a new install.
(c) A POSIX shell or Node rewrite. Rejected: it throws away the tested code and its incident history.
*Sub-question:* may `pwsh` 7 be installed on this host so the 7 leg is actually run? (a new tool on
the host, which needs the author's yes before it happens.)

**D2. Which contract wins when the private scripts and the public 0.1.2 docs disagree.**
**Recommended: the public docs.** They were already generalized (0.1.2). The scripts adapt to them:
- Coordinator line: public `session "<name>"`, private `` session `local_<id>` ("<title>") ``.
- Session identity: public uses the session *name* (`claude -n`, `ListAgents`); the private
  scripts accept only Claude Desktop `local_<hex>` ids (`coord-brief`, `coord-handoff`, the guard's
  cross-repo token rule). Generalized for display: a Session cell may hold a name or an id.
  **Amended 2026-10-18 (S1 panel; the author: "Only ids bind (Recommended)"):** only an id-shaped
  cell is a *binding* token, and a name never binds. `local_` plus 8 or more hex, or `local_`
  plus a UUID, gives `local_` plus its leading hex run, lower-cased, as the private toolkit did,
  so the short form `local_<8 hex>` and the full `local_<uuid>` of one session are one token. A
  bare UUID gives itself, lower-cased, and differs from `local_<same uuid>` (separate id
  spaces). Two sessions share a token only if their first 8 hex digits collide, about 1 in 4
  billion per pair; the author accepted that ("Accept, identical (Recommended)"). Since the
  template's Session cell holds the track name, the documented CLI flow never binds across
  repos; S6 must state that in the skill and the guard's refusal text (S6 row). Ordinary words ("none", "TBD") and a track name reused in two repos would otherwise
  become a shared token and let unrelated tracks edit inside each other's scope across repos.
  The guard's rule stays "two rows bind across repos only when they carry the same token"; rows
  that carry only names do not bind across repos, which fails closed.
- Public Baseline has a `CI: yes | none` switch; `slot-check` must honour it (no checks + `none` can
  be READY; otherwise an empty rollup is WAIT).
- Report-back: public sends a worktree track's report to its own `.claude/handovers/`; the private
  Desktop notes folder (`%APPDATA%\Claude\side-session-notes\<id>`) goes away, or becomes an
  optional `-NotesDir`.
- Brief template: the private `<<FILL: ...>>` markers that `coord-brief -Check` looks for replace the
  public `{...}` slots, keeping the public wording. One format, one checker.
- Session tools named in printed text: only the documented `ListAgents` / `SendMessage`; the
  Desktop-only `list_sessions` / `send_message` / `get_session` / `detach_session` do not appear.

**D3. How the guard is installed.**
(a) **Recommended:** plugin-native `hooks/hooks.json` with `${CLAUDE_PLUGIN_ROOT}`, enabled with the
plugin, no `settings.json` edit, no install script. Must first pass probe P1 (below).
(b) An install script that edits `settings.json` (the private route, with its backup, merge and
identity checks). Only if P1 fails.
Either way the guard is inert until a coordinator registers a ledger, and a switch turns it off
without uninstalling the skill (`TRACKSTEWARD_GUARD=off`, name open).

**D4. The SessionStart anchor footprint.** Today the guard writes an anchor file for *every*
session, in any repo, and never prunes them. Fine on the author's machine; for someone who installs
a plugin to try it, that is a file per session forever.
**Recommended:** write the anchor only when today's (or yesterday's) index exists, so only days
with a registered coordinator leave anchors, and prune anchors older than 7 days on the write
path. Cost: a track started *before* the coordinator registers its ledger has no anchor and binds
by cwd (the existing fallback), which the skill's order of steps (register, then start tracks)
already avoids.

**D5. `merge-verify`'s branch delete.** It deletes the merged remote branch (only while its tip is
the merged head, via `--force-with-lease`).
**Recommended:** keep the behaviour but make it opt-in for the public version (`-DeleteBranch`;
default prints the command it would run). A remote delete on someone else's repo should be
something they turned on.

**D6. Where the port is integrated.**
(a) **Recommended:** a `port/0.2` integration branch; each slice is a PR into it; one release PR
merges it to `main` with the version bump. `main` and every installer stay on 0.1.2 until the
whole port is reviewed. (The marketplace installs from the default branch, so slices merged
straight to `main` would ship half a port to anyone who installs that day.)
(b) Slices straight to `main`, version bumped at the end.

**D7. The private and public copies afterwards.**
(a) **Recommended for now:** a one-way port, frozen at the private head named in each slice's PR;
private fixes after that are re-ported by hand. Each script's header names its source file
(relative to the private toolkit) and the port date; the private commit it was ported from is
recorded only on the private side (the track's handover and the coordinator's ledger), never in
this repo, per section 8. Decide later, after the fresh-install gate,
whether to flip it: public becomes upstream and the private install consumes the plugin.
(b) Flip now. Too early: the public version has no users and no release review yet.

**D8. Plan docs in the public repo.** This file is in `docs/plans/`. Keep plan docs here (written
public-safe, as this one is) or keep them out of the public repo entirely?
**Recommended:** keep this one (it explains the port to a reader), and write it public-safe.

## 3. What must be generalized

Grouped; every item is a code change with a test row, not a doc note.

- **Private names and refs.** the private temp-ref namespace → `refs/tracksteward/slot-check/`; the
  author as "the user" in every printed line (`coord-log`, `coord-handoff`'s checklist,
  `merge-verify`); internal follow-up numbers, plan-doc paths, app names and incident dates out of
  comments; the hook folder name is not used at runtime and disappears.
- **Paths.** No absolute example paths (a drive-letter example path becomes `<repo>`); `$HOME/.claude/coordination`
  stays the index default with an env override (`COORD_INDEX_DIR` already exists); ledger, briefs
  and handovers stay under `<main checkout>/.claude/`.
- **Windows-only code behind one platform layer** in `coord-common`: process kill on git timeout
  (`taskkill /T /F` by PID on Windows, a PID-tree kill on Unix; never by image name), fixed-drive and UNC tests,
  reparse-point / symlink detection, 8.3 short names, drive-letter regexes, path comparison
  (case-insensitive on Windows and macOS default, case-sensitive on Linux), device names, console
  encoding. The guard's fail-closed rules (network path, link component, unresolvable path) keep
  their meaning on every platform; on an unverified platform they stay fail-closed.
- **Identity and notes** (D2): Session tokens, Coordinator line, `-NewSession` format, optional
  `-NotesDir`.
- **Shell quoting.** The private scripts carry the 5.1 `-File` / `-Command` caveats (exit code 2
  becomes 1 under `-Command`; `[ ]` in a path read as a wildcard). The hook command and the skill's
  invocation lines keep the exit-code forward and the path escape, and get a test each.
- **Floors, checked at start with a clear refusal (ruled 2026-10-29: not in 0.2.0, see section 9 item 8):** git 2.38+ (`merge-tree --write-tree`), `gh`
  for the PR scripts only (`repo-snapshot` already runs without it), PowerShell 5.1 or 7.

## 4. Layout

```
scripts/        coord-common.ps1 + the other scripts (dot-source a sibling coord-common.ps1)
hooks/          hooks.json, coord-scope-guard.ps1 (dot-sources ../scripts/coord-common.ps1)
templates/      as today; coord-brief reads ../templates/brief-template.md
tests/          run.ps1, fixtures, stubs, one suite per script, the guard suite, the scrub suite
skills/coordinate/SKILL.md   calls scripts as "${CLAUDE_PLUGIN_ROOT}/scripts/<name>.ps1"
```

The private layout keeps scripts, templates and SKILL.md in one folder; the port moves templates to
the existing `templates/` and adjusts the two lookups (`coord-brief`'s template, the guard's
library), each with a test that runs the script from the installed layout.

## 5. How the tests port

- **Harness as is:** the custom `Assert-Coord` harness, the fixture (bare origin, launch clone, work
  clone under temp), the `gh` stub (`gh.cmd` + a JSON rules file, unmatched calls exit 97) and the
  git-environment clearing the fixture depends on. Each suite keeps `-ScriptPath <mutant>`, so a
  mutation can be run per script.
- **New runner** `tests/run.ps1`: runs every suite under the current host, prints one total line;
  `-Shell powershell|pwsh` picks the host when both exist.
- **Fences rewritten:** the private suites assert the author's real `~/.claude/coordination` is
  byte-unchanged. The port points the index at a temp folder (`COORD_INDEX_DIR`) and asserts the
  *runner's* real profile is untouched, with no name in it.
- **Dropped:** `coord-install.test.ps1` tests the private install script; it is replaced by a
  `hooks.json` shape test (matcher, timeout, exit forward, escaped path) if D3 (a) holds.
- **Scrub suite, new:** fails on an absolute user path, a Desktop `local_` id, a 40-hex sha in a
  doc, an internal follow-up number, or any word in an optional denylist file named
  by `TRACKSTEWARD_SCRUB_DENYLIST`. The denylist itself (private app and repo names) never enters
  this repo; the author points the variable at a file outside it.
- **Counts reported per slice:** passed / failed / skipped per suite under each host that ran, plus
  the mutants run and seen red. Skips (for example link creation refused without developer mode)
  are listed, not hidden.

## 6. Probes before the slices that need them

- **P1 (before the guard slice):** a plugin `hooks/hooks.json` entry with `"shell": "powershell"`
  runs, `${CLAUDE_PLUGIN_ROOT}` expands inside the command, exit 2 blocks with the stderr text
  shown, a plugin path with a space works. Run in a scratch session opened with
  `claude --plugin-dir <worktree>`; this needs one interactive session (the last nested `claude -p`
  attempt failed on an expired login), so it is the author's two minutes or a fixed login first.
  **Result, 2026-10-28 (S6): passed, with one change to the form.** The login worked again, so
  the probe ran as nested `claude -p --plugin-dir` sessions under Windows PowerShell 5.1: the
  `"shell": "powershell"` entry ran, `${CLAUDE_PLUGIN_ROOT}` expanded (and the plugin root is
  exported as an environment variable), a plugin path with a space worked, and exit 2 blocked
  with the stderr text shown, but only after `; exit $LASTEXITCODE` was added to the command
  (under `-Command` a script's `exit 2` is lost). `powershell -File` reads `[` `]` in the path
  as a wildcard and can run a sibling folder's copy, so `hooks.json` ships the exec form with
  `-Command`, the path read from `$env:CLAUDE_PLUGIN_ROOT`, wildcard-escaped and exit-forwarded;
  that form was probed from a plugin folder with a space, brackets and a backtick in its name.
  A launcher that fails before the script runs was probed once, in a nested `claude -p` session
  with the plugin root unset (exit 1): the edit went ahead and the model reported no hook text,
  so the guard is silently off for that call. What an interactive session shows was not probed.
- **P2 (first slice):** `${CLAUDE_PLUGIN_ROOT}` expands in the skill's script lines the way it
  already does for the template paths, and the Bash and PowerShell tools both run them.
  *Docs, 2026-10-18:* the variable is substituted in a plugin skill's body before the model sees
  it (with forward slashes on Windows), and is not set in the Bash tool's environment, so the
  skill's lines use the substituted path, never `$env:CLAUDE_PLUGIN_ROOT`. For P1 the hooks
  docs add: `${CLAUDE_PLUGIN_ROOT}` expands in a hook's `command` and `args`; the exec form
  (`args`) avoids shell quoting; there is no documented way to disable one plugin's hooks and
  keep its skills, so the env off switch (D3) stays.

## 7. Slices and gates

Every slice: a PR into `port/0.2` (D6), tests first, suites green under 5.1 (and 7 if installed),
scrub suite green, at least three mutants per new script seen red, the review panel (reviewer +
adversary, plus Codex only on the author's go and pick), then the fix-diff panel; counts in the PR
body; no CI (house rule until November), merge on the author's go after the coordinator's slot.
A full `tests/run.ps1` run is requested from the coordinator as a heavy run first; single suites
need no go.

| # | Slice | Contents | Exit gate beyond the common one |
|---|---|---|---|
| S1 | Foundation + ledger writer | harness, fixtures, stubs, `run.ps1`, scrub suite; `coord-common` with the platform layer; `coord-log` incl. `-Register`; ledger template reconciled (D2); skill section for logging; P2 | every `coord-common` and `coord-log` row ported or listed as dropped with a reason |
| S2 | Briefs | `coord-brief`, brief template converted to one marker format (D2), identity generalized | `-Check` refuses each unfilled marker; the public walkthrough renders end to end in the fixture |
| S3 | Read-only verdicts | `repo-snapshot`, `slot-check` (with `CI: none`) | verdict lines byte-identical to what the skill names |
| S4 | Merge verify | `merge-verify`, delete opt-in (D5), NOTIFY lines | a delete without `-DeleteBranch` is impossible; tip-moved branch never deleted |
| S5 | Handoff | `coord-handoff`, name-or-id `-NewSession` | the swap is one write; a refused handoff leaves the ledger byte-unchanged |
| S6 | Scope guard | hook, `hooks.json` (D3), anchor policy (D4), off switch, guard suite; the skill and the refusal text say that name-only Session cells never bind across repos (D2) | P1 passed; guard rows ported; a session with no registered ledger writes nothing |
| S7 | Release | a scrub of every blob in `origin/main..HEAD` (the slice scrubs cover the next commit only; the author: "Tip now, history at S7 (Recommended)"); SKILL.md (script calls replace the recipes), README (Roadmap and "ships no scripts" lines, Requirements floors, what the guard does and how to turn it off), CHANGELOG, 0.2.0, merge `port/0.2` → `main` | the history scrub: `tests/scrub.test.ps1 -History origin/main..HEAD` (or `TRACKSTEWARD_SCRUB_HISTORY` set to that range, which `tests/run.ps1` passes on), with the denylist and repo variables set, and no SG6 UNCHECKED line in its output (a blob the scan could not read is not a pass); a fresh-clone run of `tests/run.ps1`; a docs read for anything that still says "no scripts" |

S3 and S5 touch separate files from each other and could run as parallel tracks once S1 has landed
(S2 also needs S1); S4 after S3 (shared `gh` helpers); S6 after S1; S7 last. One track at a time is
the default unless the coordinator opens a second.

## 8. What stays out

- Everything private: app names, repo names other than this one, session ids, ledger lines, shas of
  the private repo, local paths, internal follow-up numbers, the incidents that motivated each rule
  (the skill keeps the rule, not the story).
- The private install script and its `settings.json` merge (unless P1 fails, D3 (b)).
- The Claude Desktop sidebar filing, task chips, the notes folder as a requirement, and any
  undocumented session tool.
- Sending messages from a script: every script still prints text the coordinator sends by hand.
- A CI workflow (house rule until November; a public-repo workflow is a polish-gate decision).
- The private copy: nothing in it is edited by this port.

## 9. Open questions (beyond D1-D8)

1. Accept the frozen-seam leftovers of the private handoff and guard as they are (they are stated
   limits in the script headers), or fix any in the port? **Ruled 2026-10-28 (the author: "Accept
   all"):** accepted as they are, for the guard too (inherited `GIT_DIR` / `GIT_WORK_TREE` are not
   cleared); any fix is 0.2.1.
2. Version: 0.2.0 for the whole port, or 0.2.0 at S4 (scripts) and 0.3.0 with the guard?
3. Guard default when the plugin is installed: on (inert until a ledger is registered), or off
   until the user sets the switch? **Ruled 2026-10-28 (the author: "On, inert until registered"):**
   on; `TRACKSTEWARD_GUARD=off` in the environment turns it off.

Findings from S3, ruled 2026-10-28 (one line each; fix in S7 or 0.2.1). **Ruled 2026-10-29 (the author: "All to 0.2.1"):** items 4-8 are all 0.2.1; none is fixed in 0.2.0, and the git floor (item 8) is stated as not enforced in the README and CHANGELOG.

4. F1 (`scripts/repo-snapshot.ps1:144`, latent): a `-Repos` path that is not a git repo is skipped
   and the snapshot prints `attention none`, so a typo reads as a clean repo. S7 or 0.2.1.
5. F2 (`scripts/repo-snapshot.ps1:64`, latent): an explicit `-Ledger <missing file>` reads as
   "no ledger" with `attention none` instead of an error. S7 or 0.2.1.
6. F3 (`scripts/repo-snapshot.ps1:225`, cosmetic): a finished track whose branch is gone prints
   `branch not found` and adds attention on every run. S7 or 0.2.1.
7. F4 (`scripts/repo-snapshot.ps1`, cosmetic): the base is hard-coded to `origin/main`; there is no
   `-Base` as `slot-check` has. S7 or 0.2.1.
8. F5 (all scripts, latent): the git 2.38+ floor of section 3 is not enforced; no script refuses at
   start (grep finds comments only). S7 or 0.2.1.

Finding from the S5 round-3 review (reviewed 2026-10-29, ruled: to the plan, for 0.2.1):

9. `scripts/coord-handoff.ps1` name check (latent): a `-NewSession` made only of characters the allow-list
   accepts but that draw nothing (U+3164, U+115F, U+1160, U+FFA0, U+034F, U+FE0F, U+17B5) is not
   refused, so a name can read as blank; the header says so. 0.2.1.

Found while porting Phase D (2026-10-29), for 0.2.1:

10. `scripts/coord-status.ps1` Queue gate (latent): the gate is anchored on the exact, case-sensitive
    ` owner:`. A writer slip (`Owner:`, `owner :`, a tab, no owner part) falls back to searching the
    whole line, so a gate-shaped bracket quoted in the source note can take the gate again (with
    `-Verify`, OPEN or CLOSED for the quoted PR). The skill tells writers to write ` owner:` exactly.
    Fix: match `\s+owner\s*:` ignoring case, or add a second anchor on ` source:`.
11. The `coord-brief`, `coord-common`, `coord-handoff`, `coord-log`, `coord-set` and `coord-status` suites (latent): they fence the real
    coordination index by digest before and after the run, so a live append by a coordinator during
    a run can fail them. Fix: read a scratch index only, or tolerate appended lines.
12. `scripts/coord-log.ps1` (cosmetic): it does not expand `{now}` (only `coord-set.ps1` does) and keeps
    its inline `-Ledger` handling, which duplicates `Resolve-CoordLedgerArg` in `coord-common.ps1`.
13. `scripts/coord-status.ps1:228,231` (live, from the source): a Findings line whose id carries a carry date
    (`F3 (2026-10-28) from ...`, the form the carry rule writes) does not match the finding patterns, so a
    carried PENDING finding is missing from the board and from `findings pending`. No test covers a carried id.
14. `scripts/coord-status.ps1:154,202` (latent, from the source): with an empty PR cell, the first `#<n>` in the
    Status text is taken as the row's PR (the slot-open check, and `-Verify`'s `gh pr view`).
15. `scripts/coord-status.ps1:184,204,286` (latent, from the source): under `-Verify`, a Repo cell that is a bare
    name or a path not on this machine falls back to the current folder, and the Queue gate `[after #<n> merges]`
    always asks the current folder's repository, so another repository's PR number can be read as this one's.
    A UNC Repo cell is opened without a time limit, and `gh` has no timeout.
16. `scripts/coord-status.ps1:300` (latent, from the source): an `[after Q<n>]` gate that names an id with no line,
    or a cycle, reads CLOSED and is never flagged. Test T18b pins that behaviour.
17. `scripts/coord-status.ps1:248,254` (cosmetic, from the source): an indented or oddly spaced unticked Owed check
    is neither listed nor counted as unrecognised.
18. `scripts/coord-status.ps1:71,90` (latent, from the source): the ledger is read twice without a lock, so a
    `coord-set.ps1` or `coord-log.ps1` swap between the reads can end the board with `could not read`.
19. `scripts/coord-set.ps1` (latent, from the source): `Test-CoordTypedTime` misses a fullwidth colon, `10h22` and
    `10.22`; a Status cell can hold U+FEFF or a bidi mark; two rows with the same track name and bare-name Repo
    cells cannot be told apart by `-Repo`.
20. The port's `coord-set.ps1` `Get-RepoFull` differs from the source on purpose: it uses
    `ConvertTo-CoordRootedPath` and the platform path comparison, so it rejects `, ; ( )`, device paths and a bare
    drive root in a Repo cell, and accepts `/...` paths off Windows.

## 10. Phase D (added 2026-10-29): the status board

Ruled by the author on 2026-10-29: port the three coordinate changes of the private source since
2026-10-22 into `port/0.2` as one more slice, before the release merge. They add `coord-status.ps1` (the
status board), the ten state words with `WAIT-USER` (the neutral spelling) and `coord-set.ps1 -State`, and
the status index with the `## Queue` ledger section. `coord-set.ps1` had never been ported, so it comes
whole, with the helpers it needs (`Get-CoordStamp`, `Expand-CoordNow`, `Test-CoordTypedTime`,
`Resolve-CoordLedgerArg`, `Get-CoordStateWords`). Tests port with them (`tests/scripts/coord-set.test.ps1`,
`tests/scripts/coord-status.test.ps1`, and the changed rows of the `coord-common` and `coord-log` suites).
Dropped from the source tests: one row that read a private archived ledger, and three that pinned private
skill prose. The gate is the common one plus the history scrub of section 7.
