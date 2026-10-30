# Changelog

## 0.2.1 - 2026-10-30

Fixes the open items of the 0.2.0 port; no new commands.

- **coord-status**: lists a finding whose id carries a tag or a carry date (`F3 (2026-10-28) from ...`,
  `F22 (coordinator): ...`) and a Queue id with a `(yyyy-MM-dd)` tag; reads the ledger once; lists an
  indented or oddly spaced unticked Owed check; the Queue gate is found after `Owner:`, `owner :`, a
  tab or `source:`; an `[after Q<n>]` gate that names no line, or sits in a cycle, reads `?`; under
  `-Verify` a Repo cell that is not a folder on this machine reads `unknown` (no longer the current
  folder's repository), and a PR gate says which repository was asked.
- **repo-snapshot**: a `-Repos` path that is not a git repo, an explicit `-Ledger` that is missing and
  a `-Base` ref that does not exist each add attention; a finished track whose branch is gone no
  longer does; `-Base` (default `origin/main`) names the base.
- **Git floor**: `coord-brief`, `coord-handoff`, `coord-log`, `merge-verify`, `slot-check` and
  `repo-snapshot` refuse to start on a git older than 2.38 or one whose version cannot be read.
- **coord-handoff**: a `-NewSession` name made only of the Hangul fillers, U+034F, U+FE0F or U+17B5 is refused.
- **coord-log**: expands every `{now}` in its text (as `coord-set` does) and reuses the shared ledger-argument check.
- **coord-set**: refuses a fullwidth-colon time and `10h22`; refuses U+FEFF and bidi marks in a cell;
  `-Repo` matches a bare-name Repo cell by its text.
- **Tests**: the six script suites no longer fail when a live coordinator appends to the real index (their
  fence flags what the run wrote, not every byte; the scope-guard suite still compares the real index byte for byte).
- **Known and left**: in `coord-status` a `#<n>` in the Status text is still taken as the row's PR
  when the PR cell is empty, a repeated finding id is listed once per line, and an inline
  `| outcome: dropped` does not close a finding; `coord-set` does not refuse a dotted `10.22`;
  `coord-log` has no way to write a literal `{now}` and writes bidi and BOM characters as typed;
  `coord-set` and `coord-status` do not check the git floor. Ported as merged upstream,
  with known limits: `-Verify` can ask the current repository when a Repo cell is a relative folder
  name that exists under the current folder, and a UNC Repo cell can block; a Queue item whose text
  contains `Owner:` before its gate loses the gate (reads `?`); the suites' real-index fence flags only
  what names the run's scratch folder; the `unverified:` line is cut at 140 characters. More in the
  README, "What is not done".

- **Port notes**: `coord-set`'s Repo-cell path check (`Get-RepoFull`) is stricter than the private source on purpose: it rejects `, ; ( )`, device
  paths and a bare drive root, and accepts `/...` paths off Windows.

## 0.2.0 - 2026-10-29

The mechanical checks are code now. Adds PowerShell scripts and an edit-time scope guard hook, with
tests; the skill calls the scripts for each check, and keeps the manual commands as the fallback
where PowerShell is missing.

- **Scripts** (`scripts/`, run from the plugin folder by the skill):
  - `repo-snapshot.ps1`: a start-of-window snapshot per repo, with each ledger track's files
    checked against its scope and a conflict preview.
  - `slot-check.ps1`: a PR's full head sha, its files outside scope and its checks, ending
    `READY | WAIT | HOLD`.
  - `merge-verify.ps1`: confirms the merge commit on origin, deletes the branch only when its tip
    is still the merged head, and checks the shared checkout and git config.
  - `coord-log.ps1`: appends to the ledger with the clock's time and refuses typed times;
    `-Register` records the day's ledger for the guard.
  - `coord-brief.ps1`: renders a track's brief from the template; `-Check` verifies it before the
    pointer line is printed.
  - `coord-handoff.ps1`: hands the coordinator role to a new session.
  - `coord-set.ps1`: changes one Tracks cell (Status or Model) with a time from the clock;
    `-State <word>` writes a Status cell as one of ten state words.
  - `coord-status.ps1`: the status board over the structured ledger sections (Tracks, Merge slots,
    Owed checks, Findings, Queue); `-Verify` checks what it can against `gh`.
  - The ledger gains a `## Queue` section (work not yet started), which `coord-log.ps1 -Section Queue`
    appends to.
  - `coord-common.ps1`: the shared library.
- **Scope guard** (`hooks/`): a `PreToolUse` hook that blocks an edit outside the scope of the
  session's ledger row. On when the plugin is installed, inert until a ledger is registered;
  `TRACKSTEWARD_GUARD=off` in the environment turns it off (a convenience, not a lock). Windows-only
  as shipped; its limits are in the hook header.
- **Skill and templates**: the skill names the script for each check next to the manual commands;
  the ledger template names `coord-log.ps1` for appends and registration.
- **Tests** (`tests/`): one suite per script and for the guard, a scrub suite for private content,
  and `run.ps1`. They run under Windows PowerShell 5.1.
- **Requirements**: git 2.38 or later; PowerShell. Verified on Windows 11 with Windows PowerShell
  5.1 only. **PowerShell 7, macOS and Linux are unverified.** The git floor is not checked at start (0.2.0 only; 0.2.1 checks it in six scripts).
- **Known and left**: a `-NewSession` name made only of characters that draw nothing (a Hangul
  filler, a variation selector) is not refused. `repo-snapshot` can read a clean repo when a
  `-Repos` path is a typo or an explicit `-Ledger` is missing (`attention none`); a finished track
  whose branch is gone prints `branch not found` on every run; its base is always `origin/main`.
  `coord-status.ps1` does not list a finding whose id carries a carry date, can take a `#<n>` in the
  Status text as the row's PR, and under `-Verify` can ask the current folder's repository about a PR
  of another repository; the Queue gate is anchored on an exact ` owner:`; an `[after Q<n>]` gate that names no line reads CLOSED;
  an indented unticked Owed check is not listed. All are on the 0.2.1 list.

## 0.1.2 - 2026-10-15

Docs only: the skill, the brief, ledger, finding and report templates, and the README. No scripts.

- **Briefs are files.**
  - The coordinator saves each brief in its main checkout's `.claude/coordination/briefs/` and
    sends the track one pointer line, `BRIEF: {absolute path}; reply "ACK {track}" when read`,
    with the path and track name filled in. The file keeps the full text on disk. It does not
    deliver itself or stay fresh, so a missing ACK shows a pointer line that went nowhere, and
    every later message still carries the current sha.
  - In the template, `{...}` slots are the coordinator's to fill before saving (the CROSS-REPO
    block and the SUPERSEDES line are deleted when they do not apply) and `<...>` slots are
    filled when the line is used.
  - The ACK carries the track's model and effort. The coordinator stamps its time from its own
    clock, records `briefed HH:MM, ACK HH:MM` in the Status cell and copies the model and
    effort into the Model cell.
  - Every brief, and every change to one, gets an owed check with a 15-minute ACK deadline, added
    when it is sent. The user is told the deadline, because a session has no timer.
  - A change is appended to the file under a `CHANGES <date> <time>` heading and sent as its own message;
    the track ACKs again, and the change is in force once ACKed.
  - The day's briefs are copied next to the ledger at day close.
- **WIP line.** The brief asks the track for one line in its handover after every review round
  and before any run of an external reviewer: branch, sha, the brief's path, uncommitted files,
  open findings, next action. A session that stops can be resumed from it.
- **Slot wait.** The brief lists the slot wait among its fixed lines (0.1.1 already had the wait).
  - A PR that does not contain the current main now reads WAIT rather than HOLD, and the
    coordinator tells the track at once to merge main and report a new head. BLOCKED while a check
    is pending and none has failed also reads WAIT. Any WAIT standing after about 15 minutes goes
    to the user.
  - A go such as "merge #12 when green" covers the sha of the slot the user was shown, and the
    merge is bound to that sha. The coordinator re-reads the head just before merging; if it
    differs the go is void, and the slot check, a new slot and a fresh go come first. A go typed
    before any slot waits for one. A vague go is no go.
- **Owed checks.** A finding whose outcome leaves work open is ticked only on evidence: for a fix,
  the track's report names it, the PR's file list holds the file and the merge is on origin; for an
  investigation, the named track reports what it measured. If a track merges without the fix, the
  coordinator re-opens the finding as PENDING to the user.
- **Midnight.** The coordinator compares the date on each append to know when it has passed.
  A carried Tracks row or owed check is marked `(from <date>)`, a finding keeps its number with
  its date wherever a carried line names it, and a line carried twice keeps its first date. A
  carried track's brief stays under the old date, and any change to it after midnight is a fresh
  brief that names the one it supersedes. The carry is logged in the new ledger, and the old
  ledger is not edited after it (0.1.1 put the Log line in the old one).
- **Branch deletes.** The tip rule itself was in 0.1.1. New: a branch whose tip has moved past the
  merged head is classified in flight or stale, not merged.
- **Tracks table.** New Model column after Session (model and effort at start, then each switch,
  which the track reports and the coordinator times). The Status cell leads with `MERGED` or
  `DONE` only when the track is finished. Every row needs one cell per column, so a row carried
  from a ledger without Model gets an empty one.
- **Live exposure.** Findings of that severity go to the coordinator privately and at once, never
  into a PR body, a commit message, a report, a WIP line or any other file that is committed or
  posted. A track whose task is such a fix (the brief, the report template and the skill all say so) writes
  its report to a handover file and opens no PR until the user decides. In a public repository a PR body is readable by anyone once it is posted. If one is to
  be fixed, the user decides how and when anything about it is pushed or posted. The day-close
  scrub now covers every section, each brief and each track's handover.
- **README.** The first-day walkthrough and requirements describe the brief file and the ACK.

## 0.1.1 - 2026-10-14

Fixes from three rounds of independent review of 0.1.0. The history was rewritten at this
release, so 0.1.0 has no commit of its own.

- **Merge protocol.**
  - The slot check reads the PR's full file list from git, because gh's `files` field stops at
    100. Non-ASCII paths are compared unescaped.
  - A PR gets a slot only when it targets main, contains the current main, has the reported
    head, is not a draft, passes branch protection (`mergeStateStatus`), and every check is in
    gh's pass or skipping bucket. The PR head is fetched into `refs/coordinate/pr/<n>`, which a
    prune does not delete.
  - Failed and cancelled checks HOLD; pending ones WAIT. With no checks at all, the slot waits
    unless the ledger records that the repo has no CI, and goes to the user after about 15
    minutes.
- **Briefs.** The brief tells each track to wait for a slot message naming its full sha, and that
  any later push or merge voids the slot. `gh pr merge` names a merge method, and the merge sha is
  read from the PR.
- **Branch cleanup.**
  - A remote branch is deleted only while its tip is still the merged head, in one atomic push.
    A refused delete is diagnosed by `ls-remote --exit-code`, which tells gone, moved, refused
    for another reason and unreachable apart.
  - A local branch is deleted only when its tip is the merged head. This also works for squash
    merges.
  - The same rule applies at the start of a coordination window.
- **Ledger.** After midnight, the new ledger carries forward open tracks, a fresh Baseline, the
  slot queue, owed checks and pending findings.
- **Findings.**
  - Findings use one vocabulary of five next steps that are also the five outcomes.
  - Outcomes that leave work open (widen scope, own track, investigate first) add an owed check.
  - A file needed outside scope is a finding. Only a recorded `widen scope` puts it in scope.
  - Live-exposure findings never go into a PR body or a report. Before a handover or a ledger
    copy is committed, every line carrying their details is replaced.
- **Tracks and handovers.** Tracks start as named sessions (`claude -w <track> -n <track>`) and
  keep their worktrees while anything is unmerged. A track writes its handover in its own
  worktree's gitignored `.claude/handovers/`, since Claude Code blocks a worktree session from
  writing the main checkout, and reports it by absolute path.
- **README.**
  - It describes the cited study and write-up accurately, and explains why this pattern
    serializes merges rather than work, and what that costs.
  - New sections cover requirements and a first coordinated day.
- **Cleanup.** Private example values were removed. The plugin version is set in `plugin.json`
  only.

## 0.1.0 - 2026-10-14

First public snapshot, briefly published: the README, the coordinate skill, and the ledger,
brief, finding and report templates.
