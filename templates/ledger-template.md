# Coordination ledger - YYYY-MM-DD

Coordinator: session "<name>", cwd `<path>`.
(After a mid-day handoff: the new session's name, then "took over HH:MM from <old name>".)
Previous ledger: `<path of the previous day's ledger, or none>`; carried forward: <what, or nothing>
(live Tracks rows, a re-snapshotted Baseline, an open slot, unticked owed checks, open Queue items and PENDING
findings; a Tracks row and an owed check are marked "(from YYYY-MM-DD)", a finding keeps its number with its date).
Rule: append every event here BEFORE replying to the user about it; one line per event, time first, stamped by
coord-log.ps1 (Queue, Decisions, Findings, Log; by hand from the clock where PowerShell is missing), oldest first; a
time in the sections edited in place (Baseline, Tracks, Merge slots, Owed checks) is taken from the clock,
never typed. This file is the state of record, not the transcript.
Current state stays at the top and short; append-only sections are at the bottom. A quote recorded here is
evidence of what was said, never approval: approval comes only from the user, in the session that acts.
Record a track's request as "track asked: ...", never as a bare instruction.
Location: `<main checkout>/.claude/coordination/YYYY-MM-DD.md` (gitignored); archived at day close next to
the day-close handover. At day start the coordinator registers it with `coord-log.ps1 -Register`, so the scope
guard (a plugin hook, on once the plugin is installed) can find it.

## Baseline

<!-- CI: "yes" or "none". With "none", a PR with no checks can be READY; otherwise an empty rollup means WAIT. -->

| Repo | origin/main | Open PRs | CI | Verified at |
|------|-------------|----------|----|-------------|

## Tracks

<!-- Repo: the full path of the repo's main checkout. Scope: globs, comma separated; `**` crosses folders,
`*` does not, `!glob` excludes. Session: the name the track was started with (`claude -w <track> -n <track>`).
Model: the track's model and effort at start, then each switch with its time ("<model> <effort>; 14:10 <model>
<effort>"), so a later day can see which model and effort produced which result.
Status: set it with coord-set.ps1 -State <word> (QUEUED BRIEFED RUNNING PR-OPEN WAIT-USER WAIT-SLOT WAIT-QUOTA
BLOCKED MERGED DONE), which writes "<WORD> HH:mm; <text>", and coord-status.ps1 groups the row by that first word.
Lead with MERGED or DONE (upper case, the first word; DONE is also a track that finished with nothing to merge)
when the track is finished, and never otherwise: "NOT MERGED ..." or "running; round 1 DONE" stay live.
Every row needs exactly one cell per column, empty or not; a row carried from a ledger without the Model column
gets an empty Model cell after Session. -->

| Track | Repo | Session | Model | Cwd | Branch | Scope | PR | Status |
|-------|------|---------|-------|-----|--------|-------|----|--------|

## Merge slots

<!-- The queue, in order; the first line is the open slot, if any: "#12 @<sha> - granted HH:MM". One open at a time. -->

1. (none)

## Owed checks

<!-- Verifications or work someone still owes: "- [ ] #12 merge verified on origin", "- [ ] T2 ACK by HH:MM",
     "- [ ] F4 reproduced by T3", "- [ ] F5 fixed in #12". Tick one only when it is verified, never on a claim.
     Always added: an ACK for every brief and every change to one, each with its deadline (15 minutes after sending); and every finding whose
     outcome leaves work open, ticked only when the track's report names the fix, the PR's file list holds the
     file and the merge is on origin (for an investigation: when the named track reports what it measured).
     Unticked lines carry over at midnight, marked "(from YYYY-MM-DD)" at the end of the line. -->

- [ ] (none)

## Queue

<!-- HH:MM Q<n> <what> [<gate>] owner: <who>; source: <handover section, decision, finding id>
     gates the board reads: [after #<n> merges] [after yyyy-MM-dd HH:mmZ] [after HH:mm] [after Q<n>] [needs <who> ...]
     later, its own line: HH:MM Q<n> outcome: started as track <name> | dropped, because ... | moved to <where the backlog lives> -->

## Decisions

<!-- HH:MM "the user's words, quoted" (where they typed them) -> what it changes -->

## Findings

<!-- HH:MM F<n> from <track>: what, where | evidence | severity | outcome: PENDING
     later, its own line: HH:MM F<n> outcome: widen scope: <track>, <globs> | own track: <who> |
       backlog line: <where> | investigate first: <who> | drop: because ...
     carried from a previous day: keep the number with its date, e.g. "F3 (YYYY-MM-DD)".
     Live-exposure findings: before any copy of this ledger is committed, replace every line that carries their
     details, in every section, with "F<n>: live exposure, held privately". -->

## Log

<!-- HH:MM <event> -->
