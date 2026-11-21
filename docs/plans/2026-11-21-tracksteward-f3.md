# tracksteward F3: an annotated tag's own name in a pattern hit (Q46)

Baseline: origin/main dc57563 (tracksteward 0.2.7, v0.2.7). Branch `claude/q46-tracksteward-f3`.

## The claim

CHANGELOG 0.2.7 "Still not covered" (first written in 0.2.6): an annotated tag's own name, read in its header
block, still prints a pattern hit's text (reasoned, not measured). Since 0.2.6 a pattern hit in a file name or a
pushed ref name prints no matched text (`Add-ScrubTextHits -NoText`), because that text is part of the name. The
tag object's `tag <name>` header goes through `Add-ScrubTextHits` without `-NoText` (`Invoke-ScrubHistory`, the tag
header loop), so by reading it the name's matched text is printed.

## Step 1: measure

A new SG6 row: an annotated tag whose name matches a pattern rule (the follow-up number rule, its text built in the
test, as the 0.2.6 pattern-name rows do; no denylist, no allowed identity), scanned with `Invoke-ScrubHistory`, and
the hits (as `Format-ScrubHit` prints them) checked for the name's matched text.

- Not reproduced: stop. The row stays, the CHANGELOG line becomes a measured "not reproduced" note; docs plus the
  row, no version bump unless the maintainer says.
- Reproduced: the row is seen red first, then the fix.

## Step 2: the fix (only if measured)

Same class as the 0.2.6 name redactions: the tag header whose key is `tag` (the tag's name) is scanned with
`-NoText`. Sibling sweep: every other place a tag's name is read as text. The one found by reading is the embedded
tag of a `mergetag` commit header (its own `tag <name>` line), which gets the same treatment and its own row, seen
red first. Other headers (type, gpgsig, unknown keys) keep their text: they are not the name.

What the sweep missed (panel round 1, widened in round 2): a message keeps its text, and git's own merge messages
quote names (`Merge tag '<name>'`, `Merge branch '<name>'`, a pull's `of <url>`). The fix stays with the headers:
changing what a message prints is a new rule, not this name redaction. It is listed as still not covered, and it
went to the coordinator as a finding.

Version 0.2.8: CHANGELOG and plugin.json. Out of this slice: `-PushRefs` is still an argument.

## Verification

`tests\scrub.test.ps1` alone while iterating; the full `tests\run.ps1` once, on the coordinator's HOST GO. Panel
(reviewer + adversary) on the diff, then on any fix diff. Codex only on the maintainer's pick.

## Added in this PR: F6, a tag inside a..b (the maintainer's call, relayed by the coordinator and confirmed)

The panel found that the tag walk in `Invoke-ScrubHistory` skipped every revision holding `..`, so a range written
`a..b` never read the annotated tag at `b`. Fix: walk the positive ends (the right side of `a..b`, both sides of
`a...b`). An SG6 row is seen red first. F5 (names quoted in messages) and F7 (identity hits, a partial denylist
entry) are listed as not covered and go to a later slice.
