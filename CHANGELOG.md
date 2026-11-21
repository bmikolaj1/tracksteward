# Changelog

## 0.2.8 - 2026-11-21

- **A pattern hit in an annotated tag's own name prints no matched text** (F3, the line 0.2.6 and 0.2.7 listed as
  not covered, reasoned there). Measured first, in the suite: a tag named with a follow-up number, scanned by
  `Invoke-ScrubHistory`, kept the name's text in its hit. A history run prints a pattern hit's text in its FAIL
  detail, which the pre-push gate shows (read from the code, not measured through the hook). Since 0.2.6 a file
  name or a pushed ref name keeps no matched text, because that text is part of the name; the tag object's
  `tag <name>` header now goes the same way. The sibling sweep of the tag headers found one more: the embedded tag
  inside a commit's `mergetag` header has its own `tag <name>` line, and printed it too (measured the same way).
  Both now keep no text. The other tag headers (type, gpgsig, an unknown key) keep their text: they are not the
  name. A pattern hit whose matched text holds a whole denylist entry already kept no text, so neither leak could
  print a whole entry.

  New SG6 rows: a pattern hit in an annotated tag's own name, and in a mergetag's embedded tag name (both seen red
  before the fix, the name's text printed, and green after); and a pattern hit in a gpgsig header of a tag and of a
  mergetag, which keeps its text (seen red with the switch set for every header).

  Still not covered:
  - a message keeps its text, so any name a message quotes prints its matched text: git's own merge messages
    quote one unless the message is edited (`Merge tag '<name>'` for any tag merged, `Merge branch '<name>'`, and
    `of <url>` after it from `git pull`), and a file name quoted in a message prints the same way (0.2.6 redacted
    only the names themselves). The panel saw the tag message, for an annotated and a lightweight tag, in a
    scratch repo; the branch and pull messages are reasoned, not measured; that the hits keep the text is read from
    the code, not a suite row;
  - a pattern hit in an author, committer or tagger identity keeps its matched text (an identity is scanned as
    text, not as a name; reasoned, not measured);
  - a pattern hit whose matched text holds part of a multi-word denylist entry, but not the whole entry, keeps its
    text (reasoned, not measured);
  - `-PushRefs` is still an argument (as in 0.2.6).

- **An annotated tag named inside `a..b` or `a...b` is read as a tag** (F6, found by the panel of the F3 work).
  The tag walk skipped every revision that held `..`, so `-History origin/main..<annotated tag>` read none of that
  tag's headers, tagger or message (seen: 0 tags read). It now reads the positive ends: the right side of `a..b`
  and both sides of `a...b`, an empty side read as HEAD (HEAD can be a symbolic ref to a tag). The revision is split
  at the first `..`, a `...` when a `.` follows, and only when both sides resolve as commits (`<side>^{commit}`,
  the hint git gives a range side, so an ambiguous short sha still resolves: measured by hand on a scratch repo
  whose commit and blob share a 4-digit prefix, where the first split failed discovery on `<prefix>..HEAD`; no row,
  since building such a collision in the suite is slow); otherwise the revision is walked whole, which reads a
  message search that holds `..` but whose split does not resolve (`:/dots..here`) as git does. A reason names a side as
  `revision <n> (left side)` or `(right side)`, never by its text. The pre-push gate was not affected: it passes
  `<tip> ^<sha>`, not `a..b`. New SG6 rows, seen red before the fix and green after: a tag at the positive end of
  `a..b` and on either side of `a...b` is read and its message hits (0 tags on each form before); and a tag reached
  through an empty side while HEAD is a symbolic ref to it, and a message search that holds `..` (0 tags, and a
  discovery failure, with the first split; panel round on the F6 fix).

  Still not covered (the seam is frozen: three panel rounds each found a defect in the previous fix. The first was
  a silent miss, the empty side under a symbolic-ref HEAD, fixed above with its row. The second and third were
  discovery failures, never a pass. The maintainer chose to freeze it here):
  - a range git splits but this check does not, because `^{commit}` changes the side or the side is not a commit,
    fails discovery instead of being read: a message-search side (`:/alpha..b`, seen by the panel in a scratch
    repo), a path side (`HEAD:x..b`, reasoned) and a tree side (`<tree>..b`, seen). A failed discovery refuses the
    run; it never lets a range through;
  - a side whose text with `^{commit}` appended names some other object (a file literally named `x^{commit}`) is
    split where git would not; the split ends are walked in place of the whole revision (reasoned).

## 0.2.7 - 2026-11-21

- **The scrub suite's reasons never quote git's stderr** (F2 of the 0.2.6 work). When a git call failed, the suite
  put git's own message into the FAIL reason unchanged. Six calls did this:
  - `git ls-files` and `git diff --name-only` in the work-tree scan;
  - `git rev-list`, `git rev-parse` and `git cat-file` (twice) in the history scan.

  The pre-push gate prints FAIL details, so any of these could reach the console: a missing folder's absolute path
  (`cannot change to '<path>'`), a ref typed into a range (`bad revision '<ref>'`), the path in a
  `dubious ownership` error, or a remote URL. Two fixture rows (the big range and the undecodable path, SG6) also
  put git fast-import's output into their detail. They now say only whether it printed anything. The repo-sha
  check's `git cat-file -e` uses the same helper for consistency. It could not quote stderr: it takes no stdin, and
  its message is thrown as an error record, which the gate never shows. When git cannot start, the reason names the
  exception's type and Windows error code, not its text: under PowerShell 7 that text names git's path and the
  working directory (reasoned from .NET's message, not measured; the gate runs Windows PowerShell 5.1). git calls
  through `Invoke-ScrubGit` run with `LC_ALL=C` (unless two environment names differ only by case, below), so a git built with translations still prints its messages in
  English and their kind can be named (reasoned, not measured: this host's git prints English either way).

  `Invoke-ScrubGit` now returns git's stderr in a field of its own (`Stderr`), apart from the suite's own error
  text. The new `Get-ScrubGitFailure` builds every such reason from three things: the exit code, the suite's own
  text, and the kind of message git printed, taken from a fixed list:
  - git cannot enter the repository folder;
  - not a git repository;
  - git does not trust the repository's owner (safe.directory);
  - permission denied;
  - a corrupt or unreadable object or index;
  - a revision git cannot resolve;
  - git printed no message.

  Any other message is not printed; the reason says to run the command by hand to see it. A wrong kind is only a
  wrong hint, never a leak, but the panel rounds narrowed it:
  - The kind is read from git's `fatal:` and `error:` lines only, so a warning before them (an unreadable
    attributes file) does not decide it.
  - The names git quotes are taken out first, so a quoted folder path that holds another kind's words does not
    pick that kind, unless the name itself holds a quote.
  - Every phrase has a space ("corrupt" only as "is corrupt" or "corrupt loose"). A ref name holds no space, so an
    unquoted one cannot pick a kind.
  - The cause is matched before the symptom. An unreadable or empty object file reads as permission denied or
    corrupt, not as the `fatal: bad object <sha>` line git prints after it (seen in real `git rev-list` output); so
    does an object file git cannot open for another reason (a unit case, not seen in real output). A parent git
    cannot traverse (`Failed to traverse parents`, seen in real output) is named as corrupt or unreadable.
  - `LC_ALL=C` is set only when no two environment names differ only by case. On .NET Framework, copying such an
    environment throws halfway and would leave git a partial one (reasoned from the reference source, not
    measured). With such names, git inherits the environment unchanged.

  New rows, all four seen red before the fix and red again with the stderr appended back:
  - SG4: a missing folder, and a folder that is not a repository, both at a path that holds the entry;
  - SG4: `Get-ScrubGitFailure` on each kind of message, on an unknown message that holds a URL, on no message, and
    on the suite's own error. The panel rounds added cases that each mutation of the classifier turns red:
    - quoted names left in (a folder path and an ambiguous argument that hold an earlier kind's words);
    - warning lines read too (a permission warning before a bad revision and before a corrupt object);
    - a bare "corrupt" (an unquoted object name that holds it);
    - the revision kind matched before permission and corrupt (git's real output for an unreadable and for an
      empty object file);
  - SG6: a range with a ref that holds the entry and does not resolve.

  Codex review (balanced, gpt-6.2-sol at medium), 3 SHOULD-FIX, all fixed:
  - stderr with only warning lines no longer lets a warning pick the kind; it is "not printed" (a unit case, seen
    red with the old fallback);
  - the new rows' FAIL details print what each check found (the kind named or not, each forbidden text present or
    not), never the reason they check, so a regression cannot print what it leaked;
  - the fast-import details go through one helper, `Format-ScrubFixtureOutput`, with a unit row (seen red with
    the helper echoing its text). Restoring the raw output at a call site would still pass: no row forces a
    fixture failure through the hook (accepted, test diagnostics only).

  Still not covered, as in 0.2.6:
  - an annotated tag's own name, read in its header block, still prints a pattern hit's text (reasoned here, not
    measured; 0.2.8 measured it and fixed it);
  - `-PushRefs` is still an argument.

## 0.2.6 - 2026-11-21

- **Pre-push gate: the range goes on stdin.** The hook passed every commit the remote advertises as `^<sha>` on the
  command line, to `git rev-list --count` and to `powershell.exe -History`, so a remote that advertised about 760
  commits (a busy GitHub repo's `refs/pull/*`) passed the Windows command-line limit and every push was refused. The
  hook now writes the range one revision per line to `git rev-list --count --stdin` and to the scrub suite's new
  `-HistoryStdin` switch. `Invoke-ScrubHistory` hands the revisions to `git rev-list --stdin`. A revision that starts
  with `-` is refused before git runs, because `--stdin` reads pseudo-options such as `--all`. `Invoke-ScrubGit` takes
  a stdin text. Under Windows PowerShell 5.1, .NET Framework's `Process.Start` writes the console input encoding's
  preamble into a redirected stdin. Under a UTF-8 code page that is a BOM, which git would read as part of the first
  revision (seen: `fatal: bad revision` on every SG6 row). So the input encoding is swapped for
  one without a preamble while git starts, and a git that cannot be started that way does not run. A `-HistoryStdin`
  run with no revision on stdin is a FAIL, and so is one with `-History` as well. The suite's labels and reasons never
  quote the range: they say how many revisions it holds and name a revision by its position (`revision <n> of the
  range`), so a failing gate prints neither thousands of shas nor a ref name typed into the range (git's own stderr,
  quoted in a reason, still can). The write of git's stdin is bounded by the same deadline as the process, so a git
  that never reads it is stopped (reasoned, no row: no git command stays alive without reading its stdin).
  New rows: SG6, a range of 1101 revisions (46240 characters); P21, a clean push to a remote that advertises 1100
  more commits; S4 and S5; and an SG6 row that reads a range on stdin under a console input encoding that writes a
  BOM (seen red with the swap removed). Still an argument: `-PushRefs`, so a push of so many refs that their names
  pass the limit is refused (reasoned, no row).

- **The gate's own lines and the suite's file labels print no private path or ref name.** The scrub suite named a
  file by its path in every hit label and in its NUL, unreadable, skipped and index-version lists, and the hook named a ref by its name in its deletion and
  refusal lines and printed the absolute path of its checkout. A path or ref name that holds a private name was then
  printed on the console the gate runs on. Now a file is named by its path only when the path itself has no hit
  (denylist and pattern rules: the check that decides whether it ships; with no denylist, only the pattern rules,
  and a history run then fails anyway) and holds no U+FFFD (a byte that is not valid UTF-8 reads as one, and the
  check cannot see through it). Otherwise it is named as its file-name hit already was: `listed entry <n>` in the work tree,
  `blob <sha7>` in the history. The hook names a ref by its position (`pushed ref <n>`, the same number the suite's
  `pushed ref name <n>` uses; `deletion <n>`). Its closing refusal line names "the checkout this hook's suite lives
  in" instead of a path. Of a failed run the hook shows only the FAIL lines and the indented detail lines right after
  each: it used to show every indented line, so an error record's `    + CategoryInfo` line, which can name an
  absolute path, was shown too. When the run printed no FAIL line, the hook no longer shows its last 20 lines; it says
  so and how to run the suite by hand. git's own push output still names the refs. Not covered: a discovery reason
  in a FAIL detail quotes git's stderr as it is, which can name a path (a "dubious ownership" error names the
  repository's; a follow-up). New rows: SG4 and SG6, a NUL file, an unreadable file, a skipped entry, an index version and a content hit
  at paths that hold the entry, plus clean paths still printed, and a path with an undecodable byte (SG4 unit, SG6
  history); P1, the refusal names no checkout path; P22, a deletion; P23, a tag on a blob and a forced push over an
  unseen commit, to refs whose names hold the entry; P24, a suite that fails with no FAIL line (its file missing);
  P25, a suite that stops on an error record, alone and after a FAIL line with its detail (Codex round 1:) an SG4
  row for an index version git cannot read at such a path (seen red with the label reverted to the path), and SG6
  rows for a range label and a blob-revision reason that hold the entry; (Codex round 2:) a pattern-rule hit in a
  file name or a pushed ref name no longer prints its matched text, which is part of the name (SG4 and SG6 rows,
  red before; not covered: an annotated tag's own name, read in its header block, still prints a pattern hit's
  text, as every header does; reasoned, not measured; reproduce before fixing (0.2.8 measured it and fixed it); a
  denylist hit never prints its text anywhere), and the big-range rows (SG6, P21) use a chain of 1100 commits, so
  only the last exclusion keeps the count at 1, and P21 also refuses a commit with the entry at that scale.

- **Pre-push suite: a push from a linked worktree under the absolute `core.hooksPath`** (the README setup; F6 of the
  0.2.5 review). New row P20: a worktree whose branch has no `.githooks` of its own pushes with `core.hooksPath` set
  to the main checkout's absolute `.githooks`. A commit with the entry is refused by the main checkout's hook, and a
  clean push is scanned and pushed. It was green on arrival: no defect.

## 0.2.5 - 2026-11-19

- **History rewritten (2026-11-19)**: four commits of 2026-10-30 to 2026-11-03 held private wording in three files
  (two plan docs and a test fixture), which a later commit had already replaced at the tip. Those four commits now hold
  the replaced wording, and nothing else changed in any commit: same messages, authors and dates, and the tip tree is
  byte-identical. Every commit from `9283e47` (was `806ecb8`, "tracksteward 0.2.1 (#11)") on has a new sha, the 20
  GitHub-signed ones among them lose their signature, and the tags `v0.2.3` and `v0.2.4` were moved to the new commits
  (same tag messages). A clone from before the rewrite needs `git fetch --force --tags` and a reset or rebase of local
  branches onto the new `main`. The full-history scrub (SG6 over all of `main`, private denylist set) is green on the
  new history: 136 passed, 0 failed. Pull-request refs on GitHub (`refs/pull/*/head`) are read-only and still point at
  the old commits.

- **Scrub: an absent denylist is UNCHECKED for others, FAIL when the variable is set and in the release gate.** The
  private denylist is not in this repo, so a clone without it used to fail `tests\scrub.test.ps1` outside GitHub Actions
  (seen on a fresh clone: 12 of 13 suites passed). Now an absent denylist (variable unset, file missing or empty) is a
  FAIL when `TRACKSTEWARD_SCRUB_DENYLIST` is set to anything (a broken setup) and in every `-History` run (the release
  gate, `TRACKSTEWARD_SCRUB_HISTORY` included, and the new pre-push gate); otherwise the denylist rows print a loud
  `UNCHECKED: ... NOT CHECKED: denylist absent ...` line, not a pass, and `-Strict` still makes that a FAIL. A shell
  without the variable reads UNCHECKED too, the maintainer's included. CI is unchanged in effect (it sets neither the
  variable nor a range). New SG2 rows pin the three cases; the unset-variable row was red before. The pre-push suite
  runs the copied scrub suite as a process for the three cases too (S1-S3: exit 0 with the NOT CHECKED line, exit 1,
  exit 1).

- **Scrub: a -History run reads more, and lets nothing through unread.** In a `-History` run a blob with NUL bytes and
  no BOM (a UTF-16 file without one), and anything git could not read (a blob, a tree, a commit message, a commit's
  identity lines), is now a FAIL; it was an UNCHECKED line, so a gate run passed it. Commits and tags are read as
  stored (`git cat-file`, and every scan git call passes `--no-replace-objects`, so a `git replace` ref no longer
  makes the scan read a clean stand-in while the push sends the original): the message as a file is read (a NUL byte
  in it is a FAIL), and when an `encoding` header names another encoding than UTF-8, git's re-encoded reading (`%B`,
  asked for in UTF-8, so `i18n.logOutputEncoding` does not change it) is read as well: a false header does not hide a
  name, nor does a true legacy one git can convert (a header git cannot convert, such as one with a CR or a trailing
  space after the name, or UTF-7, can still hide one; crafted only). The history scan now also reads: file names (once
  per path, the hit named by its blob, never by the name); author and committer lines as identities and every other
  commit header as text, a `gpgsig` signature header included, but for the sha a `tree` or `parent` line starts with
  (only that sha is skipped: text after it and a continuation line are read); a `mergetag` header's tagger line as an
  identity and the rest of it as text, its `type` and `gpgsig` lines included, but for the sha its `object` line
  starts with; annotated tags in the range (every header, an extra header's key included, `type` and a `gpgsig` one too, but for
  the sha the `object` line starts with; the tagger line and the message, a signed tag's PGP block in it included; a tag chain is
  followed by each tag's first `object` header, as git follows it, and a tag that does not end on a commit fails
  discovery); and, with `-PushRefs`, the ref names a push
  writes (parted at ASCII spaces only, so a no-break space inside a ref name stays inside it). A hit in a header is
  named by its header block (`commit headers of <sha>`, `tag <sha> headers`), never by a key the object chose (only
  fixed words such as `author of commit`), which can hold the entry; a pattern-rule hit whose matched text holds a
  denylist entry (a `/home/<name>` path) is reported without its text. Hits that share a place (label, line, rule and text) are merged, so a hit two readings find is one hit;
  header hits are numbered by line within their header's text, and a re-encoded message's hex tokens may be counted
  twice for the commit-sha rule. When a
  commit's or tag's header block is not valid UTF-8 it is read as Windows-1252 too, as a whole, so a valid non-ASCII
  allowed identity in the same block also gets a Windows-1252 reading that is not allowed (a false refusal, not a
  miss). The range may be several revisions parted by spaces
  (`<tip> ^<sha> ...`), and `-AllowEmptyRange` lets a range with no commit through discovery (a tag or a ref name pushed
  alone). The work-tree scan (SG5) reads file names too, named by their position in the listing.

- **Scrub: allowed identities.** Every commit's author and committer line carries a name, and the maintainer's public
  author name holds a denylist entry on purpose. An identity line (`Name <email>`) that is exactly (ordinal, character for character) one of the lines of
  the private file `TRACKSTEWARD_SCRUB_ALLOW_IDENT` names is let through; every other identity line is scanned like any
  text, so a commit made with a personal name or email fails. The identity is everything before the trailing time
  and zone, so text between the `>` and the time is part of it. Unset: every identity line is scanned and none is let
  through. Set to a missing or empty file: a FAIL. The file is private and lives outside this repo, next to the
  denylist.

- **Scrub: a name wrapped across lines, other Unicode forms and ANSI text.** The denylist used to be matched line by
  line, so a two-word name hard-wrapped onto the next line was missed. It is now matched over the whole text, the words
  of an entry parted by any run of white space, comment markers (`# > * / ;`) and the joiners `- . _ ,` (an email local
  part, a snake_case name, a "Surname, Given" list), at most one hit per line and entry; words run together (CamelCase)
  are not matched. Each text is matched twice and the hits joined: as NFC (a letter written with a combining mark
  matches its one-code-point form), and as NFKC with U+200B to U+200D, U+2060, U+FEFF and the soft hyphen removed
  (fullwidth letters match ASCII; a name split by one of those characters hits). The folded reading only adds hits:
  folding alone would glue a name to the next word (a superscript two, a trade mark sign). Other invisible
  characters (LRM, RLM, U+2061 to U+2064) are not removed. A file that is not valid UTF-8 (an ANSI file) is read as Windows-1252 as well; a denylist hit found in
  both readings is reported once (a pattern-rule hit whose matched text differs between them, twice).

- **Pre-push gate**: `.githooks/pre-push` runs `tests\scrub.test.ps1 -History` once per push, over the pushed tips
  minus every commit the remote advertises (`git ls-remote` on the push URL) that this clone has, with the pushed ref
  names (`-PushRefs`). So a private name in a commit message or header, an author or committer line, a file name or
  any file version those commits add or change, in an annotated tag or in a pushed ref name refuses the push before it
  leaves the machine. Any failing row of that run refuses it, and so does a missing denylist; that includes a work-tree
  row (SG5), which reads the files of the checkout the hook's suite lives in (for a worktree push under the absolute
  `core.hooksPath`, the main checkout, not the worktree). Refused before any scan: a ref on something that is not a commit (a tag on a blob), and a forced push over
  a remote commit this clone does not have (fetch first), and a push URL that `url.*.insteadOf` would rewrite for
  `ls-remote` (the advertisement would come from another remote). The hook's own git calls ignore replace refs too. A
  deletion is not scanned. The local tracking refs are not
  used: a stale `<remote>/HEAD` (a remote rewound behind it, as after this release's history rewrite) would hide the
  commits the remote no longer has. UNCHECKED lines of the run are printed on success too; when the run fails without a
  FAIL line, its last 20 lines are printed. On only where `core.hooksPath` names the `.githooks` folder (see the README:
  the absolute path of the main checkout's folder, so a worktree is covered too); `--no-verify` skips it; Windows only
  (it starts `powershell.exe`); about 20 s per push here, and no timeout of its own. New suite
  `tests/hooks/prepush.test.ps1` (P0-P19, S1-S3, real pushes into a bare repo from a copy of the repo with a throwaway
  denylist). Seen red: the hook absent (P0-P7, before it existed); the first version of the hook on P5, P8, P9, P10 and
  P11; the second on P16 and P17, and its scrub suite on the new SG2 joiner and NFKC rows and the SG6 rows for a tag
  read twice, an extra commit header, a NUL in a message, Windows-1252 identity and tag text, text after an allowed
  identity and a replace ref; the third's scrub suite on the plain-reading SG2 row and the SG6 rows for a true legacy
  encoding, a mergetag tagger (allowed and not) and a continuation line under `parent`; the fourth's scrub suite on
  the SG6 rows for text after the sha on a mergetag `object` line and a continuation under it, a mergetag `type` and
  `gpgsig` line, a commit `gpgsig` header, a tag `gpgsig` header, `%B` under `i18n.logOutputEncoding` and a tag with
  a second `object` header (the walk followed the last one, so the tag git follows was never read); after the Codex
  review and its fix-diff panel, the SG6 rows for a path that differs from the self file by a soft hyphen (its
  pattern rules were skipped), an extra tag header's key (not read, and printed in the hit label), a pattern-rule hit printing a denylist entry in
  its matched text (Codex round 2), an identity that
  differs from an allowed one by a soft hyphen (allowed by the culture-aware `-ccontains`) and a pushed ref name with
  a no-break space (parted there). Mutations
  seen red: the hook ignoring a failed scan (P1, P2, P4, P7), a `-History` run no longer requiring the
  denylist (SG2, P4), the end dedupe of history hits removed (SG6), the hook reading only the first pushed ref (P12), the fetch-first check removed (P13), an
  identity allowed by its name alone (SG6), the tag type check removed (SG6), no Windows-1252 reading (SG4), no NFC
  normalisation (SG2), and history file names not scanned (SG6). Not covered by a row (reasoned): a remote that
  advertises so many commits (about 760, which a busy GitHub repo's `refs/pull/*` can reach) that the range passes the
  Windows command-line limit (the hook's own `git rev-list` fails first and the push is refused, for good, until the
  range is passed another way); an `ls-remote` that fails (refused); a host whose read path lags its write path (a
  replica could advertise a commit a rewind removed); grafts (the push then fails the remote's connectivity check);
  a tree, parent or object line whose sha is in upper-case hex (git accepts it; the scan reads the whole value as
  text, and a tag whose object is written so fails discovery: a false refusal of a crafted object, accepted); a
  signature's base64 that happens to spell a short denylist entry as a whole word (a false refusal, not seen in the
  real history); a header key that differs from a known one only by a character PowerShell's culture-aware `-ceq`
  ignores (a soft hyphen), which is then read as that header (crafted only); a commit sha of a listed repo in a tag name
  (names take no hex tokens); file names in bytes that are not valid UTF-8; a range with a submodule change (a gitlink is unreadable, so
  such a push is always refused); a push from a linked worktree under the absolute `core.hooksPath` (the README
  setup; the suite's fixture uses a relative path in one checkout); diagnostics that name what they could not read
  or classify (a NUL, UTF-16, unreadable or skipped file, by its path) and the hook's refusal and deletion lines (by
  the ref name), which print that text on the local console (nothing more is let through: a deletion was never scanned; a
  follow-up); and a stalled
  scan. `.gitattributes` checks `.githooks/*` out with LF.

- **Fix (Q24, F9)**: the SessionStart anchor is no longer dropped when the host is slow. `coord-scope-guard.ps1` refused
  to write the anchor when its stopwatch, which starts on the script's first line and so also counts the stdin wait,
  the JSON parse and the load of `coord-common.ps1`, had passed 1000 ms. On the hosted Windows runner that was 1501 ms
  (run 44333075321, G2-1..G2-3), so a real session on a slow machine would have had no anchor and warned "session
  anchor not written (the 1000 ms budget ran out)". Without an anchor the session is not recognised as a coordinator
  and binds only by cwd. The defect was in the hook, not the test: the write is one small local file that the hook
  cannot bound anyway (only the hooks.json `timeout`, 10 s, covers a stalled open), so the gate protected nothing.
  The gate is removed; the 1000 ms anchor budget now starts when the write begins and bounds only the prune loop
  after it, which has nothing to lose from stopping early. New row G2-33 delays the end of stdin by 1300 ms (a slow
  start, no seam in the hook) and was red before the fix (seen: "budget ran out" warning, no anchor). The prune bound
  itself has no row (it would need a large sessions folder): UNCHECKED. A side effect: on a slow host the prune now
  gets its full 1000 ms after the write (it used to stop at once), so a slow SessionStart with a large sessions folder
  can take up to about 1 s longer, well inside the 10 s hook timeout. The guard's own 3000 ms budget is the next entry. No change
  under `scripts/**`.

- **Fix (Q24, F11b)**: the same flaw in the guard's 3000 ms budget, found by the sibling sweep after run 44367315654
  (G10-15 timed out at 5972 ms on the runner). The guard's stopwatch also started on the first line, so a slow start
  (stdin wait, JSON parse, `coord-common.ps1` load) could use the budget up before any ledger or git work, and the
  guard allowed with "timed out ... this edit is NOT guarded" where it owed a block: a fail-open on a slow host. The
  stopwatch is now restarted once the event is read and `coord-common.ps1` is loaded, so the 3000 ms bounds the guard's
  own work; the part before it is bounded only by the 10 s `hooks.json` timeout, so the restart is capped (budget
  `min(3000, 8500 - that time)`, at least 500 ms) and a slow start usually ends in the timeout warning inside the 10 s
  (about 1.5 s are left for start-up, kill and output; a stall past about 9.5 s before the guard is still a silent kill
  by the harness; the cap has no row: UNCHECKED). Where the time went in run 44367315654 is not known from the
  log line (5972 ms is only when the budget was found spent); G10-16 simulates the stdin wait. New row G10-16 (stdin ends 3500 ms late, an
  out-of-scope edit) was red before: allow with the timeout warning, no block. The other budgets (per-git
  `min(2000, left - 500)`, the reader `-TimeoutMs` values, the 200 ms append skip) run on the same stopwatch and now
  count only the guard's work. A host so slow that the work itself passes 3000 ms still gets the documented timeout
  warning (fail-open by design, G9-6..G9-15).

## 0.2.4 - 2026-11-18

- **Fix (Q19, F5/F6)**: the two reads Q16 left unchecked now refuse a link at the ledger path: `coord-handoff.ps1`'s
  re-read after the fetch, and the compare inside `Write-CoordLedgerSwap` (before every try, so `coord-set`, `coord-log`
  and `coord-handoff` all get it); the swap returns `failed` and removes its temp file, the ledger is untouched. Tested
  through the `Get-CoordLeafAttributes` seam (a file symlink cannot be created without elevation on this host); the
  handoff re-read has no row of its own (the script runs as a subprocess, no seam): UNCHECKED. F6 decided, not
  changed: every reparse point, a cloud placeholder and a scratch `-Ledger` included, stays refused (fail closed; the
  real ledger normally lives in the main checkout, and a refusal names the cause). The F6 rows test the predicate, not
  the swap: it flags a real junction (UNCHECKED where `mklink /J` fails), and it flags the attribute values 0x401620 and
  0x420. Those two values come from the panel adversary's reading of a dehydrated and a hydrated OneDrive file on this
  host (its report; the author did not reproduce it); no row touches a real OneDrive path. If that reading is right, a
  scratch `-Ledger` in a synced folder is now refused: a behaviour change, kept on purpose. The swap row pins the refusal
  before the replace, not the exact place of the check in the retry loop, and the check is not atomic with the open that
  follows it (a link swapped in between is still followed).

- **Fix (Q16, F2)**: five scripts opened a ledger with no link check on its path (`prune-scan`, `coord-brief`,
  `merge-verify`, `repo-snapshot`, `slot-check`; found by reading, then confirmed by grep: none of them called a
  reparse-point test on the ledger, and `coord-brief` reached its trust check, which has one, only in `-Check`, after its
  first read). `Test-CoordLeafIsLink` (the leaf's own attributes, read before the ledger is opened or read;
  `Test-CoordLedgerTrusted` uses it too) now runs in `Read-CoordLedgerTracks`, `Read-CoordLedgerTracksBounded`,
  `Read-CoordLedgerFile` and `coord-brief.ps1`'s own read. So the five refuse a symbolic-link ledger, and so do
  `coord-status`, `coord-set`, `coord-log` and `coord-handoff`, whose first read goes through `Read-CoordLedgerFile`
  (the panel found those four; two later reads of the file, `coord-handoff.ps1`'s re-read and the swap's compare, are not
  checked and only follow a refused first read). The full trust check is NOT used: a scratch `-Ledger` stays allowed. Only
  the leaf is checked, not the folders above it, and `Test-Path` still stats the link's target first. Any reparse point is
  refused, not only symlinks: a ledger in a cloud-synced folder (OneDrive placeholders carry the attribute) would be too
  (by reasoning, not tried here). Tests fake the attribute read (`Get-CoordLeafAttributes`); no row creates a real file
  symlink here (UNCHECKED) and no script-level row runs a link ledger. Mutation: see the PR body.
- **Fix (Q8, F47 follow-up)**: the three same-class gaps the entry below left open.
  - A denied LEDGER: `Test-CoordLedgerTrusted` asked `FileInfo.Exists` and said "no ledger file there" (measured: an
    `icacls` deny on the file and its folder hides it). The open decides now (`Get-CoordFileState`): a ledger that cannot
    be opened is not trusted, with `Unreadable = $true` and "cannot read the ledger <path>"; a missing file or a
    folder keeps the old message. The scope guard used to skip an untrusted ledger silently; it now warns
    `ledger <path> skipped: cannot read ...` for an unreadable one (a ledger held with no sharing is warned about too, now
    with this trust-stage reason, not the read error; no test stages it), and `coord-brief.ps1 -Check` refuses with that
    reason (by reading, not pinned by a test). The ledger file's reparse-point check runs before the open, so a link at the ledger
    path is not followed by it (one open of a link target could block on a network path; a link in a folder of the path
    is still rejected after the open, and when the attribute read itself fails the check after the open is the only one); the symlink rows are UNCHECKED
    where a file symlink cannot be created.
  - A denied ANCHOR file: `Read-CsgAnchorFile` asked `File.Exists`, so a denied anchor was silently absent and the session
    bound by its cwd alone (measured by the same deny). Only a not-found open is absent now; any other failure warns
    "session anchor <path> could not be read" (a folder at the anchor path warns now; it was silent).
  - `Register-CoordLedger` asked `File.Exists` of its index: an index it cannot open now refuses ("cannot read the ledger
    index <path>; nothing was appended") instead of reading it as empty. The deny that hides the index also denies the
    append on this host, so the pin is an index path that is a folder (red before: "cannot update").
  Pinned by `tests/scripts/coord-common.test.ps1` C16/C18 and `tests/hooks/coord-scope-guard.test.ps1` G13; the rows
  that stage a deny need an `icacls` deny that hides the file from `File.Exists` and are UNCHECKED where it does not.

- **Fix (Q61, ledger F47)**: an index this user cannot read is no longer read as "no index".
  `Get-CoordIndexedLedgers` tested the path with `File.Exists`/`Directory.Exists`, which can be false for a denied file
  (an `icacls` deny on the file and on its folder gave `Ok=True Missing=True Entries=0`), so the scope guard saw no
  ledgers instead of failing closed. The open now decides: only a not-found failure is `Missing`; a denied index, or a
  path the open rejects (an empty one included), is `Ok=$false` with the error. Effects:
  - the scope guard warns that today's index was skipped (it allowed silently), and now does the same for yesterday's
    index; it also writes a SessionStart anchor when an index exists but cannot be read (it wrote none: both gates
    asked `File.Exists`). New `Get-CoordFileState` (`present` / `missing` / `unreadable`, by the open) serves those gates;
  - `prune-scan.ps1` is COULD NOT CHECK for a denied index (the header's "Not covered" note is gone);
  - `coord-brief.ps1 -Check` refused before and still does (its message changes: the error, not "not among the ledgers").
  Closed in Q8 (below): the three same-class gaps this entry listed as not covered.
  Pinned by `tests/scripts/coord-common.test.ps1` C16, `tests/hooks/coord-scope-guard.test.ps1` G12 and
  `tests/scripts/prune-scan.test.ps1` F38. The rows for the fixed behaviour were seen red against the old code; the
  `Register-CoordLedger` row, the missing-folder row and the deny-removed and control rows (C16, G12-5, F38 "ACL
  restored") are pins that were green before. The rows that stage a deny need an `icacls` deny that hides the file from
  `File.Exists` and are UNCHECKED on a host where it does not.
- **prune-scan** (new): `scripts/prune-scan.ps1` prints one `SAFE (<evidence>)` or `KEEP <reason>` line per
  worktree, local branch and origin branch of the repos it is given, and a last `PRUNE-SCAN: <n> SAFE,
  <m> KEEP` line (exit 0, 1 an apply failed, 2 could not check). A branch is SAFE only with a merged,
  same-repo PR whose head is the tip and that went into origin's default branch, no open PR, no live
  ledger row naming it and no worktree holding it; a worktree only when clean, unlocked, with no
  session inside and no ignored file beyond build caches, the two files Flutter regenerates and
  unchanged `.worktreeinclude` copies (any other ignored file, such as `_inbox/`, `CODE-REVIEW.md` or a
  `pubspec.lock` outside the build caches, is KEEP). A live ledger row of yesterday stops protecting once today's
  ledgers have a MERGED or DONE row for the same Track and Repo. Without `-Apply` the only thing it changes is what
  `git fetch --prune` and a fetch of origin's default branch by name bring in (git runs with optional locks off, so `git status` does not refresh a worktree's index); `-Apply` removes the SAFE items only, one destructive git call each, and is
  refused off Windows (exit 2). A worktree git removes except for an empty folder a process holds
  (git exit 255) counts as removed; a folder that still holds a file is FAILED. The skill's start-of-window
  step 4 and the README's script list describe it.
- **prune-scan** (F37-F39), three fixes to the item above before it ships:
  - `-Apply` re-reads the worktree list right before `git worktree remove`: a worktree that is no longer on the
    branch and HEAD it was judged on, or is detached, locked or gone from the list, is FAILED
    (`changed since the scan: ...; untouched`) and its branch is skipped, not only a worktree whose files changed.
  - A ledger that exists but cannot be looked at (access denied, say) is COULD NOT CHECK for every repo; it
    used to read as "no ledger", so its live rows protected nothing. A ledger that does not exist is still skipped.
  - Origin's default branch is also fetched by name, so a narrowed `remote.origin.fetch` cannot leave a stale
    `origin/<default>` for the stacked-PR containment check (a branch merged into a stacked base that has since
    reached the default branch was KEEP, and is now SAFE); a failed fetch of it is COULD NOT CHECK.
- **Tests**: `tests/scripts/prune-scan.test.ps1` (210 rows; the access-denied rows are UNCHECKED where
  a deny cannot be staged) runs git for real against a bare origin and the gh stub; the F37-F39 behaviour
  rows were seen red without their fix.

## 0.2.3 - 2026-11-05

Fixes to the scripts, the tests and the docs; no new commands.

- **merge-verify** (F9): after `git fetch --prune origin` the base is also fetched alone by its exact
  name, so a narrowed fetch refspec cannot leave a stale `origin/<base>` to be read; a failed base
  fetch is COULD NOT CHECK (exit 2).
- **coord-status** (F10): a finding is keyed by its id and its carry date (the first `yyyy-MM-dd` in its
  tags). A carried `F3 (2026-10-28)` and today's `F3` list separately and close separately; an undated
  `F3 outcome:` no longer closes a dated carried finding.
- **coord-status -Verify** (F11): a MERGED row whose gh call fails prints
  `unverified: #<n> (gh failed: ...; L<n>)` under DONE instead of nothing.
- **coord-status -Verify** (F25): the 140-character cut of that `unverified:` line falls on the gh error
  text, never on the `L<n>` pointer; a long error (gh not on PATH) used to cut the pointer off.
- **coord-brief -Check** (F12): refuses a brief in which a fixed label has no text after it (on its line,
  or under it up to a blank line or the next label line), naming the labels; a brief cut down to its
  labels used to pass.
- **Tests**: the scope-guard suite no longer fails when a live coordinator or guard writes the real index
  folder (#15); `sessions\` is scanned apart for content naming the run's scratch root.
- **CI**: `.github/workflows/test.yml` runs `tests\run.ps1` under Windows PowerShell 5.1 on pull requests
  and manual runs (#17). With `GITHUB_ACTIONS=true` the scrub suite skips its denylist rows when the
  denylist is absent (UNCHECKED), and `TRACKSTEWARD_SKIP_TIMING=1`, which the workflow sets, skips the
  guard suite's five G9 timing rows (UNCHECKED, not counted as passed). Otherwise an absent denylist
  fails the scrub suite, and the timing rows run unless that variable is set. Issue templates added.
- **Docs**: the skill and the brief template describe the F9-F12 behaviour above; the port plan's note on
  the test fences matches the suites after #15.

## 0.2.2 - 2026-11-03

Fixes the "Known and left" items of 0.2.1; no new commands.

- **coord-status**: only the PR cell names a row's PR; a `#<n>` in the Status text no longer does, so
  put the PR in the PR cell. A row with its PR only in the Status text matches no open Merge slot
  (which then reads BLOCKED, no live row) and reads `no PR`; a MERGED one shows its track name in DONE
  and is not checked under `-Verify`.
- **coord-status**: a repeated finding id is listed once, at its first open line. An inline
  `| outcome: <text>` that ends the line, with text not starting with `PENDING`, closes that finding
  line (so does any such tail, even a quoted one; a pipe after it leaves the line open).
- **coord-log**: `{{now}}` is written as the literal `{now}` (`coord-set` does the same); refuses a BOM
  or bidi mark in its text, as `coord-set` does.
- **Git floor**: `coord-set` and `coord-status` refuse to start on a git below 2.38 when they use git to
  find the ledger (no `-Ledger`).
- **Left as ruled**: `coord-set` still does not refuse a dotted `10.22` (it cannot be told from
  "Opus 4.15" or "git 2.38"); the other limits listed under 0.2.1 stand.
- **Version**: the 0.2.2 fixes merged without the version bump, so `.claude-plugin/plugin.json` and the
  README status line still said 0.2.1; both say 0.2.2 now.
- **Docs**: the skill documents the `{{now}}` escape and the BOM and bidi refusal of `coord-log` and
  `coord-set`. The README states the platform limits in its status block, lists what a first day
  needs, says which releases are tagged, and notes that the scripts and the guard postdate its numbers.

## 0.2.1 - 2026-10-30

Fixes the open items of the 0.2.0 port; no new commands.

- **coord-status**: lists a finding whose id carries a tag or a carry date (`F3 (2026-10-28) from ...`,
  `F22 (coordinator): ...`) and a Queue id with a `(yyyy-MM-dd)` tag; reads the ledger once; lists an
  indented or oddly spaced unticked Owed check; the Queue gate is found after `Owner:`, `owner :`, a
  tab or `source:`; an `[after Q<n>]` gate that names no line, or sits in a cycle, reads `?`; under
  `-Verify` a Repo cell that is not a folder on this machine reads `unknown` (no longer the current
  folder's repository), and a PR gate says which repository was asked.
- **repo-snapshot**: a `-Repos` path that is not a git repo, an explicit `-Ledger` that is missing and
  a `-Base` ref that does not exist each add attention; a finished track whose branch is gone no
  longer does; `-Base` (default `origin/main`) names the base.
- **Git floor**: `coord-brief`, `coord-handoff`, `coord-log`, `merge-verify`, `slot-check` and
  `repo-snapshot` refuse to start on a git older than 2.38 or one whose version cannot be read.
- **coord-handoff**: a `-NewSession` name made only of the Hangul fillers, U+034F, U+FE0F or U+17B5 is refused.
- **coord-log**: expands every `{now}` in its text (as `coord-set` does) and reuses the shared ledger-argument check.
- **coord-set**: refuses a fullwidth-colon time and `10h22`; refuses U+FEFF and bidi marks in a cell;
  `-Repo` matches a bare-name Repo cell by its text.
- **Tests**: the six script suites no longer fail when a live coordinator appends to the real index (their
  fence flags what the run wrote, not every byte; the scope-guard suite still compares the real index byte for byte).
- **Known and left**: in `coord-status` a `#<n>` in the Status text is still taken as the row's PR
  when the PR cell is empty, a repeated finding id is listed once per line, and an inline
  `| outcome: dropped` does not close a finding; `coord-set` does not refuse a dotted `10.22`;
  `coord-log` has no way to write a literal `{now}` and writes bidi and BOM characters as typed;
  `coord-set` and `coord-status` do not check the git floor. Ported as merged upstream,
  with known limits: `-Verify` can ask the current repository when a Repo cell is a relative folder
  name that exists under the current folder, and a UNC Repo cell can block; a Queue item whose text
  contains `Owner:` before its gate loses the gate (reads `?`); the suites' real-index fence flags only
  what names the run's scratch folder (a rewrite of an index file in another text encoding is not seen); the
  test `gh` stub does not record its working folder, so the `-Verify` folder choice is not pinned; the `unverified:` line is cut at 140 characters. More in the
  README, "What is not done".

- **Port notes**: `coord-set`'s Repo-cell path check (`Get-RepoFull`) is stricter than the private source on purpose: it rejects `, ; ( )`, device
  paths and a bare drive root, and accepts `/...` paths off Windows.

## 0.2.0 - 2026-10-29

The mechanical checks are code now. Adds PowerShell scripts and an edit-time scope guard hook, with
tests; the skill calls the scripts for each check, and keeps the manual commands as the fallback
where PowerShell is missing.

- **Scripts** (`scripts/`, run from the plugin folder by the skill):
  - `repo-snapshot.ps1`: a start-of-window snapshot per repo, with each ledger track's files
    checked against its scope and a conflict preview.
  - `slot-check.ps1`: a PR's full head sha, its files outside scope and its checks, ending
    `READY | WAIT | HOLD`.
  - `merge-verify.ps1`: confirms the merge commit on origin, deletes the branch only when its tip
    is still the merged head, and checks the shared checkout and git config.
  - `coord-log.ps1`: appends to the ledger with the clock's time and refuses typed times;
    `-Register` records the day's ledger for the guard.
  - `coord-brief.ps1`: renders a track's brief from the template; `-Check` verifies it before the
    pointer line is printed.
  - `coord-handoff.ps1`: hands the coordinator role to a new session.
  - `coord-set.ps1`: changes one Tracks cell (Status or Model) with a time from the clock;
    `-State <word>` writes a Status cell as one of ten state words.
  - `coord-status.ps1`: the status board over the structured ledger sections (Tracks, Merge slots,
    Owed checks, Findings, Queue); `-Verify` checks what it can against `gh`.
  - The ledger gains a `## Queue` section (work not yet started), which `coord-log.ps1 -Section Queue`
    appends to.
  - `coord-common.ps1`: the shared library.
- **Scope guard** (`hooks/`): a `PreToolUse` hook that blocks an edit outside the scope of the
  session's ledger row. On when the plugin is installed, inert until a ledger is registered;
  `TRACKSTEWARD_GUARD=off` in the environment turns it off (a convenience, not a lock). Windows-only
  as shipped; its limits are in the hook header.
- **Skill and templates**: the skill names the script for each check next to the manual commands;
  the ledger template names `coord-log.ps1` for appends and registration.
- **Tests** (`tests/`): one suite per script and for the guard, a scrub suite for private content,
  and `run.ps1`. They run under Windows PowerShell 5.1.
- **Requirements**: git 2.38 or later; PowerShell. Verified on Windows 11 with Windows PowerShell
  5.1 only. **PowerShell 7, macOS and Linux are unverified.** The git floor is not checked at start (0.2.0 only; 0.2.1 checks it in six scripts).
- **Known and left**: a `-NewSession` name made only of characters that draw nothing (a Hangul
  filler, a variation selector) is not refused. `repo-snapshot` can read a clean repo when a
  `-Repos` path is a typo or an explicit `-Ledger` is missing (`attention none`); a finished track
  whose branch is gone prints `branch not found` on every run; its base is always `origin/main`.
  `coord-status.ps1` does not list a finding whose id carries a carry date, can take a `#<n>` in the
  Status text as the row's PR, and under `-Verify` can ask the current folder's repository about a PR
  of another repository; the Queue gate is anchored on an exact ` owner:`; an `[after Q<n>]` gate that names no line reads CLOSED;
  an indented unticked Owed check is not listed. All are on the 0.2.1 list.

## 0.1.2 - 2026-10-15

Docs only: the skill, the brief, ledger, finding and report templates, and the README. No scripts.

- **Briefs are files.**
  - The coordinator saves each brief in its main checkout's `.claude/coordination/briefs/` and
    sends the track one pointer line, `BRIEF: {absolute path}; reply "ACK {track}" when read`,
    with the path and track name filled in. The file keeps the full text on disk. It does not
    deliver itself or stay fresh, so a missing ACK shows a pointer line that went nowhere, and
    every later message still carries the current sha.
  - In the template, `{...}` slots are the coordinator's to fill before saving (the CROSS-REPO
    block and the SUPERSEDES line are deleted when they do not apply) and `<...>` slots are
    filled when the line is used.
  - The ACK carries the track's model and effort. The coordinator stamps its time from its own
    clock, records `briefed HH:MM, ACK HH:MM` in the Status cell and copies the model and
    effort into the Model cell.
  - Every brief, and every change to one, gets an owed check with a 15-minute ACK deadline, added
    when it is sent. The user is told the deadline, because a session has no timer.
  - A change is appended to the file under a `CHANGES <date> <time>` heading and sent as its own message;
    the track ACKs again, and the change is in force once ACKed.
  - The day's briefs are copied next to the ledger at day close.
- **WIP line.** The brief asks the track for one line in its handover after every review round
  and before any run of an external reviewer: branch, sha, the brief's path, uncommitted files,
  open findings, next action. A session that stops can be resumed from it.
- **Slot wait.** The brief lists the slot wait among its fixed lines (0.1.1 already had the wait).
  - A PR that does not contain the current main now reads WAIT rather than HOLD, and the
    coordinator tells the track at once to merge main and report a new head. BLOCKED while a check
    is pending and none has failed also reads WAIT. Any WAIT standing after about 15 minutes goes
    to the user.
  - A go such as "merge #12 when green" covers the sha of the slot the user was shown, and the
    merge is bound to that sha. The coordinator re-reads the head just before merging; if it
    differs the go is void, and the slot check, a new slot and a fresh go come first. A go typed
    before any slot waits for one. A vague go is no go.
- **Owed checks.** A finding whose outcome leaves work open is ticked only on evidence: for a fix,
  the track's report names it, the PR's file list holds the file and the merge is on origin; for an
  investigation, the named track reports what it measured. If a track merges without the fix, the
  coordinator re-opens the finding as PENDING to the user.
- **Midnight.** The coordinator compares the date on each append to know when it has passed.
  A carried Tracks row or owed check is marked `(from <date>)`, a finding keeps its number with
  its date wherever a carried line names it, and a line carried twice keeps its first date. A
  carried track's brief stays under the old date, and any change to it after midnight is a fresh
  brief that names the one it supersedes. The carry is logged in the new ledger, and the old
  ledger is not edited after it (0.1.1 put the Log line in the old one).
- **Branch deletes.** The tip rule itself was in 0.1.1. New: a branch whose tip has moved past the
  merged head is classified in flight or stale, not merged.
- **Tracks table.** New Model column after Session (model and effort at start, then each switch,
  which the track reports and the coordinator times). The Status cell leads with `MERGED` or
  `DONE` only when the track is finished. Every row needs one cell per column, so a row carried
  from a ledger without Model gets an empty one.
- **Live exposure.** Findings of that severity go to the coordinator privately and at once, never
  into a PR body, a commit message, a report, a WIP line or any other file that is committed or
  posted. A track whose task is such a fix (the brief, the report template and the skill all say so) writes
  its report to a handover file and opens no PR until the user decides. In a public repository a PR body is readable by anyone once it is posted. If one is to
  be fixed, the user decides how and when anything about it is pushed or posted. The day-close
  scrub now covers every section, each brief and each track's handover.
- **README.** The first-day walkthrough and requirements describe the brief file and the ACK.

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
