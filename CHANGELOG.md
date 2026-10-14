# Changelog

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
