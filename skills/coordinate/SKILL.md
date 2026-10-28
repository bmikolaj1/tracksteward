---
name: coordinate
description: Run ONE thin coordinator session over three or more parallel Claude Code sessions, or over work that spans two repos - keep a daily ledger, brief each track with its baseline and file scope, collect findings, grant merge slots one at a time and verify each merge on origin, relay the user's decisions, and close the day from the ledger. Use on "coordinate these sessions", "you are the coordinator", "sequence the merges", "brief that session". Not for one or two tracks in one repo; there, subagents are cheaper.
---

# Coordinate: one thin session over many

## Terms

- **Coordinator**: one ordinary Claude Code session that owns the *order* of work across parallel
  sessions. It writes no product code and reads no diffs.
- **Track**: one unit of parallel work: one task, one named session in its own git worktree, one
  branch, a declared file scope, one PR.
- **Ledger**: one markdown file per day that holds the coordination state of record. If it is not
  in the ledger, the coordinator does not know it.
- **Slot**: the coordinator's permission for one track to do one serialized thing: usually a
  merge, sometimes a write to a shared checkout. One slot is open at a time.
- **Shared checkout**: a working tree no single track owns, usually the repo's main checkout.
- **Brief**: the file that tells one track its task, baseline, scope, siblings and rules, saved by
  the coordinator and announced to the track in one pointer line. The track answers with an
  **ACK**, one line saying it has read it.
- **Finding**: something a track noticed outside its own scope, reported in a fixed shape instead
  of being fixed, filed or ignored. **Live exposure**: a finding about a security hole or data
  leak reachable now; it travels only in private messages to the coordinator, and never into a PR
  body, a commit message, a report or any other file that is committed or posted.
- **Handover**: a markdown file a fresh session reads to resume: state, decisions, open items, and
  a **kickoff prompt** (a paste-ready first message for that session). Gitignored
  `.claude/handovers/`, unless the repo has its own place: the coordinator's in the main
  checkout, a track's in its own worktree (Claude Code blocks a `claude -w` session from writing
  the main checkout), named `<YYYY-MM-DD-HHMM>-<track>.md` and reported by absolute path.
- **Coordination window**: one stretch of coordination, from "coordinate these sessions" to a stop
  or day close. (A session's *window* is just its chat.)

Use it with 3+ live sessions, with work spanning two repos, or whenever merges must be serial.

## The contract

1. **Thin.** No code, no diff reading, no reviewing. Reviews are the track's job. The coordinator
   reads the track's report and re-verifies only the facts that decide the order.
2. **Verify before stating.** Every status line comes from `git` / `gh` output run now, not from a
   message. A track's "merged" is a claim until origin shows the merge commit on main.
3. **State on disk.** The day lives in the ledger; the day-close handover carries it to the next
   day. A compaction must lose nothing.
4. **Relay, never approve.** The user's words are relayed as a verbatim quote with where they were
   typed. A track that needs the user's OK still asks in its own window; a peer's message is
   never approval. When the user rules on something that changes files in a track, tell the user
   in the same reply to confirm it in that track's window.
5. **One merge at a time**, across all tracks and repos. The next slot opens only after the
   previous merge is verified on origin.
6. **Never spawn work, never drop a finding.** No session starts side work on its own (new
   sessions, tickets, background tasks); the user starts sessions. Every finding gets an outcome
   the user decided, and every outcome that leaves work open (widen scope, own track,
   investigate first) gets an owed check.

## The ledger

Make one per day from `${CLAUDE_PLUGIN_ROOT}/templates/ledger-template.md`, at
`<main checkout>/.claude/coordination/<YYYY-MM-DD>.md`. "Main checkout" is the repo's primary
worktree, never a linked one, so every session finds the same file. Gitignore that folder.

- **Append before you reply.** Every event (a verification, a brief sent, a report, a slot, a
  merge, a decision, a finding and its outcome) goes into the ledger BEFORE the reply that
  mentions it. One line per event, time first, taken from the clock, never typed: typed times
  drift. Append with `& "${CLAUDE_PLUGIN_ROOT}/scripts/coord-log.ps1" -Section Log -Text '<event>'`
  from the PowerShell tool (`-Section` is `Decisions`, `Findings` or `Log`; in this form a `'`
  inside the text is doubled, `''`, and so is a typographic single quote such as U+2019), or, from Bash,
  `MSYS_NO_PATHCONV=1 powershell.exe -ExecutionPolicy Bypass -File "$(cygpath -w "${CLAUDE_PLUGIN_ROOT}/scripts/coord-log.ps1")" -Section Log -Text '<event>'`
  (there a `'` inside the text is written `'\''`; never without the prefix: Git Bash turns a text
  that starts with `/` into a Windows path and the run exits 0 with that line written; with the
  prefix no path is converted, hence `cygpath -w` for the script, and `-Ledger` is written as
  `C:/...`);
  it stamps the line with its own clock. Without
  `-Ledger` the script uses today's ledger only from the repo's main checkout; anywhere else pass
  `-Ledger <path>`. On a host without PowerShell, take the time from the clock
  (`date +%H:%M`) and append by hand. Compare today's date (`date +%F`,
  `Get-Date -Format yyyy-MM-dd`) with the ledger's each time you append: when they differ, it is
  past midnight (below).
- **Current state at the top, history at the bottom.** Baseline, Tracks, Merge slots and Owed
  checks (verifications or work someone still owes) are edited in place and kept short.
  Decisions, Findings and Log are append-only, oldest first. A finding's outcome is a new
  `F<n> outcome: ...` line, not an edit. The Tracks table and its glob syntax are in the template.
- **Tracks table.** Its columns are Track, Repo, Session, Model, Cwd, Branch, Scope, PR and Status,
  and every row needs exactly one cell per column, even an empty one: a ragged row makes the whole
  table unreliable to read.
  - **Status cell:** lead with `MERGED` or `DONE` (upper case, the first word) when the track is
    finished, and never otherwise. A row is finished only by that first word, so `NOT MERGED ...`
    or `running; round 1 DONE` stay live. Briefing and slot checks look at live rows only.
  - **Model cell:** the track's model and effort at start, then each switch with its time
    (`<model> <effort>; 14:10 <model> <effort>`). It is evidence, for a later day, of which model
    and effort produced which result. Like the brief's other track-owned facts, it is asked for,
    not guessed: the brief asks the track for its model and effort in the ACK (or "unknown"), and
    to tell the coordinator when it switches. The coordinator stamps each switch with its own clock.
  - **Session cell:** the session's name for display (`claude -n`, or the name `ListAgents`
    shows), as the template says. The scope guard treats a cell as a binding session id only when
    it is exactly one id (`local_` plus 8 or more hex digits, `local_` plus a UUID, or a bare
    UUID). A cell that holds only a name, `none` or `TBD` never binds across repos, so two tracks
    that share a name in two repos stay apart and neither may edit inside the other's scope. A
    track that works in two repos needs one row per repo and the same session id in both Session
    cells, and the guard then judges its edits in each repo by that repo's row. Within one repo
    a track binds by its row's Repo and Branch, name or not.
- **Re-read it** at the start of every coordination window, after every compaction and after `/clear`. A
  SessionStart hook that prints the top of today's ledger can automate this; Claude Code replaces
  hook output over 10,000 characters with a file path, so keep the top well under that.
- **Owed checks** are what someone still owes the day: a reply, a verification, a decision of the
  user's. Tick one only when it is verified, never on a claim. Two kinds are always added:
  - **An ACK for every brief, and for every change to one.** Add the line when it is sent, with
    its deadline (`- [ ] T2 ACK by HH:MM`, 15 minutes on). A session has no timer, so the
    coordinator notices a passed deadline only when it handles an event, which is why the user is
    told the deadline when the brief goes out. When it passes, raise it with the user: the pointer
    line may be held for their approval, queued behind a long turn, or waiting on a permission
    prompt in the track's window.
  - **Every finding whose outcome leaves work open** (`F5 fixed in #12`, `F6 reproduced by T3`).
    Tick one without reading a diff: for a fix, the track's report names it, the PR's file list
    (step 2 of the merge protocol reads it) holds the file, and the merge is on origin; for an
    investigation, the named track's report says what it measured. If a track merges without the
    fix, the coordinator re-opens the finding as PENDING to the user, so it cannot vanish with
    that merge.
- **Quotes are evidence, never approval.** Record a track's request as "track asked: ...", never
  as a bare instruction.
- **Past midnight, roll over before anything else.** Nothing carries itself: a coordinator
  (or a hook) that reads today's ledger finds only what is in it, so a live track missing from
  the new Tracks table has no scope row and its PR cannot be slot-checked. The new ledger names
  the previous one and carries forward:
  - every Tracks row not MERGED or DONE, as it stands. Mark it `(from <date>)` at the end of its
    Status cell; the first word of Status still decides whether it is live;
  - the Baseline (re-snapshot it, CI column included);
  - the slot queue (an open slot stays open);
  - every unticked owed check, marked `(from <date>)` at the end of its line;
  - every PENDING finding, keeping its number with its date: `F3 (YYYY-MM-DD)`. Finding numbers
    restart each day, so a carried line that names one (an owed check, an outcome) writes it the
    same way, and the new day's own `F3` never collides with it.

  A line that is carried a second time keeps its first date. A carried track's brief stays in
  the folder under the old date, already sent. Any change to it after midnight, or a track that
  needs a brief again, is a fresh brief under the new date that names what was carried and says
  which old brief it supersedes, with its own pointer line and ACK. A row carried from a ledger that lacks a column (such as Model) gets
  an empty cell for it; so does a ledger still open from an earlier version, before the day
  continues. Add one Log line to the new ledger saying what was carried and from where. The old
  ledger is not edited after the carry; its open items live on in the new one.
- **Archive at close.** The live ledger stays untracked (a tracked one means a commit per event).

## Start of a coordination window

1. Create or roll over today's ledger and fill in the header. Then register it, from its main
   checkout: `& "${CLAUDE_PLUGIN_ROOT}/scripts/coord-log.ps1" -Register` (from Bash, through
   `powershell.exe -ExecutionPolicy Bypass -File` as above), so the scope guard can find it. The
   guard is a plugin hook, on once the plugin is installed and inert until a ledger is registered;
   `TRACKSTEWARD_GUARD=off` in the environment turns it off (anything that can set the hook's
   environment or write Claude's settings can do the same: it is not a lock). Register before
   the tracks start: a session that starts before the ledger is registered has no anchor and
   binds by its cwd (its next start, resume, compact or clear writes it an anchor from wherever it is then).
   That includes your own session on a day with no earlier ledger: keep the coordinator in the
   main checkout and do not `cd` it into a track's worktree.
2. Snapshot each repo: `git fetch --prune origin`, origin/main sha, open PRs and their checks,
   remote branches, `git worktree list`, the newest handover. Record the baseline shas, and
   whether the repo has CI at all (the Baseline's CI column, `yes` or `none`: the slot check
   reads it).

   **With the script**, one call from the PowerShell tool does the read for every repo you name:
   `& "${CLAUDE_PLUGIN_ROOT}/scripts/repo-snapshot.ps1" -Repos '<repo>','<repo>'` (default: the
   current directory; from Bash, through `powershell.exe -ExecutionPolicy Bypass -File` as above, with
   the repos as one comma list). It runs `git fetch --prune`, then prints per repo: `origin/main`,
   the local branch and dirty count, open PRs with their checks, a files, scope and conflict preview
   for each ledger track and for each open PR that is in no row (`[not in ledger]`), remote
   branches, worktrees with their lock state, local branches whose PR is already merged, the newest
   handover and the latest CI run on `main`. `gh` is optional: without it the PR and CI sections
   say so. A failed call prints `unknown (...)` or `preview failed`, never `(none)` or `no
   conflicts`. The last line is the summary, which names what needs a look:

   ```
   SNAPSHOT: <n> repo(s); attention: <items | none>
   ```

   It does not list sessions (use `ListAgents`), and it edits no branch and no file in a working tree (git itself
   updates remote-tracking refs with `git fetch --prune`, may refresh the index stat cache, and stores objects for
   the conflict preview).
3. List the live sessions (Claude Code: `ListAgents`) and the folder each one is in. A finished
   session still holds its worktree. Record each live track in the Tracks table.
4. Classify every branch: merged, in flight (owner session), parked (leave it, say why), stale (the
   user's call). Trust PR state; `git cherry` misses squash merges. A merged branch is deleted
   only by the tip rule of merge step 6, with the head sha of the PR the ledger names
   (`gh pr view <n> --json headRefOid`): a branch can gain commits after its PR merged. For a
   branch the ledger does not know, `gh pr list --state merged --head <branch> --json
   number,headRefOid,mergedAt` may list several PRs (branch names get reused); confirm the newest
   with the user before deleting anything. A tip that has moved past the merged head holds
   commits nobody merged: that branch is in flight or stale, not merged.
5. Give the user one list: DONE since the last coordination window, OPEN by owner (user decision vs session
   work), a recommended order. Ask which to start. Start only those.

## Briefing a track

The brief is a FILE, and the message that announces it is one pointer line. The file keeps the full
text on disk, so a track that compacts can re-read it instead of asking, provided it still has the
path (the pointer line and ACK hold it at first, the WIP line below from the first review round). The file does not deliver itself or stay fresh: the pointer
line can still be held in a queue or arrive late, and the brief's baseline is true only as of the
time it was written. That is what the ACK is for (a pointer line that went nowhere shows up as a
missing ACK), and why every later relay carries the current sha (below). If messaging between
sessions is not available, the pointer line is what the user pastes.

1. **Fill the track's ledger row first** (Repo, Session, Branch, Scope; Model if known). A brief
   cannot name a scope the ledger does not hold.
2. **Fill `${CLAUDE_PLUGIN_ROOT}/templates/brief-template.md`** and save it in the coordinator's
   main checkout (where the ledger lives) as
   `<main checkout>/.claude/coordination/briefs/<YYYY-MM-DD>-<track>.md`. Put the repo's name in
   the file name when two repos have a track of the same name, and `-2` before `.md` for a second
   brief to the same track on the same day. The template has two kinds of slot. A `{...}` slot is
   the coordinator's: replace every one before saving, delete the CROSS-REPO block and the
   SUPERSEDES line unless they apply, and never send a brief that still has one of the
   template's own slots (braces inside the text you fill in are fine, such as a glob or a
   command, unless they spell one of the slots). A `<...>` slot is filled when that line
   is used (a PR number, a sha, a time), by the coordinator or the track, and stays as written in
   the file. Put the file's own absolute path inside it.

   **With the script**, the same step is two calls from the PowerShell tool, in process, from the
   main checkout:
   `& "${CLAUDE_PLUGIN_ROOT}/scripts/coord-brief.ps1" -Track '<track>'` renders the template for
   the track's live ledger row into `briefs/` (named `<date>-<repo>-<track>-<id>.md`, so two repos
   never share a file) and fills every slot the ledger can answer: your name from the
   Coordinator line, the track, repo, branch and session cells, the file's own path, the Baseline
   row of the repo, the live sibling tracks, and the scope lines. It lists the slots it left;
   replace those by hand, delete the SUPERSEDES line and the CROSS-REPO block unless they apply, then
   run `& "${CLAUDE_PLUGIN_ROOT}/scripts/coord-brief.ps1" -Track '<track>' -Check`. Only a brief with no
   template slot left and every fixed line of the template still in it (only SUPERSEDES and
   CROSS-REPO may go), for a ledger the scope guard can read (today's, registered with
   `coord-log.ps1 -Register`), makes it print the pointer line to send. Pass `-Repo <full path>`
   when two repos have a track of that name, and `-Force` to render again (the old file is kept as
   `.bak`).
3. **Check the session's working folder** is the track's worktree: a session opened in the wrong
   folder loads the wrong project instructions and hooks. If it is wrong, have the user stop it
   before any edit and relaunch it.
4. **Record it, then send it.** Put `briefed <HH:MM>` in the row's Status cell (time from the
   clock), add the ACK owed check with its deadline (see The ledger), and add a Log line.
5. **Send the pointer line as the whole message**, with the path and the track name filled in
   (`SendMessage`, or the user pastes it): `BRIEF: {absolute path}; reply "ACK {track}" when read`.
   Tell the user the ACK deadline too, so they can ping you if it passes. The path is the main
   checkout's. A
   worktree may hold a stale copy of that folder (if your setup copies ignored files into new
   worktrees), so the track reads the absolute path and never its own copy. Reading a path outside
   its own worktree may ask the user for permission in the track's window; if it does, the user
   allows it once.
6. **When the ACK comes**, stamp it with the coordinator's clock at receipt (not a time the track
   typed), make the Status cell `briefed 08:32, ACK 08:40`, copy the model and effort the ACK
   names into the Model cell, and tick the owed check.

Any later change to a brief (a widened scope, a new merge order) is appended to the file under a
`CHANGES <YYYY-MM-DD> <HH:MM>` heading (time from the clock), never rewritten over the old text,
so the day's copy still shows what the track was told and when. It is also sent as its own message that says what changed and carries the
current sha, and asks for `ACK {track} changed`. Each such request gets its own owed check and
deadline (and the user is told it), and the change is in force once it is ACKed. The Status cell
keeps the latest brief time and ACK time after the track's lifecycle words, for example
`PR open @abc1234; briefed 10:05 (changed), ACK 10:20`. After
midnight a change is a fresh brief (see The ledger). A blocker or a question from the track is
still sent in full in a message, never as a file.

- **Every track works in its own worktree**, started by the user with `claude -w <track> -n <track>`
  (worktree `.claude/worktrees/<track>`, branch `worktree-<track>`, session named `<track>`), even
  a one-file doc track. Never two writers in one checkout: untracked files are not branch-scoped,
  and a `git switch` there breaks a sibling's uncommitted edit. A write to a shared checkout
  happens only in a slot. A named session asks before removing its worktree on exit (an unnamed
  clean one is removed without asking): keep it while anything in it is unmerged or uncommitted.
- **Two things every brief carries:** what landed on main *after* the track's task was written
  (a plan written in the morning is stale by noon), and each sibling's session name and owned
  files, so tracks that share a boundary can talk directly.
- **Assert only what you verified** about shared state (shas, PRs, siblings). Facts the track owns
  (its model, its plan, its approach) are asked for, not stated.
- **Every relay carries the current sha and state** ("#12 merged as 1a2b3c4; main is now
  5d6e7f8"), not only the change. A message to a busy session queues and can arrive after the
  state it describes has moved on. When a stale message made a track ask the user something
  already settled, tell the user to ignore that prompt and tell the track why.
- **The fixed lines every brief carries** (they are in the template and stay as written, apart from their `{...}` slots): the
  slot wait (the track waits for a `SLOT #<n> @<full sha>` message naming its head; a push or
  another merge voids it); the FINDING shape and the live-exposure line; the BLOCKER line; the
  ACK line; the WIP line; REPORT BACK; and what to do when its session ends.
- **The WIP line.** At the end of every review round (each pass of an independent review of its
  diff), and before any run of an external reviewer, the track writes one line into its handover,
  creating the handover file at the first one and appending after that:
  `WIP: <branch> @<sha>; brief: <path>; uncommitted: <files or none>; open findings: <ids or
  none>; next: <one action>`. A session that stops (a usage limit, a crash) can then be resumed
  from that line without reading its transcript. The track tells the coordinator the handover's
  path in its next status message. A WIP line never carries a live-exposure detail: it says
  "waiting for a ruling", not what the ruling is about.
- **Write PRs as `#12`, not as links**, in briefs and kickoff prompts: the Claude desktop app
  titles and binds a session after the first PR link in its prompt.
- **The report lives on disk**: the PR body, or a handover file in the track's own worktree. The
  track sends one pointer line, `REPORT: PR #12 body @<full head sha>` or `REPORT: <absolute path>`.
  Reading a file is cheap; searching a transcript is not. The one exception is a track whose
  task is the fix for a live exposure: its report is the handover file, and it opens or updates
  no PR until the user has decided how and when.
- **A brief never says "hand it to the user as a follow-up"**: tracks read that as "spawn
  something". Name the document where the line goes.

## Findings protocol

A track that notices something outside its task (a possible bug, a fail-open, a doc that
contradicts the code, a stale premise, a sibling of the defect it is fixing) does not fix it, does
not file it and does not ignore it. It reports it in the shape of
`${CLAUDE_PLUGIN_ROOT}/templates/finding.md`. A file it needs outside its scope is a finding too
(or a blocker); it may talk to the owning track, but it edits nothing until a `widen scope`
outcome is recorded. **A live-exposure finding goes to the coordinator in a private message only,
never into a PR body, a commit message, a report or any other file that is committed or posted.**
This matters most in a public repository, where a PR body is readable by anyone the moment it is
posted, and an edit does not unpublish it. If a live exposure is to be fixed, the user decides
how and when anything about it is pushed or posted, and the detail stays in private messages
until then. The coordinator:

1. **Reads the evidence line, not the conclusion.** A "reasoned, not measured" finding is a
   question, not a defect, until someone reproduces it.
2. **Puts it to the user with a recommendation**, one of the five next steps in the shape, and
   the cost of being wrong in each direction. The user decides; neither the coordinator nor the
   track decides alone.
3. **Records the outcome** in the ledger as one of the same five, with its detail: `widen scope:
   <track>, <globs>` (and updates that row's Scope) | `own track: <who>` | `backlog line: <where>`
   | `investigate first: <who>` | `drop: because ...`. Every outcome but `backlog line` and `drop`
   also adds an owed check ("F5 fixed in #12", "F6 reproduced by T3"), ticked only when that work
   is verified (see Owed checks in The ledger), so it survives a merge and the night. A finding
   with no recorded outcome is the failure.
4. **Tells the reporting track** what was decided, so it neither re-reports nor quietly fixes it.

A **blocker** for the track's own task is not a finding. The track tells the user in its own
window and the coordinator, at once, and stops until answered.

## Merge protocol

1. **Report.** The track has merged origin/main into its branch, rerun its suites, pushed, opened
   its PR ready for review (`gh pr ready <n>` if it was a draft), and sent its pointer line with
   its final head sha. It then waits for a slot. (A live-exposure fix has no PR until the user
   decides; its merge then starts here.)
2. **Slot check**, by the coordinator, for that exact head:
   This section says `main`; if your integration branch has another name, use it everywhere.
   - `gh pr view <n> --json state,isDraft,baseRefName,headRefOid,mergeable,mergeStateStatus`
   - `gh pr checks <n> --json name,bucket`: gh sorts every check into pass, skipping, pending,
     fail or cancel. With `--json` it exits 0 whatever the buckets, so judge by the buckets only.
     Exit 1 means "no checks" only when stderr says "no checks reported"; otherwise it failed.
   - `git fetch origin main +refs/pull/<n>/head:refs/coordinate/pr/<n>`, then the full file
     list from git, since gh's `files` field stops at 100:
     `git -c core.quotePath=false diff --name-only --no-renames origin/main...refs/coordinate/pr/<n>`
   - `git merge-base --is-ancestor origin/main refs/coordinate/pr/<n>`: exit code 0 means the PR
     contains the current main, so CI on this head ran against what it merges into (with no CI,
     the track's report is the only evidence its suites ran).
   - every file against the Scope in the ledger row. Scope creep shows up only here.

   **With the script**, the five checks are one call from the PowerShell tool, in process, from the
   coordinator's main checkout: `& "${CLAUDE_PLUGIN_ROOT}/scripts/slot-check.ps1" -Pr <n>` (from
   Bash, through `MSYS_NO_PATHCONV=1 powershell.exe -ExecutionPolicy Bypass -File "$(cygpath -w "${CLAUDE_PLUGIN_ROOT}/scripts/slot-check.ps1")" -Pr <n>`).
   It takes the scope from the ledger row whose Repo cell is this repo's full path and whose Branch is the PR's
   head branch (live rows only), or from `-Scope "<globs>"`; `-Base <branch>` names an
   integration branch other than `main`, `-Repo <path>` the PR's repo when you run it from
   another checkout, `-Ledger <path>` another ledger. It fetches `origin/<base>` and the PR's
   head, prints the PR, the files, the checks and GitHub's merge state, and ends with exactly one
   line, so the last line is the verdict:

   ```
   SLOT-CHECK #<n> @<full sha>: READY|WAIT|HOLD - <reasons>
   SLOT-CHECK #<n>: COULD NOT CHECK - <reason>
   ```

   Exit 0 is READY, 1 is WAIT or HOLD, 2 is "could not check" (a failed `gh` or `git`, invalid
   `gh` output, no scope, a bad `-Ci`): treat that as no verdict, never as READY. The `@<full sha>`
   is the head to grant the slot to. A PR with no checks at all is READY only when the repo has
   no CI: the CI column of its Baseline row in the ledger reads `none` (`-Ci none` says so for
   one call, `-Ci yes` the opposite); anything else, including a missing row, WAITs. The script
   writes nothing but `origin/<base>`, the fetched objects and a private ref it deletes again at once, and reports; it is not a merge gate.

   **READY** only when the PR is open, not a draft, based on `main`, `headRefOid` equals the
   reported sha and `refs/coordinate/pr/<n>`, the PR contains the current main, `mergeable` is
   MERGEABLE, `mergeStateStatus` is CLEAN or HAS_HOOKS (the script also lets UNSTABLE through, since it judges the checks itself), every file is in scope, and every check
   is in the pass or skipping bucket (no checks at all only when the ledger records, or `-Ci none` says, that the repo
   has no CI). **WAIT** while a check is pending, while `mergeable` or `mergeStateStatus` is
   UNKNOWN, while the fetched ref still lags `headRefOid` (refetch), or while no checks have
   appeared yet. BLOCKED while a check is pending and none has failed most likely means a
   required check is still running, so that waits too. A PR that does not yet contain the current
   main also waits, but it will not clear on its own: tell the track now to merge origin/main,
   rerun its suites, push and report a new head, so that CI runs again against the merged tree.
   Any WAIT still standing after about 15 minutes goes to the user (path filters can skip every
   workflow, and a check can hang). **HOLD** on anything else: a check in fail or cancel, a
   conflict, a draft, BLOCKED with nothing pending (branch protection not satisfied: a failing
   required check, a review missing, or another rule), a PR on another base, or a file out of
   scope. An out-of-scope file goes to the user even when the track says the user agreed in its
   window; only a recorded `widen scope` puts it in scope. Log the verdict, and on HOLD tell the
   track why; it fixes, pushes, and reports a new head.
3. **Grant the slot** to that track, naming the full sha: `SLOT #12 @<full sha>: ask the user to
   merge`. A push or a base change after the slot check voids the slot; step 2 reruns.
4. **One merge.** The user merges in the track's window, or the coordinator merges on the user's
   explicit typed go. A go covers one head: the sha of the slot, which you show the user when you
   ask for it. Record that sha with the quote ("merge #12 when green" is a go for that head
   only). A go typed before any slot exists waits for a slot; when it is granted, show the user
   its sha and take the go against it. Immediately before merging, re-read the head with
   `gh pr view <n> --json headRefOid`. If it differs from the recorded sha, the go is void
   (the track pushed, so the slot is void too): log it, rerun step 2 on the new head, and only
   on READY grant a new slot (step 3) and take a fresh go against its sha. A vague go such as
   "tell it yourself" is no go. Bind the merge to the recorded sha, never to a freshly read head:
   `gh pr merge <n> --squash --match-head-commit <full 40-char sha>` (or `--merge` /
   `--rebase`, as the repo does; outside an interactive terminal gh requires one of the three).
   With a merge queue, gh only enqueues: wait until `state` reads MERGED.
5. **Verify on origin.** `gh pr view <n> --json state,mergeCommit` gives the merge sha. Then
   `git fetch origin` and `git merge-base --is-ancestor <merge sha> origin/main`: exit code 0
   means it is on main. Log it.
6. **Delete the branch by its tip, atomically.** Delete the remote branch only while its tip is
   still the merged head, in one step:
   `git push --force-with-lease=refs/heads/<branch>:<head sha> origin :refs/heads/<branch>`.
   If it is refused, run `git ls-remote --exit-code origin refs/heads/<branch>`. Exit 2: it is
   already gone (auto-delete on merge). The merged head sha: the push was refused for another
   reason (branch protection, a hook, permissions); log it and tell the user. Another sha: it
   moved; keep it and ask its owner. Any other exit: could not check; log it as unresolved and
   retry later. Delete a local branch only when no worktree holds it and its tip equals the
   merged head. Never remove a worktree to tidy up: it may hold gitignored work. It goes when the
   user closes its session.
7. **Release the next track** with the new sha, and tell every other live track of that repo the
   same: "#12 merged as <sha>; main is now <sha>; merge origin/main, rerun your suites, push, and
   report your new head." Every merge voids the heads that were waiting, so each re-reports.
   Update a shared checkout only when no session is writing there.

   **With the script**, step 5, step 6 (only with `-DeleteBranch`; without it step 6 stays yours) and
   the notification half of step 7 are one call, after the user's merge OK, from the coordinator's
   main checkout: `& "${CLAUDE_PLUGIN_ROOT}/scripts/merge-verify.ps1" -Pr <n>` (from Bash, through
   `MSYS_NO_PATHCONV=1 powershell.exe -ExecutionPolicy Bypass -File "$(cygpath -w "${CLAUDE_PLUGIN_ROOT}/scripts/merge-verify.ps1")" -Pr <n>`).
   It checks that the merge commit is on `origin/<base>`, fast-forwards the launch checkout when
   that is safe (`-NoFastForward` skips it), checks the git config, and prints one `NOTIFY` line
   per other live track of the repo, ready to paste (it sends nothing). **It deletes no branch
   unless you pass `-DeleteBranch`.** Without the flag it prints the delete command it would have
   run (none for a branch name with characters a shell would act on); with it, it deletes only while the branch tip is still the merged head, and never a fork
   PR's branch, the base, origin's default branch, `main`, `master` or a branch an open PR uses.
   `-Repo <path>` and `-Ledger <path>` name another checkout or ledger. The last line is the verdict:

   ```
   MERGE-VERIFY #<n>: OK|PROBLEM|NOT MERGED - merge <sha12> on origin/<base>; branch <...>; checkout <...>; config <ok|WARN: ...>
   MERGE-VERIFY #<n>: COULD NOT CHECK - <reason>
   ```

   Exit 0 is OK, 1 is PROBLEM or NOT MERGED, 2 is could not check.

## Stop protocol (the user is leaving, or something is going wrong)

Send every live track the same order: start nothing new; commit a coherent green subset with the
repo's normal hooks (never skip them), push it, and open the PR as a DRAFT with "not done" in the
body; or, if nothing is green, commit nothing and say so. Either way, write a handover in its
own worktree (location in Terms) and send its absolute path; no merges. Then verify each track actually stopped: the
session is idle, a draft PR or a handover exists, and its worktree is kept.

## Mid-day handoff (the coordinator's context is growing)

The old coordinator brings the ledger current and starts nothing new; the user opens a fresh
coordinator session in the same main checkout. The new one rewrites the ledger's Coordinator line
("took over HH:MM from <old>"), re-verifies the baseline itself rather than trusting the ledger's,
and tells each live track "report to <new> from now on". It reads and logs any report still sent
to the old coordinator. In the desktop app, a session started from inside another session nests
under it; if any did, move it out before the user closes the old coordinator.

**With the script**, the ledger half is one call from the new coordinator, in the main checkout:
`& "${CLAUDE_PLUGIN_ROOT}/scripts/coord-handoff.ps1" -NewSession '<your session name or id>'`
(`-Ledger <path>` names another ledger). In one replacement it rewrites the Coordinator line
(`took over HH:mm from "<old>"`, keeping one `before that` level) and adds a `HANDOFF` line to the Log.
It first fetches `origin main` of every repo a live Tracks row names, and prints one `MESSAGE` line per
live track with that repo's `main` sha, then six `CHECKLIST` lines. It sends nothing and does not
register the ledger: send each `MESSAGE` line yourself, then run `coord-log.ps1 -Register`. It refuses
(`COORD-HANDOFF: NOT WRITTEN - <reason>`; the ledger is byte-unchanged, except that a ledger which
vanishes at the swap is not recreated and the temp file holding the new text is named) when the ledger
changed during the fetch, when `-NewSession` is a track's Session cell (its name, or an id that is the cell's first word) or the current coordinator, or when
a live row's Repo is not the full path of a git working tree's top level. The fetches are not undone
by a refusal. Run it in process (`&`), not through `powershell.exe -File`.

## Day close (built from the ledger)

Resolve first: any finding still PENDING goes to the user before the handover is written. Then
write the day-close handover section by section:

| Handover section | Comes from |
|---|---|
| State per repo (heads, PRs, branches, worktrees, CI) | a FRESH snapshot now, never the morning's Baseline |
| Decisions, with the one-line why | ledger Decisions (quotes kept as quotes) |
| Findings and their outcomes | ledger Findings |
| Incidents and gotchas | ledger Log |
| Next, by owner | unticked Owed checks, plus open tracks from the Tracks table |

Add a kickoff prompt for tomorrow that (a) re-verifies the baseline, (b) asks the user which item
to start, (c) starts only that. Put the handover, a copy of the ledger and copies of the day's
briefs in the handover folder, so a later retrospective can hold a track's work against what it
was told; they stay local by default. If your repo commits them, first replace every line, in
every section and every file (the ledger's sections including Tracks and Merge slots, each brief,
and each track's handover with its WIP lines), that carries a live-exposure finding's details
with `F<n>: live exposure, held privately`, then land them through a short PR in its own slot
like any other merge, never by a direct commit to main while tracks are live. Write a new
day-close handover each day; never edit a previous one.

## Hygiene

- Run destructive git steps (`worktree remove`, `branch -D`, a remote delete) as separate calls.
- A paste-ready prompt for the user goes in the turn's FINAL message, never in text between tool
  calls, where it can be missed. A kickoff prompt's first sentence names the folder to start in.
- When a track proves the coordinator's recommendation wrong with evidence, say so and relay it.
  The coordinator relays findings; it does not prescribe fixes, and it does not read diffs "just
  to check": its context is the scarcest thing it has.
- Recommend at most two follow-up fix PRs on any one problem; the rest becomes backlog lines.

## Optional: desktop-app sidebar

In the Claude desktop app, one sidebar group per coordination day (`Coord <YYYY-MM-DD>`) holding
the coordinator and every track makes the sessions easy to find. Ask the user once to approve the
batch of moves and renames (`<Track>: <what>`), and log each one.
