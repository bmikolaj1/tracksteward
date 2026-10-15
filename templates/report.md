# REPORT BACK shape

The track writes this into its PR body (no PR: a new handover file in its own worktree's
`.claude/handovers/`; also the place for a report on a live-exposure fix, with no PR opened until the
user decides), then sends the coordinator one pointer line:
`REPORT: PR #<n> body @<full head sha>` or `REPORT: <absolute path>`.

```
TRACK: <track> - <one line: what this PR does>
BRANCH: <branch> @ <full head sha>, with origin/main <sha> merged in before this head
FILES TOUCHED:
  <path>   in scope
  <path>   NOT in scope - widen scope recorded as F<n> (or: no ruling yet; this PR will HOLD)
EVIDENCE:
  <suite>: <n> passed, <n> failed (command: <exact command>)
  seen failing before the fix: <test or check>, then passing
FINDINGS: <FINDING lines, or none>
OPEN: <anything not done, or none>
MODEL: <the session's model and effort (or unknown), and any switch you told the coordinator about, so the user knows what produced this evidence>
```

Live-exposure findings never appear here, not even as a mention: they went to the coordinator
privately. List every out-of-scope path anyway, so the coordinator's slot check and the report
agree.
