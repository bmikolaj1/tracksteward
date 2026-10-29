# Tests for scripts/coord-status.ps1 (the status board). gh is the stub in tests\stubs. Ledgers are written into a
# scratch folder and passed with -Ledger; the clock is -Now so the time rules are deterministic.
# Ported from the private coordinate toolkit (coord-status.test.ps1), 2026-10-29.
#
# Dropped row: T11 ran the board over an archived real ledger of the private toolkit (a file that is not part of
# this repo): output within 2,000 characters, the done count and the unticked Owed checks against an independent
# count of the file. T12 (a synthetic ledger over the cap) and T2 (counts of a known ledger) stay. The Repo
# cells of the example rows are generic, and the private repo name in the Queue example became a generic title.
# Added: a fence that the runner's real index folder is unchanged by this run (T14 runs coord-log.ps1).
#
#   T1   unreadable: no ledger file, a ragged Tracks table, a doubled '## Merge slots' heading, a ledger with no
#        '## Tracks' -> ONE line `STATUS: could not read - ...`, exit 2, nothing else
#   T2   the first word of the Status cell decides the group (every vocabulary word, one row each)
#   T3   a legacy Status cell is UNCLASSIFIED: listed under WAITING with its first word, counted on the STATUS line;
#        lower-case `merged` and `NOT MERGED` stay live
#   T4   BRIEFED older than 15 minutes with no ACK says so, with the minutes; a fresh one does not
#   T5   Findings: F<n> with no later `F<n> outcome:` is PENDING; F1 is not closed by F10's outcome
#   T6   Owed checks: unticked listed ("(from ...)" tail dropped), ticked not, odd box shapes counted as unrecognised
#   T7   Merge slots: an open slot is printed on its row by PR number; one no live row carries is BLOCKED;
#        MERGED, VOIDED and `slot free` are closed
#   T8   Queue: gates read OPEN/CLOSED/? by the rules (time, local time, person, PR without -Verify, after Q<n>,
#        unknown text); a `Q<n> outcome:` closes the item; counts on the STATUS line
#   T9   -Verify: a live row with a PR prints the gh state; a failing gh prints `unknown (...)`, never a state; a
#        MERGED row whose PR is OPEN is a MISMATCH on the STATUS line; without -Verify gh is not called at all
#   T10  the Log and Decisions sections are never read (poison lines there change nothing)
#   T12  a big synthetic ledger is cut at the cap with `... <n> more; -Full or -Group <name>`; -Full lists all;
#        -Group prints only that group, uncapped
#   T13  read-only: the ledger bytes and the folder listing are unchanged by a run
#   T14  a ledger from the real ledger-template.md, its rows set with coord-set.ps1 -State (all ten words) and
#        a Queue line from coord-log.ps1, renders with 0 rows unclassified and Q1 under QUEUED; the template's
#        "(none)" placeholders in Merge slots and Owed checks are not items
#   T15  "1. (none) #12" stays a slot and "- [ ] (none) F3 owed" an owed check, a carried
#        "- [ ] (none) (from <date>)" is not one; a lone carried `Q1 outcome:` opens `[after Q1]`; a first word the
#        terminal rule refuses ("MERGED/x", "DONE!") is unclassified, not DONE
#   T16  "feedback" and lower-case "ack" are not an ACK (only "ACK HH:mm" is), and a BRIEFED stamp later than the
#        clock is yesterday's; a bracket in the item text ("[F3]") does not take the gate
#   T17  a bracket that is not gate-shaped, in owner/source or unclosed, does not take the gate; only the legacy
#        "ACK HH:mm" answers a BRIEFED row ("no ACK yet" does not); placeholders in any case and with several
#        (from ...) tails; a local gate and its UTC rewrite agree
#   T18  the gate is the last gate-shaped group before " owner:", so a gate-shaped bracket quoted in owner/source
#        does not take it over (and -Verify never asks gh about it); with no owner part, the last gate-shaped group
#   T19  the real index folder is unchanged at the end of the run
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\scripts\coord-status.test.ps1 [-ScriptPath <mutant copy>]
#       (a mutant copy needs coord-common.ps1 next to it: it dot-sources it)
# Exit: 0 = all passed, 1 = a case failed.
# The mutants run against this suite are listed in the slice's PR body.
param([string]$ScriptPath = '')

$testsDir = Split-Path -Parent $PSScriptRoot
$fixturesDir = Join-Path $testsDir 'fixtures'
try { . (Join-Path $fixturesDir 'hook-test-fixture.ps1') } catch { Write-Error "could not load hook-test-fixture.ps1: $_"; exit 1 }
Clear-HookRunnerGitEnv
. (Join-Path $fixturesDir 'coord-test-fixture.ps1')
$ErrorActionPreference = 'Stop'

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('coord-status-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory($root)
# Nothing in this run may reach the real index folder (T14 runs coord-log.ps1).
$realIndexBefore = Get-CoordRealIndexDigest
$null = New-CoordScratchIndex $root
$caseN = 0
$clock = '2026-10-27 12:00'

function New-Ledger {
    param([string[]]$Rows = @(), [string[]]$Slots = @(), [string[]]$Owed = @(), [string[]]$Findings = @(), [string[]]$Queue = $null,
        [string[]]$Log = @(), [string]$Header = '| Track | Repo | Session | Model | Cwd | Branch | Scope | PR | Status |', [string]$Name = '2026-10-27')
    $script:caseN++
    $dir = Join-Path $root "c$script:caseN"
    [void][IO.Directory]::CreateDirectory($dir)
    $t = @('# Coordination ledger - 2026-10-27', '', '## Baseline', '', 'x', '', '## Tracks', '', $Header, '|---|---|---|---|---|---|---|---|---|')
    $t += $Rows
    $t += @('', '## Merge slots', '')
    $t += $Slots
    $t += @('', '## Owed checks', '')
    $t += $Owed
    if ($null -ne $Queue) { $t += @('', '## Queue', ''); $t += $Queue }
    $t += @('', '## Decisions', '', 'POISONDEC', '', '## Findings', '')
    $t += $Findings
    $t += @('', '## Log', '')
    $t += $Log
    $p = Join-Path $dir "$Name.md"
    Set-CoordTextFile $p (($t -join "`n") + "`n")
    return [pscustomobject]@{ Dir = $dir; Path = $p }
}
function Get-Row([string]$Track, [string]$Status, [string]$Pr = '', [string]$Model = 'Opus 5.5') {
    return "| $Track | C:\Fx\alpha | s | $Model | C:\w | b-$($Track -replace '\W', '') | docs/** | $Pr | $Status |"
}
function Invoke-Board {
    param($L, [string]$ExtraArgs = '', [object[]]$Rules = @())
    $sp = if ($ScriptPath) { [System.IO.Path]::GetFullPath($ScriptPath) } else { '' }
    return (Invoke-CoordScript -Name 'coord-status.ps1' -Cwd $L.Dir -ScriptArgs ("-Ledger `"$($L.Path)`" -Now `"$clock`" $ExtraArgs") -Rules $Rules -ScriptPath $sp)
}
function Get-Lines($R) { return @($R.Out -split "`r?`n" | Where-Object { $_.Trim() }) }
function Get-GroupBlock($R, [string]$Name) {
    # the lines of one group: from its header to the next header at column 0
    $o = @()
    $in = $false
    foreach ($l in (Get-Lines $R)) {
        if ($l -match "^$Name \(") { $in = $true; $o += $l; continue }
        if ($in -and $l -match '^\S') { break }
        if ($in) { $o += $l }
    }
    return ,@($o)
}
function Test-Has($R, [string]$Rx) { return [bool]($R.Out -match $Rx) }

# ---- T1 unreadable
$gone = [pscustomobject]@{ Dir = $root; Path = (Join-Path $root 'nope.md') }
$r = Invoke-Board $gone
Assert-Coord 'T1a missing ledger -> exit 2, one line' ($r.Code -eq 2 -and (Get-Lines $r).Count -eq 1 -and $r.Last -match '^STATUS: could not read - ') $r.Out
$l = New-Ledger -Rows @((Get-Row 'a' 'RUNNING 10:00'), '| broken | row |')
$r = Invoke-Board $l
Assert-Coord 'T1b ragged Tracks row -> exit 2, one line, no group printed' ($r.Code -eq 2 -and (Get-Lines $r).Count -eq 1 -and $r.Last -match '^STATUS: could not read - ') $r.Out
$l = New-Ledger -Rows @((Get-Row 'a' 'RUNNING 10:00'))
$dup = (Get-Content -LiteralPath $l.Path -Raw -Encoding UTF8) + "`n## Merge slots`n"
Set-CoordTextFile $l.Path $dup
$r = Invoke-Board $l
Assert-Coord 'T1c a doubled section heading -> exit 2, one line' ($r.Code -eq 2 -and (Get-Lines $r).Count -eq 1 -and $r.Last -match '^STATUS: could not read - .*Merge slots') $r.Out
$l = New-Ledger -Rows @((Get-Row 'a' 'RUNNING 10:00'))
Set-CoordTextFile $l.Path ((Get-Content -LiteralPath $l.Path -Raw -Encoding UTF8) -replace '## Tracks', '## Trackz')
$r = Invoke-Board $l
Assert-Coord 'T1d no ## Tracks heading -> exit 2, never an empty board' ($r.Code -eq 2 -and (Get-Lines $r).Count -eq 1 -and $r.Last -match '^STATUS: could not read - ') $r.Out

# ---- T2 vocabulary
$rows = @(
    (Get-Row 'rowQ' 'QUEUED'), (Get-Row 'rowB' 'BRIEFED 11:55; waiting for ACK'), (Get-Row 'rowR' 'RUNNING 11:12; round 1'),
    (Get-Row 'rowP' 'PR-OPEN 11:30; PR reported' '#70'), (Get-Row 'rowWB' 'WAIT-USER 11:40; merge go'), (Get-Row 'rowWS' 'WAIT-SLOT 11:41'),
    (Get-Row 'rowWQ' 'WAIT-QUOTA 11:42; until reset'), (Get-Row 'rowX' 'BLOCKED 11:43; guard block'), (Get-Row 'rowM' 'MERGED 11:44 #71 as abcdef1234567' '#71'),
    (Get-Row 'rowD' 'DONE 11:45; stopped')
)
$l = New-Ledger -Rows $rows
$r = Invoke-Board $l
$run = Get-GroupBlock $r 'RUNNING'; $wait = Get-GroupBlock $r 'WAITING'; $que = Get-GroupBlock $r 'QUEUED'; $blk = Get-GroupBlock $r 'BLOCKED'; $dn = Get-GroupBlock $r 'DONE today'
Assert-Coord 'T2a exit 0 and the last line is the STATUS line' ($r.Code -eq 0 -and $r.Last -match '^STATUS 2026-10-27 12:00: ') $r.Out
Assert-Coord 'T2b RUNNING and PR-OPEN -> RUNNING (2)' ($run[0] -eq 'RUNNING (2)' -and ($run -join "`n") -match 'rowR' -and ($run -join "`n") -match 'rowP') ($run -join "`n")
Assert-Coord 'T2c BRIEFED, WAIT-USER, WAIT-SLOT, WAIT-QUOTA -> WAITING (4)' ($wait[0] -eq 'WAITING (4)' -and ($wait -join "`n") -match 'rowB' -and ($wait -join "`n") -match 'rowWQ') ($wait -join "`n")
Assert-Coord 'T2d QUEUED -> QUEUED (1)' ($que[0] -eq 'QUEUED (1)' -and ($que -join "`n") -match 'rowQ') ($que -join "`n")
Assert-Coord 'T2e BLOCKED -> BLOCKED (1)' ($blk[0] -eq 'BLOCKED (1)' -and ($blk -join "`n") -match 'rowX') ($blk -join "`n")
Assert-Coord 'T2f MERGED and DONE -> DONE (2), PR and sha shown' ($dn[0] -match '^DONE today \(2\)' -and $dn[0] -match '#71 abcdef1') ($dn -join "`n")
Assert-Coord 'T2g STATUS counts 2/4/1/1/2, 0 unclassified' ($r.Last -match ': 2 running, 4 waiting, 1 queued \(0 gates open, 0 unknown\), 1 blocked, 2 done; 0 rows unclassified') $r.Last
Assert-Coord 'T2h every row line ends in a pointer L<n>' (@((($run + $wait + $que + $blk) | Where-Object { $_ -match '^  \S' })).Count -ge 7 -and (($run + $wait + $que + $blk) | Where-Object { $_ -match '^  \S' } | Where-Object { $_ -notmatch ' L\d+$' }).Count -eq 0) $r.Out

# ---- T3 legacy / unclassified
$l = New-Ledger -Rows @((Get-Row 'legacy1' 'briefed 08:31, ACK 08:32; running'), (Get-Row 'legacy2' 'NOT MERGED, waiting'), (Get-Row 'legacy3' 'merged 10:00 by hand'), (Get-Row 'legacy4' ''))
$r = Invoke-Board $l
$wait = Get-GroupBlock $r 'WAITING'
Assert-Coord 'T3a all four legacy cells are UNCLASSIFIED, listed under WAITING (4) with their first word' ($wait[0] -eq 'WAITING (4)' -and ($wait -join "`n") -match 'unclassified: briefed' -and ($wait -join "`n") -match 'unclassified: NOT' -and ($wait -join "`n") -match 'unclassified: merged' -and ($wait -join "`n") -match 'unclassified: empty') ($wait -join "`n")
Assert-Coord 'T3b the STATUS line counts 4 rows unclassified' ($r.Last -match '; 4 rows unclassified') $r.Last

# ---- T4 BRIEFED ACK clock
$l = New-Ledger -Rows @((Get-Row 'old' 'BRIEFED 10:20; brief sent'), (Get-Row 'fresh' 'BRIEFED 11:50; brief sent'), (Get-Row 'acked' 'BRIEFED 10:20; ACK 10:25'))
$r = Invoke-Board $l
[string]$oldLine = @(Get-Lines $r | Where-Object { $_ -match '^  old ' })[0]
[string]$freshLine = @(Get-Lines $r | Where-Object { $_ -match '^  fresh ' })[0]
[string]$ackLine = @(Get-Lines $r | Where-Object { $_ -match '^  acked ' })[0]
Assert-Coord 'T4a BRIEFED 100 minutes ago with no ACK says "no ACK (100 min)"' ($oldLine -match 'no ACK \(100 min\)') $oldLine
Assert-Coord 'T4b a fresh brief and an ACKed one do not' ($freshLine -notmatch 'no ACK' -and $ackLine -notmatch 'no ACK') "$freshLine`n$ackLine"

# ---- T5 findings
$l = New-Ledger -Rows @((Get-Row 'a' 'RUNNING 10:00')) -Findings @(
    '09:00 F1 from a: first thing | outcome: PENDING', '09:05 F10 from a: tenth thing | outcome: PENDING', '09:10 F10 outcome: backlog line',
    '09:20 F2 from a: second | outcome: PENDING', '09:25 F2 outcome: dropped, because noise', '09:30 cF3 from b: cloud one | outcome: PENDING')
$r = Invoke-Board $l
$wait = Get-GroupBlock $r 'WAITING'
Assert-Coord 'T5a F1 stays PENDING when only F10 has an outcome line' (($wait -join "`n") -match 'F1 a: first thing.*PENDING since 09:00') ($wait -join "`n")
Assert-Coord 'T5b F10 and F2 (outcome lines) are closed; cF3 is pending' (($wait -join "`n") -notmatch 'tenth thing' -and ($wait -join "`n") -notmatch 'second' -and ($wait -join "`n") -match 'cF3 b: cloud one.*PENDING') ($wait -join "`n")
Assert-Coord 'T5c the STATUS line counts 2 findings pending' ($r.Last -match '; 2 findings pending') $r.Last

# ---- T6 owed checks
$l = New-Ledger -Rows @((Get-Row 'a' 'RUNNING 10:00')) -Owed @(
    '- [ ] User: restore the required checks (from 2026-10-16)', '- [x] (09:00 done) a ticked one', '- [ ] a coordinator item',
    '* [ ] star box', '1. [ ] numbered box', '- [~] tilde box')
$r = Invoke-Board $l
$wait = Get-GroupBlock $r 'WAITING'
Assert-Coord 'T6a the two unticked "- [ ]" lines are WAITING, the "(from ...)" tail dropped' ($wait[0] -eq 'WAITING (2)' -and ($wait -join "`n") -match 'Owed: User: restore the required checks  L' -and ($wait -join "`n") -notmatch 'from 2026-10-16') ($wait -join "`n")
Assert-Coord 'T6b a ticked line is not listed' (($wait -join "`n") -notmatch 'ticked one') ($wait -join "`n")
Assert-Coord 'T6c three odd box shapes are counted as unrecognised, not guessed' ($r.Last -match '; 3 owed-check lines in an unrecognised box shape') $r.Last

# ---- T7 merge slots
$l = New-Ledger -Rows @((Get-Row 'a' 'PR-OPEN 11:00' '#81'), (Get-Row 'b' 'RUNNING 11:00' '#82')) -Slots @(
    '1. 09:00 #80 alpha (z) @abc, READY; MERGED 09:05 as def', '2. 10:00 #81 alpha (a) @abc, READY; go asked', '3. 10:30 #83 alpha (gone) @abc, READY; go asked',
    '4. 10:40 #84 alpha @abc; VOIDED (fix)', '5. 10:50 #85 alpha @abc; MERGED; slot free')
$r = Invoke-Board $l
$run = Get-GroupBlock $r 'RUNNING'; $blk = Get-GroupBlock $r 'BLOCKED'
Assert-Coord 'T7a the open slot of #81 is printed on row a; row b (#82, no slot) has none' ((($run -join "`n") -match '(?m)^  a .*#81  slot open \(L\d+\)') -and (($run -join "`n") -notmatch '(?m)^  b .*slot open')) ($run -join "`n")
Assert-Coord 'T7b the open slot of #83, with no live row, is BLOCKED "slot open, no live row"' ($blk[0] -eq 'BLOCKED (1)' -and ($blk -join "`n") -match 'slot open, no live row \(#83\)') ($blk -join "`n")
Assert-Coord 'T7c MERGED, VOIDED and "slot free" slots (#80, #84, #85) are not printed' ($r.Out -notmatch '#80|#84|#85') $r.Out

# ---- T8 queue
$q = @(
    '09:00 Q1 after-utc gate [after 2026-10-28 23:00Z] owner: user; source: x',
    '09:01 Q2 past-utc gate [after 2026-10-27 08:00Z] owner: coordinator; source: x',
    '09:02 Q3 local later [after 13:30] owner: nobody yet; source: x',
    '09:03 Q4 local earlier [after 08:30] owner: nobody yet; source: x',
    '09:04 Q5 person gate [needs user + phone] owner: user; source: x',
    '09:05 Q6 pr gate [after #116 merges] owner: nobody yet; source: x',
    '09:06 Q7 chain [after Q8] owner: nobody yet; source: x',
    '09:07 Q8 closed one [after 08:00] owner: nobody yet; source: x',
    '09:08 Q8 outcome: started as track q8',
    '09:09 Q9 free text [whenever the moon is right] owner: user; source: x',
    '09:10 Q10 no gate at all owner: user; source: x')
$l = New-Ledger -Rows @((Get-Row 'a' 'RUNNING 10:00')) -Queue $q
$r = Invoke-Board $l
$que = Get-GroupBlock $r 'QUEUED'
function Get-QLine([string]$Id) { return @($que | Where-Object { $_ -match "^  $Id " })[0] }
Assert-Coord 'T8a a UTC time gate in the future reads CLOSED, in the past OPEN (clock 12:00 local)' ((Get-QLine 'Q1') -match '\bCLOSED\b' -and (Get-QLine 'Q2') -match '\bOPEN\b') ($que -join "`n")
Assert-Coord 'T8b a local time gate reads CLOSED before it, OPEN after it' ((Get-QLine 'Q3') -match '\bCLOSED\b' -and (Get-QLine 'Q4') -match '\bOPEN\b') ($que -join "`n")
Assert-Coord 'T8c a person gate, a PR gate without -Verify, free text and no gate all read ?' ((Get-QLine 'Q5') -match ' \? ' -and (Get-QLine 'Q6') -match ' \? ' -and (Get-QLine 'Q9') -match ' \? ' -and (Get-QLine 'Q10') -match ' \? ') ($que -join "`n")
Assert-Coord 'T8d after Q8: Q8 has an outcome line, so Q8 is not listed and Q7 reads OPEN' ((Get-QLine 'Q8') -eq $null -and (Get-QLine 'Q7') -match '\bOPEN\b') ($que -join "`n")
Assert-Coord 'T8e QUEUED (9); the STATUS line counts 3 gates open, 4 unknown' ($que[0] -eq 'QUEUED (9)' -and $r.Last -match '\(3 gates open, 4 unknown\)') "$($que -join "`n")`n$($r.Last)"
$l = New-Ledger -Rows @((Get-Row 'a' 'RUNNING 10:00')) -Queue @('09:00 Q1 pr gate [after #116 merges] owner: nobody yet; source: x')
$r = Invoke-Board $l '-Verify' -Rules @((New-CoordRule '^pr view 116\b' '{"state":"MERGED"}'))
$que8f = Get-GroupBlock $r 'QUEUED'
Assert-Coord 'T8f a PR gate with -Verify reads OPEN when gh says MERGED' ((@($que8f | Where-Object { $_ -match "^  Q1 .*OPEN" }).Count -eq 1)) ($que8f -join "|")
$l = New-Ledger -Rows @((Get-Row 'a' 'RUNNING 10:00')) -Queue $null
$r = Invoke-Board $l
Assert-Coord 'T8g a ledger with no ## Queue section still renders, QUEUED (0)' ($r.Code -eq 0 -and (Get-GroupBlock $r 'QUEUED')[0] -eq 'QUEUED (0)') $r.Out

# ---- T9 -Verify
$prJson = '{"state":"OPEN","headRefOid":"0123456789abcdef0123456789abcdef01234567","mergeStateStatus":"CLEAN"}'
$l = New-Ledger -Rows @((Get-Row 'live' 'PR-OPEN 11:00' '#90'), (Get-Row 'nopr' 'RUNNING 11:00'), (Get-Row 'fine' 'MERGED 10:00 #91 as aaaaaaaaaaaa' '#91'), (Get-Row 'liar' 'MERGED 10:05 #92 as bbbbbbbbbbbb' '#92'))
$r = Invoke-Board $l '-Verify' -Rules @((New-CoordRule '^pr view 90\b' $prJson), (New-CoordRule '^pr view 91\b' '{"state":"MERGED","headRefOid":"0123456789abcdef0123456789abcdef01234567","mergeStateStatus":"UNKNOWN"}'), (New-CoordRule '^pr view 92\b' $prJson))
Assert-Coord 'T9a a live row with a PR prints "verified: #90 OPEN @<sha12>, CLEAN"' (Test-Has $r 'verified: #90 OPEN @0123456789ab, CLEAN') $r.Out
Assert-Coord 'T9b the header says verified; a MERGED row whose PR is OPEN is a MISMATCH on its own line and on the STATUS line' (@(Get-Lines $r)[0] -match '; verified\)' -and (Test-Has $r 'MISMATCH: #92 is OPEN') -and $r.Last -match '; 1 MISMATCH' -and -not (Test-Has $r 'MISMATCH: #91')) $r.Out
$r = Invoke-Board $l '-Verify' -Rules @((New-CoordRule '^pr view 90\b' '' 1))
Assert-Coord 'T9c a failing gh prints "unknown (...)" and never a state for that row' ((Test-Has $r 'verified: #90 unknown \(') -and -not (Test-Has $r 'verified: #90 OPEN')) $r.Out
$r = Invoke-Board $l
Assert-Coord 'T9d without -Verify gh is not called and the header says "not verified"' ($r.Calls.Count -eq 0 -and @(Get-Lines $r)[0] -match 'not verified\)') "$($r.Calls -join '; ')`n$($r.Out)"

# ---- T10 the Log and Decisions are never read
$l = New-Ledger -Rows @((Get-Row 'a' 'RUNNING 10:00')) -Log @('11:00 F9 from poison: should never show | outcome: PENDING', '11:01 Q9 poison queue [after 01:00]', '- [ ] poison owed', '| poison | row |')
$r = Invoke-Board $l
Assert-Coord 'T10 poison lines in Log and Decisions change nothing (no POISON text, 0 pending, 1 running)' ($r.Code -eq 0 -and $r.Out -notmatch 'poison|POISON' -and $r.Last -match ': 1 running, 0 waiting, 0 queued' -and $r.Last -notmatch 'pending') $r.Out

# ---- T12 the cap
$many = @(); for ($i = 1; $i -le 40; $i++) { $many += (Get-Row ("track{0:D2} with a rather long descriptive title" -f $i) 'WAIT-USER 11:00; merge go for the pull request in the coordinator window') }
$l = New-Ledger -Rows $many
$r = Invoke-Board $l
Assert-Coord 'T12a 40 waiting rows: the output is within 2,000 characters and ends in the STATUS line' ($r.Out.Length -le 2000 -and $r.Last -match '^STATUS 2026-10-27 12:00: 0 running, 40 waiting') "len $($r.Out.Length)"
Assert-Coord 'T12b the cut says how many are left: "... <n> more; -Full or -Group waiting"' (Test-Has $r '  \.\.\. \d+ more; -Full or -Group waiting') $r.Out
$shownRows = @(Get-Lines $r | Where-Object { $_ -match '^  track' }).Count
$more = if ($r.Out -match '\.\.\. (\d+) more') { [int]$Matches[1] } else { -1 }
Assert-Coord 'T12c shown + more = 40 (nothing silently dropped)' ($shownRows + $more -eq 40) "shown $shownRows more $more"
$full = Invoke-Board $l '-Full'
Assert-Coord 'T12d -Full lists all 40 rows, no "more" line' (@(Get-Lines $full | Where-Object { $_ -match '^  track' }).Count -eq 40 -and $full.Out -notmatch ' more; ') ''
$grp = Invoke-Board $l '-Group waiting'
Assert-Coord 'T12e -Group waiting lists all 40, has no other group header, and keeps the STATUS line' (@(Get-Lines $grp | Where-Object { $_ -match '^  track' }).Count -eq 40 -and $grp.Out -notmatch '(?m)^(RUNNING|QUEUED|BLOCKED|DONE)' -and $grp.Last -match '^STATUS ') ''

# ---- T13 read-only
$l = New-Ledger -Rows @((Get-Row 'a' 'RUNNING 10:00' '#99')) -Slots @('1. 10:00 #99 alpha @abc, READY')
$before = (Get-FileHash -LiteralPath $l.Path -Algorithm SHA256).Hash + '|' + ((Get-ChildItem -LiteralPath $l.Dir -Force | ForEach-Object { $_.Name }) -join ',')
$null = Invoke-Board $l
$null = Invoke-Board $l '-Verify -Full' -Rules @((New-CoordRule '^pr view 99\b' $prJson))
$after = (Get-FileHash -LiteralPath $l.Path -Algorithm SHA256).Hash + '|' + ((Get-ChildItem -LiteralPath $l.Dir -Force | ForEach-Object { $_.Name }) -join ',')
Assert-Coord 'T13 the ledger bytes and the folder listing are unchanged after a plain and a -Verify -Full run' ($before -ceq $after) "$before`n$after"

# ---- T14 a ledger made from the real template, every row set with coord-set.ps1 -State and a Queue line
# appended with coord-log.ps1, renders fully classified (the template's "(none)" placeholders are not items)
$setScript = Join-Path $coordScriptsDir 'coord-set.ps1'
$logScript = Join-Path $coordScriptsDir 'coord-log.ps1'
$words = @('QUEUED', 'BRIEFED', 'RUNNING', 'PR-OPEN', 'WAIT-USER', 'WAIT-SLOT', 'WAIT-QUOTA', 'BLOCKED', 'MERGED', 'DONE')
$tpl = [System.Collections.Generic.List[string]]@([System.IO.File]::ReadAllText((Join-Path $coordTemplatesDir 'ledger-template.md')) -split "`r?`n")
$sepAt = -1
for ($k = 1; $k -lt $tpl.Count; $k++) { if ($tpl[$k] -match '^\|-+\|' -and $tpl[$k - 1] -match '^\| Track \|') { $sepAt = $k; break } }
$k = $sepAt
foreach ($w in $words) { $k++; $tpl.Insert($k, "| s$w | C:\Fx\alpha | s | Opus 5.5 | C:\w | b-$w | docs/** | | legacy |") }
$script:caseN++
$tdir = Join-Path $root "c$script:caseN"
[void][IO.Directory]::CreateDirectory($tdir)
$tl = [pscustomobject]@{ Dir = $tdir; Path = (Join-Path $tdir '2026-10-27.md') }
Set-CoordTextFile $tl.Path (($tpl -join "`n"))
$setCodes = @()
foreach ($w in $words) {
    $global:LASTEXITCODE = $null
    $null = & $setScript -Track "s$w" -State $w.ToLowerInvariant() -Text 'set by -State' -Ledger $tl.Path 2>&1
    $setCodes += "$w=$LASTEXITCODE"
}
$global:LASTEXITCODE = $null
$qOut = (@(& $logScript -Section Queue -Text 'Q1 port the next slice [after 2026-10-28 23:00Z] owner: user; source: plan Q3' -Ledger $tl.Path 2>&1) | ForEach-Object { [string]$_ }) -join ' '
$qCode = $LASTEXITCODE
$r = Invoke-Board $tl
$que = Get-GroupBlock $r 'QUEUED'
Assert-Coord 'T14a sepAt found; coord-set -State exits 0 for all ten words; coord-log -Section Queue exits 0' ($sepAt -gt 0 -and @($setCodes | Where-Object { $_ -notmatch '=0$' }).Count -eq 0 -and $qCode -eq 0) "sep=$sepAt set: $($setCodes -join ', ') queue: $qCode $qOut"
Assert-Coord 'T14b the board: 2 running, 4 waiting, 2 queued (the QUEUED row and Q1, its time gate CLOSED), 1 blocked, 2 done; 0 rows unclassified' ($r.Code -eq 0 -and $r.Last -match ': 2 running, 4 waiting, 2 queued \(0 gates open, 0 unknown\), 1 blocked, 2 done; 0 rows unclassified$') $r.Out
Assert-Coord 'T14c Q1 is listed under QUEUED with its gate and CLOSED' (($que -join "`n") -match 'Q1 port the next slice\s+gate: after 2026-10-28 23:00Z  CLOSED  L\d+') ($que -join "`n")
Assert-Coord 'T14d the template''s "1. (none)" slot and "- [ ] (none)" owed line are not items (no open slot, no Owed line)' ($r.Out -notmatch 'slot open, no live row' -and $r.Out -notmatch 'Owed: \(none\)') $r.Out

# ---- T15 the (none) anchors, a carried placeholder, a carried after-Q gate, a done word the terminal rule does not accept
$l = New-Ledger -Rows @((Get-Row 'live' 'RUNNING 10:00')) -Slots @('1. (none) #12 alpha @abc, READY') -Owed @('- [ ] (none) F3 owed by live', '- [ ] (none) (from 2026-10-26)', '- [ ] (none)  ')
$r = Invoke-Board $l
Assert-Coord 'T15a "1. (none) #12 ..." is still an open slot (BLOCKED, no live row carries #12)' (($r.Out -match 'slot open, no live row \(#12\)') -and $r.Last -match ', 1 blocked,') $r.Out
Assert-Coord 'T15b "- [ ] (none) F3 owed ..." is still owed; a carried "- [ ] (none) (from <date>)" and "(none)" with trailing spaces are not' (@(Get-Lines $r | Where-Object { $_ -match '^  Owed: ' }).Count -eq 1 -and $r.Out -match 'Owed: \(none\) F3 owed by live') $r.Out
$l = New-Ledger -Rows @((Get-Row 'live' 'RUNNING 10:00')) -Queue @('08:00 Q1 outcome: started as track 3i (from 2026-10-26)', '08:00 Q2 port it [after Q1] owner: user; source: Q1 (from 2026-10-26)')
$r = Invoke-Board $l
Assert-Coord 'T15c a carried Q1 outcome line alone (no Q1 item) opens Q2''s [after Q1] gate' (((Get-GroupBlock $r 'QUEUED') -join "`n") -match 'Q2 port it\s+gate: after Q1  OPEN') ((Get-GroupBlock $r 'QUEUED') -join "`n")
$l = New-Ledger -Rows @((Get-Row 'slash' 'MERGED/abc1234' '#12'), (Get-Row 'bang' 'DONE!'), (Get-Row 'ok' 'MERGED 10:00 as abc1234' '#13')) -Slots @('1. 10:00 #12 alpha @abc, READY')
$r = Invoke-Board $l
$dn = Get-GroupBlock $r 'DONE today'
Assert-Coord 'T15d "MERGED/abc1234" and "DONE!" are live for every script (Test-CoordRowTerminal): unclassified under WAITING, not DONE; slot #12 shown on its row' ($dn[0] -match '^DONE today \(1\)' -and $r.Last -match '; 2 rows unclassified' -and ((Get-GroupBlock $r 'WAITING') -join "`n") -match 'slash .*unclassified: MERGED.*slot open \(L\d+\)') $r.Out

# ---- T16 the ACK word and the BRIEFED clock; a bracket in the item text
$l = New-Ledger -Rows @((Get-Row 'fb' 'BRIEFED 11:30; brief sent, feedback owed'), (Get-Row 'night' 'BRIEFED 23:50; brief sent'), (Get-Row 'lower' 'BRIEFED 11:00; ack seen'))
$r = Invoke-Board $l
$fbLine = @(Get-Lines $r | Where-Object { $_ -match '^  fb ' })[0]; $nLine = @(Get-Lines $r | Where-Object { $_ -match '^  night ' })[0]; $lwLine = @(Get-Lines $r | Where-Object { $_ -match '^  lower ' })[0]
Assert-Coord 'T16a "feedback" does not count as an ACK: BRIEFED 30 minutes ago still says no ACK (30 min)' ($fbLine -match 'no ACK \(30 min\)') $fbLine
Assert-Coord 'T16b a BRIEFED stamp later than the clock is from before midnight: no ACK (730 min), never negative' ($nLine -match 'no ACK \(730 min\)') $nLine
Assert-Coord 'T16c lower-case "ack seen" is not an ACK' ($lwLine -match 'no ACK \(60 min\)') $lwLine
$l = New-Ledger -Rows @((Get-Row 'live' 'RUNNING 10:00')) -Queue @('08:00 Q2 fix [F3] regression [after 11:00] owner: user; source: F3')
$r = Invoke-Board $l
Assert-Coord 'T16d a bracket in the item text does not take the gate: "[F3]" stays in the text, [after 11:00] reads OPEN' (((Get-GroupBlock $r 'QUEUED') -join "`n") -match 'Q2 fix \[F3\] regression\s+gate: after 11:00  OPEN') ((Get-GroupBlock $r 'QUEUED') -join "`n")

# ---- T17 the gate is the last bracket group shaped like a gate; only the legacy "ACK HH:mm" answers a BRIEFED row;
# placeholders in any case and with any number of (from ...) tails; a local gate and its UTC rewrite read the same
$l = New-Ledger -Rows @((Get-Row 'live' 'RUNNING 10:00')) -Queue @(
    '08:00 Q1 port it [after 11:00] owner: me; source: [plan](notes/x.md)',
    '08:00 Q2 port it [after 11:00] owner: me; source: note [draft',
    '08:00 Q3 fix [F3] regression [after 11:00] owner: me [phone]',
    '08:00 Q4 odd item [tbd] owner: me')
$r = Invoke-Board $l
$q = (Get-GroupBlock $r 'QUEUED') -join "`n"
Assert-Coord 'T17a a bracket in source after the gate does not take it over: Q1 gate after 11:00 OPEN' ($q -match 'Q1 port it\s+gate: after 11:00  OPEN') $q
Assert-Coord 'T17b an unclosed "[" after the gate does not hide it: Q2 gate after 11:00 OPEN' ($q -match 'Q2 port it\s+gate: after 11:00  OPEN') $q
Assert-Coord 'T17c brackets before and after the gate: Q3 keeps [F3] in its text, gate after 11:00 OPEN' ($q -match 'Q3 fix \[F3\] regression\s+gate: after 11:00  OPEN') $q
Assert-Coord 'T17d no gate-shaped group: the first bracket text is printed as is with ?' ($q -match 'Q4 odd item\s+gate: tbd  \?') $q
$l = New-Ledger -Rows @((Get-Row 'noack' 'BRIEFED 11:00; no ACK yet'), (Get-Row 'legacy' 'BRIEFED 11:00; ACK 11:05')) -Slots @('1. (None)', '2. (none) (from 2026-10-25) (from 2026-10-26)') -Owed @('- [ ] (NONE)', '- [ ] (none) (from 2026-10-25) (from 2026-10-26)')
$r = Invoke-Board $l
$naLine = @(Get-Lines $r | Where-Object { $_ -match '^  noack ' })[0]; $lgLine = @(Get-Lines $r | Where-Object { $_ -match '^  legacy ' })[0]
Assert-Coord 'T17e "no ACK yet" is not an ACK: no ACK (60 min); the legacy "ACK 11:05" is' ($naLine -match 'no ACK \(60 min\)' -and $lgLine -notmatch 'no ACK') "$naLine`n$lgLine"
Assert-Coord 'T17f placeholders in any case and with two (from ...) tails are not items' ($r.Out -notmatch 'slot open, no live row' -and $r.Out -notmatch 'Owed: ') $r.Out
$loc = [DateTime]::ParseExact('2026-10-27 23:30', 'yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
$utc = $loc.ToUniversalTime().ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
$l = New-Ledger -Rows @((Get-Row 'live' 'RUNNING 10:00')) -Queue @('08:00 Q1 local [after 23:30]', "08:00 Q2 converted [after ${utc}Z]")
$spath = if ($ScriptPath) { [System.IO.Path]::GetFullPath($ScriptPath) } else { '' }
$states = foreach ($c in @('2026-10-27 23:20', '2026-10-27 23:40')) {
    $rr = Invoke-CoordScript -Name 'coord-status.ps1' -Cwd $l.Dir -ScriptArgs ("-Ledger `"$($l.Path)`" -Now `"$c`"") -ScriptPath $spath
    $qq = (Get-GroupBlock $rr 'QUEUED') -join "`n"
    $s1 = if ($qq -match 'Q1 local\s+gate: after \S+  (\S+)') { $Matches[1] } else { '-' }
    $s2 = if ($qq -match 'Q2 converted\s+gate: after \S+ \S+  (\S+)') { $Matches[1] } else { '-' }
    "$c $s1 $s2"
}
Assert-Coord "T17g a local [after 23:30] and its UTC rewrite [after ${utc}Z] read the same, CLOSED at 23:20 and OPEN at 23:40 local" (($states -join '|') -ceq '2026-10-27 23:20 CLOSED CLOSED|2026-10-27 23:40 OPEN OPEN') ($states -join '|')

# ---- T18 the gate is the last gate-shaped group BEFORE " owner:"; a gate-shaped bracket quoted in owner/source text
# does not take it over
$l = New-Ledger -Rows @((Get-Row 'live' 'RUNNING 10:00')) -Queue @(
    '08:00 Q1 port it [after 11:00] owner: me; source: D3 "start it [after #99 merges]"',
    '08:00 Q2 wait [after Q9] owner: me; source: handover [needs review]',
    '08:00 Q3 port it [after 11:00] owner: me; source: [after the retro](x.md)',
    '08:00 Q4 no owner part [needs user] then [after 11:00]')
$r = Invoke-Board $l
$q = (Get-GroupBlock $r 'QUEUED') -join "`n"
Assert-Coord 'T18a a quoted "[after #99 merges]" in source does not take the gate: Q1 gate after 11:00 OPEN, text "port it"' ($q -match 'Q1 port it\s+gate: after 11:00  OPEN') $q
Assert-Coord 'T18b a "[needs review]" in source does not take the gate: Q2 gate after Q9 CLOSED' ($q -match 'Q2 wait\s+gate: after Q9  CLOSED') $q
Assert-Coord 'T18c an "[after the retro]" link in source does not take the gate: Q3 gate after 11:00 OPEN' ($q -match 'Q3 port it\s+gate: after 11:00  OPEN') $q
Assert-Coord 'T18d a line with no owner part: the last gate-shaped group, Q4 gate after 11:00 OPEN' ($q -match 'Q4 no owner part \[needs user\] then\s+gate: after 11:00  OPEN') $q
$rv = Invoke-Board $l '-Verify' -Rules @((New-CoordRule '^pr view 99\b' '{"state":"MERGED"}'))
Assert-Coord 'T18e with -Verify, gh is never asked about the quoted #99 (the recorded calls), and #99 is not printed' (@($rv.Calls | Where-Object { "$_" -match '\b99\b' }).Count -eq 0 -and -not ($rv.Out -match '#99') -and (((Get-GroupBlock $rv 'QUEUED') -join "`n") -match 'Q1 port it\s+gate: after 11:00  OPEN')) $rv.Out

# ---- T19 the real index folder
Assert-Coord 'T19 the real index folder (COORD_INDEX_DIR as before this run, else $HOME/.claude/coordination: its listing and the SHA-256 of every file outside sessions/, or still absent) is unchanged by this run' ((Get-CoordRealIndexDigest) -ceq $realIndexBefore) "before:`n$realIndexBefore`nafter:`n$(Get-CoordRealIndexDigest)"

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
Write-CoordUncheckedSummary
Write-Host ""
Write-Host "Passed: $script:coordPass  Failed: $script:coordFail"
if ($script:coordFail -gt 0) { exit 1 }
exit 0
