# tracksteward Q47: no matched text from messages, identities or partial denylist words (F5, F7a, F7b)

Date: 2026-11-22. Track Q47, branch `claude/q47-scrub-redaction`, baseline c30654b (0.2.8). Target version 0.2.9.

Notation: this doc never spells an internal follow-up number in full, because the scrub gate's
`internal follow-up number` rule would refuse it. `<fu>61` below means the two letters, a hyphen and 61; in the suite
it is built from pieces (`'FU' + '-61'`), as the existing rows do.

## Goal

A history scan prints no pattern hit's matched text from a commit, tag or mergetag message, or from an author,
committer or tagger identity. A pattern hit that holds any word of a multi-word denylist entry prints no text
either. The release and pre-push gates, the coord-handoff placeholder exemption included, behave as before.

## Baseline (measured 2026-11-22, c30654b)

- Full suite: CI run 44933428634 on 2a9a4e2 (tree identical to c30654b): 14 suites passed, 0 failed, 11 unchecked.
  CI skips the denylist rows.
- `tests\scrub.test.ps1` locally with the private env set: 211 passed, 0 failed, 5 unchecked (0.6 min).
- The same with `-History HEAD` (whole history): 220 passed, 0 failed, 5 unchecked (1 min).

## Design

This extends the 0.2.6/0.2.8 redaction pattern; it adds no new mechanism.

- `Add-ScrubTextHits -NoText` already blanks names. Apply it to identities (`Add-ScrubIdent`) and to the mergetag body,
  which gets its own label, `message of mergetag in commit <sha7>` (diff panel round 1, B: under the headers' label
  its line 1 merged with a hit on the embedded `tag` header of the same text).
- `Add-ScrubContent` gets the same `-NoText` switch, used for the commit message, the re-encoded (%B) message and
  the tag message.
- All messages, not only git's quoted forms: any free-text message can quote any name, and detecting "quoted" forms
  needs a parser with its own gaps. The cost: a message hit is located by `<sha7>:<line>` and its rule
  (`git show <sha7>`), not by its text. That fails closed.
- Identity labels already name the role (`author of commit <sha7>`, `committer of ...`, `tagger of tag ...`,
  `tagger of mergetag in commit ...`); unchanged.
- A blank `Text` would break the two places that key on it: the dedupe keys (Add-ScrubContent and the end of
  Invoke-ScrubHistory) and the real-history exemption (`$placeholderIds -ccontains $_.Text`). Each hit therefore also
  carries a `MatchKey` (D1), and dedupe and the exemption key on it. `Format-ScrubHit` still prints only `Text`.
  Only `Format-ScrubHit` prints hits (no `Out-String`, `ConvertTo-Json`, `Write-Output` or interpolation of a hit
  object found).
- F7b: besides a whole-entry match, a pattern hit's text is blanked when it holds any single word of a multi-word
  entry as a whole word (built by `Get-ScrubDenyRegex -Plain` on the word, plain FormC and folded readings; each
  reading is split on its own, so an entry that is one word plain and two folded has word regexes in the folded
  reading only, diff panel round 1, A; a plain word made only of an invisible character is counted toward the two
  words, row: the zero-width-space second-word row). Both the whole-entry and the word checks
  run on the full match and on the cut 80-character text that would print (a cut can turn `zzgivenx` into a
  printed `zzgiven`). `Find-ScrubHits` is shared, so this applies to work-tree and index scans as well as history,
  on purpose: a pattern hit's matched text holds no whole entry and no whole word of one from any scan (Codex
  round 1, B2); a match that stops inside a name still prints the part before it (CHANGELOG 0.2.9, Still not
  covered). The
  guarantee is about matched text only: a file label is still printable when its path has no hit, so a path that
  holds one word of an entry and no pattern hit still prints (a lone word is not a hit and would ship anyway;
  Codex round 2, listed under Still not covered). Each reading is normalised once per match, and the cut-text check
  is skipped when the cut text equals the full match.
- Exemption eligibility is kept apart from the dedupe key (Codex round 1, B3) and from the word check (Codex
  round 2): each hit also carries `HoldsEntry`, true only when a WHOLE entry matched its text, as before for the
  full match; the cut reading is new and cannot reach the 14-character placeholder id. `Test-ScrubPlaceholderHit` requires `HoldsEntry` false, as the old `-ccontains $_.Text` did implicitly
  (a blanked text never equalled an id). A word-only match blanks the printed text but leaves `HoldsEntry` false,
  so the exemption holds exactly where it held on c30654b.
- Dedupe keys on Line, Rule, `MatchKey` and `Text` together: `MatchKey` keeps two blanked hits of different texts
  apart, and `Text` still keeps a blanked hit and a printable hit of the same text under one label (a mergetag's
  name and its gpgsig header) apart, as before (Codex round 1, S1).

## Decisions (maintainer; both decided 2026-11-22: hash, no minimum)

- **D1: `MatchKey` is a SHA-256 hex of the matched text (cut as today), or the raw match in a field that is never
  printed.** Recommendation: the hash. Interpolating a hit object prints every property, so a raw field is one edit
  away from a leak. Cost: about 10 lines and one hash per hit.
- **D2: no minimum word length for F7b.** Recommendation: none. Over-blanking costs only a hit's text, never a
  pass; a minimum would let a short private word print.

## Phases

Rows use synthetic entries (`zzbeta`, `zzgiven zzsur`) passed through `-Denylist`, never the private files. Do not
push between phases: the pre-push gate runs this suite.

### Phase 1: failing rows first (no fix code), `tests/scrub.test.ps1`

1.1 F5, git-written messages in the history fixture repo, each with a control that git wrote the expected subject:
  (a) `git merge --no-ff --no-edit` of annotated tag `rel-<fu>61` (`Merge tag '...'`); (b) branch `x-<fu>62`
  (`Merge branch '...'`); (c) `git -c pull.rebase=false pull --no-ff --no-edit <clone path> x-<fu>63`
  (`Merge branch '...' of <path>`), run through `Invoke-ScrubGit` (git pull writes progress to stderr, which throws
  under the suite's `$ErrorActionPreference = 'Stop'`), its exit code checked before the subject; (d) message quoting a file name `'notes-<fu>64.md'`; (e) annotated tag message
  `see <fu>65`; (f) raw commit whose mergetag body holds `<fu>66`. Each asserts the hit exists under its label and
  rule, has no `Text`, and the joined `Format-ScrubHit` output does not match the number.
1.2 %B: raw commit with `encoding UTF-7` whose stored message decodes, re-encoded, to `see <fu>67`. Control: the
  stored reading has no hit and the %B reading has one. If git's iconv lacks UTF-7, use `encoding Shift_JIS` with
  fullwidth digits after the follow-up prefix (`\d` matches the decoded digits). An observed red-to-green on this
  host is required; UNCHECKED is not an accepted outcome for this row.
1.3 F7a (raw objects): author, committer, tagger (via `Invoke-ScrubRawTag`), mergetag tagger, each holding a
  follow-up number (`<fu>71`..`<fu>74`), and a Windows-1252 author (`Zzcaf` + 0xE9 + ` <fu>75`, read twice, and
  exactly one follow-up hit for it). Each asserts the role label, no `Text`, and printed output free of the number
  and `zzbeta`.
1.4 F7b on `Find-ScrubHits` (the home-path line is built from pieces in the suite, never written whole in a
  shipped file, this doc included): (a) a line holding the home-path prefix followed by `zzgiven` and a further path
  segment, entry `zzgiven zzsur`; (b) folded: the same line, the entry holding a zero-width space after `zz` (built
  from the code point, never a backslash-u escape); (c) plain only: a follow-up number whose last digit is a
  fullwidth digit, entry `1 zzsur` (hits in FormC, misses after NFKC folds the digit, so it covers the plain word
  regexes); (d) cut: a home-path match of 66 `a` then `-zzgivenx`, whose full match holds no whole word but whose
  cut 80-character text ends in `zzgiven`; (e) the same cut case for a single-word entry `zzgiven`. Each asserts
  one hit of its rule, no `Text`, printed output free of `zzgiven` / the digit text.
1.5 Controls: a blob holding `<fu>68` still prints its text (guards against blanking inside `Format-ScrubHit`); a
  work-tree file (SG4 repo) holding (a)'s line prints no `zzgiven`; a staged version holding (a)'s line with a clean
  work-tree version keeps its index hit, with no text; an entry made only of an invisible character
  plus a real word blanks nothing else. The existing gpgsig row stays as the header control.

Verify: `tests\scrub.test.ps1`; 1.1-1.4 and the work-tree and index 1.5 rows red, the other 1.5 rows and all existing rows
green. Record the red rows in the PR.

### Phase 2: MatchKey, dedupe, exemption predicate (no output change)

2.1 `Get-ScrubMatchKey([string]$S)` before `Find-ScrubHits`; set `MatchKey` and `HoldsEntry` on every hit object
  (pattern hits: key of the cut text before blanking, `HoldsEntry` from the whole-entry check; denylist and repo-sha
  hits: `''` and false), copied through Add-ScrubContent and Add-ScrubTextHits.
2.2 Both dedupe keys add `MatchKey` to the existing Line, Rule and `Text`.
2.3 `Test-ScrubPlaceholderHit($Hit)` next to `Format-ScrubHit`: rule `desktop session id`, `HoldsEntry` false,
  `MatchKey` one of the placeholder ids' keys, and `File` a coord-handoff blob label or exactly
  `commit message 2c3b5fc`.
2.4 Guard rows, green now: (a) one message line holding two follow-up numbers gives two hits; (b) a synthetic
  placeholder hit relabelled `commit message 2c3b5fc` is exempt; a different id under that label and the real id
  under another commit are not; (c) negative control (Codex B3): under the coord-handoff blob label, `X` + the
  placeholder id + `g` with a synthetic entry `local 1234abcd` (the id's halves) is not exempt; (c2, added in
  Phase 4) a synthetic entry made of the exact placeholder id followed by `zzsur` leaves the placeholder hit exempt,
  as on c30654b (a word-only match blanks text, never eligibility); (d) a mergetag whose
  name and gpgsig header hold the same follow-up number keeps both hits, the gpgsig one with its text.

Verify: earlier rows and 2.4 green; Phase 1 rows still red.

### Phase 3: F5 and F7a fix

3.1 `[switch]$NoText` on `Add-ScrubContent` (blanks `Text`, keeps `MatchKey`).
3.2 Pass it for the tag message, the commit message and the %B message.
3.3 `-NoText` on the mergetag body and on `Add-ScrubIdent`'s `Add-ScrubTextHits` call. Non-name headers keep text.
3.4 Extend 2.4b: the printed exempt hit holds no id text.

Verify: 1.1-1.3 green; 1.5, 2.4 and the gpgsig row green.

### Phase 4: F7b fix

4.1 In `Find-ScrubHits`, one word regex per non-empty word of every entry of two or more words, plain and folded.
4.2 In the blanking loop, blank when a whole-entry or word regex matches the full match or the cut text, each in
  its reading; set `HoldsEntry` only for a whole-entry match. Update the comment.
4.3 Add row 2.4c2.

Verify: 1.4, 2.4c2 and the work-tree and index 1.5 rows green, the existing SG2 whole-entry row green.

### Phase 5: docs, version, gate runs

5.1 Suite comments that say message or identity text prints (header, SG6 list, exemption comment).
5.2 `.githooks/pre-push` header: one sentence, message and identity hits show no matched text.
5.3 README: status line to v0.2.9 (it still says v0.2.6); the gate section says how a message or identity hit is
  named.
5.4 `.claude-plugin/plugin.json` to 0.2.9; CHANGELOG `## 0.2.9 - 2026-11-22` with rows seen red and an honest
  "Still not covered".
5.5 Re-read every sentence describing the change against the final code.

Verify: `tests\scrub.test.ps1`; after committing and fetching origin/main, with the private env,
`-History origin/main..HEAD` and `-History HEAD` (takes in 2c3b5fc and the coord-handoff blobs, so it shows the
exemption on real data); compare both timings with the baseline (0.6 and 1 min); then `tests\run.ps1` on a
coordinator HOST slot.

Not in this track's scope: a pre-push hook row that a refused push forwards no matched text and leaves the remote
ref absent belongs in `tests/hooks/prepush.test.ps1` (Q48's file). Reported to the coordinator as a FINDING; the
maintainer queued it as Q50, after Q47 and Q48 merge. This track's rows assert the `Format-ScrubHit` output the
hook forwards.

## Mutation checks (revert one, named rows go red)

| Mutation | Red rows |
|---|---|
| no `-NoText` on the commit message | 1.1 a-d |
| no `-NoText` on %B | 1.2 |
| no `-NoText` on the tag message | 1.1e |
| no `-NoText` on the mergetag body | 1.1f |
| no `-NoText` in `Add-ScrubIdent` | 1.3 all |
| remove 4.2 | 1.4 a-e, 1.5 work-tree and index rows |
| remove only the folded word regexes | 1.4b |
| remove only the plain word regexes | 1.4c |
| word/entry check on the full match only, not the cut text | 1.4d, 1.4e |
| dedupe keys back to `Text` only | 2.4a |
| dedupe keys on `MatchKey` without `Text` | 2.4d |
| exemption back to `-ccontains $_.Text` | 2.4b |
| exemption without the `HoldsEntry` check | 2.4c |
| `HoldsEntry` also set by a word-only match | 2.4c2 |
| word regexes for history scans only | 1.5 work-tree row |
| `-NoText` on the tag and mergetag non-name headers | gpgsig row |
| blank `Text` inside `Format-ScrubHit` | 1.5 |
| word regexes only for an entry of two or more raw words (panel A) | the two spacing-diaeresis rows |
| mergetag body back under `commit headers of` (panel B) | 1.1f, the same-number tag-name and message row |
| `Format-ScrubHit` prints nothing for a blanked hit (panel C, the helper's exact-print check) | every `Assert-ScrubNoMatchedText` row |
| a plain word made only of an invisible character dropped before counting (panel round 2, finding 1) | the zero-width-space second-word row |
| no stripping of a folded word's leading combining marks (round 2, finding 3) | the U+00A8 and U+00B4 second-word rows |
| marks stripped and empty words dropped before counting (round 2, finding 3) | the entry-ending-in-a-diaeresis guard row |
| mergetag split back at the first `\n\n` (round 2, finding 4) | the CRLF and two-space mergetag rows |
| folded word matchers back through `Get-ScrubDenyRegex -Plain` (NFC again; round 2, finding 2) | none: no row (reasoned below) |

## Review panel round 2

Rows added before any fix and seen red for the stated reason (243 passed, 5 failed: exactly these), then green
after the fixes (248 passed, 0 failed):

- an entry `1` + space + zero-width space with a follow-up number whose last digit is fullwidth: the first-round
  fix dropped the invisible-only plain word before counting, so the entry had no plain word matcher and the number
  printed. Fix: the drop is removed; the words are counted as split.
- two entries `zzgiven` + U+00A8 or U+00B4 + `zzsur` with a home path holding `zzsur`: the second folded word
  starts with a combining mark and matched nothing, so `zzsur` printed. Fix: a folded word loses its leading
  combining marks, after the count; a word left empty gets no matcher. A guard row (`zzgiven` + U+00A8, a home path
  holding `zzgiven`) stays green and went red when the marks were stripped before counting.
- two mergetags whose blank line is a CRLF line or two spaces: the message was read as headers and printed under
  `commit headers of`. Fix: the embedded tag splits at its first line that is empty or white space only.

Finding 2 (folded word matchers normalised to NFC again) is fixed without a row: the matchers are built by
`Get-ScrubWordsRegex` from the word as it is. A folded word need not be NFC (measured in a scratch probe), but a
pattern rule's matched text holds only ASCII and `\d` digits, none of which NFC composes, so no row can show it
through `Find-ScrubHits` (reasoned). Since round 3, `Get-ScrubDenyText` normalises again after removing the
invisible characters, so that case no longer arises. The merge and pull fixtures pass
`-c merge.verifySignatures=false`; since round 3 the Q47 tag fixtures pass `-c tag.gpgSign=false`, and the merge,
pull and `Add-ScrubTestCommit` commits `-c commit.gpgSign=false`.

## Review panel round 3

Rows added before any fix: the two below were red for the stated reason (250 passed, 2 failed: exactly these),
green after the fixes (252 passed, 0 failed):

- an entry `zzjos` + U+00E9 with a text `zzjose`, a soft hyphen or a zero-width space, and U+0301: no denylist
  hit in either reading (a fail-open of the whole gate; the function is unchanged from c30654b, where the
  adversary measured it). Fix: `Get-ScrubDenyText` applies NFKC
  again after removing the invisible characters. Reverting it alone turns both rows red.

Guard rows, green before and after: every message hit of the pull from a clone path, of any rule, has no text
(red with message hits keeping their text, also for the absolute-path rule alone); a follow-up number on the
third line of a commit message is one hit labelled `commit message` + the commit's first 7 sha characters, line 3
(the message's lines counted from the body after the header block; red with the line off by one and with an
8-character label). Fixed without a row: an `Assert-ScrubNoMatchedText` FAIL detail gives counts and the
`File:Line: Rule` of the row's own hits only; `Find-ScrubHits` builds the matchers of a denylist once and reuses
them (200 clean calls with 20 two-word entries: 4.41 s before, 0.43 s after, the first call excluded); the
signing settings above.

## Risks

- Dedupe on `MatchKey` may keep two hits an empty `Text` would merge (UTF-8 and Windows-1252 readings): only adds hits.
- A FAIL on a message hit is harder to read: `<sha7>:<line>` and the rule, then `git show` locally.
- Fixture fragility: `git pull` from a local clone path; UTF-7 in Git for Windows' iconv (Shift_JIS fallback).
- F7b changes work-tree and index diagnostics too (more blanked text, never fewer hits).

## Out of scope

- Text in other headers (gpgsig, unknown headers) and in file contents still prints, by design, unless it holds a
  denylist entry or a word of one.
- `-PushRefs` stays an argument.
- A private word joined by `_` or a letter is not a whole word, as for the denylist itself.
- A file label whose path holds one word of a multi-word entry, and no pattern hit, still prints (a lone word is
  not a hit; such a path ships).
- The pre-push hook's own row (Q48's file, a FINDING); suite runtime (Q48).

## Codex rounds

- Round 1 (gpt-6.2-sol, high): REVISE, 3 blockers (B1 the plan's own home-path literal, B2 the shared scanner,
  B3 exemption broadening) and 4 should-fixes (S1 dedupe merge, S2 non-ASCII digits, S3 cut text, S4 %B and the
  hook row); all applied above, the hook row routed as a FINDING.
- Round 2 (gpt-6.2-sol, high): REVISE, 1 blocker (a word-only match must not cancel the exemption: `HoldsEntry`
  is whole-entry only, row 2.4c2) and 4 should-fixes (file-label claim narrowed to matched text; pull fixture via
  `Invoke-ScrubGit`; one-hit 1252 row and an index row; normalise once and time the gate) plus 1 nitpick (rows
  named per mutation); all applied. Per the 2-3 round cap, Codex next sees the diff in the review panel.
