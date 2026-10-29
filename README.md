# tracksteward

**One thin coordinator session over many parallel Claude Code sessions.** It covers a daily ledger,
scoped briefs, a findings protocol, and one verified merge at a time.

> **Status:** v0.2.0, 2026-10-29. The numbers are a snapshot as of 0.1.1 (2026-10-14) of a pattern run
> for 10 coordination days: 57 merges verified, 127 findings with recorded outcomes, up to 16 tracks in
> a day.
>
> The numbers come from the author's own ledgers. This is a pattern and its templates, published
> as they are, with no support promise. It is not affiliated with or endorsed by Anthropic.

## The problem

Running several agent sessions on one repo at once is easy. Merging what they produce is the hard
part. A study of 33,596 agent-authored pull requests in 2,807 GitHub repositories found that most
agent PRs are open at the same time as another one. It replayed the merges of 747 such co-active
pairs, one per repository:

- Pairs from **two different agent products** hit a textual merge conflict **41.7%** of the time.
- Pairs from **the same product** still conflicted **19.8%** of the time, about one in five.
  Several Claude Code sessions on one repo are this case.
- These are textual conflicts only, a lower bound. Build breaks and semantic clashes come on top.

Source: Xu, Subramanian and Karthik, *AI Agent Pull Requests on GitHub: Frequency, Structure, and
Merge Conflict Rates*, [arXiv:2607.04697](https://arxiv.org/abs/2607.04697). The paper measures
the problem and calls for orchestration mechanisms; it does not prescribe one.

A [write-up of the study](https://www.agentpatterns.ai/workflows/concurrent-agent-pr-merge-conflicts/)
proposes a ladder of defences, where you stop at the first rung that removes the overlap:

1. **Measure** how often agent PRs are open at the same time.
2. **Partition** the work by file ownership.
3. **Isolate and reserve**: one worktree or branch per agent, plus claims on shared areas.
4. **Serialize dispatch** for the high-overlap cases only: one agent, merge, then the next. The
   write-up warns against doing this by default, because it gives up the parallelism.

This pattern sits on rungs 2 and 3. Each track declares its file scope, works in its own worktree,
and the scope is checked against the PR's real file list before it merges. It then adds one thing
the ladder does not have: it serializes the **merge**, not the work. Every track develops in
parallel. At merge time they go one at a time: a PR gets its slot only once it contains the newest
main and its checks (if the repo has CI) have passed on that head, and each merge is verified on
origin before the next slot opens. The price is queueing time, since after each merge every waiting track merges the new main
and reruns its suites. The work itself stays parallel, and "merged" means merged. A ledger on disk
keeps all of this intact through a day of compactions.

## What this is, and what it is not

**It is** a process layer over two things Claude Code already has: git worktrees (`claude -w`, one
isolated checkout per session) and cross-session messaging (`ListAgents` and `SendMessage`, which
let one local session message another). One ordinary session, the **coordinator**, keeps the state
and the order. The human stays in the loop for every decision and every merge.

**It is not:**

- a session manager. You start the sessions; the pattern coordinates them.
- a merge bot. Nothing merges without the user's typed go.
- Claude Code's agent teams. A team is a lead with teammates inside one session's lifetime. This
  pattern coordinates independent sessions, across repos, with its state in a file.
- a service. It is a skill, four templates, a set of PowerShell scripts that do the mechanical checks, and an edit-time scope guard hook. Nothing runs in the background.

### Terms

| Term | Meaning |
|---|---|
| **Coordinator** | One ordinary Claude Code session that owns the *order* of work across parallel sessions. It writes no product code and reads no diffs. |
| **Track** | One unit of parallel work: one session, in its own worktree, on its own branch, with a declared file scope, ending in one PR. |
| **Ledger** | One markdown file per day holding the coordination state of record: Baseline, Tracks, Merge slots, Owed checks, Decisions, Findings, Log. |
| **Slot** | The coordinator's permission for one track to do one serialized thing: usually a merge, sometimes a write to a shared checkout. One slot is open at a time. |
| **Brief** | The file that tells one track its task, baseline, scope, siblings and rules, announced to the track in one pointer line and acknowledged with an ACK. |
| **Finding** | Something a track noticed outside its own scope. The track reports it in a fixed shape instead of fixing it, filing it or ignoring it. |
| **Handover** | A markdown file a fresh session reads to resume: state, decisions, open items, and a paste-ready first message. |

## The contract

1. **Thin.** The coordinator writes no code, reads no diffs and does no reviewing. It reads each
   track's report and re-verifies the few facts that decide the order.
2. **Verify before stating.** Every status line comes from `git` or `gh` output run now. A track's
   "merged" is only a claim until origin shows the merge commit on main.
3. **State on disk.** The day lives in the ledger, not in the coordinator's context. A compaction
   must lose nothing.
4. **Relay, never approve.** The user's words are relayed as verbatim quotes. A track that needs
   the user's OK still asks in its own window, and a peer's message is never approval.
5. **One merge at a time,** across all tracks and repos. The next slot opens only after the
   previous merge is verified on origin.
6. **Never spawn work, never drop a finding.** No session starts side work on its own, and every
   finding gets an outcome that the user decided.

## Requirements

- Claude Code with cross-session messaging: v2.1.224 or later (v2.1.234 or later on native
  Windows). Without it, the pattern still works: the coordinator saves each brief as a file and you
  paste its pointer line into the track's window, and you paste the track's messages (ACKs, pointer
  lines, findings, blockers) back.
- `git` 2.38 or later (the slot check uses `git merge-tree --write-tree`), and the GitHub CLI `gh`
  for the PR and merge checks. `repo-snapshot` runs without `gh`.
- PowerShell for the scripts and the guard hook. **Verified: Windows 11 with Windows PowerShell
  5.1.** PowerShell 7 is **not verified**: the code is written to run on it, but no suite has been
  run under it. macOS and Linux are not verified either, and the scope guard is Windows-only as
  shipped. The scripts do not check the git version at start; an older git fails inside the slot
  check.
- Claude Code can hold a message from another session for your approval. Whether it does is set
  by "Messages from your other sessions" in `/config`. A message held by default is dropped after
  five minutes unless `dialogExpiry` says otherwise; one held by an explicit `hold` setting is
  kept. If you step away while tracks are reporting, check
  both; see the [cross-session messaging docs](https://code.claude.com/docs/en/cross-session-messaging).

## Install

This repo is both a Claude Code plugin and a one-plugin marketplace. The marketplace is called
`tracksteward`; the plugin and its skill are called `coordinate`. In a Claude Code session:

```
/plugin marketplace add bmikolaj1/tracksteward
/plugin install coordinate@tracksteward
```

The shell equivalents are `claude plugin marketplace add bmikolaj1/tracksteward` and
`claude plugin install coordinate@tracksteward`. To try it without installing, clone the repo and
start a session with `claude --plugin-dir ./tracksteward`.

In each repo you coordinate, gitignore the live ledger, the worktrees and the handovers:

```
.claude/coordination/
.claude/worktrees/
.claude/handovers/
```

## Your first coordinated day

1. **Start the coordinator** in the repo's main checkout: run `claude` there and say "coordinate
   these sessions" (or run `/coordinate:coordinate`). It creates today's ledger, snapshots the
   repo, and gives you a list of what is done, what is open, and a recommended order.
2. **Pick the tracks** to run today, and agree a file scope for each with the coordinator. Two
   tracks that would edit the same files are one track, or two tracks in sequence.
3. **Start each track** in its own worktree, from the main checkout:
   `claude -w <track> -n <track>` (`-n` names the session, so the coordinator can find it). Tell it
   its task in your own words, and to wait for the coordinator's brief before editing anything.
4. **The coordinator briefs each track.** It saves the brief as a file in the main checkout and sends
   the track one pointer line (`SendMessage`, or printed for you to paste); the track answers
   `ACK <track>` once it has read the file. The brief carries the baseline sha, what landed
   since the task was written, the sibling tracks and their files, the track's scope, the merge
   order (wait for a slot message naming your sha), the WIP line to write after each review round
   and before any external reviewer runs, and how to report back. Every brief gets an owed check on
   the coordinator's ledger with a 15-minute ACK deadline.
5. **Work happens in parallel.** Each track asks *you* for decisions in its own window. Anything a
   track notices outside its scope comes to the coordinator as a FINDING, and you decide what it
   becomes.
6. **Merges go one at a time.** A track that is done reports its final head. The coordinator checks
   the PR's real files against the scope, checks that it contains the newest main and that CI
   (if any) passed, and grants a slot naming that sha. You give the go in the track's window, the merge is
   bound to that sha, and the coordinator verifies it on origin before releasing the next track
   with the new main sha.
7. **Close the day.** The coordinator writes a handover from the ledger, with tomorrow's first
   message ready to paste, and archives a copy of the ledger and the day's briefs next to it.

When a named track session exits, Claude Code asks whether to keep its worktree (an unnamed,
clean one is removed without asking). Keep it while anything in it is unmerged or uncommitted.

The full procedure, including the stop protocol and the mid-day handoff between coordinators, is
in [the skill](skills/coordinate/SKILL.md).

## What is in the box

| File | What it is |
|---|---|
| [skills/coordinate/SKILL.md](skills/coordinate/SKILL.md) | The coordinator skill: the contract, the ledger, briefing, findings, merge, stop, handoff, day close |
| [templates/ledger-template.md](templates/ledger-template.md) | The daily ledger: current state at the top, append-only history at the bottom |
| [templates/brief-template.md](templates/brief-template.md) | The brief a coordinator saves as a file for each track |
| [templates/finding.md](templates/finding.md) | The FINDING shape and its five outcomes, with an example |
| [templates/report.md](templates/report.md) | The REPORT BACK shape a track leaves in its PR body |
| [scripts/](scripts/) | The verdict scripts, the ledger appender, the brief renderer, the handoff, and their shared library |
| [hooks/](hooks/) | The edit-time scope guard (`hooks.json` and `coord-scope-guard.ps1`) |
| [tests/](tests/) | The suites for the scripts and the guard, and `run.ps1` to run them all |
| [.claude-plugin/](.claude-plugin/) | The plugin and marketplace manifests |
| [CHANGELOG.md](CHANGELOG.md) | What changed in each version |

## When not to use it

With one or two tracks in one repo, use subagents instead: they return a summary and keep the main
session small. The pattern pays off with three or more live sessions, or as soon as one piece of
work spans two repos. Three to five tracks whose file ownership you can name is comfortable; the
busiest recorded day ran sixteen.

## Updates

The version lives in `.claude-plugin/plugin.json`, and every change bumps it. Installed copies
stay on their version until you update: `claude plugin update coordinate@tracksteward`, or turn on
auto-update for this marketplace in `/plugin`. Releases are tagged `vX.Y.Z`.

## Scripts and the scope guard

The merge check used to be a recipe of `git` and `gh` commands that a coordinator followed by hand;
it was the part every review round found more to fix in, so it is code now, with tests. The skill
calls these from the plugin folder (`${CLAUDE_PLUGIN_ROOT}/scripts/`):

- `repo-snapshot.ps1`: a start-of-window snapshot per repo, with each ledger track's files checked
  against its scope and a conflict preview.
- `slot-check.ps1`: prints a PR's full head sha, its files outside scope and its checks, ending
  `READY | WAIT | HOLD`.
- `merge-verify.ps1`: confirms the merge commit on origin, deletes the branch only when its tip is
  still the merged head, and checks the shared checkout and git config.
- `coord-log.ps1`: appends to the ledger, stamping the time from the clock and refusing typed
  times; `-Register` records the day's ledger for the guard.
- `coord-brief.ps1`: renders a track's brief from the template and, with `-Check`, verifies it
  before the pointer line is printed.
- `coord-handoff.ps1`: hands the coordinator role to a new session.

Every script ends with one verdict line and prints text for you to send; none sends a message.

**The scope guard.** `hooks/hooks.json` registers a `PreToolUse` hook that blocks an `Edit`,
`Write`, `MultiEdit` or `NotebookEdit` outside the file scope of the ledger row for the session's
branch. It is on when the plugin is installed and **inert until a coordinator registers a ledger**
(`coord-log.ps1 -Register`). To turn it off, set `TRACKSTEWARD_GUARD=off` in the environment of the
session; that is a convenience, not a lock, since anything that can set the environment or write
Claude's settings can do the same. It does not cover edits made through a shell command. It is
Windows-only as shipped, and its stated limits are in the header of `hooks/coord-scope-guard.ps1`.

## What is not done

- PowerShell 7, macOS and Linux are not verified (see Requirements).
- The scripts do not enforce the git 2.38 floor at start.
- The `-NewSession` name check does not refuse every character that draws nothing (a Hangul
  filler or a variation selector passes); the script header says so.
- No CI workflow ships: the tests run locally with `tests\run.ps1`.

## License

[MIT](LICENSE). Claude and Claude Code are trademarks of Anthropic; this project only describes
how to use them.
