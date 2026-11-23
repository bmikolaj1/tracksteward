# tracksteward Q53: U+180E and the variation selectors in the denylist (F6), `<home>/.` in prose (F8)

Date: 2026-11-23. Track Q53, branch `claude/q53-scrub-folded`, baseline bab8737 (0.2.10, #35). Session model: Opus 5.5.

Notation as in the Q51 plan: no home path with a name after it is written here; entries are synthetic (`zz...`).
`<home>/` and `<Users>/` stand for the two home prefixes: the 0.2.10 gate, which the pre-push hook runs until this
merges, refuses even a dot segment after them.

## Goal

- **F6** (the 0.2.9 Still-not-covered line): a denylist entry holding U+180E or a variation selector (U+FE00-FE0F) is
  found when the name is written with an ordinary space or without the character; a text holding those characters
  inside or between the words of an entry still hits.
- **F8** (from Q51): the home-path rule does not hit `<home>/.` (or `<Users>/.`) in prose, where no name follows.

## The F6 rule this slice keeps (from the Q51 deferral)

Every 0.2.10 matcher and reading stays byte-for-byte as it is; the new readings are extra matchers whose hits are
joined to the old ones, so no old hit can be lost. Spellings are compared ordinally. Start from the Q51 round-3
cases (kept as guard rows).

## Measured (scratch probe on bab8737, PowerShell 5.1)

Red (16): F6 entry side, U+180E between words vs a space; a trailing U+FE0F on the first word vs a space; a
single-word entry with a trailing U+FE0F; U+FE0F then U+180E between words vs a space; U+180E inside a word vs the
word without it. F6 text side, U+180E between words; U+180E, U+FE0F, U+FE00 inside a word; fullwidth words parted by
U+180E; U+FE0F before U+180E between words; U+180E inside and between words; U+FE0F after the space between words.
F8: `<home>/.` at the end of a sentence, before a space, `<home>/..` before `)`.

Green on bab8737, kept as guards (15 at first; 17 after panel round 1): the Q51 round-3 hits (a fullwidth name then U+FE0F or U+FE00 and a letter, a
letter and U+FE0F before a fullwidth name, a fullwidth name then U+FE0F and a digit), the same spelling as the
entry, plain names; CamelCase, glued words, U+FE0F alone between words, a longer word stay no hit; a home path
whose dot segment is followed by a slash or a backslash and a name, whose name starts with a dot, whose name ends in
a dot, or whose dot is followed by an accented letter stays a hit (the exempt home path stays exempt: an older row).

The scrub suite on bab8737: 270 passed, 0 failed.

## Design

F6, one extra "loose" matcher per entry and reading (`Get-ScrubLooseWords`, `Get-ScrubLooseRegex`). First planned
as one matcher per spelling (U+180E as a space, U+180E removed); replaced before any code by one matcher in which an
entry's U+180E inside a word may match nothing or a separator run, which also covers an entry with U+180E both
inside and between words, with no spelling compare at all:

- Of the entry: the variation selectors are removed; U+180E at a word's edge is trimmed (it sits next to a
  separator); a word left empty is dropped; no word left, no matcher (the old matcher still runs).
- Readings: the entry in NFC (run on the plain text) and in `Get-ScrubDenyText` (run on the folded text). The
  texts are the 0.2.10 ones, unchanged (first form; panel round 1 adds two extra texts, see there): U+180E and the selectors stay where they are (NFKC keeps them, measured in
  Q51).
- The loose matcher is the old one with these widenings: between two characters of a word, any run of U+180E and
  variation selectors may sit; at an entry's U+180E inside a word, one run of separators, U+180E and selectors,
  possibly empty; between words, the separator class also holds U+180E, and selectors may sit around the
  separators (at least one separator character is still needed: a selector alone parts nothing, as before).
  The lookarounds are the old ones. Every text the old matcher of an entry without these characters matches, the
  loose one matches (reasoned: each widening only adds optional runs).
- No two neighbouring quantifiers share a character (measured: the first form, with U+180E in both the in-word run
  and the separator, took 78 s on a line of 25 U+180E; now 2000 take milliseconds; a row guards it).
- The word matchers (a printed pattern hit blanked for one word of a multi-word entry) and the whole-entry check
  of a pattern hit (HoldsEntry) get the loose matchers too, so a home path holding such an entry or one of its
  words prints no text.

F8 (first form; superseded, see Panel rounds 1 and 2): the home-path rule gets a lookahead: a name made only of dots, followed by the end of the line, white space or
one of `) ] } > " ' `` ` `` , ; : ! ? *`, is not a hit. A dots-only segment followed by `/`, `\`, a letter or anything
else still hits.

## Phases

1. Rows in `tests/scrub.test.ps1` (Q53 block), red on bab8737, count recorded.
2. Fix; header comments of the suite; rows green; guards green.
3. CHANGELOG, under Unreleased: the version bump and tag are the maintainer's call after the merge (brief house
   rule 6), so the plugin version stays 0.2.10 here.
4. Diff panel (reviewer + adversary; codex-reviewer only on the maintainer's pick), fix-diff panel per house rule 3.
   House rule 9: if F6 again loses an existing hit by round three, ship F8 alone.

## Verification

`tests\scrub.test.ps1` alone (denylist env set), with `-History HEAD`; full `tests\run.ps1` on a HOST slot.

## Panel round 1 (reviewer, adversary, Codex balanced; Codex REVISE)

- A U+180E or selector between a letter and its combining mark blocked composition on both sides (adversary,
  Codex; measured 0 hits). Fix: `$scrubLooseBeforeMark` removes such a run from the entry before its loose matchers
  (then normalised again), and Find-ScrubHits reads two extra texts without it when the text holds one.
- Entry with U+180E inside its first word: the word matchers split only at U+180E, so a home path holding the word
  written without it printed it (Codex, measured). Fix: word matchers from both splits.
- F8 let a dot segment, a comma and a name with no space through (Codex, measured). Fix: the dots and punctuation
  must run to the end of the line or white space.
- Rows: the timing row gets a positive control; the redaction rows check HoldsEntry; a row needs the folded loose
  HoldsEntry line (mutation red). Prose: the red count (20 then, measured), stale comments, the timing wording,
  the Still-not-covered list (adversary).
- Accepted, listed as not covered: short token + selector entries over-match (fail-closed); a quadratic case for
  an entry with U+180E beside a separator character inside a word (same order as 0.2.10's shape, measured).
- Totals after round 1: 48 new rows, 31 red on bab8737 (measured), 17 guards; suite 318 passed.

## Panel round 2 (fix diff; reviewer, adversary, Codex balanced; Codex REVISE)

First round with a defect inside the previous round's fix (house rule 3 counts; round three would be the second in a
row). No lens found a lost bab8737 hit (the adversary fuzzed 5,500 cases against bab8737: none lost, none printing
more).

- `$scrubLooseBeforeMark` tried every position inside a run: 14 s on 20000 U+180E (all three, measured). Fix: start
  at a run's start, take it whole.
- F8 lookahead: two quantifiers shared the dots, 8 s on 20000 dots, no denylist needed (all three, measured). Fix:
  one dot, then the punctuation-and-dots run taken whole.
- The removal before a mark ran only before folding; an invisible between the run and the mark, or a halfwidth
  voiced mark, escaped (all three, measured). Fix: `Get-ScrubBareFold` repeats the removal after folding (entry and
  text); the extra texts are built when the text or its folded reading holds a run.
- Codex BLOCKER (from the first form, not round 1): several in-word gaps beside dots shared a dot run out
  exponentially (9.5 s at 30 dots). Fix: `$scrubLooseMvsRun` makes the separators beside a U+180E part of its gap.
- Rows: 6 mark rows, 3 timing rows with positive controls, a wrapped-line row (Codex). Prose: the plan's first-form
  sentences marked, the ASCII claim and the timing wording corrected, Still-not-covered updated.
- Totals after round 2: 58 new rows, 40 red on bab8737 (measured), 18 guards; suite 328 passed (337 with -History).

## Panel round 3 (fix diff; reviewer, adversary, Codex balanced; Codex REVISE) and the freeze

The second round in a row with a defect inside the previous round's fix (the edge collapse). At the round-three
trajectory report the maintainer chose (2026-11-23) "Triage, then freeze F6": fix the clear-cut findings, list the
rest, one last fix-diff pass by reviewer and adversary only, then commit.

- Fixed: `$scrubLooseMvsRun` only inside a word (reviewer, measured: an edge underscore was lost against the
  round-2 tree); loose words made only of separator characters dropped (Codex BLOCKER, measured 8.6 s; also the 3x
  cost on `zz - zztwo`, adversary). Each with a row red on the round-2 fix.
- Listed in Still not covered: U+180E before a mark in an entry read only as nothing (Codex BLOCKER 2; as on
  bab8737), F8 also exempting dots-and-punctuation segments such as `<home>/...` (Codex), no pre-push row (Codex;
  a FINDING to the coordinator).
- Prose: the 0.2.10-shape cost line (now measured equal to bab8737), "every 0.2.10 denylist matcher" (F8 changed
  the home rule), "inside an entry's word".
- Totals: 61 new rows, 43 red on bab8737 (measured), 18 guards; suite 331 passed (340 with -History HEAD).

## Panel round 4 (reviewer and adversary only) and the finish

The third round in a row with a defect inside the previous round's fix: round 3's edge rule left one gap per
U+180E at a word's edge, with literal separators between them (14.5 s at ten against 30 dots; bab8737 64 ms; both
lenses, measured). No lost bab8737 hit (adversary fuzz, 4,500 cases). At that trajectory report the maintainer
chose (2026-11-23) "Edge fix, last pass, commit": `Remove-ScrubLooseEdgeMvs` removes the U+180E from a word's edge
run and keeps its separators; a timing row red on the round-3 fix (14.2 s) guards it; the three false sentences are
corrected and two Still-not-covered lines added. One reviewer-only check of that diff follows; if it finds a defect
inside this fix, F8 ships alone. The pre-push row for F6 is Q55's (the maintainer, via the coordinator).

- Totals: 62 new rows, 44 red on bab8737 (measured), 18 guards; suite 332 passed (341 with -History HEAD).
