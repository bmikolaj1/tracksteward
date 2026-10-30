# Tests for scripts/coord-set.ps1: a Tracks cell (Status or Model) changed with a
# time the script takes from its own clock, the way coord-log.ps1 stamps a line.
# Ported from the private coordinate toolkit (coord-set.test.ps1), 2026-10-29.
#
# The script runs in this process (`& <script> -Track ... -Text ...`; its `exit`
# ends only the script and sets $LASTEXITCODE). S12, and the parallel jobs of
# S16, run it through powershell.exe -File.
#
# What changed from the private suite: the example repos are generic (C:\Fx\...);
# S9 expects "not parameters" (the -Tick/-Note refusal wording of this script);
# S14 builds its linked worktree with New-HookTestWorktree and S16 starts the
# host the fixture names; S21 reads this repo's SKILL.md (two rows of the
# private suite pinned prose this repo does not have: its rules for starting a
# session from a message or a card; they are dropped); S22 pins this repo's
# SKILL.md, ledger-template.md and the script header; S0 compares the real index
# folder as the other suites do.
#
#   S1  Status: the cell is replaced, every other cell and line is unchanged;
#       the report line shows the new cell
#   S2  {now} in the text becomes HH:mm from the clock (every one of them);
#       other brace words stay; a time typed by hand is refused (also glued
#       to letters or seconds)
#   S3  -Append: ", " after a Status cell, "; " after a Model cell, nothing
#       before the text when the cell is empty; the raw cell is kept (an
#       escaped pipe stays escaped)
#   S4  -Cell Model; a ledger with no Model column is refused, unchanged
#   S5  text refused: empty, spaces, a pipe, a line break or other control
#       character; nothing written (a typed time: S2)
#   S6  the row: -Track is case-insensitive; an unknown track, a name on two
#       rows (refused without -Repo, -Repo picks one), -Repo with no match
#   S7  encoding: a BOM and CRLF line ends are kept
#   S8  a ragged Tracks row, a missing Tracks header, a Tracks header twice:
#       refused, unchanged
#   S9  -Tick and -Note are not parameters: refused as leftover words, nothing
#       written
#   S10 -Track is needed: refused when missing or empty
#   S11 leftover words after the parameters (an unknown -Cell: S4)
#   S12 -File: exit 0 written, exit 2 refused
#   S13 a missing ledger is refused and not created
#   S14 without -Ledger: today's ledger from the main checkout; a folder that
#       is no repository is refused; a linked worktree is refused
#   S15 the lock held by someone else: refused after ~5 s, unchanged
#   S16 4 coord-set and 4 coord-log runs in parallel: every change kept
#   S17 the ledger changes between the read and the swap: refused, the
#       editor's line kept
#   S18 no temp or lock file is left next to the ledger
#   S19 the edited table is still accepted by the scope guard's bounded read,
#       and a Status set to MERGED/DONE reads as a finished row, with a NOTE
#       line when the set is what finishes it
#   S20 the real ledger-template.md accepts a row, a Status set and a Model set
#   S21 SKILL.md: names coord-set.ps1, {now} and -Append
#   S22 -State <word>: the ten words (Get-CoordStateWords), any case in, upper
#       case out, as "<WORD> HH:mm; <text>"; MERGED/DONE print the NOTE; any
#       other word, -Cell Model, a typed time or an empty text refused; -Append
#       only onto the same word; through -File; the prose copies of the
#       vocabulary and of the Queue rules in SKILL.md and the template
#   S23 a BOM or a bidi mark in -Text is refused; -Repo as a bare name selects the
#       row whose Repo cell holds it (two same-name rows with bare Repo cells)
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\scripts\coord-set.test.ps1 [-ScriptPath <mutant copy>]
#       (a mutant copy needs coord-common.ps1 next to it: it dot-sources it)
# Exit: 0 = all passed, 1 = a case failed.
# The mutants run against this suite are listed in the slice's PR body.
param([string]$ScriptPath = '')

$testsDir = Split-Path -Parent $PSScriptRoot
$fixturesDir = Join-Path $testsDir 'fixtures'
try { . (Join-Path $fixturesDir 'hook-test-fixture.ps1') } catch { Write-Error "could not load hook-test-fixture.ps1: $_"; exit 1 }
Clear-HookRunnerGitEnv
. (Join-Path $fixturesDir 'coord-test-fixture.ps1')
if (-not $ScriptPath) { $ScriptPath = Join-Path $coordScriptsDir 'coord-set.ps1' }
$ScriptPath = [System.IO.Path]::GetFullPath($ScriptPath)
$logScript = Join-Path $coordScriptsDir 'coord-log.ps1'
. (Join-Path $coordScriptsDir 'coord-common.ps1')
$ErrorActionPreference = 'Stop'

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('coord-set-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory($root)
$realIndexBefore = Get-CoordRealIndexDigest
$null = New-CoordScratchIndex $root

$alphaRepo = 'C:'+[char]92+'Fx'+[char]92+'alpha'
$tHead = '| Track | Repo | Session | Model | Cwd | Branch | Scope | PR | Status |'
$tSep = '|-------|------|---------|-------|-----|--------|-------|----|--------|'
$r13 = '| T1 | C:\Fx\alpha | local_1111 | Opus 5.5 high | C:\Fx\w1 | br-one | docs/** | | briefed 08:32 |'
$r14 = '| T2 | C:\Fx\alpha | local_2222 | Sonnet 5.5 medium | C:\Fx\w2 | br-two | src/** | #12 | running |'
$r15 = '| T3 | C:\Fx\other | local_3333 | | C:\Fx\w3 | br-three | a/** | | MERGED 08:00 |'
$r16 = '| T1 | C:\Fx\other | local_1111 | | C:\Fx\w4 | br-x | b/** | | running |'
$r17 = '| Pipe | C:\Fx\alpha | s | m | c | br-p | x | | st \| escaped |'
$sample = @(
    '# Coordination ledger - 2026-10-22',
    '',
    '## Baseline',
    '',
    '| Repo | origin/main | Open PRs | CI | Verified at |',
    '|------|-------------|----------|----|-------------|',
    '',
    '## Tracks',
    '',
    '<!-- Status: lead with MERGED or DONE -->',
    '',
    $tHead,
    $tSep,
    $r13,
    $r14,
    $r15,
    $r16,
    $r17,
    '',
    '## Merge slots',
    '',
    '1. (none)',
    '',
    '## Owed checks',
    '',
    '<!-- Ticked only when verified. -->',
    '- [ ] brief to T2 has no ACK after 15 minutes',
    '- [ ] F3: fix owed by T2 (from 2026-10-21)',
    '- [ ] F4: fix owed by T1',
    '- [x] already ticked check',
    '',
    '## Decisions',
    '',
    '## Findings',
    '',
    '## Log',
    '',
    '10:42 ledger created'
)

$caseN = 0
function New-Ledger {
    param([string[]]$Lines, [string]$Nl = "`n", [bool]$Bom = $false, [bool]$TrailingNl = $true)
    $script:caseN++
    $dir = Join-Path $root ('c' + $script:caseN)
    [void][IO.Directory]::CreateDirectory($dir)
    $p = Join-Path $dir 'ledger.md'
    $text = ($Lines -join $Nl)
    if ($TrailingNl) { $text += $Nl }
    [System.IO.File]::WriteAllText($p, $text, (New-Object System.Text.UTF8Encoding($Bom)))
    return $p
}

# Runs the script in this process. $Params is splatted. Returns { Code; Out; Before; After }.
function Invoke-Set {
    param([hashtable]$Params, [string]$Cwd = '')
    $before = Get-Date
    $global:LASTEXITCODE = $null
    if ($Cwd) { Push-Location -LiteralPath $Cwd -ErrorAction Stop }
    try {
        $out = @(& $ScriptPath @Params 2>&1)
        $code = $LASTEXITCODE
    }
    catch { $out = @("THREW: $_"); $code = 'threw' }
    finally { if ($Cwd) { Pop-Location } }
    return [pscustomobject]@{ Code = $code; Out = (($out | ForEach-Object { [string]$_ }) -join "`n"); Before = $before; After = (Get-Date) }
}
function Get-Stamps($r) {
    return @($r.Before.ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture), $r.After.ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture))
}
function Read-Lines([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return , ([string[]]@("<no file at $Path>")) }
    return , ([string[]]([System.IO.File]::ReadAllText($Path) -split "`r?`n"))
}
function Get-Bytes([string]$Path) { return [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Path)) }

# $Lines with the elements at the given indexes replaced ($Changes: index -> text, where {S} is the stamp),
# plus the trailing empty element of a file that ends in a newline. True when the file equals that for
# either of the run's two clock readings.
function Test-Changed {
    param([string]$Label, $R, [string]$Path, [string[]]$Lines, [hashtable]$Changes, [string]$Report = '')
    $got = Read-Lines $Path
    $ok = $false
    foreach ($s in (Get-Stamps $R)) {
        $exp = [System.Collections.Generic.List[string]]::new($Lines)
        foreach ($k in $Changes.Keys) { $exp[[int]$k] = ([string]$Changes[$k]).Replace('{S}', $s) }
        $exp.Add('')
        $repOk = (-not $Report) -or $R.Out -ceq ($Report.Replace('{S}', $s).Replace('{LEDGER}', $Path))
        if (($got -join "`n") -ceq ($exp -join "`n") -and $repOk) { $ok = $true }
    }
    Assert-Coord $Label ($R.Code -eq 0 -and $ok) "code=$($R.Code) out=$($R.Out)`n--- got ---`n$($got -join "`n")"
}
function Test-Refused {
    param([string]$Label, $R, [string]$Path, [string]$Why = '')
    $b = $script:refusedBytes
    Assert-Coord $Label ($R.Code -eq 2 -and $R.Out -match '^COORD-SET: NOT WRITTEN - ' -and ((-not $Why) -or $R.Out -match $Why) -and (Get-Bytes $Path) -ceq $b) "code=$($R.Code) out=$($R.Out)"
}
function Invoke-Refused {
    param([string]$Label, [hashtable]$Params, [string[]]$Lines = $sample, [string]$Why = '')
    $p = New-Ledger $Lines
    $script:refusedBytes = Get-Bytes $p
    $Params['Ledger'] = $p
    $r = Invoke-Set $Params
    Test-Refused $Label $r $p $Why
}

Write-Host '(S1) Status replaced'
$p = New-Ledger $sample
$r = Invoke-Set @{ Track = 'T2'; Text = 'running; round 1 DONE'; Ledger = $p }
Test-Changed 'S1 T2 Status replaced, every other line unchanged' $r $p $sample @{ 14 = ($r14 -replace 'running \|$', 'running; round 1 DONE |') } 'COORD-SET {LEDGER} [Tracks T2 Status]: running; round 1 DONE'
$p = New-Ledger $sample
$r = Invoke-Set @{ Track = 'Pipe'; Text = 'replaced'; Ledger = $p }
Test-Changed 'S1 a cell holding an escaped pipe is replaced whole' $r $p $sample @{ 17 = ($r17 -replace 'st \\\| escaped \|$', 'replaced |') }

Write-Host '(S2) {now}'
$p = New-Ledger $sample
$r = Invoke-Set @{ Track = 'T1'; Repo = $alphaRepo; Text = 'ACK {now}, ready {now} {x} {NOW}'; Ledger = $p }
Test-Changed 'S2 every {now} is the clock''s HH:mm; {x} and {NOW} stay' $r $p $sample @{ 13 = ($r13 -replace 'briefed 08:32 \|$', 'ACK {S}, ready {S} {x} {NOW} |') }
foreach ($c in @(@('ACK 08:40', 'ACK 08:40'), @('at 9:05', 'at 9:05'), @('{now} and 14:10', '{now} and 14:10'), @('time first', '23:59 done'), @('pm', 'done 9:05pm'), @('Z', 'at 09:12Z'), @('seconds', 'at 09:12:30'),
        @('fullwidth colon (U+FF1A)', ('at 10' + [char]0xFF1A + '22')), @('10h22', 'at 10h22'))) {
    Invoke-Refused "S2 a typed time is refused: $($c[0])" @{ Track = 'T1'; Text = $c[1] } -Why 'typed time|\{now\}'
}
$p = New-Ledger $sample
$r = Invoke-Set @{ Track = 'T1'; Repo = $alphaRepo; Text = 'v1:2 and 1.5 and 10:420 and coord-brief.ps1:96'; Ledger = $p }
Test-Changed 'S2 text that only looks like a time is written as typed' $r $p $sample @{ 13 = ($r13 -replace 'briefed 08:32 \|$', 'v1:2 and 1.5 and 10:420 and coord-brief.ps1:96 |') }
$p = New-Ledger $sample
$r = Invoke-Set @{ Track = 'T1'; Repo = $alphaRepo; Cell = 'Model'; Text = 'Opus 4.15 high'; Ledger = $p }
Test-Changed 'S2 a dotted number (Model "Opus 4.15 high") is no typed time and is written as typed' $r $p $sample @{ 13 = ($r13 -replace 'Opus 5.5 high \|', 'Opus 4.15 high |') }

Write-Host '(S3) -Append'
$p = New-Ledger $sample
$r = Invoke-Set @{ Track = 'T1'; Repo = $alphaRepo; Text = 'ACK {now}'; Append = $true; Ledger = $p }
Test-Changed 'S3 Status gets ", " and the text' $r $p $sample @{ 13 = ($r13 -replace 'briefed 08:32 \|$', 'briefed 08:32, ACK {S} |') } 'COORD-SET {LEDGER} [Tracks T1 Status]: briefed 08:32, ACK {S}'
$p = New-Ledger $sample
$r = Invoke-Set @{ Track = 'T1'; Repo = $alphaRepo; Cell = 'Model'; Text = '{now} Sonnet 5.5 high'; Append = $true; Ledger = $p }
Test-Changed 'S3 Model gets "; " and the text' $r $p $sample @{ 13 = ($r13 -replace 'Opus 5.5 high \|', 'Opus 5.5 high; {S} Sonnet 5.5 high |') }
$p = New-Ledger $sample
$r = Invoke-Set @{ Track = 'T3'; Cell = 'Model'; Text = 'Opus 5.5 high'; Append = $true; Ledger = $p }
Test-Changed 'S3 an empty cell gets the text alone' $r $p $sample @{ 15 = ($r15 -replace 'local_3333 \| \|', 'local_3333 | Opus 5.5 high |') }
$p = New-Ledger $sample
$r = Invoke-Set @{ Track = 'Pipe'; Text = 'more'; Append = $true; Ledger = $p }
Test-Changed 'S3 the raw cell is kept: an escaped pipe stays escaped' $r $p $sample @{ 17 = ($r17 -replace 'escaped \|$', 'escaped, more |') }

Write-Host '(S4) -Cell'
$noModel = @($sample | ForEach-Object { $_ })
$noModel[11] = '| Track | Repo | Session | Cwd | Branch | Scope | PR | Status |'
$noModel[12] = '|-------|------|---------|-----|--------|-------|----|--------|'
$noModel[13] = '| T1 | C:\Fx\alpha | local_1111 | C:\Fx\w1 | br-one | docs/** | | briefed 08:32 |'
$noModel[14] = '| T2 | C:\Fx\alpha | local_2222 | C:\Fx\w2 | br-two | src/** | #12 | running |'
$noModel[15] = '| T3 | C:\Fx\other | local_3333 | C:\Fx\w3 | br-three | a/** | | MERGED 08:00 |'
$noModel[16] = '| T1 | C:\Fx\other | local_1111 | C:\Fx\w4 | br-x | b/** | | running |'
$noModel[17] = '| Pipe | C:\Fx\alpha | s | c | br-p | x | | st \| escaped |'
Invoke-Refused 'S4 -Cell Model on a ledger with no Model column: refused, unchanged' @{ Track = 'T1'; Cell = 'Model'; Text = 'x' } -Lines $noModel -Why "no 'Model' column"
$p = New-Ledger $noModel
$r = Invoke-Set @{ Track = 'T2'; Text = 'ok'; Ledger = $p }
Test-Changed 'S4 Status still works there' $r $p $noModel @{ 14 = ($noModel[14] -replace 'running \|$', 'ok |') }
Invoke-Refused 'S4 an unknown -Cell (PR) is refused' @{ Track = 'T1'; Cell = 'PR'; Text = 'x' } -Why "-Cell must be"

# The check that the parser's rows and the table's data lines agree cannot be reached with a real ledger (both use
# the same rule), so it is tested with a copy of the library whose row parser drops its last row.
$driftDir = Join-Path $root 'drift-scripts'
Copy-HookTestScripts -SourceDir (Split-Path -Parent $ScriptPath) -DestDir $driftDir
$driftLib = Join-Path $driftDir 'coord-common.ps1'
$driftSrc = [System.IO.File]::ReadAllText($driftLib)
$driftAnchor = $driftSrc.IndexOf('function ConvertFrom-CoordTracksRows')
$driftAt = $driftSrc.IndexOf('    return $result.ToArray()', $driftAnchor)
Assert-Coord 'S4b control: the copy of the library has its row parser patched (the anchor was found)' (($driftAnchor -ge 0) -and ($driftAt -gt $driftAnchor)) "anchor=$driftAnchor at=$driftAt"
if ($driftAt -gt $driftAnchor) {
    $driftSrc = $driftSrc.Substring(0, $driftAt) + '    return @($result.ToArray() | Select-Object -First ($result.Count - 1))' + $driftSrc.Substring($driftAt + '    return $result.ToArray()'.Length)
    [System.IO.File]::WriteAllText($driftLib, $driftSrc)
    $p = New-Ledger $sample
    $b = Get-Bytes $p
    $realScript = $ScriptPath
    $ScriptPath = Join-Path $driftDir (Split-Path -Leaf $realScript)
    try { $r = Invoke-Set @{ Track = 'T2'; Text = 'ok'; Ledger = $p } } finally { $ScriptPath = $realScript }
    Assert-Coord 'S4b the Tracks rows the parser returns and the table lines disagree: refused naming the counts, ledger unchanged' ($r.Code -eq 2 -and $r.Out -match '^COORD-SET: NOT WRITTEN - ' -and $r.Out -match 'cannot match the Tracks rows' -and (Get-Bytes $p) -ceq $b) "code=$($r.Code) out=$($r.Out)"
}

Write-Host '(S5) text'
foreach ($c in @(@('empty', ''), @('spaces', '   '), @('pipe', 'a | b'), @('LF', "a`nb"), @('CR', "a`rb"), @('NUL', "a$([char]0)b"),
        @('U+0085', "a$([char]0x85)b"), @('U+2028', "a$([char]0x2028)b"), @('DEL', "a$([char]0x7F)b"))) {
    Invoke-Refused "S5 refused: $($c[0])" @{ Track = 'T1'; Text = $c[1] } -Why 'Text|text'
}
$p = New-Ledger $sample
$r = Invoke-Set @{ Track = 'T1'; Repo = $alphaRepo; Text = "  padded `t tab  "; Ledger = $p }
Test-Changed 'S5 surrounding spaces are trimmed, a tab is allowed' $r $p $sample @{ 13 = ($r13 -replace 'briefed 08:32 \|$', "padded `t tab |") }

Write-Host '(S6) the row'
$p = New-Ledger $sample
$r = Invoke-Set @{ Track = 't2'; Text = 'lower'; Ledger = $p }
Test-Changed 'S6 -Track is case-insensitive' $r $p $sample @{ 14 = ($r14 -replace 'running \|$', 'lower |') }
Invoke-Refused 'S6 an unknown track is refused' @{ Track = 'Nope'; Text = 'x' } -Why "no Tracks row 'Nope'"
Invoke-Refused 'S6 a name on two rows, no -Repo: refused, naming the repos' @{ Track = 'T1'; Text = 'x' } -Why 'pass -Repo'
$p = New-Ledger $sample
$r = Invoke-Set @{ Track = 'T1'; Repo = 'C:\Fx\other\'; Text = 'other repo'; Ledger = $p }
Test-Changed 'S6 -Repo picks the row (trailing separator and case ignored)' $r $p $sample @{ 16 = ($r16 -replace 'running \|$', 'other repo |') }
Invoke-Refused 'S6 -Repo with no such row is refused' @{ Track = 'T1'; Repo = 'C:\Fx\nowhere'; Text = 'x' } -Why "no Tracks row 'T1'"
$dup = @($sample | ForEach-Object { $_ })
$dup[16] = $r16.Replace('C:\Fx\other', 'C:\Fx\alpha')
Invoke-Refused 'S6 the same name twice in one repo is refused even with -Repo' @{ Track = 'T1'; Repo = 'C:\Fx\alpha'; Text = 'x' } -Lines $dup -Why 'share a repo|rename'
$p = New-Ledger $sample
$r = Invoke-Set @{ Track = 'T3'; Text = 'reopened'; Ledger = $p }
Test-Changed 'S6 a finished row can be set too (a MERGED row corrected)' $r $p $sample @{ 15 = ($r15 -replace 'MERGED 08:00 \|$', 'reopened |') }

Write-Host '(S7) encoding'
$p = New-Ledger $sample -Nl "`r`n" -Bom $true
$r = Invoke-Set @{ Track = 'T2'; Text = 'crlf {now}'; Ledger = $p }
$bytes = [System.IO.File]::ReadAllBytes($p)
$txt = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
$okBom = $bytes.Length -gt 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
$crlf = ([regex]::Matches($txt, "`r`n")).Count
$bareLf = ([regex]::Matches($txt, "(?<!`r)`n")).Count
Assert-Coord 'S7 BOM kept and every line end still CRLF' ($r.Code -eq 0 -and $okBom -and $bareLf -eq 0 -and $crlf -eq ($sample.Count) -and $txt -match '(?m)^\| T2 .* \| #12 \| crlf \d\d:\d\d \|\r$') "code=$($r.Code) out=$($r.Out) crlf=$crlf bareLf=$bareLf"
$p = New-Ledger $sample
$r = Invoke-Set @{ Track = 'T2'; Text = 'lf'; Ledger = $p }
$bytes = [System.IO.File]::ReadAllBytes($p)
Assert-Coord 'S7 no BOM added and LF kept' ($r.Code -eq 0 -and -not ($bytes[0] -eq 0xEF) -and -not ([System.Text.Encoding]::UTF8.GetString($bytes)).Contains("`r")) "code=$($r.Code) out=$($r.Out)"
$p = New-Ledger $sample
$bytes = [System.IO.File]::ReadAllBytes($p)
$bad = [byte[]]($bytes + [byte[]](0xC3, 0x28))
[System.IO.File]::WriteAllBytes($p, $bad)
$script:refusedBytes = Get-Bytes $p
$r = Invoke-Set @{ Track = 'T2'; Text = 'x'; Ledger = $p }
Test-Refused 'S7 a file that is not UTF-8 is refused' $r $p 'not valid UTF-8'

Write-Host '(S8) the table'
$ragged = @($sample | ForEach-Object { $_ })
$ragged[16] = '| T1 | C:\Fx\other | local_1111 | | C:\Fx\w4 | br-x | b/** | running |'
Invoke-Refused 'S8 a ragged Tracks row: refused, unchanged' @{ Track = 'T2'; Text = 'x' } -Lines $ragged -Why 'cells'
$noTracks = @($sample | ForEach-Object { if ($_ -ceq '## Tracks') { '## Tracking' } else { $_ } })
Invoke-Refused 'S8 no ## Tracks header: refused' @{ Track = 'T2'; Text = 'x' } -Lines $noTracks -Why "found 0 '## Tracks'"
$twice = @($sample) + @('', '## Tracks', '', $tHead, $tSep, $r14)
Invoke-Refused 'S8 ## Tracks twice: refused' @{ Track = 'T2'; Text = 'x' } -Lines $twice -Why "found 2 '## Tracks'"
$noTable = @($sample[0..7]) + @('', 'no table here', '') + @($sample[19..($sample.Count - 1)])
Invoke-Refused 'S8 a Tracks section with no table: refused' @{ Track = 'T2'; Text = 'x' } -Lines $noTable -Why 'holds no table'
$hdrOnly = @($sample[0..12]) + @($sample[18..($sample.Count - 1)])
Invoke-Refused 'S8 a header-only Tracks table: refused (no such row)' @{ Track = 'T2'; Text = 'x' } -Lines $hdrOnly -Why "no Tracks row 'T2'"

Write-Host '(S9) -Tick and -Note are not parameters'
# The script has no mode that ticks an Owed check, and the words arrive as leftover arguments: refused,
# nothing written.
Invoke-Refused 'S9 -Tick / -Note: refused as leftover words, the Owed checks untouched' @{ Tick = 'F4'; Note = 'n' } -Why 'not parameters'
Invoke-Refused 'S9 -Tick with a -Track: refused as leftover words, the Status not set' @{ Track = 'T2'; Text = 'x'; Tick = 'F4' } -Why 'not parameters'

Write-Host '(S10) -Track is needed'
Invoke-Refused 'S10 no -Track (only -Text): refused' @{ Text = 'x' } -Why '-Track is needed'
Invoke-Refused 'S10 an empty -Track: refused' @{ Track = '  '; Text = 'x' } -Why '-Track is needed'

Write-Host '(S11) arguments'
$p = New-Ledger $sample
$script:refusedBytes = Get-Bytes $p
$global:LASTEXITCODE = $null
$out = (@(& $ScriptPath -Track T2 -Text merge '#40' when ready -Ledger $p 2>&1) | ForEach-Object { [string]$_ }) -join "`n"
Assert-Coord 'S11 words left over after the parameters: refused, unchanged' ($LASTEXITCODE -eq 2 -and $out -match 'unexpected words after the parameters \(#40 when ready\)' -and $out -match 'text was split' -and $out -notmatch 'not parameters' -and (Get-Bytes $p) -ceq $script:refusedBytes) "code=$LASTEXITCODE out=$out"

Write-Host '(S12) through powershell.exe -File'
$p = New-Ledger $sample
$x = Invoke-HookTestPowerShell -Script $ScriptPath -StartDir $root -ScriptArgs "-Track T2 -Text done -Ledger `"$p`""
Assert-Coord 'S12 -File: exit 0 and the cell is written' ($x.Code -eq 0 -and (Read-Lines $p)[14] -ceq ($r14 -replace 'running \|$', 'done |')) "code=$($x.Code) out=$($x.Out) err=$($x.Err)"
$x = Invoke-HookTestPowerShell -Script $ScriptPath -StartDir $root -ScriptArgs "-Track Nope -Text done -Ledger `"$p`""
Assert-Coord 'S12 -File: a refusal exits 2 with the NOT WRITTEN line' ($x.Code -eq 2 -and ([string]$x.Out) -match 'COORD-SET: NOT WRITTEN - no Tracks row') "code=$($x.Code) out=$($x.Out) err=$($x.Err)"

Write-Host '(S13) a missing ledger'
$gone = Join-Path $root 'nowhere\ledger.md'
$r = Invoke-Set @{ Track = 'T2'; Text = 'x'; Ledger = $gone }
Assert-Coord 'S13 a missing ledger (no folder) is refused and not created' ($r.Code -eq 2 -and $r.Out -match '^COORD-SET: NOT WRITTEN - no ledger at ' -and -not (Test-Path -LiteralPath $gone) -and -not (Test-Path -LiteralPath (Split-Path $gone))) "code=$($r.Code) out=$($r.Out)"
$goneDir = Join-Path $root ('c' + $caseN)
$r = Invoke-Set @{ Track = 'T2'; Text = 'x'; Ledger = (Join-Path $goneDir 'absent.md') }
Assert-Coord 'S13 a missing ledger (folder there) is refused and not created' ($r.Code -eq 2 -and $r.Out -match '^COORD-SET: NOT WRITTEN - no ledger at ' -and -not (Test-Path -LiteralPath (Join-Path $goneDir 'absent.md'))) "code=$($r.Code) out=$($r.Out)"
$r = Invoke-Set @{ Track = 'T2'; Text = 'x'; Ledger = 'C:\bad|path.md' }
Assert-Coord 'S13 an unusable -Ledger path: the NOT WRITTEN line, exit 2' ($r.Code -eq 2 -and $r.Out -match '^COORD-SET: NOT WRITTEN - -Ledger is not a usable path') $r.Out

Write-Host '(S14) without -Ledger'
$repo = New-CoordCanonRepo $root 'canon' -Commit
$today = Get-CoordToday
$canon = New-CoordCanonLedger $repo $today ((($sample -join "`n") + "`n"))
$r = Invoke-Set @{ Track = 'T2'; Text = 'main checkout' } -Cwd $repo
Assert-Coord 'S14 from the main checkout: today''s canonical ledger is written' ($r.Code -eq 0 -and (Read-Lines $canon)[14] -ceq ($r14 -replace 'running \|$', 'main checkout |')) "code=$($r.Code) out=$($r.Out)"
$plain = Join-Path $root 'plain'
[void][IO.Directory]::CreateDirectory($plain)
$r = Invoke-Set @{ Track = 'T2'; Text = 'x' } -Cwd $plain
Assert-Coord 'S14 outside a repository: refused, pass -Ledger' ($r.Code -eq 2 -and $r.Out -match '^COORD-SET: NOT WRITTEN - .* is not in a git repository; pass -Ledger') $r.Out
$wt = Join-Path $root 'canon-wt'
New-HookTestWorktree -Repo $repo -Path $wt -Branch 'wt-branch'
$before = Get-Bytes $canon
$r = Invoke-Set @{ Track = 'T2'; Text = 'from a worktree' } -Cwd $wt
Assert-Coord 'S14 from a linked worktree: refused (it would reach the main checkout''s live ledger), ledger unchanged' ($r.Code -eq 2 -and $r.Out -match 'is not the repo''s main checkout; pass -Ledger' -and (Get-Bytes $canon) -ceq $before) $r.Out

Write-Host '(S15) a held lock'
$p = New-Ledger $sample
$script:refusedBytes = Get-Bytes $p
$held = New-Object System.IO.FileStream(($p + '.coord-log.lock'), [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
try { $r = Invoke-Set @{ Track = 'T2'; Text = 'x'; Ledger = $p } } finally { $held.Dispose() }
Assert-Coord 'S15 coord-log''s lock held elsewhere: refused after waiting, unchanged (one lock for every ledger writer)' ($r.Code -eq 2 -and $r.Out -match 'cannot take .*coord-log\.lock within 5 s' -and (Get-Bytes $p) -ceq $script:refusedBytes -and ($r.After - $r.Before).TotalSeconds -ge 4) "code=$($r.Code) out=$($r.Out)"
Remove-Item -LiteralPath ($p + '.coord-log.lock') -Force -ErrorAction SilentlyContinue

Write-Host '(S16) parallel runs with coord-log'
$p = New-Ledger $sample
$procs = @()
for ($i = 1; $i -le 4; $i++) {
    foreach ($job in @(@($ScriptPath, "-Track T2 -Append -Text p$i"), @($logScript, "-Section Log -Text l$i"))) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = Get-HookTestShellPath
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$($job[0])`" $($job[1]) -Ledger `"$p`""
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $procs += [System.Diagnostics.Process]::Start($psi)
    }
}
$codes = @()
$outs = @()
# The stdout reads of all children are started before any wait (these jobs redirect stdout only); each wait is
# capped at 120 s and kills its child at the cap.
$tasks = @($procs | ForEach-Object { $_.StandardOutput.ReadToEndAsync() })
foreach ($pr in $procs) { if (-not $pr.WaitForExit(120000)) { try { $pr.Kill() } catch { } }; $codes += $(if ($pr.HasExited) { $pr.ExitCode } else { -1 }) }
foreach ($tk in $tasks) { $outs += $(if ($tk.Wait(5000)) { $tk.Result.Trim() } else { '' }) }
$got = Read-Lines $p
$t2 = $got[14]
$allP = @(1..4 | Where-Object { $t2 -match "\bp$_\b" }).Count
$allL = @(1..4 | Where-Object { $i = $_; @($got | Where-Object { $_ -match "^\d\d:\d\d l$i$" }).Count -eq 1 }).Count
Assert-Coord 'S16 8 parallel runs (4 coord-set, 4 coord-log): all exit 0, p1..p4 in the T2 cell, l1..l4 once each, the rest intact' (($codes | Where-Object { $_ -ne 0 }).Count -eq 0 -and $t2.StartsWith('| T2 | C:\Fx\alpha | local_2222 | Sonnet 5.5 medium | C:\Fx\w2 | br-two | src/** | #12 | running, p') -and $allP -eq 4 -and $allL -eq 4 -and $got[13] -ceq $r13 -and $got[15] -ceq $r15) "codes=$($codes -join ',')`n$($outs -join "`n")`n--- ledger ---`n$($got -join "`n")"

Write-Host '(S17) the ledger changes between the read and the swap'
$p = New-Ledger $sample
$global:s17Ledger = $p
function global:Get-Date { [System.IO.File]::AppendAllText($global:s17Ledger, "editor line`n"); Microsoft.PowerShell.Utility\Get-Date @args }
$global:LASTEXITCODE = $null
try { $out = (@(& $ScriptPath -Track T2 -Text 'x' -Ledger $p 2>&1) | ForEach-Object { [string]$_ }) -join "`n"; $code = $LASTEXITCODE }
catch { $out = "THREW: $_"; $code = 'threw' }
finally { Remove-Item -LiteralPath 'Function:\Get-Date' -Force -ErrorAction SilentlyContinue }
Assert-Coord 'S17 refused; the editor''s line kept, our change not written' ($code -eq 2 -and $out -match 'changed while this run read it' -and [System.IO.File]::ReadAllText($p) -ceq ((($sample -join "`n")) + "`neditor line`n")) "code=$code out=$out"

Write-Host '(S18) nothing left next to the ledger'
$left = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force | Where-Object { $_.Name -like '*.tmp' -or $_.Name -like '*.lock' })
Assert-Coord 'S18 no .tmp or .lock file anywhere under the test folder' ($left.Count -eq 0) (($left | ForEach-Object { $_.FullName }) -join "`n")

Write-Host '(S19) the guard still reads the table'
$p = New-Ledger $sample
$r = Invoke-Set @{ Track = 'T2'; Text = 'DONE {now}, merged as abc1234'; Ledger = $p }
$noteOut = $r.Out
$bounded = Read-CoordLedgerTracksBounded -Path $p
$row = @($bounded.Rows | Where-Object { $_.Track -ceq 'T2' })
Assert-Coord 'S19 Read-CoordLedgerTracksBounded accepts the edited ledger and T2 reads as a finished row' ($r.Code -eq 0 -and $bounded.Ok -and $row.Count -eq 1 -and (Test-CoordRowTerminal $row[0].Status) -and $row[0].Session -ceq 'local_2222' -and $row[0].PR -ceq '#12') "code=$($r.Code) out=$($r.Out) bounded=$($bounded.Error) status=$($row[0].Status)"
Assert-Coord 'S19 the set that finishes a row says so (a second NOTE line); the report line is first' ($noteOut -match "(?s)^COORD-SET .* \[Tracks T2 Status\]: DONE \d\d:\d\d, merged as abc1234\r?\nCOORD-SET NOTE: row 'T2' now reads as FINISHED") $noteOut
$r = Invoke-Set @{ Track = 'T1'; Repo = $alphaRepo; Text = '`DONE` in review'; Ledger = $p }
Assert-Coord 'S19 backticks do not hide it: the readers drop them, so `DONE` finishes the row and the NOTE says so' ($r.Code -eq 0 -and $r.Out -match 'COORD-SET NOTE: row ''T1'' now reads as FINISHED') $r.Out
$r = Invoke-Set @{ Track = 'T3'; Text = 'MERGED again, 09 checked'; Ledger = $p }
Assert-Coord 'S19 no NOTE when the row was already finished' ($r.Code -eq 0 -and $r.Out -notmatch 'NOTE') $r.Out
$r = Invoke-Set @{ Track = 'T3'; Text = 'NOT MERGED, back in review'; Ledger = $p }
Assert-Coord 'S19 a finished row set live again says so (the flip is never silent, either way)' ($r.Code -eq 0 -and $r.Out -match "COORD-SET NOTE: row 'T3' now reads as LIVE again") $r.Out
$rows = @(Read-CoordLedgerTracks $p)
$t3 = @($rows | Where-Object { $_.Track -ceq 'T3' })[0].Status
Assert-Coord 'S19 and a Status set to "NOT MERGED ..." reads as live again' ($r.Code -eq 0 -and $t3 -ceq 'NOT MERGED, back in review' -and -not (Test-CoordRowTerminal $t3)) "out=$($r.Out) status=$t3"
$r = Invoke-Set @{ Track = 'T3'; Text = 'still in review'; Ledger = $p }
Assert-Coord 'S19 no NOTE when a live row stays live' ($r.Code -eq 0 -and $r.Out -notmatch 'NOTE') $r.Out

Write-Host '(S20) the real ledger-template.md'
$tpl = @([System.IO.File]::ReadAllText((Join-Path $coordTemplatesDir 'ledger-template.md')) -split "`r?`n")
$sepAt = -1
for ($k = 0; $k -lt $tpl.Count; $k++) { if ($tpl[$k] -match '^\|-+\|-+\|-+\|-+\|-+\|-+\|-+\|-+\|-+\|$') { $sepAt = $k } }
Assert-Coord 'S20 the template has the nine-column Tracks separator' ($sepAt -gt 0) 'no separator row found'
$tplRow = '| X1 | C:\Fx\alpha | local_9999 | Opus 5.5 high | C:\Fx\w9 | br-x1 | docs/** | | briefed |'
$tplLines = @($tpl[0..$sepAt]) + @($tplRow) + @($tpl[($sepAt + 1)..($tpl.Count - 1)])
$p = New-Ledger $tplLines
$r1 = Invoke-Set @{ Track = 'X1'; Text = 'ACK {now}'; Append = $true; Ledger = $p }
$r2 = Invoke-Set @{ Track = 'X1'; Cell = 'Model'; Text = '{now} Sonnet 5.5 high'; Append = $true; Ledger = $p }
$got = Read-Lines $p
Assert-Coord 'S20 the template takes a Status append and a Model append (template and script cannot drift)' ($r1.Code -eq 0 -and $r2.Code -eq 0 -and @($got -match '^\| X1 .* \| briefed, ACK \d\d:\d\d \|$').Count -eq 1 -and @($got -match 'Opus 5\.5 high; \d\d:\d\d Sonnet 5\.5 high').Count -eq 1) "$($r1.Out) $($r2.Out)`n$($got -join "`n")"

Write-Host '(S21) SKILL.md'
$skill = [regex]::Replace([System.IO.File]::ReadAllText((Join-Path $coordScriptsDir '..\skills\coordinate\SKILL.md')), '\s+', ' ')
Assert-Coord 'S21 SKILL.md documents coord-set.ps1 with {now} and -Append' ($skill.Contains('coord-set.ps1') -and $skill.Contains('{now}') -and $skill.Contains('-Append')) 'missing'
Assert-Coord 'S21 SKILL.md calls coord-set.ps1 through the plugin root' ($skill.Contains('"${CLAUDE_PLUGIN_ROOT}/scripts/coord-set.ps1"')) 'missing'

Write-Host '(S22) -State: the Status vocabulary'
$vocab = @('QUEUED', 'BRIEFED', 'RUNNING', 'PR-OPEN', 'WAIT-USER', 'WAIT-SLOT', 'WAIT-QUOTA', 'BLOCKED', 'MERGED', 'DONE')
$shared = @()
try { $shared = @((Get-CoordStateWords).Keys) } catch { }
Assert-Coord 'S22 Get-CoordStateWords (coord-common.ps1) is the ten words in order, the list coord-set and coord-status share' (($shared -join ',') -ceq ($vocab -join ',')) "got: $($shared -join ',')"
$p = New-Ledger $sample
$r = Invoke-Set @{ Track = 'T2'; State = 'running'; Text = 'ACK {now}'; Ledger = $p }
Test-Changed 'S22 -State running: the cell is "RUNNING HH:mm; <text>", the word upper case, {now} expanded' $r $p $sample @{ 14 = ($r14 -replace 'running \|$', 'RUNNING {S}; ACK {S} |') } 'COORD-SET {LEDGER} [Tracks T2 Status]: RUNNING {S}; ACK {S}'
foreach ($w in $vocab) {
    $p = New-Ledger $sample
    $r = Invoke-Set @{ Track = 'T2'; State = $w.ToLowerInvariant(); Text = 'x'; Ledger = $p }
    $cell = (Read-Lines $p)[14]
    $noteWant = $w -in @('MERGED', 'DONE')
    Assert-Coord "S22 -State $($w.ToLowerInvariant()) is accepted and written as $w$(if ($noteWant) { ', with the FINISHED note' })" ($r.Code -eq 0 -and $cell -cmatch ('\| ' + [regex]::Escape($w) + ' \d\d:\d\d; x \|$') -and (($r.Out -match 'COORD-SET NOTE: .* FINISHED') -eq $noteWant)) "code=$($r.Code) out=$($r.Out) cell=$cell"
}
foreach ($bad in @('PAUSED', 'WAIT-OWNER', 'running;', 'WAIT')) {
    Invoke-Refused "S22 -State '$bad' is not a vocabulary word: refused, the list named" @{ Track = 'T2'; State = $bad; Text = 'x' } -Why '-State must be one of: QUEUED, BRIEFED, RUNNING, PR-OPEN, WAIT-USER, WAIT-SLOT, WAIT-QUOTA, BLOCKED, MERGED, DONE'
}
Invoke-Refused 'S22 -State with -Cell Model: refused (the state word is the Status cell''s)' @{ Track = 'T2'; Cell = 'Model'; State = 'RUNNING'; Text = 'x' } -Why '-State sets the Status cell'
Invoke-Refused 'S22 -State with a typed time in -Text: refused' @{ Track = 'T2'; State = 'RUNNING'; Text = 'ACK 08:40' } -Why 'typed time'
Invoke-Refused 'S22 -State with an empty -Text: refused' @{ Track = 'T2'; State = 'RUNNING'; Text = '' } -Why '-Text is empty'
$st = @($sample | ForEach-Object { $_ })
$st[14] = '| T2 | C:\Fx\alpha | local_2222 | Sonnet 5.5 medium | C:\Fx\w2 | br-two | src/** | #12 | RUNNING 10:00; ACK |'
$p = New-Ledger $st
$r = Invoke-Set @{ Track = 'T2'; State = 'Running'; Text = 'round 2'; Append = $true; Ledger = $p }
Test-Changed 'S22 -State with -Append and the same word: the text is appended, the word and its time kept' $r $p $st @{ 14 = ($st[14] -replace 'ACK \|$', 'ACK, round 2 |') }
Invoke-Refused 'S22 -State with -Append and another word: refused (a state change replaces the cell)' @{ Track = 'T2'; State = 'BLOCKED'; Text = 'x'; Append = $true } -Lines $st -Why 'state change replaces the cell'
Invoke-Refused 'S22 -State with -Append on a legacy cell (first word "running", not RUNNING): refused' @{ Track = 'T2'; State = 'RUNNING'; Text = 'x'; Append = $true } -Why 'state change replaces the cell'
$p = New-Ledger $sample
$x = Invoke-HookTestPowerShell -Script $ScriptPath -StartDir $root -ScriptArgs "-Track T2 -State pr-open -Text reported -Ledger `"$p`""
Assert-Coord 'S22 -File: -State pr-open is written as PR-OPEN, exit 0' ($x.Code -eq 0 -and (Read-Lines $p)[14] -cmatch '\| PR-OPEN \d\d:\d\d; reported \|$') "code=$($x.Code) out=$($x.Out) err=$($x.Err)"
$p = New-Ledger $sample
$r = Invoke-Set @{ Track = 'T3'; State = 'BLOCKED'; Text = 'reopened'; Ledger = $p }
Assert-Coord 'S22 -State BLOCKED on a MERGED row: written, with the LIVE-again NOTE' ($r.Code -eq 0 -and $r.Out -match "COORD-SET NOTE: row 'T3' now reads as LIVE again") $r.Out
Invoke-Refused 'S22 an explicit but blank -State is refused, not read as no -State' @{ Track = 'T2'; State = '  '; Text = 'x' } -Why '-State must be one of'
# The prose pins: the -State paragraph names every word; the template's Tracks comment lists them in order; the
# examples teach -State; the Queue and carry-forward rules are stated.
$stateAt = $skill.IndexOf("-State RUNNING -Text 'ACK'")
$para = if ($stateAt -ge 0) { $skill.Substring($stateAt, [Math]::Min(700, $skill.Length - $stateAt)) } else { '' }
# Ordered: from "The words:" each word is found after the one before it.
function Test-WordsInOrder([string]$Text, [string]$From) {
    $at = $Text.IndexOf($From)
    if ($at -lt 0) { return $false }
    foreach ($w in $vocab) { $at = [regex]::Match($Text.Substring($at), '(?<![A-Z-])' + [regex]::Escape($w) + '(?![A-Z-])') | ForEach-Object { if ($_.Success) { $at + $_.Index + $_.Length } else { -1 } }; if ($at -lt 0) { return $false } }
    return $true
}
Assert-Coord 'S22 SKILL.md: the -State paragraph lists all ten words in order' ($stateAt -ge 0 -and (Test-WordsInOrder $para 'The words:')) "paragraph: $para"
Assert-Coord 'S22 SKILL.md: the Reporting status copy lists the ten words in order' ($skill.Contains('Status vocabulary the board reads (first word, upper case): ' + ($vocab -join ', ') + '.')) 'missing'
Assert-Coord 'S22 SKILL.md: the [after HH:mm] rewrite converts local time to UTC, and new ids go above every carried id' ($skill.Contains('the local time converted to UTC') -and $skill.Contains('above the highest id in any carried line, outcome lines included')) 'missing'
$tplText = [regex]::Replace([System.IO.File]::ReadAllText((Join-Path $coordTemplatesDir 'ledger-template.md')), '\s+', ' ')
Assert-Coord 'S22 ledger-template.md: the Tracks comment lists the ten words in order' ($tplText.Contains('coord-set.ps1 -State <word> (' + ($vocab -join ' ') + ')')) 'missing'
Assert-Coord 'S22 SKILL.md: the append-only section lists name Queue' ($skill.Contains('(`-Section` is `Queue`, `Decisions`, `Findings` or `Log`') -and $skill.Contains('Queue, Decisions, Findings and Log are append-only')) 'missing'
Assert-Coord 'S22 SKILL.md: the first-word rule for a cell set without -State is stated (a legacy cell is unclassified)' ($skill.Contains('the board classifies it by its first word') -and -not $skill.Contains('the board counts it as unclassified')) 'missing'
Assert-Coord 'S22 SKILL.md: carry-forward keeps the outcome line an open [after Q<n>] gate names, and rewrites [after HH:mm]' ($skill.Contains('the outcome line of every item an open item''s `[after Q<n>]` gate names') -and $skill.Contains('`[after <HH:mm>]` gate is rewritten')) 'missing'
$csSrc = [System.IO.File]::ReadAllText($ScriptPath)
Assert-Coord 'S22 coord-set.ps1: the header does not say the board counts a cell set without -State as unclassified' (-not ([regex]::Replace($csSrc, '\s+', ' ')).Contains('the board counts it as unclassified')) 'missing'

Write-Host '(S23) a BOM or a bidi mark in -Text; -Repo as the text of a Repo cell'
foreach ($cp in @(0xFEFF, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069)) {
    Invoke-Refused ('S23 U+{0:X4} inside a Status -Text is refused' -f $cp) @{ Track = 'T2'; Text = ('ok' + [char]$cp + 'ok') } -Why 'BOM character or a bidi mark'
}
Invoke-Refused 'S23 a bidi mark in a Model -Text is refused too (the check is on the text, whatever the cell)' @{ Track = 'T2'; Cell = 'Model'; Text = ('ok' + [char]0x202E + 'ok') } -Why 'BOM character or a bidi mark'
$bare = @($sample | ForEach-Object { $_ })
$bare[13] = '| T1 | alpha | local_1111 | Opus 5.5 high | C:' + [char]92 + 'Fx' + [char]92 + 'w1 | br-one | docs/** | | briefed 08:32 |'
$bare[16] = '| T1 | beta | local_1111 | | C:' + [char]92 + 'Fx' + [char]92 + 'w4 | br-x | b/** | | running |'
$p = New-Ledger $bare
$r = Invoke-Set @{ Track = 'T1'; Repo = 'beta'; Text = 'picked beta'; Ledger = $p }
Test-Changed 'S23 two rows named T1 with bare-name Repo cells: -Repo beta selects the row whose Repo cell is beta' $r $p $bare @{ 16 = ($bare[16] -replace 'running \|$', 'picked beta |') }
$p = New-Ledger $bare
$r = Invoke-Set @{ Track = 'T1'; Repo = ' alpha '; Text = 'picked alpha'; Ledger = $p }
Test-Changed 'S23 -Repo alpha (padded with spaces) selects the row whose Repo cell is alpha' $r $p $bare @{ 13 = ($bare[13] -replace 'briefed 08:32 \|$', 'picked alpha |') }
Invoke-Refused 'S23 a bare -Repo that no Repo cell holds is refused: no such row' @{ Track = 'T1'; Repo = 'gamma'; Text = 'x' } -Lines $bare -Why "no Tracks row 'T1' in gamma"
$bareDup = @($bare | ForEach-Object { $_ })
$bareDup[16] = $bare[16].Replace('| beta |', '| alpha |')
Invoke-Refused 'S23 a bare -Repo that two same-name rows hold is still refused as ambiguous' @{ Track = 'T1'; Repo = 'alpha'; Text = 'x' } -Lines $bareDup -Why 'share a repo|rename'
Invoke-Refused 'S23 control: no -Repo on two same-name bare-Repo rows is refused, naming how to pick' @{ Track = 'T1'; Text = 'x' } -Lines $bare -Why 'pass -Repo <full path, or the Repo cell''s text>'

Assert-Coord 'S0 the real index folder (COORD_INDEX_DIR as before this run, else $HOME/.claude/coordination) is byte-unchanged by this run' ((Get-CoordRealIndexDigest) -ceq $realIndexBefore) "before:`n$realIndexBefore`nafter:`n$(Get-CoordRealIndexDigest)"
Write-CoordUncheckedSummary

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host "Passed: $script:coordPass  Failed: $script:coordFail"
if ($script:coordFail -gt 0) { exit 1 }
exit 0
