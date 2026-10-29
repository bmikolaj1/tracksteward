# Ported from the private coordinate toolkit (coord-set.ps1), 2026-10-29.
#
# coord-set.ps1 - change one Tracks cell (Status or Model) with a time the
# script takes from its own clock.
#
# Times typed by hand into the Status cell and the Model cell drift.
# coord-log.ps1 stamps an appended line; this script stamps the cells that are
# edited in place. (Outcome lines are appended, so they are coord-log.ps1's.
# Ticking an Owed check is not done here: tick it by hand with a time from
# Get-Date.)
#
#   -Track <name> [-Repo <full path>] [-Cell Status|Model] -Text '<text>' [-Append]
#       The Tracks row whose Track cell is <name> (case-insensitive). The row
#       must be one: a name on rows of two repos needs -Repo, a name twice in
#       one repo is refused (rename one). -Cell defaults to Status. -Text
#       replaces the cell; with -Append it is added after the cell's raw text
#       (", " after a Status cell, "; " after a Model cell, nothing before it
#       when the cell is empty). Every other cell and line is unchanged.
#   -State <word>: the Status cell becomes "<WORD> HH:mm; <text>", the word one
#       of QUEUED, BRIEFED, RUNNING, PR-OPEN, WAIT-USER, WAIT-SLOT, WAIT-QUOTA,
#       BLOCKED, MERGED, DONE (Get-CoordStateWords; any case in, upper case
#       out), the time from the clock; coord-status.ps1 groups the row by it.
#       Any other word, a blank -State, or -State with -Cell Model, is refused.
#       With -Append the text is appended as above, and only when the cell's
#       first word already is <word> (a state change replaces the cell). A cell
#       set without -State is written as before; the board classifies it by its
#       first word, so a legacy cell ("running", "briefed 08:32") counts as
#       unclassified.
#   A Status set that FINISHES a live row (the new text starts with MERGED or DONE,
#   backticks ignored, as the readers do; a row that was finished already, or a
#   Model set, prints nothing extra) prints a second line, "COORD-SET NOTE: ...
#   FINISHED": slot-check, coord-brief, coord-handoff and merge-verify and the scope
#   guard treat such a row as not live. The reverse flip, a finished row set back to
#   live, prints "COORD-SET NOTE: ... LIVE again": those scripts and the guard pick
#   the row up again.
#
# Time: {now} in -Text is replaced by HH:mm from Get-Date, every one of them, from
# one clock read. (Only this script expands {now}: coord-log.ps1 stamps the line
# it appends and leaves a {now} in its text as typed.) A time typed by hand
# (H:mm or HH:mm not inside a longer number: "9:05pm", "09:12Z", "T10:22" and
# "09:12:30" all count) is refused: write {now}. The line number of a file
# reference ("coord-brief.ps1:96") is not a time; a ratio, a port map and an id
# with a colon ("F3:12") are refused too (Test-CoordTypedTime): rephrase. NOT
# caught: a time glued right after a dotted word ("done.T10:22").
# -Text is refused (nothing written) when empty, when it holds a pipe (it would
# split the table cell), a line break or another control character; surrounding
# spaces are trimmed. So is any argument left over after the parameters (a split
# text: see coord-log.ps1, Usage; no parameter binds by position).
#
# Writing: the same as coord-log.ps1. Runs are serialized by
# <ledger>.coord-log.lock, the one lock of every ledger writer, so a coord-set
# and a coord-log (or coord-handoff) run never both read the old ledger. The
# ledger is compared with what was read before each swap try and a change is
# refused, not merged; its encoding (UTF-8, BOM or not) is kept, and so is the
# line end (CRLF when the file holds any CRLF, else LF: a file that mixes both
# comes back with one, as with coord-log.ps1).
# The helpers are in coord-common.ps1 (Resolve-CoordLedgerArg,
# Enter-CoordLedgerLock, Read-CoordLedgerFile, Find-CoordSectionEnd,
# ConvertFrom-CoordTracksRows, Write-CoordLedgerSwap). The table is parsed with
# the reader the other scripts use, so a ragged row, a missing Repo, Branch or
# Scope column or a Tracks header that is not there once is refused, and the
# changed row keeps its cell count (the scope guard warns about a ledger whose
# table is malformed, see its header). Cell padding of the changed cell
# becomes one space each side. The ledger is not registered here (that is
# coord-log.ps1 -Register); a missing ledger is not created. Like coord-log.ps1
# it edits the ledger it is given, canonical or not: a linked worktree's stale
# copy of today's ledger is edited and reported as written, so pass the main
# checkout's ledger (the default does, and refuses anywhere else).
#
# Without -Ledger: today's ledger, from the repo's MAIN checkout only (from a
# linked worktree or another repo pass -Ledger). Anything that probes or tests
# the script passes a scratch -Ledger.
#
# Usage, from the PowerShell tool, in process, the text in single quotes (a ' in
# the text is doubled, 'the user''s go'):
#   & "<plugin root>/scripts/coord-set.ps1" -Track '<name>' -State BRIEFED -Text 'brief sent'
#   & "<plugin root>/scripts/coord-set.ps1" -Track '<name>' -State RUNNING -Text 'ACK'
#   & "<plugin root>/scripts/coord-set.ps1" -Track '<name>' -State RUNNING -Text 'round 2 at {now}' -Append
#   & "<plugin root>/scripts/coord-set.ps1" -Track '<name>' -Cell Model -Text '{now} <model> <effort>' -Append
# Not through `powershell.exe -File` from the PowerShell tool (Windows
# PowerShell 5.1 drops the double quotes inside the text); from the Bash tool
# use the coord-log.ps1 form: MSYS_NO_PATHCONV=1 powershell.exe
# -ExecutionPolicy Bypass -File "$(cygpath -w "<plugin root>/scripts/coord-set.ps1")" ...
# Prints: COORD-SET <ledger> [Tracks <track> <Cell>]: <the new cell>
#     or: COORD-SET: NOT WRITTEN - <reason>
# Exit: 0 written; 2 not written. (A call PowerShell cannot bind at all, such as
# -Text with no value, fails before the script runs: exit 1, nothing written.)

[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Track = '',
    [string]$Repo = '',
    [string]$Cell = 'Status',
    [string]$Text = '',
    [string]$State = '',
    [switch]$Append,
    [string]$Ledger = '',
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest = @()
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'coord-common.ps1')
Initialize-CoordConsole

$script:lock = $null
$notice = ''
function Exit-NotWritten([string]$Reason) {
    if ($script:lock) { $script:lock.Dispose(); $script:lock = $null }
    Write-Output "COORD-SET: NOT WRITTEN - $Reason"
    exit 2
}

if ($Rest.Count) {
    # The words that did not bind are either a -Text that was split on its way in (the usual case, see Usage) or
    # -Tick / -Note, which this script does not have: the refusal always says the first and, when a word is -Tick or
    # -Note, also the second.
    $why = 'the text was split; pass it as one single-quoted -Text, in process with & (see Usage)'
    if (@($Rest | Where-Object { $_ -match '^-(Tick|Note)(:|$)' }).Count) { $why = '-Tick and -Note are not parameters of this script: tick an Owed check by hand. Otherwise the text was split; pass it as one single-quoted -Text, in process with & (see Usage)' }
    Exit-NotWritten "unexpected words after the parameters ($($Rest -join ' ')): $why"
}

# The rule for -Text: one line, no pipe, no typed time. Returns the trimmed text.
function Get-CheckedText([string]$Name, [string]$Value) {
    $t = $Value.Trim()
    if (-not $t) { Exit-NotWritten "$Name is empty" }
    # C0 controls but tab, DEL, NEL, and the line and paragraph separators, checked on the untrimmed value
    # (Trim() would drop a leading or trailing one); built from [char]: this file stays ASCII.
    if ($Value -match ('[\x00-\x08\x0A-\x1F\x7F\x85' + [char]0x2028 + [char]0x2029 + ']')) { Exit-NotWritten "$Name holds a line break or a control character; one line per event" }
    if ($t.Contains('|')) { Exit-NotWritten "$Name holds a pipe; it would split the table cell" }
    if (Test-CoordTypedTime $t) { Exit-NotWritten "$Name holds a typed time; the script stamps it: write {now} where the time goes" }
    return $t
}

$wantTrack = $Track.Trim()
if (-not $wantTrack) { Exit-NotWritten '-Track is needed: the name of the Tracks row to set' }
$cellName = @('Status', 'Model') | Where-Object { [string]::Equals($_, $Cell.Trim(), [System.StringComparison]::OrdinalIgnoreCase) }
if (-not $cellName) { Exit-NotWritten "-Cell must be Status or Model (got '$Cell')" }
$newText = Get-CheckedText '-Text' $Text
# -State: the first word of the Status cell from the vocabulary (Get-CoordStateWords), written upper case.
$stateWord = ''
if ($PSBoundParameters.ContainsKey('State')) {
    $words = @((Get-CoordStateWords).Keys)
    $stateWord = @($words | Where-Object { [string]::Equals($_, $State.Trim(), [System.StringComparison]::OrdinalIgnoreCase) })
    if ($stateWord.Count -ne 1) { Exit-NotWritten "-State must be one of: $($words -join ', ') (got '$State')" }
    $stateWord = $stateWord[0]
    if ($cellName -cne 'Status') { Exit-NotWritten '-State sets the Status cell; it cannot go with -Cell Model' }
}

# The ledger, from -Ledger or (without it) today's, from the main checkout (Resolve-CoordLedgerArg).
$res = Resolve-CoordLedgerArg -Ledger $Ledger
if (-not $res.Ok) { Exit-NotWritten $res.Error }
$Ledger = $res.Ledger
$noLedger = "no ledger at $Ledger (from another repo's checkout, pass -Ledger with the coordinator's ledger; only a new day's ledger is started from ledger-template.md)"
if (-not $res.HasDir) { Exit-NotWritten $noLedger }

# A Repo cell as one rooted full path, or $null for one that is not a rooted path (ConvertTo-CoordRootedPath).
function Get-RepoFull([string]$Value) {
    return (ConvertTo-CoordRootedPath $Value)
}

try {
    $taken = Enter-CoordLedgerLock -Path $Ledger
    $script:lock = $taken.Lock
    if (-not $taken.Ok) { Exit-NotWritten $taken.Error }
    # Checked only under the lock: another run's swap briefly leaves no file at the ledger's name.
    if (-not (Test-Path -LiteralPath $Ledger -PathType Leaf)) { Exit-NotWritten $noLedger }

    $read = Read-CoordLedgerFile -Path $Ledger
    if (-not $read.Ok) { Exit-NotWritten $read.Error }
    $lines = $read.Lines

    # The one clock read: every {now} in the text.
    $at = Get-Date

    $sec = Find-CoordSectionEnd -Lines $lines -Name 'Tracks' -Path $Ledger
    if (-not $sec.Ok) { Exit-NotWritten $sec.Error }
    # The table: the first line that starts with a pipe, and the table lines after it (the
    # reader's rule in Read-CoordLedgerTracks: the first other line after the rows ends it).
    $tbl = New-Object System.Collections.Generic.List[int]
    for ($k = $sec.Header + 1; $k -lt $sec.End; $k++) {
        if ($lines[$k].TrimStart().StartsWith('|')) { $tbl.Add($k) }
        elseif ($tbl.Count -gt 0) { break }
    }
    if ($tbl.Count -eq 0) { Exit-NotWritten "the ## Tracks section of $Ledger holds no table" }
    $tblText = New-Object System.Collections.Generic.List[string]
    foreach ($k in $tbl) { $tblText.Add($lines[$k]) }
    try { $rows = @(ConvertFrom-CoordTracksRows $tblText $Ledger) }
    catch { Exit-NotWritten $_.Exception.Message }
    # Data rows in the reader's order: every table line after the header, but the separator.
    $dataAt = New-Object System.Collections.Generic.List[int]
    for ($j = 1; $j -lt $tbl.Count; $j++) {
        $raw = $lines[$tbl[$j]]
        if ($raw -match '^[\s|:-]+$' -and $raw.Contains('-')) { continue }
        $dataAt.Add($tbl[$j])
    }
    if ($dataAt.Count -ne $rows.Count) { Exit-NotWritten "cannot match the Tracks rows of $Ledger to its lines ($($dataAt.Count) lines, $($rows.Count) rows)" }

    $head = Split-CoordTableRow $lines[$tbl[0]]
    $col = -1
    for ($k = 0; $k -lt $head.Length; $k++) { if ([string]::Equals($head[$k], $cellName, [System.StringComparison]::OrdinalIgnoreCase)) { $col = $k; break } }
    if ($col -lt 0) { Exit-NotWritten "the Tracks table of $Ledger has no '$cellName' column" }

    $cmp = Get-CoordPathComparison
    $hitIdx = @(for ($i = 0; $i -lt $rows.Count; $i++) { if ([string]::Equals($rows[$i].Track.Trim(), $wantTrack, [System.StringComparison]::OrdinalIgnoreCase)) { $i } })
    if ($Repo) {
        $wantRepo = Get-RepoFull $Repo
        if (-not $wantRepo) { Exit-NotWritten "-Repo '$Repo' is not a usable full path" }
        $hitIdx = @($hitIdx | Where-Object { $r = Get-RepoFull $rows[$_].Repo; $r -and [string]::Equals($r, $wantRepo, $cmp) })
    }
    if ($hitIdx.Count -eq 0) { Exit-NotWritten "no Tracks row '$wantTrack'$(if ($Repo) { " in $Repo" }) in $Ledger" }
    if ($hitIdx.Count -gt 1) {
        $ignoreCase = ($cmp -eq [System.StringComparison]::OrdinalIgnoreCase)
        $repos = @($hitIdx | ForEach-Object { $r = Get-RepoFull $rows[$_].Repo; if ($r) { if ($ignoreCase) { $r.ToLowerInvariant() } else { $r } } else { $rows[$_].Repo } } | Sort-Object -Unique)
        if ($repos.Count -lt $hitIdx.Count) { Exit-NotWritten "$($hitIdx.Count) Tracks rows named '$wantTrack' share a repo in $Ledger; rename one in the ledger" }
        Exit-NotWritten "$($hitIdx.Count) Tracks rows '$wantTrack' in $Ledger (repos: $(($hitIdx | ForEach-Object { $rows[$_].Repo }) -join ', ')); pass -Repo <full path>"
    }
    $ri = $hitIdx[0]
    $li = $dataAt[$ri]

    # The raw line, cut at its unescaped pipes: parts[0] is what precedes the first pipe, the cells follow,
    # and an unescaped pipe that ends the line leaves an empty last part (Split-CoordTableRow's rule).
    $rawLine = $lines[$li]
    $core = $rawLine.TrimEnd()
    $tail = $rawLine.Substring($core.Length)
    $parts = [System.Collections.Generic.List[string]]::new([string[]][regex]::Split($core, '(?<!\\)\|'))
    $endPipe = $core -match '(?<!\\)\|$'
    if ($endPipe) { $parts.RemoveAt($parts.Count - 1) }
    if ($parts.Count - 1 -ne $head.Length -or $parts[0].Trim()) { Exit-NotWritten "Tracks row of '$wantTrack' in $Ledger has $($parts.Count - 1) cells, the header has $($head.Length)" }
    $expanded = Expand-CoordNow $newText $at
    $old = $parts[$col + 1].Trim()
    $value = $expanded
    if ($stateWord) {
        # An append adds detail to the state the cell already has; a state change replaces the cell.
        $oldWord = if (($old -replace '`', '') -match '^\s*([A-Za-z][A-Za-z-]*)') { $Matches[1] } else { '' }
        if ($Append -and $oldWord -cne $stateWord) { Exit-NotWritten "-State $stateWord with -Append: the cell's first word is '$oldWord', not $stateWord; a state change replaces the cell (drop -Append)" }
        if (-not $Append) { $value = "$stateWord $(Get-CoordStamp $at); $expanded" }
    }
    if ($Append -and $old) { $value = $old + $(if ($cellName -ceq 'Model') { '; ' } else { ', ' }) + $expanded }
    $parts[$col + 1] = " $value "
    $lines[$li] = ($parts -join '|') + $(if ($endPipe) { '|' } else { '' }) + $tail
    $report = "COORD-SET $Ledger [Tracks $($rows[$ri].Track.Trim()) ${cellName}]: $value"
    # The readers drop backticks before they test the first word, so `DONE` finishes a row as well. A row
    # that reads as finished is skipped by slot-check.ps1, coord-brief.ps1, coord-handoff.ps1, merge-verify.ps1
    # and by the scope guard (it stops guarding that track), so the flip is never silent, in either direction.
    if ($cellName -ceq 'Status' -and (Test-CoordRowTerminal ($value -replace '`', '')) -and -not (Test-CoordRowTerminal ($old -replace '`', ''))) {
        $notice = "COORD-SET NOTE: row '$($rows[$ri].Track.Trim())' now reads as FINISHED (its Status starts with MERGED or DONE): slot-check, coord-brief, coord-handoff, merge-verify and the scope guard no longer treat it as live"
    }
    elseif ($cellName -ceq 'Status' -and (Test-CoordRowTerminal ($old -replace '`', '')) -and -not (Test-CoordRowTerminal ($value -replace '`', ''))) {
        $notice = "COORD-SET NOTE: row '$($rows[$ri].Track.Trim())' now reads as LIVE again (its Status no longer starts with MERGED or DONE): slot-check, coord-brief, coord-handoff, merge-verify and the scope guard treat it as live again; check that no other live row holds its repo and branch (two live rows block every edit of that session)"
    }

    $swap = Write-CoordLedgerSwap -Path $Ledger -Expected $read.Bytes -Text ($lines -join $read.Newline) -Bom $read.Bom -Added 'the change'
    if ($swap.Status -eq 'changed') { Exit-NotWritten "$Ledger changed while this run read it; run it again" }
    if (-not $swap.Ok) { Exit-NotWritten $swap.Error }
}
finally {
    if ($script:lock) { $script:lock.Dispose(); $script:lock = $null }
}
Write-Output $report
if ($notice) { Write-Output $notice }
exit 0
