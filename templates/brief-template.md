# Brief template

Save the filled brief as a file in the coordinator's main checkout (where the ledger lives),
`.claude/coordination/briefs/<YYYY-MM-DD>-<track>.md`, and send the track only the pointer line:
`BRIEF: {absolute path}; reply "ACK {track}" when read`. The file keeps the full text on disk, so a
track that compacts can re-read it instead of asking. It does not deliver itself or stay fresh: a missing
ACK shows a pointer line that went nowhere, and every later message carries the current sha.

Two kinds of slot. `{...}` is the coordinator's: replace every one before saving (delete the CROSS-REPO
block and the SUPERSEDES line unless they apply); a brief that still has one of the template's own slots
is not sent (braces inside the text you fill in, such as a glob or a command, are fine). `<...>` is filled when that line is
used (a PR number, a sha, a time) and stays as written in the file. Assert only what you verified just now;
ask for what the track owns. Write PRs as `#12`, never as links. Quote the user verbatim; if they gave no words for this track, delete that sentence.

```
Coordination brief from {coordinator session name}. The user's request, quoted: "{their words}"
(typed in {which session}, {HH:MM}). The user's decisions still reach you only in your own window.
TRACK: {track}, in {repo}, branch {branch}, session {session name}.
THIS FILE: {absolute path of this file}. It is the brief of record; re-read it instead of asking me.
SUPERSEDES: {old brief path, and what was carried from the previous day - after midnight only; otherwise delete this line}.

BASELINE, verified {HH:MM}: {repo} origin/main = {sha}; open PRs: {list or none}; branch from {sha}.
(True as of that time. Every later message from me carries the current sha.)

LANDED SINCE YOUR TASK WAS WRITTEN, read before designing: {#PR, one line each, or none}.

LIVE TRACKS: (1) YOU, {branch}; (2) "{session name}", branch {branch}, owns {globs}; ...

FILE SCOPE, yours: {globs}. NOT yours: {globs}. If you need a file outside your scope, do not
edit it: send me a FINDING with "widen scope" (or a BLOCKER if it stops you). You may talk to the
owning track, but only a widen-scope outcome I confirm puts the file in your scope.

REPO RULES: {this repo's current gotchas: how to run the suites, CI quirks, commit conventions}.

MERGE ORDER: {who goes first and why}. When you are done: merge origin/main into your branch,
rerun the suites, push, open the PR ready for review (gh pr ready <n> if it is a draft; no PR for a live-exposure fix, see REPORT BACK), and send
me your pointer line with your full head sha. Then WAIT for my slot message naming that sha
("SLOT #<n> @<full sha>"). Only then ask the user to merge, in YOUR window, bound to that sha
(gh pr merge <n> --{method: squash, merge or rebase, as this repo does} --match-head-commit <full 40-char sha>). A push after my
slot message voids it, and so does a merge of another PR: merge origin/main again, rerun, push,
report the new head, and wait again. If I tell you your branch is behind, do that at once. After
your merge, send me the merge commit sha.

CROSS-REPO (only if you edit a second repo): in {target repo}, work in a worktree at {location}
and merge with {its merge command}, in a slot like any other merge.

Never start side work (new sessions, tickets, background tasks) and never silently drop something
you noticed: anything outside your task comes to me as a FINDING (shape below). The user decides
what it becomes, and I tell you the outcome. A finding of severity "live exposure" (a security
hole or data leak reachable now) goes to me at once, in a private message only, never into a PR
body, a commit message, a report or any other file that is committed or posted, and never into a
WIP line. Do not push or post anything about one until the user has decided how.

FINDING: <one line: what, where (file:line), how observed (measured / reasoned / read)>
  evidence: <the command or test that showed it, or "reasoned, not measured">
  scope: outside mine (<owner track, or nobody>) | mine but outside this task
  severity guess: live exposure | latent | cosmetic
  suggested next step: widen scope | own track | backlog line | investigate first | drop

BLOCKER (anything that stops your own task): tell the user in your own window AND send it to me
in full, at once, then stop until answered. It is not a finding.

ACK: when you have read this file, send me one line: "ACK {track}", with your model and effort in
it ("unknown" if you cannot tell), and tell me whenever you switch either. I stamp the time myself.
If I change the brief, I append the change to this file and send you a message that says what
changed; read the file again and ACK again ("ACK {track} changed").

WIP: at the end of every review round (each pass of an independent review of your diff), and before
any run of an external reviewer, write one line into your handover. Create the handover at the first
one, in YOUR worktree (.claude/handovers/<YYYY-MM-DD-HHMM>-{track}.md), then append, and tell me its
path in your next status message:
  WIP: <branch> @<sha>; brief: <path of this file>; uncommitted: <files or none>; open findings: <ids or none>; next: <one action>
so that a session that stops (a usage limit, a crash) can be resumed from that line without a
transcript. Do not put a live-exposure detail in it; "waiting for a ruling" is enough.

REPORT BACK: put the final report in your PR body (no PR: in the handover file above), then send me
ONE pointer line: "REPORT: PR #<n> body @<full head sha>" or "REPORT: <absolute path>". The report
holds FILES TOUCHED (every path, in scope or not), evidence (suite counts, what you saw fail before
it passed), your FINDING lines (never live-exposure ones), and your model and effort. If your task
is the fix for a live exposure, write the report to the handover file instead, send its path, and
open or update no PR until the user has decided.

WHEN YOUR SESSION ENDS: keep your worktree while anything in it is unmerged or uncommitted.
```
