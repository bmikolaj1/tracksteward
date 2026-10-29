# Ported from the private coordinate toolkit (coord-handoff.ps1), 2026-10-28.
#
# coord-handoff.ps1 - hand the coordination ledger to a new coordinator session.
#
# A mid-day handoff used to be hand-edited: the Coordinator line renamed, a Log
# line typed, one "report to <new>" message per track with a sha read off the
# ledger. This script makes the two ledger changes in ONE replacement and
# prints the messages with the sha each repo's fetch brought. It sends nothing,
# starts no session, runs no snapshot and never registers the ledger in the
# index: the new coordinator does those (see the CHECKLIST lines).
#
# Order of operations:
#   1. Inputs, before any read or git call. -NewSession is the new coordinator
#      session's NAME or its id: trimmed, 1 to 80 characters, no control
#      character (tab and line breaks included, checked before the trim), no
#      character other than letters, digits, combining marks, punctuation,
#      symbols and the plain space (so no zero-width space, BOM, soft hyphen,
#      bidi mark, braille blank, object replacement character or
#      non-breaking space, and no character outside the Basic
#      Multilingual Plane, an emoji included; some other letters and marks that
#      draw nothing, such as a Hangul filler or a variation selector, are not
#      recognized, and a code point the host's Unicode tables do not know yet,
#      for example a recent letter on Windows PowerShell 5.1, is refused),
#      no backtick, no |, no double quote, not a <placeholder>, and not holding
#      "; before that: " (the text the Coordinator line is cut at). Any
#      argument left over after the parameters (a loose word, or an unknown
#      parameter such as -Time) is refused: the stamp is this script's. Then
#      the ledger path (-Ledger, or the default below), when shaped like
#      today's canonical ledger (.../.claude/coordination/<today>.md, case
#      ignored, as coord-log.ps1), must be it (Test-CoordLedgerCanonical,
#      which runs git): a network path, or one not on a local fixed drive, is
#      refused for that; on a fixed drive, a copy elsewhere, such as a linked
#      worktree's stale one, is refused naming the canonical path, and one whose
#      check cannot decide (no main root found) is refused as "cannot tell
#      whether ... is canonical". Any other path (a scratch ledger) is not
#      checked. The ledger is never registered here.
#   2. Under the lock coord-log.ps1 takes (<ledger>.coord-log.lock), the
#      ledger is read ONCE and kept as the snapshot (UTF-8, a BOM kept as
#      found, anything that is not valid UTF-8 refused; CRLF if the text holds
#      any CRLF, else LF); the lock is released before any fetch.
#   3. From the snapshot: exactly one `Coordinator:` line, which must start
#      `Coordinator: session "<old name>"` (the shape the ledger template and
#      this script write; the old name may be an id; it is trimmed, must not be
#      a <placeholder> or hold "; before that: "; a -NewSession equal to it,
#      ignoring case, is refused; look-alike spellings, such as a Cyrillic letter
#      for a Latin one or a decomposed accent, are not recognized as equal); `## Log` and `## Tracks` each exactly once
#      (case-insensitive); the Tracks section must hold a table (a header row; a
#      header with no data rows is accepted), read by Read-CoordLedgerTracks'
#      section scan and row parser. A -NewSession that is any row's Session
#      cell (finished rows included; the cell with one pair of quotes or
#      backticks removed, ignoring case) or whose session token
#      (Get-CoordSessionToken) is the token of any row's cell, or of the first
#      word of one (an id followed by a note), is refused: it is a track, not
#      a new coordinator. A row is live unless Test-CoordRowTerminal says it
#      is finished. Every live row's Repo cell must be a rooted full path
#      (ConvertTo-CoordRootedPath); a relative cell (.\x, ..\x), a drive-relative
#      one (C:x), a bare folder name, a drive root, or a path holding , ; ( or )
#      is refused, "row <track>: Repo '<cell>' is not a full path". The cell
#      must be an existing folder and the top level of a git working tree
#      (git rev-parse --is-inside-work-tree is true and --show-prefix is empty,
#      so the spelling does not matter: a junction is fine, and so is a subst
#      drive whose repo is below its root; a folder inside another repo, or its
#      .git folder, would otherwise fetch the enclosing repo under the wrong
#      name). The distinct
#      full paths (a trailing separator dropped, compared as Get-CoordPath
#      Comparison says) are kept in first-seen order; git runs on that full
#      path, and the repo leaf in the Log line and the MESSAGE lines is its
#      last part.
#   4. Per distinct repo of a live row, with GIT_TERMINAL_PROMPT=0 (set before
#      the first fetch, restored afterwards): `git -C <repo> fetch --quiet
#      origin main`, then refs/remotes/origin/main and FETCH_HEAD, each read
#      as a commit; both must be 40 hex and equal (a fetch refspec that does
#      not map main leaves a stale refs/remotes/origin/main behind). The ref is
#      always main, whatever base a row's PR targets; gh is never called. No
#      live row: no fetch. The fetch has no timeout: a stalled network blocks
#      the run (no lock is held then).
#   5. The lock again, then the ledger's bytes are read and compared with the
#      snapshot's bytes, before any decoding: any difference (a row added, a
#      Repo changed, a Log line, bytes that no longer decode) is refused,
#      "ledger changed during the fetch; rerun", so the messages match the
#      track set that was fetched. A ledger gone by then is refused as gone.
#   6. One stamp, HH:mm from one Get-Date call. The Coordinator line becomes
#        Coordinator: session "<new>", took over <HH:mm> from "<old>"; before that: <old line after "Coordinator: ", cut at its own first "; before that: ">
#      so a line this script wrote keeps the new coordinator, the old one and
#      the one the old took over from; the Log's HANDOFF lines keep the whole
#      history. A Log line is added after the Log section's last non-blank
#      line:
#        <HH:mm> HANDOFF: "<new>" took over from "<old>" (coord-handoff.ps1); live tracks: <n>; <repo leaf> main <sha12>[, ...]
#   7. ONE replacement holding both changes (Write-CoordLedgerSwap: compared
#      with the snapshot before every try, temp file next to the ledger, up to
#      10 tries 100 ms apart). Refused: the file is as it was, with neither
#      change. A ledger gone when the swap fails is never recreated; the temp
#      file holding the snapshot plus both changes is kept and named.
#   8. Only after the swap, the lines under Prints.
# The lock, the read and decoding, the section search and the swap are
# coord-common.ps1 helpers (Enter-CoordLedgerLock, Read-CoordLedgerFile,
# Find-CoordSectionEnd, Write-CoordLedgerSwap); this script words every
# refusal.
#
# What a refusal leaves: the ledger as it was (the exception is below), but a
# refusal after step 4 does not undo the fetches: each repo's
# refs/remotes/origin/main and objects stay updated.
#
# Concurrency: every coord-log.ps1 and coord-handoff.ps1 write waits on the
# lock, but a hand edit of the ledger (the Edit tool) takes no lock, and one
# landing inside the few milliseconds between the final comparison and the swap
# is lost, as coord-log.ps1's header says. So: no hand edit of the ledger while
# a ledger script is running.
#
# Limits: GIT_DIR, GIT_WORK_TREE and GIT_INDEX_FILE are not cleared; run the
# script from a shell where they are unset. An inherited absolute GIT_DIR (git
# sets it when it runs a hook) makes every Repo cell be read through that one
# repository. A Repo cell on a network share is checked for existence and probed
# with git (step 3) and fetched (step 4) with no timeout, so an unreachable server can stall the run
# there (no lock is held then). GIT_TERMINAL_PROMPT=0 stops git's own terminal
# prompt only: an ssh passphrase prompt or a credential-manager window can
# still wait for an answer. Step 6 keeps one "before that" level; the Log's
# HANDOFF lines keep the rest.
#
# Usage, from the PowerShell tool, in process, the name in single quotes:
#   & "<plugin root>/scripts/coord-handoff.ps1" -NewSession '<name or id>' [-Ledger <path>]
# (A ' inside the name is doubled, 'the user''s coordinator'.) Not through
# `powershell.exe -File` from Windows PowerShell 5.1: it drops double quotes
# inside an argument and splits a quoted span holding a space (see
# coord-log.ps1's Usage).
# Without -Ledger: today's ledger, <main checkout>/.claude/coordination/
# <yyyy-MM-dd>.md, and only when the current directory is in that repo's MAIN
# checkout, as coord-log.ps1. A missing ledger is not created.
# Prints, after a write:
#   COORD-HANDOFF <ledger>: Coordinator line now: <the new line>
#   COORD-HANDOFF <ledger> [Log]: <the stamped Log line>
#   MESSAGE <track> (<session cell or 'no session'>): coordinator handoff: report to "<new>" from now on; <repo leaf> main is now <sha12>
#     (one per live row, in table order; <track> is the Branch when the Track cell is empty)
#   CHECKLIST: (1) .. (6)
#   COORD-HANDOFF: done; nothing sent (the coordinator sends each MESSAGE line)
# or, refused, one line: COORD-HANDOFF: NOT WRITTEN - <reason>
# Exit: 0 written; 2 refused: the ledger is as it was, except when it is gone
# at the swap (moved away, or a swap that failed half-way): then it is not
# recreated, and the temp file holding the snapshot plus both changes is kept
# and named in the reason. A call PowerShell cannot bind at all, such as
# -NewSession with no value, fails before the script runs and writes nothing:
# in process (&) it throws a parameter binding error and the script sets no
# $LASTEXITCODE; through powershell.exe -File the process exits 1.

[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$NewSession = '',
    [string]$Ledger = '',
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest = @()
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'coord-common.ps1')
Initialize-CoordConsole

$script:lock = $null
# GIT_TERMINAL_PROMPT as it was before the fetches; Exit-NotWritten and the
# fetch loop's finally put it back.
$script:promptSet = $false
$script:promptPrev = $null
function Restore-GitPrompt {
    if (-not $script:promptSet) { return }
    if ($null -eq $script:promptPrev) { Remove-Item -LiteralPath 'Env:\GIT_TERMINAL_PROMPT' -ErrorAction SilentlyContinue }
    else { $env:GIT_TERMINAL_PROMPT = $script:promptPrev }
    $script:promptSet = $false
}
function Exit-NotWritten([string]$Reason) {
    if ($script:lock) { $script:lock.Dispose(); $script:lock = $null }
    Restore-GitPrompt
    Write-Output "COORD-HANDOFF: NOT WRITTEN - $Reason"
    exit 2
}

# ---- 1. inputs ---------------------------------------------------------------
if ($Rest.Count) { Exit-NotWritten "unexpected arguments after the parameters ($($Rest -join ' ')): there is no time parameter (the stamp is this script's clock) and no positional word; pass -NewSession '<name or id>' and -Ledger only, in process with & (see Usage)" }

# C0 controls (tab and line breaks included), DEL, NEL, and the line and
# paragraph separators (U+2028/9, built from [char]: the file stays ASCII).
$ctlRe = '[\x00-\x1F\x7F\x85' + [char]0x2028 + [char]0x2029 + ']'
# Checked on the untrimmed value: Trim() would drop a leading or trailing one.
if ($NewSession -match $ctlRe) { Exit-NotWritten '-NewSession holds a tab, a line break or another control character' }
# Invisible characters (zero-width space, BOM, soft hyphen, bidi marks, no-break
# space) pass the trim and make a name that looks like another; the regex sees
# UTF-16 code units, so a surrogate pair (any non-BMP character) is refused too.
# An allow-list, not a Cf test: .NET's \p{Cf} does not match every format character,
# and it files the soft hyphen (U+00AD) under punctuation, so that one is named,
# as are the braille blank (U+2800) and the object replacement character (U+FFFC).
if ($NewSession -match '[^\p{L}\p{N}\p{M}\p{P}\p{S} ]') { Exit-NotWritten '-NewSession holds a character other than letters, digits, combining marks, punctuation, symbols and the plain space (no invisible, no-break-space or non-BMP character)' }
if ($NewSession -match '[\u00AD\u2800\uFFFC]') { Exit-NotWritten '-NewSession holds U+00AD, U+2800 or U+FFFC, a character that can draw nothing or look like a space' }
if ($NewSession.Contains('`')) { Exit-NotWritten '-NewSession holds a backtick' }
if ($NewSession.Contains('|')) { Exit-NotWritten '-NewSession holds a |, which would break a Tracks or Log reader' }
if ($NewSession.Contains('"')) { Exit-NotWritten '-NewSession holds a double quote; the ledger writes the name between double quotes' }
$new = $NewSession.Trim()
if (-not $new) { Exit-NotWritten '-NewSession is empty' }
if ($new.Length -gt 80) { Exit-NotWritten "-NewSession is $($new.Length) characters after the trim, over 80" }
if ($new -match '^<.*>$') { Exit-NotWritten "-NewSession is a placeholder ($new); pass the new coordinator session's name or id" }
$beforeThat = '; before that: '
if ($new.Contains($beforeThat)) { Exit-NotWritten "-NewSession holds '$beforeThat', the text the next handoff cuts the Coordinator line at" }

# ---- the ledger path (as coord-log.ps1) --------------------------------------
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
# A relative -Ledger is resolved against the PowerShell location; only a
# FileSystem path is accepted.
try {
    $prov = $null
    $drive = $null
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Ledger, [ref]$prov, [ref]$drive)
    if ($prov.Name -ne 'FileSystem') { Exit-NotWritten "-Ledger is not a file path (provider $($prov.Name)): $Ledger" }
    $Ledger = [System.IO.Path]::GetFullPath($resolved)
    $hasDir = Test-Path -LiteralPath (Split-Path -Parent $Ledger) -PathType Container
}
catch { Exit-NotWritten "-Ledger is not a usable path: $($_.Exception.Message)" }
$noLedger = "no ledger at $Ledger (from another repo's checkout, pass -Ledger with the coordinator's ledger)"
if (-not $hasDir) { Exit-NotWritten $noLedger }

# A path shaped like today's canonical ledger must be it (a linked worktree's
# copy is refused). The handoff never registers (CHECKLIST (2)).
$today = Get-CoordToday
$shape = '(?i)\\\.claude\\coordination\\'
if (-not (Test-CoordWindows)) {
    # Not verified off Windows.
    $shape = '(?i)[\\/]\.claude[\\/]coordination[\\/]'
}
if ($Ledger -match ($shape + [regex]::Escape($today) + '\.md$')) {
    $canon = Test-CoordLedgerCanonical -Path $Ledger -Date $today
    if (-not $canon.Ok) {
        if ($canon.Undecided) { Exit-NotWritten "cannot tell whether $Ledger is canonical: $($canon.Error)" }
        Exit-NotWritten $canon.Error
    }
}

# ---- 2. the snapshot, under the lock ------------------------------------------
# Read under the lock: a coord-log.ps1 swap briefly leaves no file at the
# ledger's name. The lock is released before the fetches.
try {
    $taken = Enter-CoordLedgerLock -Path $Ledger
    $script:lock = $taken.Lock
    if (-not $taken.Ok) { Exit-NotWritten $taken.Error }
    if (-not (Test-Path -LiteralPath $Ledger -PathType Leaf)) { Exit-NotWritten $noLedger }
    $snap = Read-CoordLedgerFile -Path $Ledger
    if (-not $snap.Ok) { Exit-NotWritten $snap.Error }
}
finally {
    if ($script:lock) { $script:lock.Dispose(); $script:lock = $null }
}
$lines = $snap.Lines

# ---- 3. parse the snapshot ---------------------------------------------------
$coordIdx = @()
for ($k = 0; $k -lt $lines.Count; $k++) { if ($lines[$k] -match '^Coordinator:') { $coordIdx += $k } }
if ($coordIdx.Count -ne 1) { Exit-NotWritten "found $($coordIdx.Count) 'Coordinator:' lines in $Ledger, need exactly one" }
$ci = $coordIdx[0]
$oldLine = $lines[$ci]
$om = [regex]::Match($oldLine, '^Coordinator:\s*session\s+"([^"]+)"')
if (-not $om.Success) { Exit-NotWritten "the Coordinator line of $Ledger does not start with session ""<name>"": $oldLine" }
$old = $om.Groups[1].Value.Trim()
if (-not $old -or $old -match '^<.*>$') { Exit-NotWritten "the Coordinator line of $Ledger names no coordinator session (empty or a <placeholder>): $oldLine" }
if ($old.Contains($beforeThat)) { Exit-NotWritten "the Coordinator line of $Ledger names a session holding '$beforeThat', the text the handoff cuts the line at: $oldLine" }
if ([string]::Equals($old, $new, [System.StringComparison]::OrdinalIgnoreCase)) { Exit-NotWritten "-NewSession $new is already the coordinator named in $Ledger" }

$sec = Find-CoordSectionEnd -Lines $lines -Name 'Log' -Path $Ledger
if (-not $sec.Ok) { Exit-NotWritten $sec.Error }

# `## Tracks` exactly once (as the Log header), and a table in it (a header
# row; a header with no data rows is accepted).
$tsec = Find-CoordSectionEnd -Lines $lines -Name 'Tracks' -Path $Ledger
if (-not $tsec.Ok) { Exit-NotWritten $tsec.Error }

# The Tracks table, by Read-CoordLedgerTracks' section scan (Add-CoordTracksLine)
# and row parser, on the snapshot: the file is not read a second time.
$scan = @{ Heading = $false; Ended = $false; Rows = (New-Object System.Collections.Generic.List[string]) }
foreach ($l in $lines) {
    foreach ($part in $l.Split([char]13)) { Add-CoordTracksLine $scan $part; if ($scan.Ended) { break } }
    if ($scan.Ended) { break }
}
if ($scan.Rows.Count -eq 0) { Exit-NotWritten "the '## Tracks' section of $Ledger holds no table (no header row); the live tracks cannot be read" }
try { $rows = @(ConvertFrom-CoordTracksRows $scan.Rows $Ledger) }
catch { Exit-NotWritten "cannot read the Tracks table: $($_.Exception.Message)" }

function Get-TrackName($Row) {
    $n = ([string]$Row.Track).Trim()
    if (-not $n) { $n = ([string]$Row.Branch).Trim() }
    return $n
}

# The Session cell as written, one pair of surrounding quotes or backticks off.
function Get-CellText([string]$Cell) {
    $t = $Cell.Trim()
    if ($t.Length -ge 2 -and (($t.StartsWith('`') -and $t.EndsWith('`')) -or ($t.StartsWith('"') -and $t.EndsWith('"')))) { $t = $t.Substring(1, $t.Length - 2).Trim() }
    return $t
}

# A -NewSession that is a track's Session cell (its text, or its id token as the
# scope guard binds rows; any row, finished or live) is refused.
# -NewSession is read the same way as a cell: its first word, with a local_ prefix in any case
# (the token reader is case-sensitive there, so a refusal would be missed).
$newFirst = ($new -split '\s+')[0] -replace '\A(?i:local_)', 'local_'
$newToken = Get-CoordSessionToken $newFirst
foreach ($row in $rows) {
    $cellText = Get-CellText ([string]$row.Session)
    $tok = Get-CoordSessionToken ([string]$row.Session)
    $same = ($cellText -and [string]::Equals($cellText, $new, [System.StringComparison]::OrdinalIgnoreCase))
    # An id followed by a note (an id, a space, then "(opus)") names that id too.
    $firstTok = $null
    if ($cellText) { $firstTok = Get-CoordSessionToken ($cellText -split '\s+')[0] }
    if ($same -or ($tok -and $newToken -and $tok -ceq $newToken) -or ($firstTok -and $newToken -and $firstTok -ceq $newToken)) { Exit-NotWritten "-NewSession $new is a track's session (row $(Get-TrackName $row)), not a new coordinator" }
}

$live = @($rows | Where-Object { -not (Test-CoordRowTerminal $_.Status) })

# Distinct repos (full path, compared as the platform compares paths) in
# first-seen order; every live row is checked before any fetch.
$repos = New-Object System.Collections.Generic.List[string]
$repoIndex = New-Object 'System.Collections.Generic.Dictionary[string,int]' (Get-CoordPathComparison -Comparer)
$rowRepo = New-Object System.Collections.Generic.List[int]
foreach ($row in $live) {
    $cell = ([string]$row.Repo).Trim()
    $full = ConvertTo-CoordRootedPath $cell
    if (-not $full) { Exit-NotWritten "row $(Get-TrackName $row): Repo '$cell' is not a full path (a rooted path below a drive root, with no , ; ( or ))" }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { Exit-NotWritten "row $(Get-TrackName $row): Repo '$cell' is not an existing folder; nothing can be fetched for it" }
    if (-not $repoIndex.ContainsKey($full)) {
        # git walks up from a folder that is no repo: only a working tree's own top level is that repo.
        # Asked by property, not by comparing paths: git prints the resolved path, which differs from a
        # cell spelled through a junction or a subst drive.
        $iw = Invoke-CoordGit $full @('rev-parse', '--is-inside-work-tree')
        if ($iw.Code -ne 0) { Exit-NotWritten "row $(Get-TrackName $row): git could not read Repo '$cell' as a working tree (exit $($iw.Code)); nothing can be fetched for it" }
        $pf = Invoke-CoordGit $full @('rev-parse', '--show-prefix')
        $inside = ($iw.Out.Count -and $iw.Out[0].Trim() -ceq 'true')
        $atTop = ($pf.Code -eq 0 -and (-not $pf.Out.Count -or -not $pf.Out[0].Trim()))
        if (-not $inside -or -not $atTop) {
            Exit-NotWritten "row $(Get-TrackName $row): Repo '$cell' is not the top level of a git working tree; the fetch would not be of that folder"
        }
        $repoIndex[$full] = $repos.Count; $repos.Add($full)
    }
    $rowRepo.Add($repoIndex[$full])
}

# ---- 4. fetch origin main per repo ------------------------------------------
# git runs on the validated full path, with GIT_TERMINAL_PROMPT=0 for the
# fetches; the fetch itself has no timeout.
$tips = New-Object System.Collections.Generic.List[string]
if ($repos.Count) {
    $script:promptPrev = $env:GIT_TERMINAL_PROMPT
    $script:promptSet = $true
    $env:GIT_TERMINAL_PROMPT = '0'
}
try {
    foreach ($repo in $repos) {
        $f = Invoke-CoordGit $repo @('fetch', '--quiet', 'origin', 'main')
        if ($f.Code -ne 0) { Exit-NotWritten "git -C $repo fetch --quiet origin main failed (exit $($f.Code)); no sha to relay" }
        $t = Invoke-CoordGit $repo @('rev-parse', '--verify', '--quiet', 'refs/remotes/origin/main^{commit}')
        $tip = ''
        if ($t.Code -eq 0 -and $t.Out.Count) { $tip = $t.Out[0].Trim() }
        if (-not (Test-CoordSha40 $tip)) { Exit-NotWritten "$repo refs/remotes/origin/main tip is not a 40-hex commit after the fetch (got '$tip')" }
        $h = Invoke-CoordGit $repo @('rev-parse', '--verify', '--quiet', 'FETCH_HEAD^{commit}')
        $fh = ''
        if ($h.Code -eq 0 -and $h.Out.Count) { $fh = $h.Out[0].Trim() }
        if (-not (Test-CoordSha40 $fh)) { Exit-NotWritten "$repo FETCH_HEAD is not a 40-hex commit after the fetch (got '$fh')" }
        if ($tip -cne $fh) { Exit-NotWritten "$repo refs/remotes/origin/main ($tip) is not what the fetch brought ($fh); does origin's fetch refspec map main?" }
        $tips.Add($tip)
    }
}
finally { Restore-GitPrompt }

# ---- 5-7. lock, compare, stamp, swap ----------------------------------------
# Everything from the lock on runs inside try/finally, so a run that dies in
# process (a throw, Ctrl+C) still releases it.
try {
    $taken = Enter-CoordLedgerLock -Path $Ledger
    $script:lock = $taken.Lock
    if (-not $taken.Ok) { Exit-NotWritten $taken.Error }
    if (-not (Test-Path -LiteralPath $Ledger -PathType Leaf)) { Exit-NotWritten "no ledger at $Ledger any more (moved away during the fetch?)" }
    # Raw bytes, before any decoding: a change that no longer decodes is still
    # a change during the fetch.
    try { $againBytes = [System.IO.File]::ReadAllBytes($Ledger) }
    catch { Exit-NotWritten "cannot read ${Ledger}: $($_.Exception.Message)" }
    if ([Convert]::ToBase64String($againBytes) -cne [Convert]::ToBase64String($snap.Bytes)) { Exit-NotWritten "ledger changed during the fetch; rerun ($Ledger)" }

    $stamp = (Get-Date).ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
    # The old line without its own "before that" tail: the line names the new
    # one, the old one, and whoever the old one took over from; the Log's
    # HANDOFF lines keep the whole history. The cut is at the first
    # "; before that: ". A name this script writes cannot hold that text
    # (step 1 refuses it), so the cut never lands inside one it wrote.
    $oldRest = $oldLine -replace '^Coordinator:\s*', ''
    $cut = $oldRest.IndexOf($beforeThat, [System.StringComparison]::Ordinal)
    if ($cut -ge 0) { $oldRest = $oldRest.Substring(0, $cut) }
    $newLine = 'Coordinator: session "' + $new + '", took over ' + $stamp + ' from "' + $old + '"' + $beforeThat + $oldRest
    $repoPart = ''
    if ($repos.Count) {
        $parts = New-Object System.Collections.Generic.List[string]
        for ($j = 0; $j -lt $repos.Count; $j++) { $parts.Add([System.IO.Path]::GetFileName($repos[$j]) + ' main ' + $tips[$j].Substring(0, 12)) }
        $repoPart = '; ' + ($parts -join ', ')
    }
    $logLine = $stamp + ' HANDOFF: "' + $new + '" took over from "' + $old + '" (coord-handoff.ps1); live tracks: ' + $live.Count + $repoPart

    $lines[$ci] = $newLine
    $lines.Insert($sec.Insert, $logLine)

    $swap = Write-CoordLedgerSwap -Path $Ledger -Expected $snap.Bytes -Text ($lines -join $snap.Newline) -Bom $snap.Bom -Added 'the new Coordinator line and the HANDOFF Log line'
    if ($swap.Status -eq 'changed') { Exit-NotWritten "ledger changed since it was read; rerun ($Ledger)" }
    if (-not $swap.Ok) { Exit-NotWritten $swap.Error }
}
finally {
    if ($script:lock) { $script:lock.Dispose(); $script:lock = $null }
}

# ---- 8. print ----------------------------------------------------------------
Write-Output "COORD-HANDOFF ${Ledger}: Coordinator line now: $newLine"
Write-Output "COORD-HANDOFF $Ledger [Log]: $logLine"
for ($i = 0; $i -lt $live.Count; $i++) {
    $row = $live[$i]
    $sess = ([string]$row.Session).Trim()
    if (-not $sess) { $sess = 'no session' }
    $j = $rowRepo[$i]
    Write-Output ('MESSAGE ' + (Get-TrackName $row) + ' (' + $sess + '): coordinator handoff: report to "' + $new + '" from now on; ' + [System.IO.Path]::GetFileName($repos[$j]) + ' main is now ' + $tips[$j].Substring(0, 12))
}
Write-Output 'CHECKLIST: (1) re-verify the baseline yourself: repo-snapshot.ps1 and ListAgents, not the ledger''s Baseline'
Write-Output 'CHECKLIST: (2) run coord-log.ps1 -Register from the main checkout'
Write-Output 'CHECKLIST: (3) send each MESSAGE line above to its session with SendMessage'
Write-Output 'CHECKLIST: (4) read and log any report still sent to the old coordinator'
Write-Output 'CHECKLIST: (5) in the desktop app a session started from inside the old coordinator nests under it; move it out before the old coordinator is closed'
Write-Output 'CHECKLIST: (6) no hand edit of the ledger while a ledger script runs (a hand edit takes no lock)'
Write-Output 'COORD-HANDOFF: done; nothing sent (the coordinator sends each MESSAGE line)'
exit 0
