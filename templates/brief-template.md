# Brief template

Fill every `<...>` before sending. Assert only what you verified just now; ask for what the track
owns. Write PRs as `#12`, never as links. Quote the user verbatim or not at all.

```
Coordination brief from <coordinator session name>. The user's request, quoted: "<their words>"
(typed in <which session>, <HH:MM>). Their decisions still reach you only in your own window.

BASELINE, verified <HH:MM>: <repo> origin/main = <sha>; open PRs: <list or none>; branch from <sha>.

LANDED SINCE YOUR TASK WAS WRITTEN, read before designing: <#PR, one line each, or none>.

LIVE TRACKS: (1) YOU, <branch>; (2) "<session name>", branch <branch>, owns <globs>; ...

FILE SCOPE, yours: <globs>. NOT yours: <globs>. If you need a file outside your scope, do not
edit it: send me a FINDING with "widen scope" (or a BLOCKER if it stops you). You may talk to the
owning track, but only a widen-scope outcome I confirm puts the file in your scope.

REPO RULES: <this repo's current gotchas: how to run the suites, CI quirks, commit conventions>.

MERGE ORDER: <who goes first and why>. When you are done: merge origin/main into your branch,
rerun the suites, push, open the PR ready for review (gh pr ready <n> if it is a draft), and send
me your pointer line with your full head sha. Then WAIT for my slot message naming that sha
("SLOT #<n> @<full sha>"). Only then ask the user to merge, in YOUR window, bound to that sha
(gh pr merge <n> --<squash|merge|rebase> --match-head-commit <full 40-char sha>). A push after my
slot message voids it, and so does a merge of another PR: merge origin/main again, rerun, push,
report the new head, and wait again. After your merge, send me the merge commit sha.

CROSS-REPO (only if you edit a second repo): in <target repo>, work in a worktree at <location>
and merge with <its merge command>, in a slot like any other merge.

Never start side work (new sessions, tickets, background tasks) and never silently drop something
you noticed: anything outside your task comes to me as a FINDING (shape below). The user decides
what it becomes, and I tell you the outcome. A finding of severity "live exposure" (a security
hole or data leak reachable now) goes to me in a private message only, never into the PR body or
any public file.

FINDING: <one line: what, where (file:line), how observed (measured / reasoned / read)>
  evidence: <the command or test that showed it, or "reasoned, not measured">
  scope: outside mine (<owner track, or nobody>) | mine but outside this task
  severity guess: live exposure | latent | cosmetic
  suggested next step: widen scope | own track | backlog line | investigate first | drop

BLOCKER (anything that stops your own task): tell the user in your own window AND send it to me
in full, at once, then stop until answered. It is not a finding.

REPORT BACK: put the final report in your PR body (no PR: in a new handover file in YOUR
worktree, .claude/handovers/<YYYY-MM-DD-HHMM>-<track>.md), then send me ONE pointer line:
"REPORT: PR #<n> body @<full head sha>" or "REPORT: <absolute path>". The report holds FILES TOUCHED
(every path, in scope or not), evidence (suite counts, what you saw fail before it passed), your
FINDING lines (never live-exposure ones), and your model.

WHEN YOUR SESSION ENDS: keep your worktree while anything in it is unmerged or uncommitted.
```
