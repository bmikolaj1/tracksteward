# tracksteward Q51 + Q50: no partial private name in a printed hit (F2), separator-like entry characters (F6), the pre-push row for message and identity hits (F1)

Date: 2026-11-22. Track Q51, branch `claude/q51-scrub-names`, baseline 9aec33e (0.2.9, #34). Target version 0.2.10.

Notation: this doc never writes a home path with a name after it, a session id or an internal follow-up number in
full, because the scrub gate would refuse it. `/home/<name>` stands for such a path; in the suite the paths are
built from pieces (`'/ho' + 'me/'`), as the existing rows do. All entries are synthetic (`zz...`).

Decisions (the maintainer, 2026-11-22): inline work, then the diff panel (reviewer + adversary + codex-reviewer); F2 trims
the partial word (not the denylist-only extension); no Codex plan review.

## Goal

Close three lines of the 0.2.9 "Still not covered" list, and nothing else (Q47 froze the redaction seam; this slice
stays narrow):

- **F2** a pattern hit's printed text never ends inside a word, so it never prints the start of a private name: not
  where the home-path class stops at a non-ASCII letter or an invisible character, and not where the 80-character
  cut lands inside a word.
- **F6** a denylist entry holding U+180E (Mongolian vowel separator) or a variation selector (U+FE00-FE0F) is found
  when the name is written with an ordinary space, and a text holding those characters inside or between the words
  of an entry still hits.
- **F1 (Q50)** a pre-push row shows that a push refused for a message hit and for an identity hit prints no matched
  text and leaves the remote ref absent.

## Measured (scratch probe, PowerShell 5.1, CLR 4.0.30319, 2026-11-22)

- `[regex]'\s'` does not match U+180E; its category is Format (Cf). `'zzone' + U+180E + 'zztwo' -split '\s+'` is one
  word. NFKC keeps U+180E and U+FE0F (neither is removed by normalising).
- The home-path rule on `/home/<name>` + U+00E9 + `/x` (a synthetic name) matches only up to the accented letter.

## Design

### F2: the printed text never ends inside a word (Find-ScrubHits)

After the cut to 80 characters, look at the character that follows the printed text in the line (the 81st character
of the match when cut; otherwise the character after the match; none at the end of the line). The printed text
"ends inside a word" when that next character is:

- an ASCII letter, digit or `_` (only possible after a cut: every rule's class or literal stops at anything else), or
- any non-ASCII character that is not white space (a letter, a combining mark, an invisible or format character, a
  variation selector: whatever the class stopped at).

Then the run of letters, marks, digits and `_` (`[\p{L}\p{M}\p{N}_]*`) the printed text ends in is dropped. For the
home-path rule that is the name segment after `/home/`; for the follow-up rule the digits; for the session-id rule
the hex digits and the prefix (`_` is a word character). An empty result prints no text, as a blanked hit does.

- `MatchKey` stays the key of the 80-character cut text, taken before any blanking or trimming (the dedupe and the
  placeholder exemption are unchanged: the exemption keys on `MatchKey`, never on `Text`, so a trimmed placeholder
  hit is still let through; the `-History HEAD` run over the real history shows it).
- The denylist checks (`HoldsEntry`, the word check) run on the full match and the cut text, as now. The trimmed text
  is a prefix of the cut text that ends after a non-word character, so it holds no whole word the cut text does not
  (reasoned).
- Why not extend the match and check the denylist: that only blanks names on the denylist; `/home/` + a name with an
  accented letter that is not on it would still print its start. Trimming needs no denylist and fails closed.
- Cost: a hit that stops at a non-ASCII character, or is cut, prints less (for the home rule, only `/home/`). The
  file, line and rule still locate it. Existing row "SG1 the matched text of a hit is cut to 80 characters" (100
  ASCII letters) changes: its cut lands inside the name, so it now prints `/home/`. It is replaced by two rows: a
  cut that lands between words prints exactly 80 characters; a cut inside a word drops that word's part.

### F6: U+180E and the variation selectors (the denylist reader side and the text side)

- Entry side (`Get-ScrubMatchers`, both readings, and `Get-ScrubDenyRegex`): before splitting into words, an entry's
  U+180E is read as a space and its variation selectors (U+FE00-FE0F) are removed. So `zzone` U+180E `zztwo` is the
  two-word entry `zzone zztwo`, and `zzone` U+FE0F ` zztwo` is `zzone zztwo`. A new `Get-ScrubEntryForm` does this,
  called once per entry; the matcher cache key stays the raw entry.
- Text side, folded reading (`$scrubInvisible`): U+180E and U+FE00-FE0F join the characters removed, so a text with
  either inside a word (`zz` U+180E `alpha`) hits `zzalpha`.
- Text side, plain reading (`Get-ScrubWordsRegex`): U+180E joins the separator class between words, so a text with
  U+180E between the words (`zzone` U+180E `zztwo`, which the folded reading glues) hits the two-word entry.
- Not covered, kept as a line: other format characters (U+2061-2064, U+034F, tag characters U+E0000-E007F, U+FE00
  supplement U+E0100-E01EF) are not removed; this slice adds only the two named in the 0.2.9 list.

### F1 / Q50: tests/hooks/prepush.test.ps1 row P26

One commit whose message holds a home-path hit with a synthetic word (`/home/` + `zzq50msg`, a pattern hit, not a
denylist entry, so only the 0.2.9 message redaction keeps the word out), and one clean commit whose author name holds
`/home/` + `zzq50id`. For each push: refused (exit not 0), the remote ref absent, the hook's output holds the hit
line (`commit message <sha7>:1: user home path` / `author of commit <sha7>:1: user home path`) and does not hold the
word. Red check: the row is green on 0.2.9 (the fix landed in #34); its strength is shown by a mutation in a scratch
copy (remove `-NoText` from the message and identity calls) that turns it red, recorded below.

### Panel round 1 (supersedes parts of the F2 and F6 design above)

- F2: the word-run trim left a dotted or hyphenated name's first part, and the next-character test read ASCII
  punctuation (`'`, `%`) and a no-break space as a name's end (reviewer, adversary, measured). The trim now fires on
  any cut and whenever the next character is not a space, a tab, `/` or `\`, and it cuts back to the last space,
  tab, `/` or `\` (`[^ \t/\\]+$`). The claim above that the trimmed text "holds no whole word the cut text does
  not" was false (Codex: an entry ending in a hyphen); the denylist check now runs on the printed text as well.
  The old cut row, and the "cut between words prints 80" guard, change: every home-path cut prints `/home/`.
- F6: building every matcher from the rewritten entry lost an entry whose variation selector and U+180E sit
  between two words, against the same spelling (Codex, measured). Each entry is now matched in both spellings (as
  written, and rewritten; `Get-ScrubEntrySpellings`, one alternation per reading in `Get-ScrubWordsRegex`). A
  spelling with no word builds no matcher; `Get-ScrubEmptyEntries` names such entries, and SG5 fails on one in the
  private denylist.
- Tests: the print helper checks the whole `Format-ScrubHit` line; P26 checks the exact sha7 and that nothing
  follows the rule, and looks for the word in both output streams.

### Panel round 2 (the fix diff)

- F6: folding removed U+180E before matching, losing a name whose words U+180E parts when folding is also needed (a
  fullwidth word, a variation selector before U+180E; Codex, measured; 9aec33e found the fullwidth one).
  `Get-ScrubDenyTexts` folds a text that holds U+180E a second time with U+180E read as a space.
- The round-1 hyphen row did not test the printed-text check (all three, measured). A row with an entry that ends
  in a slash does; it went red with the check removed in a scratch copy.
- SG5's empty-entry row no longer skips when its function is missing; comments narrowed.

### Panel round 3 and the decision: F6 deferred

Round 3 (all three lenses) found nothing new in F2 or P26. In F6 it found a hit 9aec33e had and the change lost (a
fullwidth name followed by U+FE0F and a letter, and three siblings: U+FE00, the selector before the name, a digit
after it), a culture-aware `-ceq` in the spelling compare (PowerShell 5.1 treats a variation selector as ignorable),
a name with U+180E both inside a word and between words (missed on 9aec33e too), and a false sentence in the
round-2 prose (9aec33e did not find the fullwidth two-word case). Each round had found a new defect in the F6 fold.
The maintainer chose (2026-11-22) to ship F2 and Q50 and to defer F6 to a slice of its own: every F6 change is
reverted to 9aec33e's code, and the 0.2.9 F6 line stays in Still not covered. For that slice: keep the 0.2.9
readings unchanged and add the U+180E and selector readings only as extra texts, so no old hit can be lost;
compare spellings ordinally; and start from the cases above.

## Phases (TDD: red row first, recorded, then the fix; as first planned, before F6 was deferred)

1. Rows, red on 9aec33e: F2 stop at an accented letter (single-word entry ending in it and a name not on the
   denylist), stop at a zero-width space, stop at U+180E, cut inside a word, cut between words (guard, green), the
   placeholder exemption still passing (guard); F6 entry with U+180E between words vs a text with a space, entry with
   a trailing variation selector vs a text with a space, text with U+180E between words, text with U+180E and with
   U+FE0F inside a word; the replaced cut row. Record the red count.
2. Fix F2 in `Find-ScrubHits`; fix F6 in `Get-ScrubEntryForm`, `$scrubInvisible`, `Get-ScrubWordsRegex`. Header
   comments of `tests/scrub.test.ps1` updated (the "matched text cut to 80 characters" sentence, the readings list).
3. Q50 row P26 in `tests/hooks/prepush.test.ps1`, plus its header line; mutation red in a scratch copy.
4. CHANGELOG 0.2.10 (move the three closed items out of the 0.2.9 Still not covered list), README if it states the
   cut, version bump in `.claude-plugin/plugin.json`.
5. Diff panel (reviewer + adversary + codex-reviewer on the maintainer's pick), fix-diff panel per house rule (3).

## Verification

- `tests\scrub.test.ps1` alone with the private env set, and with `-History HEAD`; `tests\hooks\prepush.test.ps1`.
- Full `tests\run.ps1` once, on a HOST slot from the coordinator.
- Baseline counts recorded before Phase 1 (scrub on 9aec33e).

## Files (all in the brief's scope)

`tests/scrub.test.ps1`, `tests/hooks/prepush.test.ps1`, `CHANGELOG.md`, `README.md` (only if it states the cut),
`.claude-plugin/plugin.json`, this plan.
