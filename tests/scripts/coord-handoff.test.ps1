# Tests for scripts/coord-handoff.ps1: one replacement of the coordination
# ledger holding the rewritten Coordinator line and a stamped HANDOFF Log line,
# after a fetch of origin main for every repo a live Tracks row names.
# Ported from the private coordinate toolkit (coord-handoff.test.ps1), 2026-10-28.
#
# What changed from the private suite (D2 of docs/plans/2026-10-18-script-port.md):
#   - -NewSession is a NAME or an id and -NewTitle is gone: the public
#     Coordinator line is `session "<name>", ...`, so a name is written between
#     double quotes and a name that holds one is refused (H10)
#   - the NOTES lines and the Desktop notes folder are gone with their cases
#     (private H12, H23, H28, H29, H32, H33); H12 now pins the "before that"
#     chain instead, and the private H27 (a title holding "; before that: ")
#     became a refusal row in H10
#   - the session-id-only refusals became name-or-id rows (H21)
#   - the checklist names ListAgents / SendMessage and no Desktop-only tool
# The harness is as before: the script runs in this process
# (`& <script> -NewSession ...`; its `exit` ends only the script and sets
# $LASTEXITCODE). A global function named `git` shadows git.exe for the
# script's Invoke-CoordGit calls: it records every call, lets a case edit the
# ledger or answer a call, and otherwise runs the real git by full path. A
# global `gh` records any call (the script must make none). A global Get-Date
# lets a case edit the ledger at the moment the script stamps. Every global
# function is removed after its case. Only H14 uses powershell.exe -File.
#
#   H0  the script exists (a missing script fails every case below)
#   H1  happy path: one live row; the Coordinator line rewritten once (old name
#       kept in the took-over text and in "before that"), the Log line stamped
#       from the clock, every other line byte-identical; coord-brief's regex
#       reads the new name; the output order and lines; origin/main fetched
#   H2  encoding and line ends: BOM kept / not added, CRLF kept, mixed ends
#       become CRLF, LF kept, non-ASCII round-trips, invalid UTF-8 refused
#   H3  a forced swap failure (read-only ledger): byte-unchanged, no temp file;
#       the coord-log lock held by someone else: refused, unchanged
#   H4  an editor's write between the read and the swap: refused, kept
#   H5  a live row added / a row's Repo changed / a Log line added while the
#       fetch runs: refused "ledger changed during the fetch; rerun"
#   H6  a failed fetch: refused, unchanged
#   H7  a fetch refspec that excludes main: refused, unchanged
#   H8  a tip that is not 40 hex, a FETCH_HEAD that is not 40 hex or differs
#   H9  a live row whose PR targets a non-main base: main's sha, gh never called
#   H10 input validation, each refused before any fetch; accepted spellings
#   H11 per-track messages carry their own repo's sha; a terminal row gets none
#   H12 four handoffs A->B->C->D: the line names D, C and, after "before that",
#       B only; the Log keeps every HANDOFF
#   H13 header and section problems, bad live rows: refused, no fetch
#   H14 no time parameter, no leftover word
#   H15 no live rows: no fetch, written, "live tracks: 0"
#   H16 without -Ledger: linked worktree and outside a repo refused; main
#       checkout written, never registered
#   H19 a live row's Repo must be a rooted full path; git runs on the full path
#   H20 an unreadable Tracks section is refused before any fetch
#   H21 -NewSession is a track's session (name or id)
#   H22 a stale copy of today's ledger is refused; the canonical one accepted
#   H25 GIT_TERMINAL_PROMPT is 0 for the fetch and restored after
#   H26 the ledger deleted during the swap retry: never recreated, temp kept
#   H30 the snapshot is read under the coord-log lock, which waits up to 5 s
#   H31 non-UTF-8 bytes written during the fetch are a change
#   H34 the swap is one write: a watcher sampling the ledger during a run saw
#       the original and never a version holding only one of the two changes.
#       This is a sampling check: it catches a two-step write only when a
#       sample lands between the steps. The structural guarantee is the single
#       Write-CoordLedgerSwap call; a refused handoff leaves the ledger
#       byte-unchanged (every Test-Refused row above)
#   H17 no temp or lock files, no global functions left (runs last)
#   H18 the real index folder is byte-unchanged
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\scripts\coord-handoff.test.ps1 [-ScriptPath <mutant copy>]
#       (a mutant copy needs coord-common.ps1 next to it: it dot-sources it)
# Exit: 0 = all passed, 1 = a case failed.
param([string]$ScriptPath = '')

try { . (Join-Path $PSScriptRoot '../fixtures/hook-test-fixture.ps1') } catch { Write-Error "could not load hook-test-fixture.ps1: $_"; exit 1 }
Clear-HookRunnerGitEnv
. (Join-Path $PSScriptRoot '../fixtures/coord-test-fixture.ps1')
if (-not $ScriptPath) { $ScriptPath = Join-Path $coordScriptsDir 'coord-handoff.ps1' }
$ScriptPath = [System.IO.Path]::GetFullPath($ScriptPath)
. (Join-Path $coordScriptsDir 'coord-common.ps1')
$ErrorActionPreference = 'Stop'

# The real git, by full path, before any stub exists.
$global:hGitExe = (Get-Command git -CommandType Application | Select-Object -First 1).Source
$global:hUtf8 = New-Object System.Text.UTF8Encoding($false)
$global:hGitCalls = New-Object System.Collections.Generic.List[string]
$global:hGhCalls = New-Object System.Collections.Generic.List[string]
$global:hGitHook = $null
$global:hDateHook = $null

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('coord-handoff-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory($root)
# Nothing in this run may reach the real index folder.
$realIndexBefore = Get-CoordRealIndexDigest
$null = New-CoordScratchIndex $root

$script:caseN = 0
$script:hWritten = 0
$script:hRefused = 0
$script:hLedgers = New-Object System.Collections.Generic.List[string]
$script:advN = 0

# ---- ledger builders ---------------------------------------------------------
function New-Id { return ('local_' + [Guid]::NewGuid().ToString()) }

function New-CoordLine([string]$Name) {
    return ('Coordinator: session "' + $Name + '", cwd `/work/main`.')
}

# One Tracks row with the nine columns of the ledger template.
function New-Row {
    param([string]$Track, [string]$Repo, [string]$Session = '', [string]$Branch = 'br', [string]$Pr = '', [string]$Status = 'running')
    return ('| ' + $Track + ' | ' + $Repo + ' | ' + $Session + ' |  |  | ' + $Branch + ' | ** | ' + $Pr + ' | ' + $Status + ' |')
}

function Get-HLines {
    param([string]$CoordLine, [string[]]$Rows = @(), [string[]]$LogLines = @('10:00 ledger created'))
    $top = @('# Coordination ledger - 2026-10-17', '', $CoordLine, 'Rule: append every event here.', '',
        '## Baseline', '', '| Repo | origin/main | Open PRs | CI | Verified at |', '|------|-------------|----------|----|-------------|', '',
        '## Tracks', '', '| Track | Repo | Session | Model | Cwd | Branch | Scope | PR | Status |',
        '|-------|------|---------|-------|-----|--------|-------|----|--------|')
    $bottom = @('', '## Merge slots', '', '1. (none)', '', '## Owed checks', '', '- [ ] (none)', '', '## Decisions', '', '## Findings', '',
        '## Log', '', '<!-- HH:MM <event> -->')
    $tail = @('', '## field notes', '', 'note one')
    return [string[]](@($top) + @($Rows) + @($bottom) + @($LogLines) + @($tail))
}

function New-HLedger {
    param([string[]]$Lines, [string]$Nl = "`n", [bool]$Bom = $false, [bool]$TrailingNl = $true)
    $script:caseN++
    $dir = Join-Path $root ('c' + $script:caseN)
    [void][IO.Directory]::CreateDirectory($dir)
    $p = Join-Path $dir 'ledger.md'
    $text = ($Lines -join $Nl)
    if ($TrailingNl) { $text += $Nl }
    [System.IO.File]::WriteAllText($p, $text, (New-Object System.Text.UTF8Encoding($Bom)))
    $script:hLedgers.Add($p)
    return $p
}

function Get-Bytes([string]$Path) { return [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Path)) }

# Files beside the ledger named <ledger>.* : the lock, a temp file.
function Get-Stray([string]$Path) {
    $dir = Split-Path -Parent $Path
    $leaf = Split-Path -Leaf $Path
    return @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like ($leaf + '.*') })
}

function Get-Stamps($R) {
    return @($R.Before.ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture), $R.After.ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture))
}

# ---- expected text -----------------------------------------------------------
function Get-NewCoordLine([string]$OldLine, [string]$Old, [string]$New, [string]$Stamp) {
    # The old line's own "; before that: ..." tail is dropped; the cut is at the first one.
    $rest = $OldLine.Substring('Coordinator: '.Length)
    $cut = $rest.IndexOf('; before that: ', [System.StringComparison]::Ordinal)
    if ($cut -ge 0) { $rest = $rest.Substring(0, $cut) }
    return ('Coordinator: session "' + $New + '", took over ' + $Stamp + ' from "' + $Old + '"; before that: ' + $rest)
}

function Get-LogLine([string]$Old, [string]$New, [string]$Stamp, [int]$Live, [string]$Tail) {
    return ($Stamp + ' HANDOFF: "' + $New + '" took over from "' + $Old + '" (coord-handoff.ps1); live tracks: ' + $Live + $Tail)
}

# The whole expected file text: $Lines with the first Coordinator line rewritten and
# the Log line inserted after the Log section's last non-blank line.
function Get-ExpectedText {
    param([string[]]$Lines, [string]$Old, [string]$New, [string]$Stamp, [int]$Live, [string]$Tail, [string]$Nl)
    $exp = New-Object System.Collections.Generic.List[string]
    foreach ($l in $Lines) { $exp.Add($l) }
    $c = -1
    for ($k = 0; $k -lt $exp.Count; $k++) { if ($exp[$k] -match '^Coordinator:') { $c = $k; break } }
    $exp[$c] = Get-NewCoordLine $exp[$c] $Old $New $Stamp
    $h = -1
    for ($k = 0; $k -lt $exp.Count; $k++) { if ($exp[$k] -match '^##\s+Log\s*$') { $h = $k; break } }
    $end = $exp.Count
    for ($k = $h + 1; $k -lt $exp.Count; $k++) { if ($exp[$k] -match '^#{1,2}\s') { $end = $k; break } }
    $last = $h
    for ($k = $end - 1; $k -gt $h; $k--) { if ($exp[$k].Trim()) { $last = $k; break } }
    $exp.Insert($last + 1, (Get-LogLine $Old $New $Stamp $Live $Tail))
    return (($exp.ToArray() -join $Nl) + $Nl)
}

function Get-MsgLine([string]$Track, [string]$Sess, [string]$New, [string]$Sha) {
    return ('MESSAGE ' + $Track + ' (' + $Sess + '): coordinator handoff: report to "' + $New + '" from now on; launch main is now ' + $Sha.Substring(0, 12))
}

# $Lines with everything between the '## Tracks' heading and '## Merge slots' replaced by $Body.
function Set-TracksBody([string[]]$Lines, [string[]]$Body) {
    $o = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($l in $Lines) {
        if ($skip) {
            if ($l -ceq '## Merge slots') { $skip = $false; $o.Add(''); $o.Add($l) }
            continue
        }
        $o.Add($l)
        if ($l -ceq '## Tracks') { $skip = $true; foreach ($b in $Body) { $o.Add($b) } }
    }
    return $o.ToArray()
}

# A refusal's output shape alone, for a run whose ledger is gone.
function Test-RefusalShape($R) {
    $lines = @($R.Lines)
    $noMsg = (@($lines | Where-Object { $_ -match '^(MESSAGE |CHECKLIST:|COORD-HANDOFF: done)' -or $_ -match 'Coordinator line now:' -or $_ -match '\[Log\]:' }).Count -eq 0)
    return ($R.Code -eq 2 -and $lines.Count -eq 1 -and $lines[0] -cmatch '^COORD-HANDOFF: NOT WRITTEN - ' -and $noMsg)
}

# ---- fixture helpers ---------------------------------------------------------
# Advances origin's main by a merge commit (through the work clone); returns its sha.
function Step-Origin($Fx) {
    $script:advN++
    $b = 'adv' + $script:advN
    $sha = New-CoordBranch $Fx $b -Write @{ ($b + '.txt') = "x`n" }
    $m = @(Merge-CoordIntoMain $Fx ([string]@($sha)[-1]))
    return [string]$m[$m.Count - 1]
}
function Get-LaunchTip($Fx) { return (Get-CoordGitOut $Fx.Launch @('rev-parse', 'refs/remotes/origin/main')) }
function Get-OriginMain($Fx) { return (Get-CoordRemoteRef $Fx 'refs/heads/main') }

# ---- running the script ------------------------------------------------------
# In process. Returns { Code; Out; Lines (non-empty output lines); Calls (every git
# call, as "-C <repo> <args>"); GhCalls; Before; After }.
function Invoke-Handoff {
    param([string]$Session = '', [string]$Ledger = '', [string]$Cwd = '',
        [scriptblock]$GitHook = $null, [scriptblock]$DateHook = $null, [string[]]$Tail = @())
    $global:hGitCalls = New-Object System.Collections.Generic.List[string]
    $global:hGhCalls = New-Object System.Collections.Generic.List[string]
    $global:hGitHook = $GitHook
    $global:hDateHook = $DateHook
    $splat = @{ NewSession = $Session }
    if ($Ledger) { $splat['Ledger'] = $Ledger }
    $before = Get-Date
    function global:git {
        $line = (@($args | ForEach-Object { [string]$_ }) -join ' ')
        $global:hGitCalls.Add($line)
        if ($global:hGitHook) {
            $h = $global:hGitHook
            $a = & $h $line
            if ($a -is [hashtable] -and $a.ContainsKey('Handled')) { $global:LASTEXITCODE = $a.Code; return $a.Out }
        }
        & $global:hGitExe @args 2>$null
    }
    function global:gh {
        $global:hGhCalls.Add((@($args | ForEach-Object { [string]$_ }) -join ' '))
        $global:LASTEXITCODE = 1
    }
    if ($DateHook) {
        function global:Get-Date {
            if ($global:hDateHook) { $h = $global:hDateHook; $global:hDateHook = $null; & $h }
            Microsoft.PowerShell.Utility\Get-Date @args
        }
    }
    $global:LASTEXITCODE = $null
    $pushed = $false
    try {
        if ($Cwd) { Push-Location -LiteralPath $Cwd -ErrorAction Stop; $pushed = $true }
        $out = @(& $ScriptPath @splat @Tail 2>&1)
        $code = $LASTEXITCODE
    }
    catch { $out = @("THREW: $_"); $code = 'threw' }
    finally {
        if ($pushed) { Pop-Location }
        Remove-Item -LiteralPath 'Function:\git', 'Function:\gh', 'Function:\Get-Date' -Force -ErrorAction SilentlyContinue
        $global:hGitHook = $null
        $global:hDateHook = $null
    }
    $after = Get-Date
    if ($code -eq 0) { $script:hWritten++ } elseif ($code -eq 2) { $script:hRefused++ }
    $text = (($out | ForEach-Object { [string]$_ }) -join "`n")
    return [pscustomobject]@{
        Code = $code; Out = $text; Lines = @($text -split "`r?`n" | Where-Object { $_.Trim() })
        Calls = @($global:hGitCalls.ToArray()); GhCalls = @($global:hGhCalls.ToArray()); Before = $before; After = $after
    }
}

# Through powershell.exe -File (the only route a mutant with a -Time parameter shows red on).
function Invoke-HandoffFile([string]$ArgText) {
    $x = Invoke-HookTestPowerShell -Script $ScriptPath -StartDir $root -ScriptArgs $ArgText
    $text = [string]$x.Out
    if ($x.Code -eq 0) { $script:hWritten++ } elseif ($x.Code -eq 2) { $script:hRefused++ }
    return [pscustomobject]@{ Code = $x.Code; Out = $text; Lines = @($text -split "`r?`n" | Where-Object { $_.Trim() }); Calls = @(); GhCalls = @(); Err = [string]$x.Err }
}

# ---- assertions --------------------------------------------------------------
# A refusal: exit 2, exactly one NOT WRITTEN line (matching $Reason when given), no
# MESSAGE / CHECKLIST / done / "Coordinator line now" line; and the ledger
# holds exactly $Bytes (base64) with no temp or lock file beside it.
function Test-Refused {
    param([string]$Label, $R, [string]$Path, [string]$Bytes, [string]$Reason = '')
    $lines = @($R.Lines)
    $shape = ($R.Code -eq 2 -and $lines.Count -eq 1 -and $lines[0] -cmatch '^COORD-HANDOFF: NOT WRITTEN - ')
    $noMsg = (@($lines | Where-Object { $_ -match '^(MESSAGE |CHECKLIST:|COORD-HANDOFF: done)' -or $_ -match 'Coordinator line now:' -or $_ -match '\[Log\]:' }).Count -eq 0)
    $why = $true
    if ($Reason) { $why = ($R.Out -match $Reason) }
    Assert-Coord "$Label : refused (exit 2) with one NOT WRITTEN line and no MESSAGE/CHECKLIST line" ($shape -and $noMsg -and $why) "code=$($R.Code) out=$($R.Out)"
    Assert-Coord "$Label : ledger bytes are exactly the expected ones (nothing of ours), no temp or lock file beside it" ($R.Code -eq 2 -and (Get-Bytes $Path) -ceq $Bytes -and @(Get-Stray $Path).Count -eq 0) "code=$($R.Code) stray=$((Get-Stray $Path | ForEach-Object { $_.Name }) -join ',')"
}

# A refusal that came before any fetch: no fetch call was made and the repo's
# refs/remotes/origin/main is still $Stale (origin's main had moved on).
function Test-RefusedNoFetch {
    param([string]$Label, $R, [string]$Path, [string]$Bytes, $Fx, [string]$Stale, [string]$Reason = '')
    Test-Refused $Label $R $Path $Bytes $Reason
    $fetches = @($R.Calls | Where-Object { $_ -cmatch ' fetch ' })
    $now = Get-LaunchTip $Fx
    Assert-Coord "$Label : no fetch ran, launch's refs/remotes/origin/main is still the old tip" ($R.Code -eq 2 -and $fetches.Count -eq 0 -and $now -ceq $Stale) "code=$($R.Code) fetches=$($fetches.Count) tip=$now stale=$Stale"
}

# A write: exit 0 and the file is exactly the expected text for one of the clock's
# two candidate minutes. Returns the matching stamp (or $null).
function Test-Written {
    param([string]$Label, $R, [string]$Path, [string[]]$Lines, [string]$Old, [string]$New, [string]$Tail = '', [int]$Live = 0, [string]$Nl = "`n")
    $got = [System.IO.File]::ReadAllText($Path)
    $hit = $null
    foreach ($s in (Get-Stamps $R)) {
        if ($got -ceq (Get-ExpectedText $Lines $Old $New $s $Live $Tail $Nl)) { $hit = $s }
    }
    Assert-Coord $Label ($R.Code -eq 0 -and $null -ne $hit) "code=$($R.Code) out=$($R.Out)`n--- got ---`n$got"
    return $hit
}

function Get-Fetches($R) { return @($R.Calls | Where-Object { $_ -cmatch ' fetch ' }) }

# What coord-brief.ps1 reads from the Coordinator line.
$coordBriefRegex = '^Coordinator:\s*session\s+"([^"]+)"'

$oldName = 'Morning coordinator'
$newName = 'Evening coordinator'

# =============================================================================
Write-Host "(H0) the script under test"
Assert-Coord 'H0 coord-handoff.ps1 exists' (Test-Path -LiteralPath $ScriptPath -PathType Leaf) $ScriptPath

# =============================================================================
Write-Host "(H1) happy path"
$fxA = New-CoordFixture $root 'fxA'
$sess1 = 'track-one'
$shaA = Step-Origin $fxA
$staleA = Get-LaunchTip $fxA
Assert-Coord 'H1 setup: launch still holds the old origin/main, so only a fetch can bring the new one' ($staleA -cne $shaA) "$staleA $shaA"
$lines = @(Get-HLines (New-CoordLine $oldName) @(New-Row 'track1' $fxA.Launch $sess1 'br1' '#5' 'running'))
$p = New-HLedger $lines
$r = Invoke-Handoff $newName $p
$tail = '; launch main ' + $shaA.Substring(0, 12)
$stamp = Test-Written 'H1 the file is the original with the Coordinator line rewritten and the Log line stamped, every other line byte-identical' $r $p $lines $oldName $newName $tail 1
$gotLines = @([System.IO.File]::ReadAllText($p) -split "`r?`n")
$coordLines = @($gotLines | Where-Object { $_ -match '^Coordinator:' })
$oldInTook = ('from "' + $oldName + '"; before that: session "' + $oldName + '"')
Assert-Coord 'H1 exactly one Coordinator line, holding the old name in the took-over text and in the before-that text' ($r.Code -eq 0 -and $coordLines.Count -eq 1 -and $coordLines[0].Contains($oldInTook)) "code=$($r.Code) lines=$($coordLines -join ' // ')"
$briefOk = ($coordLines.Count -eq 1 -and $coordLines[0] -match $coordBriefRegex -and $Matches[1] -ceq $newName)
Assert-Coord "H1 coord-brief's regex reads the new name from the rewritten line" ($r.Code -eq 0 -and $briefOk) ($coordLines -join ' // ')
$expCoord = Get-NewCoordLine (New-CoordLine $oldName) $oldName $newName $stamp
$expLog = Get-LogLine $oldName $newName $stamp 1 $tail
$ol = @($r.Lines)
Assert-Coord 'H1 prints the new Coordinator line, then the stamped Log line' ($r.Code -eq 0 -and $ol.Count -ge 2 -and $ol[0] -ceq ("COORD-HANDOFF ${p}: Coordinator line now: " + $expCoord) -and $ol[1] -ceq ("COORD-HANDOFF ${p} [Log]: " + $expLog)) ($r.Out)
$msgs = @($ol | Where-Object { $_ -cmatch '^MESSAGE ' })
Assert-Coord "H1 one MESSAGE line for the live row, with the row's session and the fetched origin/main sha12" ($r.Code -eq 0 -and $msgs.Count -eq 1 -and $msgs[0] -ceq (Get-MsgLine 'track1' $sess1 $newName $shaA)) ($msgs -join "`n")
Assert-Coord 'H1 no NOTES line (the notes folder is not part of the public version)' ($r.Code -eq 0 -and @($ol | Where-Object { $_ -match '^NOTES' }).Count -eq 0) $r.Out
$cl = @($ol | Where-Object { $_ -cmatch '^CHECKLIST:' })
$clOk = ($cl.Count -eq 6 -and $cl[0] -match 'repo-snapshot\.ps1' -and $cl[0] -match 'ListAgents' -and $cl[1] -match 'coord-log\.ps1 -Register' -and $cl[1] -match 'main checkout' -and
    $cl[2] -match 'MESSAGE' -and $cl[2] -match 'SendMessage' -and $cl[3] -match 'old coordinator' -and $cl[4] -match 'nests' -and $cl[5] -match 'hand edit')
Assert-Coord 'H1 six CHECKLIST lines in order (baseline, -Register, send MESSAGE, old reports, nesting, no hand edit)' ($r.Code -eq 0 -and $clOk) ($cl -join "`n")
Assert-Coord 'H1 no Desktop-only session tool is named (list_sessions, send_message, get_session, detach_session)' ($r.Code -eq 0 -and $r.Out -notmatch 'list_sessions|send_message|get_session|detach_session') $r.Out
$iMsg = -1; $iCl = -1
for ($k = 0; $k -lt $ol.Count; $k++) {
    if ($iMsg -lt 0 -and $ol[$k] -cmatch '^MESSAGE ') { $iMsg = $k }
    if ($iCl -lt 0 -and $ol[$k] -cmatch '^CHECKLIST:') { $iCl = $k }
}
Assert-Coord 'H1 output order: Coordinator line, Log line, MESSAGE, CHECKLIST, then the done line last' ($r.Code -eq 0 -and $iMsg -eq 2 -and $iCl -gt $iMsg -and $ol[$ol.Count - 1] -ceq 'COORD-HANDOFF: done; nothing sent (the coordinator sends each MESSAGE line)') ($r.Out)
Assert-Coord 'H1 the fetch ran: launch''s refs/remotes/origin/main is now origin''s main, from exactly the call git -C <repo> fetch --quiet origin main' ($r.Code -eq 0 -and (Get-LaunchTip $fxA) -ceq $shaA -and $r.Calls -contains ('-C ' + $fxA.Launch + ' fetch --quiet origin main')) (($r.Calls) -join "`n")
Assert-Coord 'H1 the script called no gh' ($r.Code -eq 0 -and $r.GhCalls.Count -eq 0) (($r.GhCalls) -join "`n")

# =============================================================================
Write-Host "(H2) encoding and line ends"
$eAcute = [string][char]0xE9
$arrow = [string][char]0x2192
$plain = @(Get-HLines (New-CoordLine 'Old coordinator') @())

$p = New-HLedger $plain -Bom $true
$r = Invoke-Handoff $newName $p
$bytes = [System.IO.File]::ReadAllBytes($p)
Assert-Coord 'H2 a BOM is kept (exactly one)' ($r.Code -eq 0 -and $bytes.Length -gt 4 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF -and -not ($bytes[3] -eq 0xEF -and $bytes[4] -eq 0xBB)) $r.Out
$null = Test-Written 'H2 BOM file: content right' $r $p $plain 'Old coordinator' $newName

$p = New-HLedger $plain
$r = Invoke-Handoff $newName $p
$bytes = [System.IO.File]::ReadAllBytes($p)
Assert-Coord 'H2 no BOM stays without' ($r.Code -eq 0 -and $bytes.Length -gt 0 -and $bytes[0] -ne 0xEF) $r.Out
$null = Test-Written 'H2 no-BOM file: content right' $r $p $plain 'Old coordinator' $newName

$p = New-HLedger $plain -Nl "`r`n"
$r = Invoke-Handoff $newName $p
$t = [System.IO.File]::ReadAllText($p)
Assert-Coord 'H2 CRLF kept on every line (no bare LF or CR)' ($r.Code -eq 0 -and $t.Contains("`r`n") -and ($t -replace "`r`n", '') -notmatch "[`r`n]") $r.Out
$null = Test-Written 'H2 CRLF file: content right' $r $p $plain 'Old coordinator' $newName '' 0 "`r`n"

$p = New-HLedger $plain -Nl "`r`n"
$t = [System.IO.File]::ReadAllText($p).Replace("note one`r`n", "note one`n")
[System.IO.File]::WriteAllText($p, $t, $coordUtf8)
$r = Invoke-Handoff $newName $p
$t = [System.IO.File]::ReadAllText($p)
Assert-Coord 'H2 mixed line ends: written with CRLF throughout' ($r.Code -eq 0 -and ($t -replace "`r`n", '') -notmatch "[`r`n]" -and $t.EndsWith("note one`r`n")) $r.Out
$null = Test-Written 'H2 mixed line ends: content right' $r $p $plain 'Old coordinator' $newName '' 0 "`r`n"

$p = New-HLedger $plain
$r = Invoke-Handoff $newName $p
Assert-Coord 'H2 LF stays LF' ($r.Code -eq 0 -and -not [System.IO.File]::ReadAllText($p).Contains("`r")) $r.Out

$uniOld = 'Caf' + $eAcute + ' coord'
$uni = @(Get-HLines (New-CoordLine $uniOld) @() @('10:00 ledger created'))
$uni = @($uni | ForEach-Object { if ($_ -ceq 'note one') { 'note caf' + $eAcute + ' ' + $arrow + ' done' } else { $_ } })
$p = New-HLedger $uni
$uniNew = 'Caf' + $eAcute + ' ' + $arrow + ' new'
$r = Invoke-Handoff $uniNew $p
$null = Test-Written 'H2 non-ASCII in the Coordinator line, the new name and another line round-trips' $r $p $uni $uniOld $uniNew

$p = New-HLedger $plain
$raw = New-Object 'System.Collections.Generic.List[byte]'
$raw.AddRange([System.IO.File]::ReadAllBytes($p))
$raw.InsertRange(2, [byte[]](0xC3, 0x28))
[System.IO.File]::WriteAllBytes($p, $raw.ToArray())
$b = Get-Bytes $p
$r = Invoke-Handoff $newName $p
Test-Refused 'H2 a file that is not UTF-8' $r $p $b 'UTF-8'

# =============================================================================
Write-Host "(H3) a forced swap failure, and the lock"
$lines3 = @(Get-HLines (New-CoordLine $oldName) @(New-Row 'tr3' $fxA.Launch $sess1 'br3' '' 'running'))
$p = New-HLedger $lines3
$b = Get-Bytes $p
Set-ItemProperty -LiteralPath $p -Name IsReadOnly -Value $true
try { $r = Invoke-Handoff $newName $p } finally { Set-ItemProperty -LiteralPath $p -Name IsReadOnly -Value $false }
Test-Refused 'H3 read-only ledger, every swap try fails (neither the Coordinator change nor the Log line landed)' $r $p $b
Assert-Coord 'H3 ... the fetch had run before the swap failed (a live row existed), so the refusal is the swap''s' ($r.Code -eq 2 -and @(Get-Fetches $r).Count -ge 1) (($r.Calls) -join "`n")

$p = New-HLedger $plain
$b = Get-Bytes $p
$held = New-Object System.IO.FileStream(($p + '.coord-log.lock'), [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
try { $r = Invoke-Handoff $newName $p } finally { $held.Dispose() }
Remove-Item -LiteralPath ($p + '.coord-log.lock') -Force -ErrorAction SilentlyContinue
Test-Refused 'H3 the coord-log lock held by someone else' $r $p $b 'coord-log\.lock'

# =============================================================================
Write-Host "(H4) the ledger changes between the read and the swap"
# The script's one Get-Date call sits after its lock and re-read and before the swap's
# own comparison, so a Get-Date that appends is an editor writing in that window.
$p = New-HLedger $lines3
$global:hEditPath = $p
$r = Invoke-Handoff $newName $p -DateHook { [System.IO.File]::AppendAllText($global:hEditPath, "editor line`n") }
$exp4 = (($lines3 -join "`n") + "`neditor line`n")
Test-Refused "H4 an editor's line landed at the stamp: refused, the editor's line kept, no line of ours" $r $p ([Convert]::ToBase64String($global:hUtf8.GetBytes($exp4))) 'changed'

# =============================================================================
Write-Host "(H5) the ledger changes while the fetch runs"
$fxB = New-CoordFixture $root 'fxB'
$null = Step-Origin $fxB
$rowA = New-Row 'tr5' $fxA.Launch $sess1 'br5' '' 'running'
$base5 = @(Get-HLines (New-CoordLine $oldName) @($rowA))
$edits = @(
    @('a live row added', @(Get-HLines (New-CoordLine $oldName) @($rowA, (New-Row 'tr5b' $fxB.Launch 'other' 'br5b' '' 'running')))),
    @("a row's Repo changed", @(Get-HLines (New-CoordLine $oldName) @((New-Row 'tr5' $fxB.Launch $sess1 'br5' '' 'running')))),
    @('a Log line added', @(Get-HLines (New-CoordLine $oldName) @($rowA) @('10:00 ledger created', '10:05 editor line')))
)
foreach ($e in $edits) {
    $p = New-HLedger $base5
    $text2 = (($e[1] -join "`n") + "`n")
    $global:hEditPath = $p
    $global:hEditText = $text2
    $global:hFired = $false
    $hook = { param($l) if (-not $global:hFired -and $l -cmatch ' fetch ') { $global:hFired = $true; [System.IO.File]::WriteAllText($global:hEditPath, $global:hEditText, $global:hUtf8) }; return $null }
    $r = Invoke-Handoff $newName $p -GitHook $hook
    Assert-Coord "H5 $($e[0]): setup, the fetch ran and the edit landed during it" ($r.Code -eq 2 -and $global:hFired -eq $true) "code=$($r.Code) fired=$($global:hFired) out=$($r.Out)"
    Test-Refused "H5 $($e[0]) while the fetch ran" $r $p ([Convert]::ToBase64String($coordUtf8.GetBytes($text2))) 'ledger changed during the fetch; rerun'
}

# =============================================================================
Write-Host "(H6) a failed fetch"
$fx6 = New-CoordFixture $root 'fx6'
$null = Step-Origin $fx6
Invoke-HookTestGit $fx6.Launch @('remote', 'set-url', 'origin', (Join-Path $root 'nowhere.git'))
$lines6 = @(Get-HLines (New-CoordLine $oldName) @(New-Row 'tr6' $fx6.Launch $sess1 'br6' '' 'running'))
$p = New-HLedger $lines6
$b = Get-Bytes $p
$r = Invoke-Handoff $newName $p
Test-Refused 'H6 origin url pointing nowhere' $r $p $b 'fetch'
Assert-Coord 'H6 ... the refusal is the fetch failing (a fetch call was made)' ($r.Code -eq 2 -and @(Get-Fetches $r).Count -ge 1) (($r.Calls) -join "`n")

# =============================================================================
Write-Host "(H7) a fetch refspec that excludes main"
$fx7 = New-CoordFixture $root 'fx7'
$null = Step-Origin $fx7
Invoke-HookTestGit $fx7.Launch @('config', 'remote.origin.fetch', '+refs/heads/other:refs/remotes/origin/other')
$stale7 = Get-LaunchTip $fx7
$lines7 = @(Get-HLines (New-CoordLine $oldName) @(New-Row 'tr7' $fx7.Launch $sess1 'br7' '' 'running'))
$p = New-HLedger $lines7
$b = Get-Bytes $p
$r = Invoke-Handoff $newName $p
Test-Refused 'H7 refspec maps only another branch, a stale refs/remotes/origin/main left behind' $r $p $b 'not what the fetch brought'
Assert-Coord 'H7 setup: the stale ref is still stale and differs from origin''s advanced main (the fetch ran and brought it only to FETCH_HEAD)' ($r.Code -eq 2 -and @(Get-Fetches $r).Count -ge 1 -and (Get-LaunchTip $fx7) -ceq $stale7 -and $stale7 -cne (Get-OriginMain $fx7)) "stale=$stale7 tip=$(Get-LaunchTip $fx7) origin=$(Get-OriginMain $fx7)"

# =============================================================================
Write-Host "(H8) a tip that is not 40 hex, or not what the fetch brought"
$rows8 = @(
    @('tip short (7 hex)', 'refs/remotes/origin/main\^\{commit\}', 'abc1234', '40-hex'),
    @('tip 64 hex', 'refs/remotes/origin/main\^\{commit\}', ('a' * 64), '40-hex'),
    @('FETCH_HEAD short', 'FETCH_HEAD\^\{commit\}', 'abc1234', ''),
    @('FETCH_HEAD another 40-hex commit', 'FETCH_HEAD\^\{commit\}', ('b' * 40), 'not what the fetch brought')
)
foreach ($c in $rows8) {
    $p = New-HLedger $lines3
    $b = Get-Bytes $p
    $global:hHookRe = $c[1]
    $global:hHookAns = $c[2]
    $global:hHookHits = 0
    $hook = { param($l) if ($l -cmatch $global:hHookRe) { $global:hHookHits++; return @{ Handled = $true; Code = 0; Out = @($global:hHookAns) } }; return $null }
    $r = Invoke-Handoff $newName $p -GitHook $hook
    Test-Refused "H8 $($c[0])" $r $p $b $c[3]
    Assert-Coord "H8 $($c[0]): setup, the stub answered the rev-parse" ($r.Code -eq 2 -and $global:hHookHits -ge 1) "hits=$($global:hHookHits)"
}

# =============================================================================
Write-Host "(H9) a live row whose PR targets a non-main base"
$fx9 = New-CoordFixture $root 'fx9'
$devSha = New-CoordBranch $fx9 'develop' -Write @{ 'dev.txt' = "d`n" }
$shaMain9 = Step-Origin $fx9
Assert-Coord 'H9 setup: origin has a develop branch at another sha than main' ((Get-CoordRemoteRef $fx9 'refs/heads/develop') -ceq $devSha -and $devSha -cne $shaMain9) "$devSha $shaMain9"
$lines9 = @(Get-HLines (New-CoordLine $oldName) @(New-Row 'tr9' $fx9.Launch $sess1 'br9' '#7 (base develop)' 'running'))
$p = New-HLedger $lines9
$r = Invoke-Handoff $newName $p
$null = Test-Written 'H9 written, the Log line carries origin/main''s sha12' $r $p $lines9 $oldName $newName ('; launch main ' + $shaMain9.Substring(0, 12)) 1
$msgs = @($r.Lines | Where-Object { $_ -cmatch '^MESSAGE ' })
Assert-Coord "H9 the MESSAGE says main and carries main's sha12, not develop's" ($r.Code -eq 0 -and $msgs.Count -eq 1 -and $msgs[0] -ceq (Get-MsgLine 'tr9' $sess1 $newName $shaMain9) -and -not $msgs[0].Contains($devSha.Substring(0, 12))) ($msgs -join "`n")
Assert-Coord 'H9 only main is fetched (never develop), and gh is never called' ($r.Code -eq 0 -and $r.Calls -contains ('-C ' + $fx9.Launch + ' fetch --quiet origin main') -and @($r.Calls | Where-Object { $_ -match 'develop' }).Count -eq 0 -and $r.GhCalls.Count -eq 0) ((($r.Calls) -join "`n") + "`ngh: " + (($r.GhCalls) -join "`n"))

# =============================================================================
Write-Host "(H10) input validation, refused before any fetch"
$fxV = New-CoordFixture $root 'fxV'
$null = Step-Origin $fxV
$staleV = Get-LaunchTip $fxV
$oldV = 'Old coordinator'
$linesV = @(Get-HLines (New-CoordLine $oldV) @(New-Row 'tv' $fxV.Launch 'tv-session' 'bv' '' 'running'))
Assert-Coord 'H10 setup: origin has advanced past the launch checkout''s refs/remotes/origin/main' ($staleV -cne (Get-OriginMain $fxV)) "$staleV"
$badNames = @(
    @('LF', "a`nb"), @('CR', "a`rb"), @('tab', "a`tb"), @('trailing LF', "ab`n"), @('leading tab', "`tab"),
    @('NUL', ('a' + [char]0 + 'b')), @('U+0085', ('a' + [char]0x85 + 'b')), @('U+2028', ('a' + [char]0x2028 + 'b')),
    @('backtick', 'a`b'), @('pipe', 'a|b'), @('a double quote', 'Say "hi" now'),
    @('only a zero-width space (U+200B)', [string][char]0x200B), @('only a BOM character (U+FEFF)', [string][char]0xFEFF),
    @('a name ending in a zero-width space', ('Evening' + [char]0x200B)), @('a bidi override (U+202E)', ('a' + [char]0x202E + 'b')),
    @('a lone surrogate (U+D800)', ('a' + [char]0xD800 + 'b')),
    @('an emoji (a surrogate pair, outside the BMP)', ('Night ' + [char]::ConvertFromUtf32(0x1F680))),
    @('a braille blank (U+2800)', ('Evening' + [char]0x2800), 'U\+00AD, U\+2800 or U\+FFFC'), @('an object replacement character (U+FFFC)', ('Evening' + [char]0xFFFC), 'U\+00AD, U\+2800 or U\+FFFC'),
    @('a soft hyphen (U+00AD)', ('Eve' + [char]0xAD + 'ning')), @('a no-break space (U+00A0)', ('Evening' + [char]0xA0 + 'shift')),
    @('81 characters', ('x' * 81)), @('81 characters after the trim', ('  ' + ('x' * 81) + '  ')),
    @('empty', ''), @('blank', '   '),
    @('a <placeholder>', '<name>'),
    @('the text the next handoff cuts at', 'B; before that: x'),
    @('equal to the old name', $oldV), @('equal to the old name, other case and padded', ('  ' + $oldV.ToUpper() + ' '))
)
foreach ($c in $badNames) {
    $p = New-HLedger $linesV
    $b = Get-Bytes $p
    $r = Invoke-Handoff $c[1] $p
    $why10 = ''
    if ($c.Count -gt 2) { $why10 = $c[2] }
    Test-RefusedNoFetch "H10 -NewSession $($c[0])" $r $p $b $fxV $staleV $why10
}
# Accepted (these fetch, so they run after every refusal above).
$shaV = Get-OriginMain $fxV
$tailV = '; launch main ' + $shaV.Substring(0, 12)
$idName = New-Id
$accepted = @(
    @('80 characters', ('y' * 80), ('y' * 80)),
    @('80 characters padded with spaces (trimmed)', ('  ' + ('z' * 80) + '  '), ('z' * 80)),
    @('an id', $idName, $idName),
    @('a name with spaces and non-ASCII', ('Caf' + $eAcute + ' night shift'), ('Caf' + $eAcute + ' night shift')),
    @('an apostrophe, parentheses, a hyphen and a colon', 'Sam''s coord (night-2): v2', 'Sam''s coord (night-2): v2'),
    @('CJK, digits and a combining accent', ([string][char]0x65E5 + [char]0x672C + ' 42 e' + [char]0x0301), ([string][char]0x65E5 + [char]0x672C + ' 42 e' + [char]0x0301))
)
foreach ($c in $accepted) {
    $p = New-HLedger $linesV
    $r = Invoke-Handoff $c[1] $p
    $null = Test-Written "H10 -NewSession $($c[0]) accepted" $r $p $linesV $oldV $c[2] $tailV 1
    $coordLine = @([System.IO.File]::ReadAllText($p) -split "`r?`n" | Where-Object { $_ -match '^Coordinator:' })
    Assert-Coord "H10 -NewSession $($c[0]): the name read back by coord-brief's regex is the written one" ($r.Code -eq 0 -and $coordLine.Count -eq 1 -and $coordLine[0] -match $coordBriefRegex -and $Matches[1] -ceq $c[2]) ($coordLine -join ' // ')
    $m = @($r.Lines | Where-Object { $_ -cmatch '^MESSAGE ' })
    Assert-Coord "H10 -NewSession $($c[0]): the MESSAGE carries the written name" ($r.Code -eq 0 -and $m.Count -eq 1 -and $m[0].Contains('report to "' + $c[2] + '" from now on')) ($m -join "`n")
}

# =============================================================================
Write-Host "(H11) per-track messages, terminal rows, one fetch per repo"
$fxC = New-CoordFixture $root 'fxC'
$null = Step-Origin $fxC
$staleC = Get-LaunchTip $fxC
$shaA11 = Step-Origin $fxA
$shaB11 = Step-Origin $fxB
$rows11 = @(
    (New-Row 't1' $fxA.Launch 'sess-a' 'b1' '#1' 'running'),
    (New-Row 't2' $fxB.Launch '' 'b2' '' 'waiting on review'),
    (New-Row '' $fxA.Launch 'sess-x' 'b3' '' 'NOT MERGED yet'),
    (New-Row 't4' $fxC.Launch 'sess-d' 'b4' '#4' 'MERGED #4')
)
$lines11 = @(Get-HLines (New-CoordLine $oldName) $rows11)
$p = New-HLedger $lines11
$r = Invoke-Handoff $newName $p
$tail11 = '; launch main ' + $shaA11.Substring(0, 12) + ', launch main ' + $shaB11.Substring(0, 12)
$null = Test-Written 'H11 written: three live tracks, the repos in first-seen order with their own sha12' $r $p $lines11 $oldName $newName $tail11 3
$msgs = @($r.Lines | Where-Object { $_ -cmatch '^MESSAGE ' })
$expMsgs = @((Get-MsgLine 't1' 'sess-a' $newName $shaA11), (Get-MsgLine 't2' 'no session' $newName $shaB11), (Get-MsgLine 'b3' 'sess-x' $newName $shaA11))
Assert-Coord "H11 three MESSAGE lines in table order, each with its own repo's sha12 ('no session' for an empty Session, the Branch for an empty Track)" ($r.Code -eq 0 -and ($msgs -join "`n") -ceq ($expMsgs -join "`n")) ($msgs -join "`n")
Assert-Coord 'H11 the terminal row (MERGED) gets no MESSAGE' ($r.Code -eq 0 -and @($r.Lines | Where-Object { $_ -cmatch '^MESSAGE t4 ' }).Count -eq 0) $r.Out
$f11 = @(Get-Fetches $r)
Assert-Coord 'H11 two fetches only: one per distinct live repo (two rows share fxA), each `git -C <repo> fetch --quiet origin main`' ($r.Code -eq 0 -and $f11.Count -eq 2 -and $f11 -contains ('-C ' + $fxA.Launch + ' fetch --quiet origin main') -and $f11 -contains ('-C ' + $fxB.Launch + ' fetch --quiet origin main')) ($f11 -join "`n")
Assert-Coord "H11 the terminal row's repo is not fetched" ($r.Code -eq 0 -and @($f11 | Where-Object { $_.Contains($fxC.Launch) }).Count -eq 0 -and (Get-LaunchTip $fxC) -ceq $staleC) "tip=$(Get-LaunchTip $fxC) stale=$staleC"
Assert-Coord "H11 each live repo's refs/remotes/origin/main is its origin's main" ($r.Code -eq 0 -and (Get-LaunchTip $fxA) -ceq $shaA11 -and (Get-LaunchTip $fxB) -ceq $shaB11) "$(Get-LaunchTip $fxA) $(Get-LaunchTip $fxB)"

# =============================================================================
Write-Host "(H12) four handoffs A -> B -> C -> D: the line keeps three levels, the Log keeps all"
$names12 = @('First coordinator', 'Second coordinator', 'Third coordinator', 'Fourth coordinator')
$p = New-HLedger @(Get-HLines (New-CoordLine $names12[0]) @())
$codes12 = @()
for ($k = 1; $k -le 3; $k++) {
    $r = Invoke-Handoff $names12[$k] $p
    $codes12 += $r.Code
}
Assert-Coord 'H12 setup: the three handoffs were all written' (($codes12 -join ',') -ceq '0,0,0') ($codes12 -join ',')
$t12 = @([System.IO.File]::ReadAllText($p) -split "`r?`n")
$c12 = @($t12 | Where-Object { $_ -match '^Coordinator:' })
$exp12 = '^Coordinator: session "Fourth coordinator", took over \d\d:\d\d from "Third coordinator"; before that: session "Third coordinator", took over \d\d:\d\d from "Second coordinator"$'
Assert-Coord 'H12 the one Coordinator line names D, then C, and after "before that" B only (the earlier tail is dropped)' ($c12.Count -eq 1 -and $c12[0] -cmatch $exp12) ($c12 -join ' // ')
Assert-Coord 'H12 ... A (its name and cwd text) is no longer on the line' ($c12.Count -eq 1 -and -not $c12[0].Contains($names12[0]) -and -not $c12[0].Contains('cwd')) ($c12 -join ' // ')
$h12 = @($t12 | Where-Object { $_ -match ' HANDOFF: ' })
Assert-Coord 'H12 the Log keeps one HANDOFF line per handoff, naming A, B and C as the coordinators handed over from' ($h12.Count -eq 3 -and $h12[0].Contains('took over from "' + $names12[0] + '"') -and $h12[1].Contains('took over from "' + $names12[1] + '"') -and $h12[2].Contains('took over from "' + $names12[2] + '"')) ($h12 -join "`n")
Assert-Coord "H12 coord-brief's regex reads D from the line" ($c12.Count -eq 1 -and $c12[0] -match $coordBriefRegex -and $Matches[1] -ceq $names12[3]) ($c12 -join ' // ')

# =============================================================================
Write-Host "(H13) header and section problems, bad live rows: refused, nothing written, no fetch"
$fxR = New-CoordFixture $root 'fxR'
$null = Step-Origin $fxR
$staleR = Get-LaunchTip $fxR
$liveR = New-Row 'tr' $fxR.Launch 'sess-r' 'br' '' 'running'
$okLines = @(Get-HLines (New-CoordLine 'Old coordinator') @($liveR))

$noHeader = @(Get-HLines 'Note: there is no coordinator header here.' @($liveR))
$p = New-HLedger $noHeader
$b = Get-Bytes $p
$r = Invoke-Handoff $newName $p
Test-RefusedNoFetch 'H13 no Coordinator line' $r $p $b $fxR $staleR "found 0 'Coordinator:' lines"

$dup = New-Object System.Collections.Generic.List[string]
foreach ($l in $okLines) { $dup.Add($l) }
$dup.Insert(3, (New-CoordLine 'Another'))
$p = New-HLedger ($dup.ToArray())
$b = Get-Bytes $p
$r = Invoke-Handoff $newName $p
Test-RefusedNoFetch 'H13 two Coordinator lines' $r $p $b $fxR $staleR "found 2 'Coordinator:' lines"

$badCoord = @(
    @('no quoted name', 'Coordinator: session Evening, cwd `/x`.'),
    @('an empty name', 'Coordinator: session "", cwd `/x`.'),
    @('no session word', 'Coordinator: the user''s session'),
    @('a blank name', 'Coordinator: session "  ", cwd `/x`.', 'names no coordinator session'),
    @('a <placeholder> name', 'Coordinator: session "<name>", cwd `/x`.', 'names no coordinator session'),
    @('a name holding the cut text', 'Coordinator: session "x; before that: y", cwd `/x`.', 'the handoff cuts the line at')
)
foreach ($c in $badCoord) {
    $p = New-HLedger @(Get-HLines $c[1] @($liveR))
    $b = Get-Bytes $p
    $r = Invoke-Handoff $newName $p
    $why13 = 'does not start with session'
    if ($c.Count -gt 2) { $why13 = $c[2] }
    Test-RefusedNoFetch "H13 Coordinator line with $($c[0])" $r $p $b $fxR $staleR $why13
}

# A padded old name is compared trimmed: -NewSession Old is the same session.
$p = New-HLedger @(Get-HLines 'Coordinator: session " Old ", cwd `/x`.' @($liveR))
$b = Get-Bytes $p
$r = Invoke-Handoff 'Old' $p
Test-RefusedNoFetch 'H13 -NewSession equal to a padded old name' $r $p $b $fxR $staleR 'already the coordinator'

# The coordinator named by an id is the same session however the id is spelled: a note after it,
# the short local_<8 hex> form against the full id, and an upper-case local_ prefix.
$idC = New-Id
$coordIdCases = @(
    @('the id and a note, the ledger holding the bare id', $idC, ($idC + ' (opus)')),
    @('the short id and a note, the ledger holding the full id', $idC, ($idC.Substring(0, 14) + ' (opus)')),
    @('the full id, the ledger holding the short id and a note', ($idC.Substring(0, 14) + ' (port work)'), $idC),
    @('an upper-case local_ prefix, the ledger holding the short id', $idC.Substring(0, 14), ('LOCAL_' + $idC.Substring(6, 8))),
    @('the full id, the ledger holding an upper-case local_ prefix, the short id and a note', ('LOCAL_' + $idC.Substring(6, 8) + ' (opus)'), $idC),
    @('an upper-case local_ prefix and a note, the ledger holding the id and a note', ($idC + ' (port work)'), ('LOCAL_' + $idC.Substring(6, 8) + ' (opus)'))
)
foreach ($c in $coordIdCases) {
    $p = New-HLedger @(Get-HLines ('Coordinator: session "' + $c[1] + '", cwd `/x`.') @($liveR))
    $b = Get-Bytes $p
    $r = Invoke-Handoff $c[2] $p
    Test-RefusedNoFetch "H13 -NewSession is the coordinator: $($c[0])" $r $p $b $fxR $staleR 'already the coordinator'
}

$noLog = @($okLines | ForEach-Object { if ($_ -ceq '## Log') { '## Journal' } else { $_ } })
$p = New-HLedger $noLog
$b = Get-Bytes $p
$r = Invoke-Handoff $newName $p
Test-RefusedNoFetch 'H13 no ## Log section' $r $p $b $fxR $staleR

$twoLog = @($okLines + @('', '## Log', '', '10:59 a second Log section'))
$p = New-HLedger $twoLog
$b = Get-Bytes $p
$r = Invoke-Handoff $newName $p
Test-RefusedNoFetch 'H13 two ## Log sections' $r $p $b $fxR $staleR

$badRepos = @(
    @('a bare folder name', 'bare13', 'some-repo'),
    @('a directory that does not exist', 'gone13', (Join-Path $root 'no\such\dir13')),
    @('a path holding parentheses', 'paren13', (Join-Path $root 'My (stuff)')),
    @('a plain folder inside another repo', 'inner13', (Join-Path $fxR.Launch 'notarepo13'), 'is not the top level of a git working tree'),
    @('a bare repository', 'bare13r', (Join-Path $root 'bare13.git'), 'is not the top level of a git working tree'),
    @('a folder in no repository', 'norepo13r', (Join-Path $root 'norepo13'), 'git could not read Repo'),
    @('the .git folder of a repo', 'dotgit13', (Join-Path $fxR.Launch '.git'), 'is not the top level of a git working tree')
)
$bare13 = Join-Path $root 'bare13.git'
Invoke-HookTestGit $root @('init', '--bare', '--quiet', $bare13)
[void][IO.Directory]::CreateDirectory((Join-Path $root 'My (stuff)'))
[void][IO.Directory]::CreateDirectory((Join-Path $root 'norepo13'))
[void][IO.Directory]::CreateDirectory((Join-Path $fxR.Launch 'notarepo13'))
# git must not walk up from the folder in no repository to one above the temp folder.
$prevCeil13 = $env:GIT_CEILING_DIRECTORIES
$env:GIT_CEILING_DIRECTORIES = $root
try {
    foreach ($c in $badRepos) {
        $p = New-HLedger @(Get-HLines (New-CoordLine 'Old coordinator') @($liveR, (New-Row $c[1] $c[2] 'sess-b' 'bb' '' 'running')))
        $b = Get-Bytes $p
        $r = Invoke-Handoff $newName $p
        $why13r = $c[1]
        if ($c.Count -gt 3) { $why13r = $c[3] }
        Test-RefusedNoFetch "H13 a live row whose Repo is $($c[0]) (the valid row's repo is not fetched either)" $r $p $b $fxR $staleR $why13r
    }
} finally { $env:GIT_CEILING_DIRECTORIES = $prevCeil13 }

# =============================================================================
Write-Host "(H14) no time parameter, no leftover words"
$p = New-HLedger $okLines
$b = Get-Bytes $p
$x = Invoke-HandoffFile ("-NewSession Nextname -Ledger `"" + $p + "`" -Time 07:00")
Test-RefusedNoFetch 'H14 -Time 07:00 through -File' $x $p $b $fxR $staleR
$x = Invoke-HandoffFile ("-NewSession Nextname -Ledger `"" + $p + "`" extra")
Test-RefusedNoFetch 'H14 a leftover word through -File' $x $p $b $fxR $staleR
$r = Invoke-Handoff 'Nextname' $p -Tail @('extra')
Test-RefusedNoFetch 'H14 a leftover word in process' $r $p $b $fxR $staleR

# =============================================================================
Write-Host "(H15) no live rows"
$empty15 = @(Get-HLines (New-CoordLine $oldName) @())
$p = New-HLedger $empty15
$r = Invoke-Handoff $newName $p
$null = Test-Written 'H15 an empty Tracks table: written, "live tracks: 0" with no repo part' $r $p $empty15 $oldName $newName '' 0
Assert-Coord 'H15 ... no fetch ran and no MESSAGE line was printed' ($r.Code -eq 0 -and @(Get-Fetches $r).Count -eq 0 -and @($r.Lines | Where-Object { $_ -cmatch '^MESSAGE ' }).Count -eq 0) ((($r.Calls) -join "`n") + "`n" + $r.Out)
$c15 = @($r.Lines | Where-Object { $_ -cmatch '^CHECKLIST:' })
Assert-Coord 'H15 ... six CHECKLIST lines and the done line are still printed' ($r.Code -eq 0 -and $c15.Count -eq 6 -and $r.Lines[$r.Lines.Count - 1] -ceq 'COORD-HANDOFF: done; nothing sent (the coordinator sends each MESSAGE line)') $r.Out

$terminal15 = @(
    (New-Row 'm1' 'gone-repo-15' 'sess-m' 'bm' '#1' 'MERGED #1'),
    (New-Row 'd1' $fxR.Launch 'sess-d' 'bd' '' 'DONE; archived')
)
$lines15 = @(Get-HLines (New-CoordLine $oldName) $terminal15)
$p = New-HLedger $lines15
$r = Invoke-Handoff $newName $p
$null = Test-Written 'H15 only terminal rows (one with a bogus Repo): written, "live tracks: 0"' $r $p $lines15 $oldName $newName '' 0
Assert-Coord 'H15 ... no fetch ran and no MESSAGE line was printed' ($r.Code -eq 0 -and @(Get-Fetches $r).Count -eq 0 -and @($r.Lines | Where-Object { $_ -cmatch '^MESSAGE ' }).Count -eq 0 -and (Get-LaunchTip $fxR) -ceq $staleR) $r.Out

# =============================================================================
Write-Host "(H16) without -Ledger"
$cRepo = New-CoordCanonRepo $root 'h16repo' -Commit
$today = Get-CoordToday
$lines16 = @(Get-HLines (New-CoordLine $oldName) @())
$cLedger = New-CoordCanonLedger $cRepo $today -Text ((($lines16) -join "`n") + "`n")
$script:hLedgers.Add($cLedger)
$wt16 = Join-Path $root 'h16-wt'
New-HookTestWorktree -Repo $cRepo -Path $wt16 -Branch 'h16wt'
$null = New-CoordScratchIndex $root
$idx16 = Get-CoordIndexPath
$b = Get-Bytes $cLedger
$r = Invoke-Handoff $newName -Cwd $wt16
Test-Refused "H16 from a linked worktree (it would reach the main checkout's live ledger)" $r $cLedger $b "is not the repo's main checkout; pass -Ledger"

$outside = Join-Path $root 'outside16'
[void][IO.Directory]::CreateDirectory($outside)
$prevCeil = $env:GIT_CEILING_DIRECTORIES
$env:GIT_CEILING_DIRECTORIES = $root
try { $r = Invoke-Handoff $newName -Cwd $outside } finally { $env:GIT_CEILING_DIRECTORIES = $prevCeil }
Test-Refused 'H16 outside any git repository' $r $cLedger $b 'not in a git repository; pass -Ledger'

$r = Invoke-Handoff $newName -Cwd $cRepo
$null = Test-Written "H16 from the main checkout: today's ledger there is written" $r $cLedger $lines16 $oldName $newName '' 0
Assert-Coord 'H16 ... and the handoff never registers a ledger in the index (the scratch index file does not exist)' ($r.Code -eq 0 -and -not (Test-Path -LiteralPath $idx16)) $idx16

# =============================================================================
Write-Host "(H19) a live row's Repo must be a full path; git runs on the full path"
$fxP = New-CoordFixture $root 'fxP'
$shaP = Step-Origin $fxP
$staleP = Get-LaunchTip $fxP
$drvP = $fxP.Base.Substring(0, 2)
# [Environment]::CurrentDirectory is what GetFullPath resolves a relative cell against
# (Push-Location does not move it), so it is set to the folder each cell is relative to.
$relCells = @(
    @('r1dot', '.\launch', $fxP.Base),
    @('r1dotdot', '..\launch', $fxP.Work),
    @('r1drive', ($drvP + 'launch'), $fxP.Base)
)
$prevCwd = [Environment]::CurrentDirectory
foreach ($c in $relCells) {
    $p = New-HLedger @(Get-HLines (New-CoordLine $oldName) @(New-Row $c[0] $c[1] 'sess-p' 'br' '' 'running'))
    $b = Get-Bytes $p
    $resolved = ''
    try {
        [Environment]::CurrentDirectory = $c[2]
        $resolved = ConvertTo-CoordFullPath $c[1]
        $r = Invoke-Handoff $newName $p
    }
    finally { [Environment]::CurrentDirectory = $prevCwd }
    Assert-Coord "H19 setup: '$($c[1])' resolves from its folder to the real launch repo (so only the full-path rule can refuse it)" ($resolved -ceq $fxP.Launch) "resolved=$resolved launch=$($fxP.Launch)"
    Test-RefusedNoFetch "H19 Repo '$($c[1])' (not rooted)" $r $p $b $fxP $staleP ("row $($c[0]): Repo '" + [regex]::Escape($c[1]) + "' is not a full path")
}
$fwdCell = $fxP.Launch.Replace('\', '/') + '/'
$twinCell = $fxP.Launch.ToUpper() + '\'
$linesP = @(Get-HLines (New-CoordLine $oldName) @((New-Row 'r1fwd' $fwdCell 'sp1' 'b1' '' 'running'), (New-Row 'r1twin' $twinCell 'sp2' 'b2' '' 'running')))
$p = New-HLedger $linesP
$r = Invoke-Handoff $newName $p
$null = Test-Written 'H19 rooted spellings (forward slashes with a trailing /, and an upper-case twin with a trailing \) are accepted: one repo, the Log line names it once' $r $p $linesP $oldName $newName ('; launch main ' + $shaP.Substring(0, 12)) 2
$fP = @(Get-Fetches $r)
Assert-Coord 'H19 ... one fetch for the two spellings, and git ran on the full path, not on a cell as written' ($r.Code -eq 0 -and $fP.Count -eq 1 -and $fP[0] -ceq ('-C ' + $fxP.Launch + ' fetch --quiet origin main') -and @($r.Calls | Where-Object { $_.Contains($fwdCell) -or $_.Contains($twinCell) }).Count -eq 0) (($r.Calls) -join "`n")
$mP = @($r.Lines | Where-Object { $_ -cmatch '^MESSAGE ' })
Assert-Coord "H19 ... both MESSAGE lines name the repo by the full path's leaf (launch), each with the fetched sha12" ($r.Code -eq 0 -and ($mP -join "`n") -ceq ((Get-MsgLine 'r1fwd' 'sp1' $newName $shaP) + "`n" + (Get-MsgLine 'r1twin' 'sp2' $newName $shaP))) ($mP -join "`n")

# A Repo cell spelled through a junction is the same working tree: accepted, fetched under that spelling.
$juncP = Join-Path $root 'h19junc'
if (New-CoordJunction $juncP $fxP.Launch) {
    $shaP2 = Step-Origin $fxP
    $linesJ = @(Get-HLines (New-CoordLine $oldName) @(New-Row 'r1junc' $juncP 'spj' 'b1' '' 'running'))
    $p = New-HLedger $linesJ
    $r = Invoke-Handoff $newName $p
    $null = Test-Written 'H19 a Repo cell that is a junction to a repo is accepted (git prints the target path; the check is by property, not by spelling), the leaf is the cell''s own' $r $p $linesJ $oldName $newName ('; h19junc main ' + $shaP2.Substring(0, 12)) 1
    Remove-CoordJunction $juncP
}
else { Write-CoordUnchecked 'H19 junction Repo cell (the machine refused to create a junction)' }

# =============================================================================
Write-Host "(H20) an unreadable Tracks section is refused before any fetch"
$fxQ = New-CoordFixture $root 'fxQ'
$null = Step-Origin $fxQ
$staleQ = Get-LaunchTip $fxQ
$baseQ = @(Get-HLines (New-CoordLine $oldName) @((New-Row 'r2live' $fxQ.Launch 'sq' 'bq' '' 'running')))
$tHead = '| Track | Repo | Session | Model | Cwd | Branch | Scope | PR | Status |'
$tSep = '|-------|------|---------|-------|-----|--------|-------|----|--------|'
$otherRow = New-Row 'r2other' $fxQ.Launch 'sq2' 'bq2' '' 'running'
$cases2 = @(
    @('the ## Tracks heading is missing', @($baseQ | Where-Object { $_ -cne '## Tracks' })),
    @('the heading is misspelled (## Track)', @($baseQ | ForEach-Object { if ($_ -ceq '## Tracks') { '## Track' } else { $_ } })),
    @('the heading appears twice', @($baseQ + @('', '## Tracks', '', $tHead, $tSep, $otherRow))),
    @('the heading appears twice, the second in capitals', @($baseQ + @('', '## TRACKS', '', $tHead, $tSep, $otherRow))),
    # The two no-table cases pin their own reason: without the explicit check the row parser still refuses
    # ('no Repo column'), so only the reason tells the check is there.
    @('the section holds prose and no table', (Set-TracksBody $baseQ @('', 'Tracks are kept in the other file.', '')), 'holds no table'),
    @('the section is empty', (Set-TracksBody $baseQ @('')), 'holds no table')
)
foreach ($c in $cases2) {
    $p = New-HLedger ([string[]]$c[1])
    $b = Get-Bytes $p
    $r = Invoke-Handoff $newName $p
    $why = 'Tracks'
    if ($c.Count -gt 2) { $why = $c[2] }
    Test-RefusedNoFetch "H20 $($c[0])" $r $p $b $fxQ $staleQ $why
}
$caps2 = @(Get-HLines (New-CoordLine $oldName) @() | ForEach-Object { if ($_ -ceq '## Tracks') { '## TRACKS' } else { $_ } })
$p = New-HLedger $caps2
$r = Invoke-Handoff $newName $p
$null = Test-Written 'H20 an upper-case ## TRACKS heading with a header-only table is accepted (the heading is matched without regard to case)' $r $p $caps2 $oldName $newName '' 0

# =============================================================================
Write-Host "(H21) -NewSession is a track's session (a name or an id)"
$idS = New-Id
$upperTok = 'local_' + $idS.Substring(6).ToUpper()
$cases3 = @(
    @('a live row, by name', 'r3live', 'Review lane', 'Review lane', 'running'),
    @('a terminal row (MERGED), by name', 'r3done', 'Review lane', 'Review lane', 'MERGED #3'),
    @('a Session cell in backticks', 'r3tick', 'Review lane', '`Review lane`', 'running'),
    @('a Session cell in other case', 'r3case', 'review LANE', 'Review lane', 'running'),
    @('a Session cell in double quotes', 'r3dq', 'Review lane', '"Review lane"', 'running'),
    @('a Session cell holding the id and a note', 'r3note', $idS, ($idS.Substring(0, 14) + ' (port work, sonnet)'), 'running'),
    @('a live row, by id', 'r3id', $idS, $idS, 'running'),
    @('a Session cell with the id in upper-case hex', 'r3upper', $idS, $upperTok, 'running'),
    @('a Session cell holding only the short token (local_ plus the first 8 hex)', 'r3short', $idS, $idS.Substring(0, 14), 'running'),
    @('a -NewSession of the id and a note, the cell holding the bare id', 'r3newnote', ($idS + ' (opus)'), $idS, 'running'),
    @('a -NewSession of the short id and a note, the cell holding the full id', 'r3newshort', ($idS.Substring(0, 14) + ' (opus)'), $idS, 'running'),
    @('a -NewSession whose local_ prefix is in upper case, the cell holding the short id', 'r3newucp', ('LOCAL_' + $idS.Substring(6)), $idS.Substring(0, 14), 'running'),
    @('a -NewSession of an upper-case prefix and a note, the cell holding the id and a note', 'r3newucn', ('LOCAL_' + $idS.Substring(6, 8) + ' (opus)'), ($idS.Substring(0, 14) + ' (port work)'), 'running')
)
foreach ($c in $cases3) {
    $rows3 = @((New-Row 'r3other' $root 'someone else' 'bo' '' 'running'), (New-Row $c[1] $root $c[3] 'bs' '' $c[4]))
    $p = New-HLedger @(Get-HLines (New-CoordLine $oldName) $rows3)
    $b = Get-Bytes $p
    $r = Invoke-Handoff $c[2] $p
    Test-Refused "H21 -NewSession named by $($c[0])" $r $p $b ([regex]::Escape("is a track's session (row $($c[1])), not a new coordinator"))
}

# =============================================================================
Write-Host "(H22) a stale copy of today's ledger is refused"
$today22 = Get-CoordToday
$repo22 = New-CoordCanonRepo $root 'h22repo' -Commit
$wt22 = Join-Path $repo22 '.claude\worktrees\x'
New-HookTestWorktree -Repo $repo22 -Path $wt22 -Branch 'h22wt'
$null = New-CoordScratchIndex $root
$lines22 = @(Get-HLines (New-CoordLine $oldName) @())
$text22 = (($lines22) -join "`n") + "`n"
$stale22 = Join-Path $wt22 ('.claude\coordination\' + $today22 + '.md')
Set-CoordTextFile $stale22 $text22
$script:hLedgers.Add($stale22)
$canon22 = Get-CoordLedgerPath $repo22 $today22
$b = Get-Bytes $stale22
$r = Invoke-Handoff $newName $stale22
Test-Refused "H22 today's ledger in a linked worktree of the repo (a stale copy) is refused, naming the canonical path" $r $stale22 $b ([regex]::Escape($canon22))
Assert-Coord 'H22 ... and the canonical ledger was not created by the refusal' ($r.Code -eq 2 -and -not (Test-Path -LiteralPath $canon22)) $canon22

$norepo22 = Join-Path $root 'h22norepo'
$und22 = Join-Path $norepo22 ('.claude\coordination\' + $today22 + '.md')
Set-CoordTextFile $und22 $text22
$script:hLedgers.Add($und22)
$b = Get-Bytes $und22
$prevCeil = $env:GIT_CEILING_DIRECTORIES
$env:GIT_CEILING_DIRECTORIES = $root
try { $r = Invoke-Handoff $newName $und22 } finally { $env:GIT_CEILING_DIRECTORIES = $prevCeil }
Test-Refused 'H22 a ledger shaped like today''s canonical one in a folder outside any repo is refused: cannot tell' $r $und22 $b 'cannot tell whether .* is canonical'

$can22 = New-CoordCanonLedger $repo22 $today22 -Text $text22
$script:hLedgers.Add($can22)
$null = New-CoordScratchIndex $root
$idx22 = Get-CoordIndexPath
$r = Invoke-Handoff $newName $can22
$null = Test-Written 'H22 the main checkout''s canonical ledger is accepted and written' $r $can22 $lines22 $oldName $newName '' 0
Assert-Coord 'H22 ... and it is not registered in the index (the scratch index file does not exist)' ($r.Code -eq 0 -and -not (Test-Path -LiteralPath $idx22)) $idx22

# =============================================================================
Write-Host "(H25) GIT_TERMINAL_PROMPT is 0 for the fetch and restored after"
$fxG = New-CoordFixture $root 'fxG'
$shaG = Step-Origin $fxG
$linesG = @(Get-HLines (New-CoordLine $oldName) @((New-Row 'r9' $fxG.Launch 'sg' 'bg' '' 'running')))
$prevPrompt = [Environment]::GetEnvironmentVariable('GIT_TERMINAL_PROMPT')
$hookG = { param($l) if ($l -cmatch ' fetch ') { $global:hPrompt = [pscustomobject]@{ Val = [Environment]::GetEnvironmentVariable('GIT_TERMINAL_PROMPT') } }; return $null }
try {
    [Environment]::SetEnvironmentVariable('GIT_TERMINAL_PROMPT', $null)
    $global:hPrompt = $null
    $p = New-HLedger $linesG
    $r = Invoke-Handoff $newName $p -GitHook $hookG
    $during = if ($global:hPrompt) { $global:hPrompt.Val } else { '<fetch not seen>' }
    $after = [Environment]::GetEnvironmentVariable('GIT_TERMINAL_PROMPT')
    $null = Test-Written 'H25 variable unset beforehand: the fetch ran and the ledger was written' $r $p $linesG $oldName $newName ('; launch main ' + $shaG.Substring(0, 12)) 1
    Assert-Coord 'H25 ... GIT_TERMINAL_PROMPT was 0 during the fetch' ($during -ceq '0') "during=$during"
    Assert-Coord 'H25 ... and is unset again afterwards' ($null -eq $after) "after=$after"

    [Environment]::SetEnvironmentVariable('GIT_TERMINAL_PROMPT', '1')
    $global:hPrompt = $null
    $hookFail = { param($l) if ($l -cmatch ' fetch ') { $global:hPrompt = [pscustomobject]@{ Val = [Environment]::GetEnvironmentVariable('GIT_TERMINAL_PROMPT') }; return @{ Handled = $true; Code = 1; Out = @() } }; return $null }
    $p = New-HLedger $linesG
    $b = Get-Bytes $p
    $r = Invoke-Handoff $newName $p -GitHook $hookFail
    $during = if ($global:hPrompt) { $global:hPrompt.Val } else { '<fetch not seen>' }
    $after = [Environment]::GetEnvironmentVariable('GIT_TERMINAL_PROMPT')
    Test-Refused 'H25 variable set to 1 beforehand, the fetch fails' $r $p $b 'fetch'
    Assert-Coord 'H25 ... GIT_TERMINAL_PROMPT was 0 during the failed fetch' ($during -ceq '0') "during=$during"
    Assert-Coord 'H25 ... and is 1 again after the refusal' ($after -ceq '1') "after=$after"
}
finally {
    [Environment]::SetEnvironmentVariable('GIT_TERMINAL_PROMPT', $prevPrompt)
    $global:hPrompt = $null
}

# =============================================================================
Write-Host "(H26) the ledger is deleted during the swap retry"
# The first File.Replace fails on a handle that shares no delete right, and the
# retry's Start-Sleep closes the handle and deletes the ledger.
$p = New-HLedger $plain
$global:h26Ledger = $p
$global:h26Handle = [System.IO.File]::Open($p, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
function global:Start-Sleep {
    if ($global:h26Handle) { $global:h26Handle.Dispose(); $global:h26Handle = $null; [System.IO.File]::Delete($global:h26Ledger) }
    Microsoft.PowerShell.Utility\Start-Sleep @args
}
try { $r = Invoke-Handoff $newName $p }
finally {
    Remove-Item -LiteralPath 'Function:\Start-Sleep' -Force -ErrorAction SilentlyContinue
    if ($global:h26Handle) { $global:h26Handle.Dispose(); $global:h26Handle = $null }
}
$tmps26 = @(Get-ChildItem -LiteralPath (Split-Path -Parent $p) -Force -Filter '*.coord-log-*.tmp')
$tmpOk = $false
if ($tmps26.Count -eq 1) {
    $tmpText = [System.IO.File]::ReadAllText($tmps26[0].FullName)
    foreach ($s in (Get-Stamps $r)) { if ($tmpText -ceq (Get-ExpectedText $plain 'Old coordinator' $newName $s 0 '' "`n")) { $tmpOk = $true } }
}
Assert-Coord 'H26 refused (exit 2, one NOT WRITTEN line, no MESSAGE/CHECKLIST line), saying the ledger is gone' ((Test-RefusalShape $r) -and $r.Out -match ' is gone ') "code=$($r.Code) out=$($r.Out)"
Assert-Coord 'H26 the ledger is not recreated' ($r.Code -eq 2 -and -not (Test-Path -LiteralPath $p)) $p
Assert-Coord 'H26 one temp file is kept, named in the message with "the new Coordinator line and the HANDOFF Log line"' ($r.Code -eq 2 -and $tmps26.Count -eq 1 -and $r.Out.Contains($tmps26[0].FullName) -and $r.Out.Contains('the new Coordinator line and the HANDOFF Log line')) "tmps=$($tmps26.Count) out=$($r.Out)"
Assert-Coord 'H26 the kept temp file holds the old ledger with both changes' ($r.Code -eq 2 -and $tmpOk) "tmps=$($tmps26.Count)"
foreach ($t in $tmps26) { Remove-Item -LiteralPath $t.FullName -Force }
Assert-Coord 'H26 once the kept temp file is removed nothing else is left beside the ledger (the lock was released)' ($r.Code -eq 2 -and @(Get-Stray $p).Count -eq 0) ((Get-Stray $p | ForEach-Object { $_.Name }) -join ',')

# =============================================================================
Write-Host "(H30) the snapshot is read under the coord-log lock, which waits up to 5 s"
# The lock is held from a background runspace (a second thread; the handoff runs in this
# one) with the script's own lock options, so releasing it also removes the lock file.
function Stop-LockHolder($H) {
    if (-not $H) { return }
    $H.Release.Set()
    try { if ($H.Async) { [void]$H.Ps.EndInvoke($H.Async) } } catch { }
    $H.Ps.Dispose()
    $H.Rs.Dispose()
}
function Start-LockHolder([string]$LockPath, [int]$HoldMs) {
    $h = [pscustomobject]@{ Ready = (New-Object System.Threading.ManualResetEventSlim($false)); Release = (New-Object System.Threading.ManualResetEventSlim($false)); Rs = $null; Ps = $null; Async = $null }
    $h.Rs = [runspacefactory]::CreateRunspace()
    $h.Rs.Open()
    $h.Ps = [powershell]::Create()
    $h.Ps.Runspace = $h.Rs
    [void]$h.Ps.AddScript({
        param($lp, $ready, $release, $ms)
        $fs = [System.IO.FileStream]::new($lp, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None, 1, [System.IO.FileOptions]::DeleteOnClose)
        try { $ready.Set(); [void]$release.Wait($ms) } finally { $fs.Dispose() }
    }).AddArgument($LockPath).AddArgument($h.Ready).AddArgument($h.Release).AddArgument($HoldMs)
    $h.Async = $h.Ps.BeginInvoke()
    if (-not $h.Ready.Wait(15000)) { Stop-LockHolder $h; throw "the lock holder never took $LockPath" }
    return $h
}

$p = New-HLedger $plain
$holder = $null
$sw = [System.Diagnostics.Stopwatch]::new()
try {
    $holder = Start-LockHolder ($p + '.coord-log.lock') 1500
    $sw.Start()
    $r = Invoke-Handoff $newName $p
    $sw.Stop()
}
finally { Stop-LockHolder $holder }
$null = Test-Written 'H30 the lock held by another thread for ~1.5 s: the handoff waited and then wrote the ledger (exit 0)' $r $p $plain 'Old coordinator' $newName
Assert-Coord 'H30 ... it really waited for the holder (the run took at least 0.5 s with nothing but the lock to wait for)' ($r.Code -eq 0 -and $sw.ElapsedMilliseconds -ge 500) "ms=$($sw.ElapsedMilliseconds) out=$($r.Out)"
Assert-Coord 'H30 ... and no lock or temp file is left beside the ledger' (@(Get-Stray $p).Count -eq 0) ((Get-Stray $p | ForEach-Object { $_.Name }) -join ',')

$p = New-HLedger $plain
$b = Get-Bytes $p
$holder = $null
$sw = [System.Diagnostics.Stopwatch]::new()
try {
    $holder = Start-LockHolder ($p + '.coord-log.lock') 60000
    $sw.Start()
    $r = Invoke-Handoff $newName $p
    $sw.Stop()
}
finally { Stop-LockHolder $holder }
Assert-Coord 'H30 the lock held past the wait: the handoff gave up only after about 5 s (at least 4 s)' ($r.Code -eq 2 -and $sw.ElapsedMilliseconds -ge 4000) "ms=$($sw.ElapsedMilliseconds) code=$($r.Code)"
Test-Refused 'H30 the lock held past 5 s' $r $p $b 'cannot take .*coord-log\.lock within 5 s'

# The snapshot read itself must be under the lock (the later write lock waits the same way,
# so the cases above cannot tell the two apart). The holder takes the lock, renames the
# ledger away (as a coord-log.ps1 swap briefly leaves no file at the ledger's name), and
# after ~1 s moves it back and then releases the lock. A handoff started meanwhile that
# read the snapshot without the lock would find no ledger and refuse.
function Start-SwapHolder([string]$LedgerPath) {
    $h = [pscustomobject]@{ Ready = (New-Object System.Threading.ManualResetEventSlim($false)); Release = (New-Object System.Threading.ManualResetEventSlim($false)); Rs = $null; Ps = $null; Async = $null }
    $h.Rs = [runspacefactory]::CreateRunspace()
    $h.Rs.Open()
    $h.Ps = [powershell]::Create()
    $h.Ps.Runspace = $h.Rs
    [void]$h.Ps.AddScript({
        param($lp, $ready, $release)
        $side = $lp + '.side'
        $fs = [System.IO.FileStream]::new(($lp + '.coord-log.lock'), [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None, 1, [System.IO.FileOptions]::DeleteOnClose)
        try {
            [System.IO.File]::Move($lp, $side)
            $ready.Set()
            [void]$release.Wait(1000)
            [System.IO.File]::Move($side, $lp)
        }
        finally { $fs.Dispose() }
    }).AddArgument($LedgerPath).AddArgument($h.Ready).AddArgument($h.Release)
    $h.Async = $h.Ps.BeginInvoke()
    if (-not $h.Ready.Wait(15000)) { Stop-LockHolder $h; throw "the swap holder never took the lock on $LedgerPath" }
    return $h
}

$p = New-HLedger $plain
$holder = $null
try {
    $holder = Start-SwapHolder $p
    $r = Invoke-Handoff $newName $p
}
finally { Stop-LockHolder $holder }
$null = Test-Written 'H30 the ledger moved away while the lock is held and back before it is released: the handoff read the snapshot under the lock, waited, and wrote the restored ledger (exit 0)' $r $p $plain 'Old coordinator' $newName
Assert-Coord 'H30 ... and neither the moved-aside ledger nor a lock or temp file is left beside the ledger' (@(Get-Stray $p).Count -eq 0) ((Get-Stray $p | ForEach-Object { $_.Name }) -join ',')
Remove-Item -Path 'Function:\Start-LockHolder', 'Function:\Start-SwapHolder', 'Function:\Stop-LockHolder' -Force -ErrorAction SilentlyContinue

# =============================================================================
Write-Host "(H31) bytes that are not UTF-8 written during the fetch are a change, not a decode error"
$lines31 = @(Get-HLines (New-CoordLine $oldName) @((New-Row 'tr31' $fxA.Launch $sess1 'br31' '' 'running')))
$p = New-HLedger $lines31
$raw31 = New-Object 'System.Collections.Generic.List[byte]'
$raw31.AddRange([System.IO.File]::ReadAllBytes($p))
$raw31.AddRange([byte[]](0x61, 0xC3, 0x28, 0xFF))
$global:hEditPath = $p
$global:hEditBytes = $raw31.ToArray()
$global:hFired = $false
$hook31 = { param($l) if (-not $global:hFired -and $l -cmatch ' fetch ') { $global:hFired = $true; [System.IO.File]::WriteAllBytes($global:hEditPath, $global:hEditBytes) }; return $null }
$r = Invoke-Handoff $newName $p -GitHook $hook31
Assert-Coord 'H31 setup: the fetch ran and the invalid bytes landed during it' ($r.Code -eq 2 -and $global:hFired -eq $true) "code=$($r.Code) fired=$($global:hFired) out=$($r.Out)"
Test-Refused 'H31 invalid UTF-8 written during the fetch: refused as a change during the fetch (not as a UTF-8 error), the replacement bytes kept' $r $p ([Convert]::ToBase64String($global:hEditBytes)) 'ledger changed during the fetch; rerun'
Assert-Coord 'H31 ... the refusal does not call the file "not valid UTF-8" (that is the decode refusal of an unchanged file)' ($r.Code -eq 2 -and $r.Out -notmatch 'valid UTF-8') $r.Out
Remove-Variable -Name hEditBytes, hEditPath, hFired -Scope Global -ErrorAction SilentlyContinue

# =============================================================================
Write-Host "(H34) the swap is one write"
# A watcher thread samples the ledger while the handoff runs: every sampled
# version must be the original or the final text, never a state holding one of
# the two changes alone.
$p = New-HLedger $lines3
$orig34 = [System.IO.File]::ReadAllText($p)
$global:h34Seen = New-Object 'System.Collections.Concurrent.ConcurrentDictionary[string,bool]'
# The watcher runs in its own runspace; it stops through a file flag.
$watchRs = [runspacefactory]::CreateRunspace(); $watchRs.Open()
$stopFlag = $p + '.stopwatch'
$watch = [powershell]::Create(); $watch.Runspace = $watchRs
[void]$watch.AddScript({
    param($path, $seen, $flag)
    # Opened with Delete sharing so the sampler cannot make the swap's Replace fail.
    while (-not [System.IO.File]::Exists($flag)) {
        try {
            $fs = [System.IO.FileStream]::new($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
            try { $sr = New-Object System.IO.StreamReader($fs, (New-Object System.Text.UTF8Encoding($false))); $t = $sr.ReadToEnd(); [void]$seen.TryAdd($t, $true) } finally { $fs.Dispose() }
        } catch { }
        [System.Threading.Thread]::Sleep(1)
    }
}).AddArgument($p).AddArgument($global:h34Seen).AddArgument($stopFlag)
$wAsync = $watch.BeginInvoke()
try { $r = Invoke-Handoff $newName $p }
finally {
    [System.IO.File]::WriteAllText($stopFlag, 'x')
    try { [void]$watch.EndInvoke($wAsync) } catch { }
    $watch.Dispose(); $watchRs.Dispose()
    Remove-Item -LiteralPath $stopFlag -Force -ErrorAction SilentlyContinue
}
$final34 = [System.IO.File]::ReadAllText($p)
$versions34 = @($global:h34Seen.Keys)
$odd34 = @($versions34 | Where-Object { $_ -cne $orig34 -and $_ -cne $final34 })
Assert-Coord 'H34 the run wrote (exit 0) and the final file differs from the original' ($r.Code -eq 0 -and $final34 -cne $orig34) "code=$($r.Code)"
Assert-Coord 'H34 the watcher sampled the original text before the swap' ($versions34 -contains $orig34) ("sampled " + $versions34.Count + " versions")
Assert-Coord 'H34 every version the watcher sampled is the original or the final text: never one change without the other' ($odd34.Count -eq 0) ("odd versions: " + $odd34.Count)
Remove-Variable -Name h34Seen -Scope Global -ErrorAction SilentlyContinue

# =============================================================================
Write-Host "(H17) no temp or lock files, no global functions left"
$stray = @()
foreach ($lp in $script:hLedgers) { $stray += @(Get-Stray $lp) }
Assert-Coord 'H17 the runs above wrote and refused (so this check is not vacuous)' ($script:hWritten -ge 10 -and $script:hRefused -ge 10) "written=$($script:hWritten) refused=$($script:hRefused)"
Assert-Coord 'H17 no <ledger>.* temp or lock file is left beside any ledger of this run' ($stray.Count -eq 0) (($stray | ForEach-Object { $_.FullName }) -join "`n")
$leftFns = @('git', 'gh', 'Get-Date', 'Start-Sleep' | Where-Object { Test-Path -LiteralPath ('Function:\' + $_) })
Assert-Coord 'H17 no global git, gh, Get-Date or Start-Sleep function is left behind' ($leftFns.Count -eq 0) ($leftFns -join ',')

# =============================================================================
Write-Host "(H18) the real index folder"
Assert-Coord 'H18 the real index folder ($HOME\.claude\coordination, *.ledgers and sessions\) is byte-unchanged by this run' ((Get-CoordRealIndexDigest) -ceq $realIndexBefore) "before:`n$realIndexBefore`nafter:`n$(Get-CoordRealIndexDigest)"
Write-CoordUncheckedSummary

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Passed: $script:coordPass  Failed: $script:coordFail"
if ($script:coordFail -gt 0) { exit 1 }
exit 0
