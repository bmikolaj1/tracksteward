# Ported from the private coordinate toolkit (coord-status.ps1), 2026-10-29.
#
# coord-status.ps1 - the coordinator's status board: what runs, waits, is queued, is blocked, is done.
#
# One read-only pass over the STRUCTURED sections of today's ledger (Tracks, Merge slots, Owed checks, Findings,
# Queue), never the Log or Decisions, so it stays cheap on a long ledger: about 2,000 characters against the whole
# file. Every row, finding, owed-check, queue and slot line ends in `L<n>`, the ledger line it came from (a DONE entry
# ends in its PR number and sha instead).
#
# Groups (the first word of a Tracks row's Status cell decides; anything else is UNCLASSIFIED and listed under WAITING):
#   QUEUED -> QUEUED                    BRIEFED, WAIT-USER, WAIT-SLOT, WAIT-QUOTA -> WAITING
#   RUNNING, PR-OPEN -> RUNNING         BLOCKED -> BLOCKED              MERGED, DONE -> DONE
# The words are Get-CoordStateWords (coord-common.ps1). MERGED and DONE count as DONE only when Test-CoordRowTerminal
# agrees ("MERGED/x" is live for every other script, so it is unclassified here). BRIEFED with no legacy "ACK HH:mm"
# after 15 minutes says so (the skill has an ACKed row set to RUNNING; a note such as "no ACK yet" is not an ACK); a
# stamp later than the clock is yesterday's.
# Also WAITING: Findings F<n> with no later `F<n> outcome:` line, unticked Owed checks. Also BLOCKED: an open Merge
# slot no live row carries. The template's placeholders `1. (none)` and `- [ ] (none)` (any case, with any number of
# `(from <date>)` tails) are not items. QUEUED also takes the `Q<n>` lines of the Queue section with no `Q<n> outcome:`
# line; the gate is the LAST bracket group shaped like one, `[after ...]` or `[needs ...]`, before ` owner:` (the
# whole line when it has no ` owner:`; with no such group there, the first group there), read OPEN, CLOSED or ? (only these shapes: after #<n> merges, after <yyyy-MM-dd> <HH:mm>Z (UTC), after
# <HH:mm> (local), after Q<n>, needs <who> ...). The line shows the text before the gate, cut.
#
# Last line, always: STATUS <yyyy-MM-dd HH:mm>: <counts>. A ledger that cannot be read prints ONE line,
# `STATUS: could not read - <reason>`, exit 2, nothing else (never "none" for a failure).
#
# -Verify: for each live row with a PR that is not in the QUEUED group, `gh pr view` (state, head, mergeStateStatus)
#   printed under the row; a row that says MERGED while its PR is not counts as MISMATCH; a Queue gate
#   `[after #<n> merges]` is read from gh as well (OPEN once the PR is merged). A failed call prints
#   `unknown (<why>)`, never a state. Branch heads are not fetched here (slot-check.ps1 owns them).
# -Full: no 2,000-character cap. -Group <name>: only that group, uncapped.
# -Now 'yyyy-MM-dd HH:mm': the clock (tests); default the local clock.
# Without -Ledger: today's ledger, from the repo's MAIN checkout only (from a linked worktree or another repo pass
# -Ledger).
# Usage, from the PowerShell tool, in process:
#   & "<plugin root>/scripts/coord-status.ps1" [-Ledger <path>] [-Verify] [-Full] [-Group running|waiting|queued|blocked|done]
# From the Bash tool (Git Bash), the script path goes through cygpath -w and a -Ledger is written in Windows form (C:/...):
#   MSYS_NO_PATHCONV=1 powershell.exe -ExecutionPolicy Bypass -File "$(cygpath -w "<plugin root>/scripts/coord-status.ps1")" [-Ledger <path>] ...
# Writes nothing, takes no lock, registers nothing.

param(
    [string]$Ledger = '',
    [switch]$Verify,
    [switch]$Full,
    [ValidateSet('', 'running', 'waiting', 'queued', 'blocked', 'done')][string]$Group = '',
    [string]$Now = ''
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'coord-common.ps1')
Initialize-CoordConsole

function Exit-Unreadable([string]$Reason) {
    Write-Output "STATUS: could not read - $Reason"
    exit 2
}

$at = [DateTime]::Now
if ($Now) {
    $parsed = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact($Now, 'yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        Exit-Unreadable "-Now '$Now' is not yyyy-MM-dd HH:mm"
    }
    $at = $parsed
}
$cap = 2000

$arg = Resolve-CoordLedgerArg $Ledger
if (-not $arg.Ok) { Exit-Unreadable $arg.Error }
$path = $arg.Ledger
if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Exit-Unreadable "no ledger at $path" }
$file = Read-CoordLedgerFile $path
if (-not $file.Ok) { Exit-Unreadable $file.Error }
$lines = $file.Lines

# Sections: Tracks must exist exactly once; the others may be absent (a ledger from before the Queue section) but not doubled.
function Get-Section([string]$Name, [bool]$Required) {
    $s = Find-CoordSectionEnd $lines $Name $path
    if (-not $s.Ok) {
        if ($s.Error -match 'found (\d+) ' -and [int]$Matches[1] -eq 0 -and -not $Required) { return $null }
        Exit-Unreadable $s.Error
    }
    return $s
}
$secTracks = Get-Section 'Tracks' $true
$secSlots = Get-Section 'Merge slots' $false
$secOwed = Get-Section 'Owed checks' $false
$secFind = Get-Section 'Findings' $false
$secQueue = Get-Section 'Queue' $false

try { $rows = @(Read-CoordLedgerTracks $path) } catch { Exit-Unreadable $_.Exception.Message }

# Line number (1-based) of each data row, in the order the reader returns them.
$rowLine = New-Object System.Collections.Generic.List[int]
$seenHeader = $false
for ($k = $secTracks.Header + 1; $k -lt $secTracks.End; $k++) {
    $l = $lines[$k]
    if (-not $l.TrimStart().StartsWith('|')) { continue }
    if (-not $seenHeader) { $seenHeader = $true; continue }
    if ($l -match '^[\s|:-]+$' -and $l.Contains('-')) { continue }
    $rowLine.Add($k + 1)
}

function Get-SectionLines($Sec) {
    if (-not $Sec) { return @() }
    $o = @()
    for ($k = $Sec.Header + 1; $k -lt $Sec.End; $k++) { $o += , @(($k + 1), $lines[$k]) }
    return $o
}

function Get-FirstWord([string]$Status) {
    if ($Status -match '^\s*([A-Za-z][A-Za-z-]*)') { return $Matches[1] }
    return ''
}
function Get-PrNumber([string]$Cell) {
    if ($Cell -match '#(\d+)') { return [int]$Matches[1] }
    if ($Cell -match '/pull/(\d+)') { return [int]$Matches[1] }
    return 0
}
function Get-Trunc([string]$Text, [int]$Max) {
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max - 3) + '...'
}

# ---- Merge slots: open ones, by PR number
$openSlots = @()
foreach ($e in (Get-SectionLines $secSlots)) {
    # the template's placeholder "1. (none)" is not a slot
    if ($e[1] -match '^\d+\.\s' -and $e[1] -notmatch '^\d+\.\s+\(none\)(\s+\(from [^)]*\))*\s*$' -and $e[1] -cnotmatch 'MERGED|VOIDED|slot free') {
        $openSlots += , ([pscustomobject]@{ Line = $e[0]; Pr = (Get-PrNumber $e[1]); Text = $e[1] })
    }
}

# ---- Tracks
$vocab = Get-CoordStateWords
$g = @{ running = @(); waiting = @(); queued = @(); blocked = @(); done = @() }
$gCount = @{ running = 0; waiting = 0; queued = 0; blocked = 0; done = 0 }
$unclassified = 0
$mismatch = 0
$matchedSlots = @{}
$doneBits = @()
$verifyLines = @{}

for ($i = 0; $i -lt $rows.Count; $i++) {
    $r = $rows[$i]
    $ln = $rowLine[$i]
    $word = Get-FirstWord $r.Status
    $isTerminal = Test-CoordRowTerminal $r.Status
    # a done word the terminal rule refuses ("MERGED/x", "DONE!") is a live row for every other script: unclassified
    $known = $vocab.Contains($word) -and $word -ceq $word.ToUpperInvariant() -and ($vocab[$word] -ne 'done' -or $isTerminal)
    $key = if ($isTerminal) { 'done' } elseif ($known) { $vocab[$word] } else { 'waiting' }
    $classified = $isTerminal -or $known
    if (-not $classified) { $unclassified++ }
    $pr = Get-PrNumber $r.PR
    if (-not $pr) { $pr = Get-PrNumber $r.Status }
    $prText = if ($pr) { "PR #$pr" } else { 'no PR' }
    $status = $r.Status
    $extra = ''
    if (-not $classified) { $extra = "  [unclassified: $(if ($word) { $word } else { 'empty' })]" }
    if ($word -ceq 'BRIEFED' -and $r.Status -match 'BRIEFED\s+(\d\d):(\d\d)') {
        $stamp = $at.Date.AddHours([int]$Matches[1]).AddMinutes([int]$Matches[2])
        # a stamp later than the clock was written before midnight
        if ($stamp -gt $at) { $stamp = $stamp.AddDays(-1) }
        $mins = [int]($at - $stamp).TotalMinutes
        # only the legacy append "ACK HH:mm" answers the brief; "no ACK yet" or "feedback" do not
        if ($mins -gt 15 -and $r.Status -cnotmatch '\bACK \d\d:\d\d\b') { $extra = ", no ACK ($mins min)" }
    }
    if ($isTerminal) {
        $sha = ''
        if ($r.Status -match '\bas ([0-9a-f]{7,40})\b') { $sha = $Matches[1].Substring(0, [Math]::Min(7, $Matches[1].Length)) }
        $doneBits += $(if ($pr) { "#$pr $sha".Trim() } else { ((Get-Trunc $r.Track 18) + " $sha").Trim() })
        $gCount.done++
        # a closed row's PR is not an open slot
        continue
    }
    $slotNote = ''
    if ($pr) {
        foreach ($s in $openSlots) { if ($s.Pr -eq $pr) { $matchedSlots[$s.Line] = $true; $slotNote = "  slot open (L$($s.Line))" } }
    }
    $mdl = if ($r.Model) { '  ' + (Get-Trunc $r.Model 22) } else { '' }
    $line = '  {0,-34} {1}{2}{3}  {4}{5}  L{6}' -f (Get-Trunc $r.Track 34), (Get-Trunc $status 60), $extra, $mdl, $prText, $slotNote, $ln
    $gCount[$key]++
    $g[$key] += $line
    if ($Verify -and $pr -and $key -ne 'queued') {
        $cwd = if ($r.Repo -and (Test-Path -LiteralPath $r.Repo -PathType Container)) { $r.Repo } else { (Get-Location).Path }
        Push-Location -LiteralPath $cwd
        try { $j = Invoke-CoordGhJson @('pr', 'view', "$pr", '--json', 'state,headRefOid,mergeStateStatus') }
        finally { Pop-Location }
        if ($j.Ok) {
            $sha12 = ([string]$j.Data.headRefOid)
            if ($sha12.Length -gt 12) { $sha12 = $sha12.Substring(0, 12) }
            $g[$key] += "    verified: #$pr $($j.Data.state) @$sha12, $($j.Data.mergeStateStatus)"
        }
        else { $g[$key] += "    verified: #$pr unknown ($($j.Error))" }
    }
}
# MISMATCH: a MERGED row whose PR is not merged (only checked with -Verify)
if ($Verify) {
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $r = $rows[$i]
        if ($r.Status -cnotmatch '^\s*MERGED') { continue }
        $pr = Get-PrNumber $r.PR
        if (-not $pr) { $pr = Get-PrNumber $r.Status }
        if (-not $pr) { continue }
        $cwd = if ($r.Repo -and (Test-Path -LiteralPath $r.Repo -PathType Container)) { $r.Repo } else { (Get-Location).Path }
        Push-Location -LiteralPath $cwd
        try { $j = Invoke-CoordGhJson @('pr', 'view', "$pr", '--json', 'state,headRefOid,mergeStateStatus') }
        finally { Pop-Location }
        if ($j.Ok -and [string]$j.Data.state -ne 'MERGED') {
            $mismatch++
            $g.done += "    MISMATCH: #$pr is $($j.Data.state), the row says MERGED (L$($rowLine[$i]))"
        }
    }
}

# open slots no live row carries
foreach ($s in $openSlots) {
    if (-not $matchedSlots.ContainsKey($s.Line)) {
        $gCount.blocked++
        $g.blocked += ('  slot open, no live row{0}  L{1}' -f $(if ($s.Pr) { " (#$($s.Pr))" } else { '' }), $s.Line)
    }
}

# ---- Findings: F<n> from ... with no later "<id> outcome:" line
$pending = 0
$findEntries = Get-SectionLines $secFind
$closed = @{}
foreach ($e in $findEntries) {
    if ($e[1] -match '^\d\d:\d\d\s+(c?F\d+)\s+outcome:') { $closed[$Matches[1]] = $true }
}
foreach ($e in $findEntries) {
    if ($e[1] -match '^\d\d:\d\d\s+(c?F\d+)\s+from\s' -and -not $closed.ContainsKey($Matches[1])) {
        $id = $Matches[1]
        $since = if ($e[1] -match '^(\d\d:\d\d)') { $Matches[1] } else { '?' }
        $what = ($e[1] -replace '^\d\d:\d\d\s+c?F\d+\s+from\s+', '')
        $pending++
        $gCount.waiting++
        $g.waiting += ('  {0} {1}   PENDING since {2}  L{3}' -f $id, (Get-Trunc $what 60), $since, $e[0])
    }
}

# ---- Owed checks
$owedOpen = 0
$unrecognised = 0
foreach ($e in (Get-SectionLines $secOwed)) {
    $t = $e[1]
    # the template's placeholder "- [ ] (none)" is not an owed check, in any case and with any "(from <date>)" tails
    if ($t -match '^- \[ \] \(none\)(\s+\(from [^)]*\))*\s*$') { continue }
    if ($t -cmatch '^- \[ \] (.*)$') {
        $owedText = $Matches[1]
        $owedOpen++
        $gCount.waiting++
        $g.waiting += ('  Owed: {0}  L{1}' -f (Get-Trunc ($owedText -replace '\s*\(from [^)]*\)', '') 70), $e[0])
    }
    elseif ($t -cmatch '^\s*([*+]|\d+\.)\s+\[.\]' -or $t -cmatch '^- \[[^ xX]\]') { $unrecognised++ }
}

# ---- Queue: Q<n> lines with no later "Q<n> outcome:" line
$gatesOpen = 0
$gatesUnknown = 0
$queueEntries = Get-SectionLines $secQueue
$qClosed = @{}
foreach ($e in $queueEntries) { if ($e[1] -match '^\d\d:\d\d\s+(Q\d+)\s+outcome:') { $qClosed[$Matches[1]] = $true } }
foreach ($e in $queueEntries) {
    if ($e[1] -notmatch '^\d\d:\d\d\s+(Q\d+)\s+(?!outcome:)(.*)$') { continue }
    $qid = $Matches[1]
    $rest = $Matches[2]
    if ($qClosed.ContainsKey($qid)) { continue }
    $gate = ''
    $state = '?'
    $what = $rest
    # the gate is the LAST bracket group shaped like a gate, "[after ...]" or "[needs ...]", BEFORE " owner:" (the
    # line shape: Q<n> <what> [<gate>] owner: ...; source: ...): a bracket in the text ("fix [F3]
    # regression"), an unclosed "[", or any bracket after " owner:" (a quoted "[after #99 merges]" in source) does not
    # take it over. A line with no " owner:" is searched whole. With no gate-shaped group the first group is the gate,
    # printed as is with ?
    $ownerAt = $rest.IndexOf(' owner:', [System.StringComparison]::Ordinal)
    $scope = if ($ownerAt -ge 0) { $rest.Substring(0, $ownerAt) } else { $rest }
    $groups = @([regex]::Matches($scope, '\[([^\[\]]*)\]'))
    $pick = @($groups | Where-Object { $_.Groups[1].Value -match '^\s*(after|needs)\s' } | Select-Object -Last 1)
    if (-not $pick.Count -and $groups.Count) { $pick = @($groups[0]) }
    if ($pick.Count) {
        $what = $rest.Substring(0, $pick[0].Index).TrimEnd()
        $gate = $pick[0].Groups[1].Value
        if ($gate -match '^after\s+#(\d+)\s+merges$') {
            if ($Verify) {
                $j = Invoke-CoordGhJson @('pr', 'view', $Matches[1], '--json', 'state')
                $state = if ($j.Ok) { if ([string]$j.Data.state -eq 'MERGED') { 'OPEN' } else { 'CLOSED' } } else { '?' }
            }
        }
        elseif ($gate -match '^after\s+(\d{4}-\d\d-\d\d)\s+(\d\d:\d\d)Z$') {
            $when = [DateTime]::MinValue
            if ([DateTime]::TryParseExact("$($Matches[1]) $($Matches[2])", 'yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$when)) {
                $state = if ($at.ToUniversalTime() -ge $when) { 'OPEN' } else { 'CLOSED' }
            }
        }
        elseif ($gate -match '^after\s+(\d\d):(\d\d)$') {
            $when = $at.Date.AddHours([int]$Matches[1]).AddMinutes([int]$Matches[2])
            $state = if ($at -ge $when) { 'OPEN' } else { 'CLOSED' }
        }
        elseif ($gate -match '^after\s+(Q\d+)$') {
            $state = if ($qClosed.ContainsKey($Matches[1])) { 'OPEN' } else { 'CLOSED' }
        }
    }
    if ($state -eq 'OPEN') { $gatesOpen++ } elseif ($state -eq '?') { $gatesUnknown++ }
    $gCount.queued++
    $g.queued += ('  {0} {1}   gate: {2}  {3}  L{4}' -f $qid, (Get-Trunc $what 46), $(if ($gate) { Get-Trunc $gate 30 } else { 'none' }), $state, $e[0])
}

# ---- Output
$names = 'running', 'waiting', 'queued', 'blocked', 'done'
$ledgerNote = if ($Verify) { 'verified' } else { 'not verified' }
$date = Get-CoordLedgerDate ([System.IO.Path]::GetFileNameWithoutExtension($path))
if (-not $date) { $date = $at.ToString('yyyy-MM-dd') }
$stamp = $at.ToString('HH:mm')
$head = "STATUS BOARD $date $stamp (ledger $path; $ledgerNote)"
$tail = "STATUS ${date} ${stamp}: $($gCount.running) running, $($gCount.waiting) waiting, $($gCount.queued) queued ($gatesOpen gates open, $gatesUnknown unknown), $($gCount.blocked) blocked, $($gCount.done) done; $unclassified rows unclassified"
if ($pending) { $tail += "; $pending findings pending" }
if ($unrecognised) { $tail += "; $unrecognised owed-check lines in an unrecognised box shape" }
if ($mismatch) { $tail += "; $mismatch MISMATCH" }

$out = New-Object System.Collections.Generic.List[string]
$out.Add($head)
# the DONE line (label + up to 160 characters of entries) and the group headers after the first group are reserved
$budget = $cap - $head.Length - $tail.Length - 4 - 240
foreach ($n in $names) {
    if ($Group -and $Group -ne $n) { continue }
    $title = $n.ToUpperInvariant()
    if ($n -eq 'done') {
        $label = "DONE today ($($gCount.done))"
        $bits = ''
        if ($doneBits.Count) { $bits = '  ' + ($doneBits -join ', ') }
        $detail = $g.done
        $dl = $label + $(if ($Full -or $Group) { $bits } else { Get-Trunc $bits 160 })
        $out.Add($dl)
        $budget -= $dl.Length + 1
        foreach ($x in $detail) { $out.Add($x); $budget -= $x.Length + 1 }
        continue
    }
    $hdr = "$title ($($gCount[$n]))"
    $out.Add($hdr)
    $budget -= $hdr.Length + 1
    $items = @($g[$n])
    $shown = 0
    foreach ($x in $items) {
        if (-not $Full -and -not $Group -and ($budget - $x.Length - 1) -lt 60 -and $shown -lt $items.Count) {
            $left = @($items | Where-Object { $_ -notmatch '^    ' }).Count - @($items[0..($shown - 1)] | Where-Object { $_ -notmatch '^    ' }).Count
            if ($shown -eq 0) { $left = @($items | Where-Object { $_ -notmatch '^    ' }).Count }
            $out.Add("  ... $left more; -Full or -Group $n")
            $budget -= 40
            break
        }
        $out.Add($x)
        $budget -= $x.Length + 1
        $shown++
    }
}
$out.Add($tail)
foreach ($o in $out) { Write-Output $o }
exit 0
