# Ported from the private coordinate toolkit (coord-log.ps1), 2026-10-18.
#
# coord-log.ps1 - append one stamped line to the coordination ledger.
#
# The coordinator never types a time: hand-typed stamps drift. This script
# takes HH:mm from its own clock (Get-Date, local time) and appends
# "<HH:mm> <text>" as the LAST line of one of the ledger's append-only
# sections:
#   Decisions | Findings | Log
# The sections edited in place (Baseline, Tracks, Merge slots, Owed checks) are
# refused: they are rewritten, not appended to.
#
# The text is refused (nothing written) when it is empty, holds a line break or
# another control character (one line per event), or starts with a time of its
# own (the stamp is this script's); so is any argument left over after the
# parameters (a split text, see Usage; no parameter binds by position).
# Leading and trailing spaces are trimmed. The file keeps its encoding (UTF-8,
# with or without a BOM; anything that is not valid UTF-8 is refused) and its
# line ends (CRLF if it has any, else LF). The section header must appear
# exactly once (`## <Section>`, case-insensitive); the section runs to the next
# `#` or `##` header or the end of the file.
#
# Writing: runs are serialized by <ledger>.coord-log.lock (waits up to 5 s for
# another run; a lock that cannot be created at all fails at once). The new file
# is written next to the ledger and swapped in (up to 10 tries, 100 ms apart).
# Before each try the ledger is compared with what was read: a change (an
# editor's write) is refused, not merged. The comparison and the swap are not
# one step, so a write landing between them is still lost; the window is the
# few milliseconds of one comparison. A failed swap with the ledger still in
# place leaves it as it was and removes the temp file. A ledger that is gone
# when the run fails (moved away, or a swap that failed half-way) is never
# recreated: the run is refused and the temp file, which holds the ledger as
# read plus the new line, is kept and named. The lock, the read and decoding,
# the section search and the swap are helpers in coord-common.ps1
# (Enter-CoordLedgerLock, Read-CoordLedgerFile, Find-CoordSectionEnd,
# Write-CoordLedgerSwap); this script words every refusal.
#
# Registration: the scope guard (when installed) finds the day's ledgers
# through its index, <index dir>/<yyyy-MM-dd>.ledgers (coord-common.ps1,
# Get-CoordIndexPath). When the ledger is today's canonical one
# (<main checkout>/.claude/coordination/<yyyy-MM-dd>.md of the repo that
# holds it, Test-CoordLedgerCanonical), it is registered there
# (Register-CoordLedger) before the ledger's lock is taken and before anything
# is appended; a failed registration (for example: the index already holds 8
# distinct ledgers, or passed 64 KiB) is refused with the ledger unchanged, so a retry
# never writes an event twice. A ledger at a path shaped like today's
# canonical one (.../.claude/coordination/<today>.md) whose check cannot
# decide, because no main root is found (git failed, or no repo there), is
# refused with the ledger unchanged. Any other ledger (a test's scratch
# ledger, a worktree's stale copy, another day's) is appended to and not
# registered.
# -Register does the registration alone and writes nothing to the ledger; the
# skill runs it at day start, right after creating the day's ledger. It takes
# no -Section or -Text, and a missing ledger is refused.
#
# Usage, from the PowerShell tool, in process, the text in single quotes:
#   & "<plugin root>/scripts/coord-log.ps1" -Section Log -Text '<event>' [-Ledger <path>]
#   & "<plugin root>/scripts/coord-log.ps1" -Register [-Ledger <path>]
# (In that call a ' inside the text is doubled, 'the user''s go'; the
# typographic single quotes, U+2018, U+2019, U+201A and U+201B, also end the
# string and need the same doubling.)
# Not through `powershell.exe -File` from Windows PowerShell 5.1: it
# drops the double quotes inside an argument it passes on, so quotes around
# one word or around the whole text vanish (written without them, exit 0), a
# quoted span holding a space anywhere else splits the text (refused, as
# leftover words), and a text ending in a backslash swallows the next
# parameter (not detectable here). From the Bash tool (Git Bash),
# `MSYS_NO_PATHCONV=1 powershell.exe -ExecutionPolicy Bypass -File "<plugin root>/scripts/coord-log.ps1" ...`
# passes the text intact, a ' in it written '\''. Without MSYS_NO_PATHCONV=1,
# Git Bash rewrites an argument that starts with / into a Windows path
# ('/review-code done' arrives as 'C:/Program Files/Git/review-code done'),
# and that is written, with exit 0. With the prefix Git Bash converts no path
# either, so -Ledger and the script path are written in Windows form (C:/...,
# or `cygpath -w` of a /c/... path): /c/x.md would be read as C:\c\x.md.
# Without -Ledger: today's ledger, <main checkout>/.claude/coordination/
# <yyyy-MM-dd>.md, and only when the current directory is in that repo's MAIN
# checkout, where the coordinator sits. From a linked worktree or another repo,
# pass -Ledger: a probe in a worktree once wrote into the live ledger this way.
# A missing ledger is not created.
# Prints: COORD-LOG <ledger> [<Section>]: <the line written>
#     or: COORD-LOG: NOT WRITTEN - <reason>
#     or, with -Register: COORD-LOG REGISTERED <ledger> in <index>   (added, or already there)
#     or, with -Register: COORD-LOG: NOT REGISTERED - <reason>
# Exit: 0 written (with -Register: registered); 2 not written (not registered).
# (A call PowerShell cannot bind at all, such as -Text with no value, fails
# before the script runs: exit 1, nothing written.)

[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Section = '',
    [string]$Text = '',
    [string]$Ledger = '',
    [switch]$Register,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest = @()
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'coord-common.ps1')
Initialize-CoordConsole

$script:lock = $null
function Exit-NotWritten([string]$Reason) {
    if ($script:lock) { $script:lock.Dispose(); $script:lock = $null }
    if ($Register) { Write-Output "COORD-LOG: NOT REGISTERED - $Reason" }
    else { Write-Output "COORD-LOG: NOT WRITTEN - $Reason" }
    exit 2
}

# git finds the main checkout and the canonical ledger; without it every ledger
# path below would end in PowerShell's own "not recognized" error instead of a
# refusal line. It runs first, so with no git a bad -Section or -Text is
# reported as the missing git. Nothing has been read or written yet.
if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
    Exit-NotWritten 'git is not on PATH (coord-log uses it to find the main checkout and the canonical ledger)'
}

# Words left over mean the text was split on the way in: Windows PowerShell 5.1
# drops the double quotes inside an argument it hands to powershell.exe, so
# '"merge #40" (the user)' arrives as -Text merge plus loose words. Without
# this check it would be written, with exit 0.
if ($Rest.Count) { Exit-NotWritten "unexpected words after the parameters ($($Rest -join ' ')): the text was split; pass it as one single-quoted -Text, in process with & (see Usage)" }

if ($Register) {
    if ($Section -or $Text) { Exit-NotWritten '-Register takes no -Section or -Text: registering and appending are separate calls' }
}
else {
    $sections = @('Decisions', 'Findings', 'Log')
    $name = @($sections | Where-Object { [string]::Equals($_, $Section.Trim(), [System.StringComparison]::OrdinalIgnoreCase) })
    if ($name.Count -ne 1) { Exit-NotWritten "-Section must be one of: $($sections -join ', ') (got '$Section')" }
    $name = $name[0]

    $line = $Text.Trim()
    if (-not $line) { Exit-NotWritten '-Text is empty' }
    # C0 controls but tab, DEL, NEL, and the line and paragraph separators
    # (U+2028/9, built from [char]: the file stays ASCII for Windows PowerShell 5.1).
    # Checked on the untrimmed text: Trim() would drop a leading or trailing one.
    if ($Text -match ('[\x00-\x08\x0A-\x1F\x7F\x85' + [char]0x2028 + [char]0x2029 + ']')) { Exit-NotWritten '-Text holds a line break or a control character; one line per event' }
    if ($line -match '^\d{1,2}:\d{2}(?!\d)') { Exit-NotWritten '-Text starts with a time; the script stamps it, drop yours' }
}

if (-not $Ledger) {
    $here = (Get-Location).Path
    $Ledger = Get-CoordLedgerPath $here
    if (-not $Ledger) { Exit-NotWritten "$here is not in a git repository; pass -Ledger" }
    $top = Invoke-CoordGit $here @('rev-parse', '--show-toplevel')
    $main = Get-CoordMainRoot $here
    if ($top.Code -ne 0 -or -not $top.Out.Count -or -not $main -or
        -not [string]::Equals((ConvertTo-CoordFullPath $top.Out[0].Trim()), (ConvertTo-CoordFullPath $main), (Get-CoordPathComparison))) {
        Exit-NotWritten "$here is not the repo's main checkout; pass -Ledger (the default would be $Ledger)"
    }
}
# A relative -Ledger is resolved against the PowerShell location: in process,
# `cd` moves that, not the process directory GetFullPath would use. Only a
# FileSystem path is accepted (Env:\x or HKLM:\x would otherwise land under
# the process directory).
try {
    $prov = $null
    $drive = $null
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Ledger, [ref]$prov, [ref]$drive)
    if ($prov.Name -ne 'FileSystem') { Exit-NotWritten "-Ledger is not a file path (provider $($prov.Name)): $Ledger" }
    $Ledger = [System.IO.Path]::GetFullPath($resolved)
    $hasDir = Test-Path -LiteralPath (Split-Path -Parent $Ledger) -PathType Container
}
catch { Exit-NotWritten "-Ledger is not a usable path: $($_.Exception.Message)" }
$noLedger = "no ledger at $Ledger (from another repo's checkout, pass -Ledger with the coordinator's ledger; only a new day's ledger is started from ledger-template.md)"
if (-not $hasDir) { Exit-NotWritten $noLedger }

# The scope guard (when installed) finds the day's ledgers through the index (coord-common.ps1,
# Register-CoordLedger). Today's canonical ledger is registered BEFORE the lock
# on it is taken and before anything is appended, so a failed registration
# leaves the ledger as it was and a retry never writes an event twice. Any
# other ledger (a scratch one, a worktree's stale copy, another day's) is not
# registered.
$today = Get-CoordToday
if ($Register) {
    if (-not (Test-Path -LiteralPath $Ledger -PathType Leaf)) { Exit-NotWritten $noLedger }
    $reg = Register-CoordLedger -Ledger $Ledger -Date $today
    if (-not $reg.Ok) { Exit-NotWritten $reg.Error }
    Write-Output "COORD-LOG REGISTERED $Ledger in $($reg.Index)"
    exit 0
}
$canon = Test-CoordLedgerCanonical -Path $Ledger -Date $today
# A path shaped like today's canonical ledger whose check could not decide (no
# main root found: git failed, or no repo) is refused: appending to it
# unregistered could leave the coordinator's live ledger unseen by the guard.
# On Windows the separator is '\'; elsewhere either one is accepted.
$shape = '(?i)\\\.claude\\coordination\\'
if (-not (Test-CoordWindows)) {
    # Not verified off Windows.
    $shape = '(?i)[\\/]\.claude[\\/]coordination[\\/]'
}
if (-not $canon.Ok -and $canon.Undecided -and $Ledger -match ($shape + [regex]::Escape($today) + '\.md$')) {
    Exit-NotWritten "cannot tell whether $Ledger is canonical: $($canon.Error)"
}
if ($canon.Ok) {
    $reg = Register-CoordLedger -Ledger $Ledger -Date $today
    if (-not $reg.Ok) { Exit-NotWritten "ledger not registered: $($reg.Error)" }
}

# One run at a time: a lock file next to the ledger, opened with no sharing and
# deleted on close. Two runs in parallel (two tool calls in one message) would
# otherwise both read the old ledger, and the later swap would drop the
# earlier line. Everything from here runs inside try/finally, so a run that
# dies in process (a throw, Ctrl+C) still releases it. The lock, the read, the
# section search and the swap are coord-common.ps1 helpers.
try {
    $taken = Enter-CoordLedgerLock -Path $Ledger
    $script:lock = $taken.Lock
    if (-not $taken.Ok) { Exit-NotWritten $taken.Error }
    # Checked only under the lock: another run's swap briefly leaves no file at
    # the ledger's name (one parallel run in 200 read "no ledger" before this).
    if (-not (Test-Path -LiteralPath $Ledger -PathType Leaf)) { Exit-NotWritten $noLedger }

    $read = Read-CoordLedgerFile -Path $Ledger
    if (-not $read.Ok) { Exit-NotWritten $read.Error }
    $lines = $read.Lines
    $sec = Find-CoordSectionEnd -Lines $lines -Name $name -Path $Ledger
    if (-not $sec.Ok) { Exit-NotWritten $sec.Error }

    $stamped = (Get-Date).ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) + ' ' + $line
    $lines.Insert($sec.Insert, $stamped)

    $swap = Write-CoordLedgerSwap -Path $Ledger -Expected $read.Bytes -Text ($lines -join $read.Newline) -Bom $read.Bom -Added 'the new line'
    if ($swap.Status -eq 'changed') { Exit-NotWritten "$Ledger changed while this run read it; run it again" }
    if (-not $swap.Ok) { Exit-NotWritten $swap.Error }
}
finally {
    if ($script:lock) { $script:lock.Dispose(); $script:lock = $null }
}
Write-Output "COORD-LOG $Ledger [$name]: $stamped"
exit 0
