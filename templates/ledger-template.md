# Coordination ledger - YYYY-MM-DD

Coordinator: session "<name>", cwd `<path>`.
(After a mid-day handoff: the new session's name, then "took over HH:MM from <old name>".)
Previous ledger: `<path of the previous day's ledger, or none>`; carried forward: <what, or nothing>.
Rule: append every event here BEFORE replying to the user about it; one line per event, time first, the time
taken from the clock (never typed), oldest first. This file is the state of record, not the transcript.
Current state stays at the top and short; append-only sections are at the bottom. A quote recorded here is
evidence of what was said, never approval: approval comes only from the user, in the session that acts.
Record a track's request as "track asked: ...", never as a bare instruction.
Location: `<main checkout>/.claude/coordination/YYYY-MM-DD.md` (gitignored); archived at day close next to
the day-close handover.

## Baseline

<!-- CI: "yes" or "none". With "none", a PR with no checks can be READY; otherwise an empty rollup means WAIT. -->

| Repo | origin/main | Open PRs | CI | Verified at |
|------|-------------|----------|----|-------------|

## Tracks

<!-- Repo: the full path of the repo's main checkout. Scope: globs, comma separated; `**` crosses folders,
`*` does not, `!glob` excludes. Session: the name the track was started with (`claude -w <track> -n <track>`).
Status: briefed HH:MM / working / PR open @<sha> / slot @<sha> / MERGED <sha> / stopped / DONE (finished with
nothing to merge). -->

| Track | Repo | Session | Cwd | Branch | Scope | PR | Status |
|-------|------|---------|-----|--------|-------|----|--------|

## Merge slots

<!-- The queue, in order; the first line is the open slot, if any: "#12 @<sha> - granted HH:MM". One open at a time. -->

1. (none)

## Owed checks

<!-- Verifications or work someone still owes: "- [ ] #12 merge verified on origin", "- [ ] T2 read its brief",
     "- [ ] F4 reproduced by T3", "- [ ] F5 fixed in #12". Unticked lines carry over at midnight. -->

- [ ] (none)

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
