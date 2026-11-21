# tracksteward 0.2.7: no git stderr in a scrub reason (Q41, F2)

Baseline: origin/main 39fec6e (tracksteward 0.2.6, v0.2.6). Branch `claude/q41-tracksteward-027`.

## The defect

`Invoke-ScrubGit` returns git's stderr in `Error`, and six sites in `tests/scrub.test.ps1` put `Error` verbatim
into a FAIL reason (a seventh, `Add-ScrubRepoShaHits`, throws `Error` but can never hold stderr there: no stdin):

- `Get-ScrubShippedFiles` (ls-files) and `Get-ScrubUnstagedNames` (diff --name-only);
- (`Add-ScrubRepoShaHits`, cat-file -e, thrown: moved to the helper for consistency);
- `Invoke-ScrubHistory`: rev-list, rev-parse, cat-file -t, cat-file tag.

The pre-push hook shows FAIL lines and the detail right after each, so that text reaches the console. git's stderr
can name a path (`cannot change to '<folder>'`, a `dubious ownership` error names the repository), a ref typed into a
range (`fatal: bad revision 'refs/heads/...'`), or a remote URL. This is the same leak class as F4. The hook's
own git calls already send stderr to /dev/null: only the suite's reasons leak.

## The fix

1. `Invoke-ScrubGit` keeps git's stderr apart. `Error` holds only the suite's own text (git missing, did not
   start, timeouts, the stdin write), and the new field `Stderr` holds git's text. The suite's own messages are
   fixed strings, plus .NET exception messages on the console encoding change and the stdin write and close (IO
   texts that name no path); a git that cannot start is named by the
   exception's type and Windows error code (under PowerShell 7 its text names git's path and the working
   directory; reasoned, not measured). git calls through `Invoke-ScrubGit` run with `LC_ALL=C`, so its messages
   are in English (reasoned, not measured).
2. A new `Get-ScrubGitFailure $r` builds the reason tail: the exit code, the suite's own `Error`, and a class of
   git's stderr from a fixed list, never the stderr text itself. The classes:
   - git cannot enter the repository folder;
   - not a git repository;
   - the repository's owner is not trusted (safe.directory);
   - a revision git cannot resolve (bad revision, unknown revision, ambiguous argument, bad or invalid object
     name);
   - permission denied;
   - git reported a corrupt or unreadable object or index.

   Anything else gets "git's message is not printed (it can name a path, a ref or a URL): run the command by
   hand to see it". No stderr reads as "git printed no message".
3. All seven sites use it.

Out of this slice: F3 (an annotated tag's own name in its header block prints a pattern hit's text; reasoned, not
measured). `-PushRefs` stays an argument.

## Rows (RED first)

- SG4: a missing folder, and a plain folder that is no repository, both at paths that hold the test entry:
  discovery fails, the reason names "git cannot enter the repository folder" resp. "not a git
  repository" and holds neither the entry nor the folder path.
- SG6: a range `refs/heads/<entry>-nosuch ^HEAD`: discovery fails, the reason names the class "a revision git
  cannot resolve" and not the entry.
- SG4 unit (`Get-ScrubGitFailure`): canned stderr for each class gives the class and no stderr text; an unknown
  stderr holding a path and a URL gives the fixed "not printed" text and neither; the suite's own `Error` is kept.
- Mutation: `Get-ScrubGitFailure` returning `$r.Stderr` turns the rows red.

## Panel round 1 (reviewer + adversary)

- The class is read from git's `fatal:` and `error:` lines only, with quoted names taken out first (a ref named
  `corrupt-x` was classed as corruption; a warning line could outrank the fatal one).
- Two fixture rows (SG6 big range, undecodable path) printed git fast-import's output in their detail: now only
  whether it printed anything.
- The hook's header comment said a reason could still quote git's stderr: rewritten.
- `cat-file -e` (repo-sha check) never quoted stderr: the CHANGELOG counts six sites, not seven.

## Verification

- `tests\scrub.test.ps1` alone, then the full `tests\run.ps1` on HOST GO.
- The live gate on this branch's push runs the main checkout's 0.2.6 hook; 0.2.7 runs live only after the merge.
- Panel (reviewer + adversary) on the diff, and a fix-diff panel on any fix. Codex only on the maintainer's pick.

## Ship

CHANGELOG 0.2.7, `.claude-plugin/plugin.json` 0.2.7, README if it quotes a reason. The tag and release are the
maintainer's call.

## Fix-diff panel round 2

- Round 1's reorder (revision before permission and corrupt) named a locked or empty object file as "a revision
  git cannot resolve": real `git rev-list` prints `error: ... Permission denied` or `error: ... is empty`, then
  `fatal: bad object <sha>`. The cause now comes before the symptom (permission, corrupt, then revision), and
  "corrupt" is matched as "is corrupt" so an unquoted ref name cannot pick it. Two unit cases from that real
  output.
- Three of round 1's cases passed under the mutation they were meant to catch. They were replaced so that each of
  four classifier mutations (no quote strip, no fatal-line filter, a bare "corrupt", revision before permission)
  turns the row red; all four were run and seen red.
- Setting `LC_ALL` was wrapped in a try (round 3 found that wrong, see below).
- Prose: the PowerShell 7 and LC_ALL sentences say "reasoned, not measured"; the hook comment and the README
  say a failed git call in a reason is named by its exit code and kind, and that no detail quotes git's text.

## Fix-diff panel round 3

- The round-2 try around `LC_ALL` was false comfort: on .NET Framework a failed environment copy (two names that
  differ only by case) leaves a partial dictionary, so git would run with part of its environment. Now `LC_ALL` is
  set only when no two names clash; otherwise git inherits the environment untouched (reasoned from the reference
  source, not measured).
- Corrupt kind also matches `unable to open loose object` (any errno) and `failed to traverse` (a missing parent),
  each with a unit case; the "every phrase but one has a space" wording is fixed.
- Adversary round 3: no BLOCKER or SHOULD-FIX; real-git probes (unreadable or corrupt index, missing tree, missing
  pack, missing parent) all classed right or fall back to "not printed".
