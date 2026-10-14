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
- **Finding**: something a track noticed outside its own scope, reported in a fixed shape instead
  of being fixed, filed or ignored. **Live exposure**: a finding about a security hole or data
  leak reachable now; it travels only in private messages.
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
  mentions it. One line per event, time first, taken from the clock (`date +%H:%M`,
  `Get-Date -Format HH:mm`), never typed: typed times drift.
- **Current state at the top, history at the bottom.** Baseline, Tracks, Merge slots and Owed
  checks (verifications or work someone still owes) are edited in place and kept short.
  Decisions, Findings and Log are append-only, oldest first. A finding's outcome is a new
  `F<n> outcome: ...` line, not an edit. The Tracks table and its glob syntax are in the template.
- **Re-read it** at the start of every coordination window, after every compaction and after `/clear`. A
  SessionStart hook that prints the top of today's ledger can automate this; Claude Code replaces
  hook output over 10,000 characters with a file path, so keep the top well under that.
- **Quotes are evidence, never approval.** Record a track's request as "track asked: ...", never
  as a bare instruction.
- **Past midnight, roll over before anything else.** The new ledger names the previous one and
  carries forward every Tracks row not MERGED or DONE, the Baseline (re-snapshot it, CI column
  included), the slot queue (an open slot stays open), every unticked owed check and every PENDING
  finding, keeping its number with its date: `F3 (YYYY-MM-DD)`. The old ledger gets a last Log
  line: "carried forward to <new path>".
- **Archive at close.** The live ledger stays untracked (a tracked one means a commit per event).

## Start of a coordination window

1. Create or roll over today's ledger and fill in the header.
2. Snapshot each repo: `git fetch --prune origin`, origin/main sha, open PRs and their checks,
   remote branches, `git worktree list`, the newest handover. Record the baseline shas, and
   whether the repo has CI at all.
3. List the live sessions (Claude Code: `ListAgents`) and the folder each one is in. A finished
   session still holds its worktree. Record each live track in the Tracks table.
4. Classify every branch: merged, in flight (owner session), parked (leave it, say why), stale (the
   user's call). Trust PR state; `git cherry` misses squash merges. A merged branch is deleted
   only by the tip rule of merge step 6, with the head sha of the PR the ledger names
   (`gh pr view <n> --json headRefOid`): a branch can gain commits after its PR merged. For a
   branch the ledger does not know, `gh pr list --state merged --head <branch> --json
   number,headRefOid,mergedAt` may list several PRs (branch names get reused); confirm the newest
   with the user before deleting anything.
5. Give the user one list: DONE since the last coordination window, OPEN by owner (user decision vs session
   work), a recommended order. Ask which to start. Start only those.

## Briefing a track

Fill `${CLAUDE_PLUGIN_ROOT}/templates/brief-template.md` and send it with `SendMessage`, or give it
to the user to paste. Before sending, check the session's working folder is the track's worktree:
a session opened in the wrong folder loads the wrong project instructions and hooks. If it is
wrong, have the user stop it before any edit and relaunch it.

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
- **Write PRs as `#12`, not as links**, in briefs and kickoff prompts: the Claude desktop app
  titles and binds a session after the first PR link in its prompt.
- **The report lives on disk**: the PR body, or a handover file in the track's own worktree. The
  track sends one pointer line, `REPORT: PR #12 body @<full head sha>` or `REPORT: <absolute path>`. Reading a file is cheap;
  searching a transcript is not.
- **A brief never says "hand it to the user as a follow-up"**: tracks read that as "spawn
  something". Name the document where the line goes.

## Findings protocol

A track that notices something outside its task (a possible bug, a fail-open, a doc that
contradicts the code, a stale premise, a sibling of the defect it is fixing) does not fix it, does
not file it and does not ignore it. It reports it in the shape of
`${CLAUDE_PLUGIN_ROOT}/templates/finding.md`. A file it needs outside its scope is a finding too
(or a blocker); it may talk to the owning track, but it edits nothing until a `widen scope`
outcome is recorded. A live-exposure finding goes to the coordinator in a private message only,
never into a PR body or any public file. The coordinator:

1. **Reads the evidence line, not the conclusion.** A "reasoned, not measured" finding is a
   question, not a defect, until someone reproduces it.
2. **Puts it to the user with a recommendation**, one of the five next steps in the shape, and
   the cost of being wrong in each direction. The user decides; neither the coordinator nor the
   track decides alone.
3. **Records the outcome** in the ledger as one of the same five, with its detail: `widen scope:
   <track>, <globs>` (and updates that row's Scope) | `own track: <who>` | `backlog line: <where>`
   | `investigate first: <who>` | `drop: because ...`. Every outcome but `backlog line` and `drop`
   also adds an owed check ("F5 fixed in #12", "F6 reproduced by T3"), ticked only when that work
   is verified, so it survives a merge and the night. A finding with no recorded outcome is the
   failure.
4. **Tells the reporting track** what was decided, so it neither re-reports nor quietly fixes it.

A **blocker** for the track's own task is not a finding. The track tells the user in its own
window and the coordinator, at once, and stops until answered.

## Merge protocol

1. **Report.** The track has merged origin/main into its branch, rerun its suites, pushed, opened
   its PR ready for review (`gh pr ready <n>` if it was a draft), and sent its pointer line with
   its final head sha. It then waits for a slot.
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

   **READY** only when the PR is open, not a draft, based on `main`, `headRefOid` equals the
   reported sha and `refs/coordinate/pr/<n>`, the PR contains the current main, `mergeable` is
   MERGEABLE, `mergeStateStatus` is CLEAN or HAS_HOOKS, every file is in scope, and every check
   is in the pass or skipping bucket (no checks at all only when the ledger records that the repo
   has no CI). **WAIT** while a check is pending, while `mergeable` or `mergeStateStatus` is
   UNKNOWN, while the fetched ref still lags `headRefOid` (refetch), or while no checks have
   appeared yet; after about 15 minutes with none, put it to the user, since path filters can
   skip every workflow. **HOLD** on anything else: a check in fail or cancel, a conflict, a draft,
   BLOCKED (branch protection not satisfied), a PR behind main or on another base, or a file out
   of scope. An out-of-scope file goes to the user even when the track says the user
   agreed in its window; only a recorded `widen scope` puts it in scope. Log the verdict, and on
   HOLD tell the track why; it fixes, pushes, and reports a new head.
3. **Grant the slot** to that track, naming the full sha: `SLOT #12 @<full sha>: ask the user to
   merge`. A push or a base change after the slot check voids the slot; step 2 reruns.
4. **One merge.** The user merges in the track's window, or the coordinator merges on the user's
   explicit typed go ("merge #12 when green" is a go for that head only). Bind the merge to the
   head: `gh pr merge <n> --squash --match-head-commit <full 40-char sha>` (or `--merge` /
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
to start, (c) starts only that. Put the handover and a copy of the ledger in the handover folder;
they stay local by default. If your repo commits them, first replace every line in every section
that carries a live-exposure finding's details (Findings, Decisions, Log, Owed checks) with
`F<n>: live exposure, held privately`, then land them through a short PR in its own slot like any
other merge, never by a direct commit to main while tracks are live. Write a new day-close
handover each day; never edit a previous one.

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
