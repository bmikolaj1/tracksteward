# Tests for scripts/coord-brief.ps1: a track's brief rendered from the ledger
# into a file, and checked before the pointer line is sent.
# Ported from the private coordinate toolkit (coord-brief.test.ps1), 2026-10-25.
# The script runs in this process (`& <script> ...`; its `exit` ends only the
# script and sets $LASTEXITCODE), always from inside a throwaway fixture repo
# and, except in B14 and B18 (which run from the main checkout of a fixture repo),
# with a scratch -Ledger: no call can reach a live ledger.
#
# What changed from the private suite (D2 of docs/plans/2026-10-18-script-port.md):
#   - the template's markers are the public {slot} format, one format and one
#     checker, so every row that looked for <<FILL: ...>> looks for {slot}
#   - the Coordinator line is the public `session "<name>"` form, and the
#     rendered brief names the coordinator by that name
#   - the Tracks table has the public Model column, the Baseline table the CI
#     column
#   - the notes folder is gone (the track's report goes to its own handovers/)
#   - the pointer line is the one the skill names: BRIEF: <path>; reply "ACK <track>" when read
#   - new rows: B1 checks the slots left are exactly the template's coordinator
#     slots, B7 refuses each of them one by one (and passes braces inside filled
#     text), B18 runs the whole public walkthrough in a fixture
#
#   B1  render: every slot the ledger answers is filled (coordinator name, track,
#       repo, branch, session, this file's path, the track repo's Baseline row
#       only, live rows of the same repo only, scope yours / not yours); every
#       other slot stays as the template has it; the identity line first; the
#       ledger byte-unchanged
#   B2  terminal rows: MERGED / DONE first word is terminal; NOT MERGED,
#       "running; round 1 DONE", "REPORT in", lower-case "merged", "DONEish"
#       and an empty Status are live
#   B3  -Track selection: case-insensitive; a name in two repos refuses without
#       -Repo and -Repo picks one (trailing separator, case ignored); a name
#       with only terminal rows, or no row, refuses; nothing written on refusal
#   B4  file names: the same Track in two repos of the same leaf name, and
#       `api/a` vs `api\a`, render into different files; -Check refuses the
#       other row's file by its identity line; `x:y` and `../../evil` stay
#       directly inside briefs/; `CON`, `..`, `---` and a cell holding `-->`
#       refuse; one name twice in one repo refuses as a ledger error
#   B5  a row with no Scope, or no Session: refused, nothing written
#   B6  an existing brief: refused without -Force, unchanged; -Force keeps the
#       old one as <file>.<stamp>.bak, a second -Force keeps both copies, and
#       an existing .bak of the same second (a decoy) is never overwritten
#   B7  -Check: names every slot left and exits 2; each coordinator slot of the
#       template, left alone, refuses by itself; a damaged slot (no closing
#       brace, no opening brace, spaces, other case) still refuses; braces inside
#       filled text do not; prints exactly one pointer line, and nothing else,
#       once none is left; no file: refused
#   B8  ledger problems: missing ledger, no Coordinator line, the template's
#       <name> placeholder, a ragged Tracks row: refused, nothing written; no
#       Baseline row for the repo: the Baseline slots stay, which -Check names
#   B9  the real ledger-template.md, its Coordinator placeholder filled and one
#       row added, renders (templates and the Coordinator-line parser cannot drift)
#   B10 the brief file's date comes from the ledger's file name
#   B11 a Baseline cell naming several shas (also upper case) is copied whole,
#       and the branch-from slot stays, never the first (oldest) sha; a
#       leaf-named Baseline row two live repos share leaves the slots for both
#       repos' tracks; with full-path rows only, each is used for its own repo
#       only; any Baseline Repo cell that is neither a clean leaf name nor a
#       rooted path (annotated, empty, unreadable) leaves the slots for every track
#   B12 another live row's Repo cell that is not one rooted path (a list,
#       `/c/x`, `Fx\x`, `C:x`, an annotation in parentheses): exit 2 naming the
#       row, never a raw error and never a silent drop
#   B13 a -Ledger inside a linked worktree (a stale copy), or under any
#       .claude/worktrees/ folder (a stray folder, or one whose .git file
#       dangles so git fails there), refuses
#   B14 without -Ledger: today's ledger at the fixture repo's canonical
#       location from its main checkout; refused from a linked worktree
#   B15 the fence: after every case above, the fixture repo's own
#       .claude/coordination (where a missing -Ledger would have written) holds
#       only what B14 put there
#   -Check also needs a ledger the scope guard reads. B7 runs on a registered
#   canonical ledger of today in a fixture repo (a scratch ledger no longer
#   passes -Check); B4 and B8 keep their scratch ledgers, they only check
#   refusals. The whole run uses a scratch COORD_INDEX_DIR:
#   B16 -Check prints the pointer for a registered, trusted, well-formed canonical
#       ledger; refuses one that is unregistered, not canonical for today (another
#       day, outside a repo, a stale worktree copy), tracked, behind a junction,
#       has a Tracks table that ends the file or starts after 1 MiB; passes a
#       900 KiB ledger; the index's own limits (8 entries, 64 KiB, torn last line,
#       case and separators, CRLF)
#   B17 the real index folder is byte-unchanged at the end of the run
#   B18 the public walkthrough end to end in a fixture: the ledger from the
#       real template, coord-log.ps1 -Register, a Baseline row and a Tracks row,
#       render, fill every slot the way the skill says, -Check prints the pointer
#   B19 the template and the skill agree with the script: the script fills only
#       slots the template has, the skill and the script header name the same call
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\scripts\coord-brief.test.ps1 [-ScriptPath <mutant copy of coord-brief.ps1>]
#       (a mutant copy needs coord-common.ps1 next to it and ..\templates\brief-template.md above it)
# Exit: 0 = all passed, 1 = a case failed.
# The mutants run against this suite are listed in the slice's PR body.
param([string]$ScriptPath = '')

$testsDir = Split-Path -Parent $PSScriptRoot
$fixturesDir = Join-Path $testsDir 'fixtures'
try { . (Join-Path $fixturesDir 'hook-test-fixture.ps1') } catch { Write-Error "could not load hook-test-fixture.ps1: $_"; exit 1 }
Clear-HookRunnerGitEnv
. (Join-Path $fixturesDir 'coord-test-fixture.ps1')
if (-not $ScriptPath) { $ScriptPath = Join-Path $coordScriptsDir 'coord-brief.ps1' }
$ScriptPath = [System.IO.Path]::GetFullPath($ScriptPath)
. (Join-Path $coordScriptsDir 'coord-common.ps1')
$ErrorActionPreference = 'Stop'

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('coord-brief-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory($root)
# Nothing in this run may reach the real index folder.
$realIndexBefore = Get-CoordRealIndexDigest
$null = New-CoordScratchIndex $root
# Every call runs from inside this repo, so a default ledger could only ever be
# the fixture's own.
$fxRepo = Join-Path $root 'fxrepo'
New-HookTestRepo $fxRepo
Set-CoordFile $fxRepo 'README.md' "readme`n"
Invoke-HookTestGit $fxRepo @('-c', 'core.autocrlf=false', 'add', '-A')
Invoke-HookTestGit $fxRepo @('-c', 'core.autocrlf=false', 'commit', '--quiet', '-m', 'base')
$fxCoord = Join-Path $fxRepo '.claude\coordination'

# ---- the real template, read the way the script reads it
$tplText = [System.IO.File]::ReadAllText((Join-Path $coordTemplatesDir 'brief-template.md'), [System.Text.Encoding]::UTF8)
$tplAll = @($tplText -split '\r\n|\r|\n')
$tplFences = @(0..($tplAll.Count - 1) | Where-Object { $tplAll[$_] -match '^```' })
$tplBlock = @($tplAll[($tplFences[0] + 1)..($tplFences[1] - 1)])
$slotRx = '\{([^{}\r\n]+)\}'
$tplSlots = @([regex]::Matches(($tplBlock -join "`n"), $slotRx) | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
# The slots the script fills (and the ones it fills only when the Baseline row
# is clear); {globs} is only in the LIVE TRACKS line, which the script builds whole.
$scriptSlots = @('coordinator session name', 'track', 'repo', 'branch', 'session name', 'absolute path of this file', 'your globs', 'globs not yours',
    'verified at', 'baseline repo', 'origin/main sha', 'list or none', 'branch-from sha', 'globs')
$baselineSlots = @('verified at', 'baseline repo', 'origin/main sha', 'list or none', 'branch-from sha')
$coordSlots = @($tplSlots | Where-Object { $scriptSlots -cnotcontains $_ })

function Get-OpenSlotNames([string]$Text) {
    return @($tplSlots | Where-Object { $Text.Contains('{' + $_ + '}') })
}
# Replaces the slots of $Names (default: every coordinator slot) with filler text
# that itself holds braces, as a glob or a command would.
function Set-SlotsFilled {
    param([string]$Text, [string[]]$Names = $coordSlots, [string]$With = 'filled, see src/{a,b}/** and ${x}')
    foreach ($n in $Names) { $Text = $Text.Replace('{' + $n + '}', $With) }
    return $Text
}

function Get-BriefId8([string]$Repo, [string]$Track) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(([System.IO.Path]::GetFullPath($Repo)).TrimEnd('\', '/').ToLowerInvariant() + "`n" + $Track)
    $h = $sha.ComputeHash($bytes)
    return (-join ($h[0..3] | ForEach-Object { $_.ToString('x2') }))
}

function Invoke-Brief {
    param([hashtable]$BriefArgs, [string]$Cwd = $fxRepo, [string]$Script = $ScriptPath)
    Push-Location -LiteralPath $Cwd
    try {
        $global:LASTEXITCODE = 0
        $out = @(& $Script @BriefArgs 2>&1 | ForEach-Object { [string]$_ })
        $code = $LASTEXITCODE
    }
    finally { Pop-Location }
    $lines = @($out | Where-Object { $_.Trim() })
    return [pscustomobject]@{ Code = $code; Out = ($out -join "`n"); Lines = $lines }
}

$coordLine = 'Coordinator: session "Coordinator Test", cwd `C:\Fx\alpha`.'
function New-Row([string]$Track, [string]$Repo, [string]$Session, [string]$Cwd, [string]$Branch, [string]$Scope, [string]$Pr, [string]$Status) {
    return "| $Track | $Repo | $Session | model-x high | $Cwd | $Branch | $Scope | $Pr | $Status |"
}
$rowsStd = @(
    (New-Row 'T1' 'C:\Fx\alpha' 's-one' 'C:\Fx\w1' 'br-one' 'docs/**, src/a.ps1' 'none yet' 'briefed'),
    (New-Row 'T2' 'C:\Fx\alpha' 's-two' 'C:\Fx\w2' 'br-two' 'src/b/**' '#5' 'running; round 1 DONE'),
    (New-Row 'T3' 'C:\Fx\alpha' 's-three' 'C:\Fx\w3' 'br-three' 'old/**' '#3 merged' 'MERGED abc1234 13:05'),
    (New-Row 'T4' 'C:\Fx\alpha' 's-four' 'C:\Fx\w4' 'br-four' 'done/**' 'none' 'DONE; report placed'),
    (New-Row 'T5' 'C:\Fx\alpha' 's-five' 'C:\Fx\w5' 'br-five' 'nm/**' '#6' 'NOT MERGED: conflicts'),
    (New-Row 'T6' 'C:\Fx\alpha' 's-six' 'C:\Fx\w6' 'br-six' 'rep/**' '#7' 'REPORT in'),
    (New-Row 'T7' 'C:\Fx\alpha' 's-seven' 'C:\Fx\w7' 'br-seven' 'low/**' '#8' 'merged per gh, not verified'),
    (New-Row 'T8' 'C:\Fx\alpha' 's-eight' 'C:\Fx\w8' 'br-eight' 'ish/**' '#9' 'DONEish'),
    (New-Row 'T9' 'C:\Fx\alpha' 's-nine' 'C:\Fx\w9' 'br-nine' 'empty/**' '#10' ''),
    (New-Row 'T1' 'C:\Fx\beta' 'c-one' 'C:\Fx\cw1' 'br-c' 'lib/**' 'none' 'REPORT in'),
    (New-Row 'noscope' 'C:\Fx\alpha' 's-ns' 'C:\Fx\wn' 'br-ns' '' 'none' 'briefed'),
    (New-Row 'nosession' 'C:\Fx\alpha' '' 'C:\Fx\wo' 'br-no' 'ns/**' 'none' 'briefed'),
    (New-Row 'api/a' 'C:\Fx\alpha' 's-aa' 'C:\Fx\wa' 'br-aa' 'aa/**' 'none' 'briefed'),
    (New-Row 'api\a' 'C:\Fx\alpha' 's-ab' 'C:\Fx\wb' 'br-ab' 'ab/**' 'none' 'briefed'),
    (New-Row 'CON' 'C:\Fx\alpha' 's-con' 'C:\Fx\wc' 'br-con' 'con/**' 'none' 'briefed'),
    (New-Row '..' 'C:\Fx\alpha' 's-dd' 'C:\Fx\wd' 'br-dd' 'dd/**' 'none' 'briefed'),
    (New-Row '---' 'C:\Fx\alpha' 's-dash' 'C:\Fx\wdash' 'br-dash' 'dash/**' 'none' 'briefed'),
    (New-Row 'x:y' 'C:\Fx\alpha' 's-xy' 'C:\Fx\wx' 'br-xy' 'xy/**' 'none' 'briefed'),
    (New-Row '../../evil' 'C:\Fx\alpha' 's-ev' 'C:\Fx\we' 'br-ev' 'ev/**' 'none' 'briefed'),
    (New-Row 'Done1' 'C:\Fx\alpha' 's-d1' 'C:\Fx\wd1' 'br-d1' 'd1/**' '#2' 'MERGED 1111111')
)
$baselineStd = @('| alpha | a1b2c3d (#66 day close) | none | yes | 08:25 snapshot |', '| beta | e4f5a6b (#28 slice one) | #12 release (parked) | yes | 08:26 snapshot |')
function New-BriefLedger {
    param([string]$Name, [string]$Date = '2026-10-15', [string[]]$Rows = $rowsStd, [switch]$NoCoordinator, [switch]$NoBaseline, [string]$LedgerDir = '',
        [string[]]$BaselineRows = $baselineStd, [string]$CoordinatorLine = $coordLine)
    $dir = if ($LedgerDir) { $LedgerDir } else { Join-Path $root $Name }
    [void][IO.Directory]::CreateDirectory($dir)
    $l = New-Object System.Collections.Generic.List[string]
    $l.Add("# Coordination ledger - $Date"); $l.Add('')
    if (-not $NoCoordinator) { $l.Add($CoordinatorLine) }
    $l.Add('Rule: append every event here BEFORE replying.'); $l.Add('')
    $l.Add('## Baseline'); $l.Add('')
    $l.Add('| Repo | origin/main | Open PRs | CI | Verified at |')
    $l.Add('|------|-------------|----------|----|-------------|')
    if (-not $NoBaseline) {
        foreach ($b in $BaselineRows) { $l.Add($b) }
    }
    $l.Add(''); $l.Add('## Tracks'); $l.Add('')
    $l.Add('<!-- Repo: the full path. -->'); $l.Add('')
    $l.Add('| Track | Repo | Session | Model | Cwd | Branch | Scope | PR | Status |')
    $l.Add('|-------|------|---------|-------|-----|--------|-------|----|--------|')
    foreach ($r in $Rows) { $l.Add($r) }
    $l.Add(''); $l.Add('## Merge slots'); $l.Add(''); $l.Add('1. (none)'); $l.Add('')
    $l.Add('## Log'); $l.Add(''); $l.Add('08:00 ledger created'); $l.Add('')
    $path = Join-Path $dir "$Date.md"
    [System.IO.File]::WriteAllText($path, ($l -join "`r`n"), $coordUtf8)
    return $path
}
function Get-FileHashHex([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Get-BriefFiles([string]$Ledger) {
    $d = Join-Path (Split-Path -Parent $Ledger) 'briefs'
    if (-not (Test-Path -LiteralPath $d)) { return @() }
    return @(Get-ChildItem -LiteralPath $d -File -Force | ForEach-Object { $_.Name } | Sort-Object)
}
function Get-BriefPath([string]$Ledger, [string]$Repo, [string]$Track, [string]$Safe, [string]$Date = '2026-10-15') {
    $leaf = Split-Path -Leaf $Repo
    return (Join-Path (Join-Path (Split-Path -Parent $Ledger) 'briefs') ("$Date-$leaf-$Safe-" + (Get-BriefId8 $Repo $Track) + '.md'))
}
function Read-Text([string]$Path) { if (Test-Path -LiteralPath $Path) { return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) } return '' }

# ---- -Check also needs a ledger the scope guard would read (canonical for
# today, registered, trusted, a well-formed Tracks table). The ledger of a
# fixture repo's main checkout is canonical; its index is the scratch
# COORD_INDEX_DIR set at the top of the run.
$todayStr = Get-CoordToday
function Set-IdxText([string]$Text) {
    $f = Get-CoordIndexPath
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $f))
    [System.IO.File]::WriteAllBytes($f, $coordUtf8.GetBytes($Text))
    return $f
}
# A ledger like New-BriefLedger's, at the canonical path of the main checkout of a
# new fixture repo $root\$Name; -Register adds it to the scratch index, -Commit
# gives the repo a commit (a linked worktree needs one).
function New-CanonBriefLedger {
    param([string]$Name, [string[]]$Rows = $rowsStd, [switch]$Register, [switch]$Commit)
    $repo = New-CoordCanonRepo $root $Name -Commit:$Commit
    $dir = Split-Path -Parent (Get-CoordLedgerPath $repo $todayStr)
    $path = New-BriefLedger $Name -Date $todayStr -Rows $Rows -LedgerDir $dir
    if ($Register) {
        $reg = Register-CoordLedger -Ledger $path -Date $todayStr
        if (-not $reg.Ok) { throw "fixture: could not register ${path}: $($reg.Error)" }
    }
    return $path
}
# Renders the brief of $Track and fills its slots; returns the brief's path.
function New-FilledBrief {
    param([string]$Ledger, [string]$Track = 'T5', [string]$Repo = 'C:\Fx\alpha', [string]$Date = $todayStr)
    $r = Invoke-Brief @{ Track = $Track; Repo = $Repo; Ledger = $Ledger }
    if ($r.Code -ne 0) { throw "fixture: could not render the brief: $($r.Out)" }
    $p = Get-BriefPath $Ledger $Repo $Track $Track $Date
    [System.IO.File]::WriteAllText($p, (Set-SlotsFilled (Read-Text $p) -Names $tplSlots), $coordUtf8)
    return $p
}
function Invoke-BriefCheck([string]$Ledger, [string]$Track = 'T5', [string]$Repo = 'C:\Fx\alpha') {
    return (Invoke-Brief @{ Track = $Track; Repo = $Repo; Check = $true; Ledger = $Ledger })
}
function Test-CheckPointer($R, [string]$Brief, [string]$Track = 'T5') {
    return ($R.Code -eq 0 -and $R.Lines.Count -eq 1 -and $R.Lines[0] -ceq ("BRIEF: $Brief; reply `"ACK $Track`" when read"))
}
function Test-CheckRefused($R) {
    return ($R.Code -eq 2 -and -not @($R.Lines | Where-Object { $_.StartsWith('BRIEF:') }).Count)
}

# ---------------------------------------------------------------- B1 render
Write-Host '(B1) render'
Assert-Coord 'B1 the template''s coordinator slots are found (the suite reads them from the real template)' ($coordSlots.Count -ge 10 -and $coordSlots -ccontains 'their words' -and $coordSlots -ccontains 'who goes first and why') ($coordSlots -join ' | ')
$L1 = New-BriefLedger 'b1'
$h0 = Get-FileHashHex $L1
$r = Invoke-Brief @{ Track = 'T1'; Repo = 'C:\Fx\alpha'; Ledger = $L1 }
$p1 = Get-BriefPath $L1 'C:\Fx\alpha' 'T1' 'T1'
Assert-Coord 'B1 exit 0' ($r.Code -eq 0) $r.Out
Assert-Coord 'B1 the file is <date>-<repo leaf>-<track>-<id8>.md in briefs\' (Test-Path -LiteralPath $p1) "want $p1; have $((Get-BriefFiles $L1) -join ', ')`n$($r.Out)"
Assert-Coord 'B1 the output names the file' ($r.Out.Contains($p1)) $r.Out
Assert-Coord 'B1 the ledger is byte-unchanged' ((Get-FileHashHex $L1) -eq $h0)
$t = Read-Text $p1
$tl = @($t -split "`r?`n")
Assert-Coord 'B1 first line is the identity line' ($tl[0] -ceq '<!-- coord-brief repo=C:\Fx\alpha track=T1 -->') $tl[0]
Assert-Coord 'B1 the template''s own prose is not copied' (-not $t.Contains('# Brief template') -and -not $t.Contains('Two kinds of slot') -and -not $t.Contains('```'))
Assert-Coord 'B1 the coordinator''s name from the Coordinator line' ($t.Contains('Coordination brief from Coordinator Test. The user''s request, quoted: "{their words}"')) $t
Assert-Coord 'B1 track, repo, branch, session' ($t.Contains('TRACK: T1, in C:\Fx\alpha, branch br-one, session s-one.')) $t
Assert-Coord 'B1 this file''s own path' ($t.Contains("THIS FILE: $p1. It is the brief of record")) $t
Assert-Coord 'B1 baseline of the track''s repo' ($t.Contains('BASELINE, verified 08:25 snapshot: alpha origin/main = a1b2c3d (#66 day close); open PRs: none; branch from a1b2c3d.')) $t
Assert-Coord 'B1 no baseline of another repo' (-not $t.Contains('e4f5a6b'))
$lt = ($tl | Where-Object { $_.StartsWith('LIVE TRACKS:') }) -join ''
Assert-Coord 'B1 LIVE TRACKS: YOU first' ($lt.StartsWith('LIVE TRACKS: (1) YOU, br-one;')) $lt
foreach ($want in @('(2) "s-two", branch br-two, owns src/b/**', '"s-five", branch br-five, owns nm/**', '"s-six"', '"s-seven"', '"s-eight"', '"s-nine"')) {
    Assert-Coord "B1 LIVE TRACKS holds $want" ($lt.Contains($want)) $lt
}
foreach ($not in @('"s-three"', '"s-four"', '"s-d1"', 'lib/**', '"c-one"')) {
    Assert-Coord "B1 LIVE TRACKS leaves out $not" (-not $lt.Contains($not)) $lt
}
Assert-Coord 'B1 FILE SCOPE yours is the row''s Scope' ($t.Contains('FILE SCOPE, yours: docs/**, src/a.ps1. NOT yours:')) $t
$ny = if ($t -match 'NOT yours: ([^\r\n]*)') { $Matches[1] } else { '' }
Assert-Coord 'B1 NOT yours holds the other live scopes' ($ny.Contains('src/b/**') -and $ny.Contains('nm/**') -and $ny.Contains('rep/**')) $ny
Assert-Coord 'B1 NOT yours leaves out terminal rows and other repos' (-not $ny.Contains('old/**') -and -not $ny.Contains('done/**') -and -not $ny.Contains('lib/**') -and -not $ny.Contains('docs/**')) $ny
$open = @(Get-OpenSlotNames $t)
$wantOpen = @($coordSlots | Where-Object { $_ -cne 'globs' } | Sort-Object)
Assert-Coord 'B1 the slots left are exactly the template''s coordinator slots' ((($open | Sort-Object) -join '|') -ceq ($wantOpen -join '|')) "left: $($open -join ' | ')`nwant: $($wantOpen -join ' | ')"
foreach ($k in $baselineSlots + @('coordinator session name', 'track', 'repo', 'branch', 'session name', 'absolute path of this file', 'your globs', 'globs not yours')) {
    Assert-Coord "B1 the slot {$k} is filled" (-not $t.Contains('{' + $k + '}'))
}
Assert-Coord 'B1 the second output line names every slot left' (($r.Lines | Where-Object { $_ -like 'COORD-BRIEF: fill*' }).Count -eq 1 -and ($wantOpen | Where-Object { -not $r.Out.Contains('{' + $_ + '}') }).Count -eq 0) $r.Out
Assert-Coord 'B1 the ACK line names the track and asks for no time' ($t.Contains('"ACK T1"') -and -not $t.Contains('ACK T1 <HH:mm>')) $t
Assert-Coord 'B1 the WIP line verbatim' ($t.Contains('WIP: <branch> @<sha>; brief: <path of this file>; uncommitted: <files or none>; open findings: <ids or none>; next: <one action>'))
Assert-Coord 'B1 the slot wait' ($t.Contains('("SLOT #<n> @<full sha>")') -and $t.Contains('A push after my'))
Assert-Coord 'B1 the FINDING shape' ($t.Contains('severity guess: live exposure | latent | cosmetic'))
Assert-Coord 'B1 no notes folder, no private marker format' (-not $t.Contains('side-session-notes') -and -not $t.Contains('<<FILL'))
Assert-Coord 'B1 nothing else in briefs\' ((Get-BriefFiles $L1).Count -eq 1) ((Get-BriefFiles $L1) -join ', ')

# ---------------------------------------------------------------- B2 terminal
Write-Host '(B2) terminal rows (through LIVE TRACKS)'
# Covered by B1's LIVE TRACKS rows: T3 MERGED, T4 DONE;, Done1 MERGED out;
# T2 "round 1 DONE", T5 NOT MERGED, T6 REPORT in, T7 lower-case merged, T8
# DONEish, T9 empty Status in. A terminal-only name refuses (B3).

# ---------------------------------------------------------------- B3 selection
Write-Host '(B3) -Track selection'
$L3 = New-BriefLedger 'b3'
$r = Invoke-Brief @{ Track = 'T1'; Ledger = $L3 }
Assert-Coord 'B3 a name in two repos refuses without -Repo' ($r.Code -eq 2 -and $r.Out.Contains('-Repo')) $r.Out
Assert-Coord 'B3 ... and writes nothing' ((Get-BriefFiles $L3).Count -eq 0)
$r = Invoke-Brief @{ Track = 't1'; Repo = 'c:\fx\BETA\'; Ledger = $L3 }
$pc = Get-BriefPath $L3 'C:\Fx\beta' 'T1' 'T1'
Assert-Coord 'B3 -Repo picks one (case, trailing separator ignored); -Track is case-insensitive' ($r.Code -eq 0 -and (Test-Path -LiteralPath $pc)) "$($r.Out)`nwant $pc; have $((Get-BriefFiles $L3) -join ', ')"
$tc = Read-Text $pc
Assert-Coord 'B3 the beta brief carries beta''s baseline and scope' ($tc.Contains('e4f5a6b') -and $tc.Contains('FILE SCOPE, yours: lib/**') -and -not $tc.Contains('a1b2c3d')) $tc
foreach ($c in @(@('T3', 'only a MERGED row'), @('Done1', 'only a MERGED row'), @('nope', 'no row'))) {
    $r = Invoke-Brief @{ Track = $c[0]; Ledger = $L3 }
    Assert-Coord "B3 -Track $($c[0]) ($($c[1])) refuses with exit 2" ($r.Code -eq 2 -and $r.Out.Contains('NOT WRITTEN')) $r.Out
}
$r = Invoke-Brief @{ Track = 'T2'; Repo = 'C:\Fx\beta'; Ledger = $L3 }
Assert-Coord 'B3 -Repo that narrows to nothing refuses' ($r.Code -eq 2) $r.Out
Assert-Coord 'B3 only the beta brief was written' ((Get-BriefFiles $L3).Count -eq 1) ((Get-BriefFiles $L3) -join ', ')

# ---------------------------------------------------------------- B4 names
Write-Host '(B4) file names and identity'
$L4 = New-BriefLedger 'b4'
$briefs4 = Join-Path (Split-Path -Parent $L4) 'briefs'
$ra = Invoke-Brief @{ Track = 'api/a'; Ledger = $L4 }
$rb = Invoke-Brief @{ Track = 'api\a'; Ledger = $L4 }
$pa = Get-BriefPath $L4 'C:\Fx\alpha' 'api/a' 'api-a'
$pb = Get-BriefPath $L4 'C:\Fx\alpha' 'api\a' 'api-a'
Assert-Coord 'B4 api/a and api\a both render' ($ra.Code -eq 0 -and $rb.Code -eq 0) "$($ra.Out)`n$($rb.Out)"
Assert-Coord 'B4 ... into two different files' ($pa -ne $pb -and (Test-Path -LiteralPath $pa) -and (Test-Path -LiteralPath $pb)) ((Get-BriefFiles $L4) -join ', ')
$L4b = New-BriefLedger 'b4b' -Rows @(
    (New-Row 'T1' 'C:\Fx\alpha' 's1' 'C:\w1' 'br1' 'a/**' 'none' 'briefed'), (New-Row 'T1' 'C:\Fy\alpha' 's2' 'C:\w2' 'br2' 'b/**' 'none' 'briefed'),
    (New-Row 'a-->b' 'C:\Fx\alpha' 's3' 'C:\w3' 'br3' 'c/**' 'none' 'briefed'), (New-Row 'dup' 'C:\Fx\alpha' 's4' 'C:\w4' 'br4' 'd/**' 'none' 'briefed'),
    (New-Row 'DUP' 'C:\Fx\alpha' 's5' 'C:\w5' 'br5' 'e/**' 'none' 'briefed'))
$r1 = Invoke-Brief @{ Track = 'T1'; Repo = 'C:\Fx\alpha'; Ledger = $L4b }
$r2 = Invoke-Brief @{ Track = 'T1'; Repo = 'C:\Fy\alpha'; Ledger = $L4b }
$q1 = Get-BriefPath $L4b 'C:\Fx\alpha' 'T1' 'T1'
$q2 = Get-BriefPath $L4b 'C:\Fy\alpha' 'T1' 'T1'
Assert-Coord 'B4 the same Track in two repos with the same leaf: two files, rendered' ($r1.Code -eq 0 -and $r2.Code -eq 0 -and $q1 -ne $q2 -and (Test-Path -LiteralPath $q1) -and (Test-Path -LiteralPath $q2)) "$($r1.Out)`n$($r2.Out)`n$((Get-BriefFiles $L4b) -join ', ')"
$r = Invoke-Brief @{ Track = 'a-->b'; Ledger = $L4b }
Assert-Coord 'B4 a Track cell holding --> refuses' ($r.Code -eq 2 -and $r.Out.Contains('-->')) $r.Out
$r = Invoke-Brief @{ Track = 'dup'; Ledger = $L4b }
Assert-Coord 'B4 two live rows of one name in ONE repo: refused as a ledger error, not "pass -Repo"' ($r.Code -eq 2 -and $r.Out.Contains('share a repo') -and -not $r.Out.Contains('pass -Repo')) $r.Out
Assert-Coord 'B4 ... only the two T1 briefs written' ((Get-BriefFiles $L4b).Count -eq 2) ((Get-BriefFiles $L4b) -join ', ')
# Put api\a's brief (no slots) where api/a's belongs: -Check must refuse it.
[System.IO.File]::WriteAllText($pa, (Set-SlotsFilled (Read-Text $pb)), $coordUtf8)
$r = Invoke-Brief @{ Track = 'api/a'; Check = $true; Ledger = $L4 }
Assert-Coord 'B4 -Check refuses another row''s file by its identity line' ($r.Code -eq 2 -and -not @($r.Lines | Where-Object { $_.StartsWith('BRIEF:') }).Count -and $r.Out.Contains('does not belong')) $r.Out
foreach ($c in @(@('x:y', 'x-y'), @('../../evil', '..-..-evil'))) {
    $r = Invoke-Brief @{ Track = $c[0]; Ledger = $L4 }
    $want = Get-BriefPath $L4 'C:\Fx\alpha' $c[0] $c[1]
    Assert-Coord "B4 '$($c[0])' -> '$($c[1])', directly inside briefs\" ($r.Code -eq 0 -and (Test-Path -LiteralPath $want) -and ((Split-Path -Parent $want) -eq $briefs4)) "$($r.Out)`nwant $want; have $((Get-BriefFiles $L4) -join ', ')"
}
Assert-Coord 'B4 nothing named evil outside briefs\' (@(Get-ChildItem -LiteralPath $root -Recurse -Force -Filter '*evil*' | Where-Object { (Split-Path -Parent $_.FullName) -ne $briefs4 }).Count -eq 0)
$before = (Get-BriefFiles $L4).Count
foreach ($c in @('CON', '..', '---')) {
    $r = Invoke-Brief @{ Track = $c; Ledger = $L4 }
    Assert-Coord "B4 Track '$c' refuses with exit 2" ($r.Code -eq 2 -and $r.Out.Contains('NOT WRITTEN')) $r.Out
}
Assert-Coord 'B4 ... and writes nothing' ((Get-BriefFiles $L4).Count -eq $before) ((Get-BriefFiles $L4) -join ', ')

# ---------------------------------------------------------------- B5 row fields
Write-Host '(B5) Scope and Session required'
$L5 = New-BriefLedger 'b5'
foreach ($c in @(@('noscope', 'Scope'), @('nosession', 'Session'))) {
    $r = Invoke-Brief @{ Track = $c[0]; Ledger = $L5 }
    Assert-Coord "B5 a row with no $($c[1]) refuses, naming it" ($r.Code -eq 2 -and $r.Out.Contains($c[1])) $r.Out
}
Assert-Coord 'B5 nothing written' ((Get-BriefFiles $L5).Count -eq 0) ((Get-BriefFiles $L5) -join ', ')

# ---------------------------------------------------------------- B6 overwrite
Write-Host '(B6) an existing brief'
$L6 = New-BriefLedger 'b6'
$p6 = Get-BriefPath $L6 'C:\Fx\alpha' 'T2' 'T2'
$r = Invoke-Brief @{ Track = 'T2'; Ledger = $L6 }
[System.IO.File]::WriteAllText($p6, 'hand-filled', $coordUtf8)
$r = Invoke-Brief @{ Track = 'T2'; Ledger = $L6 }
Assert-Coord 'B6 refused without -Force' ($r.Code -eq 2 -and $r.Out.Contains('-Force')) $r.Out
Assert-Coord 'B6 ... the hand-filled file unchanged' ([System.IO.File]::ReadAllText($p6) -ceq 'hand-filled')
$r = Invoke-Brief @{ Track = 'T2'; Force = $true; Ledger = $L6 }
Assert-Coord 'B6 -Force renders' ($r.Code -eq 0 -and (Read-Text $p6).Contains('{their words}')) $r.Out
function Get-Baks { return @(Get-ChildItem -LiteralPath (Split-Path -Parent $p6) -File -Filter ((Split-Path -Leaf $p6) + '.*.bak') | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) }
Assert-Coord 'B6 -Force keeps the old one as <file>.<stamp>.bak' (@(Get-Baks) -ccontains 'hand-filled') ((Get-BriefFiles $L6) -join ', ')
[System.IO.File]::WriteAllText($p6, 'second fill', $coordUtf8)
# Decoys at the stamps of this second and the next five force the -k suffix.
$now = [DateTime]::Now
$decoys = @()
foreach ($s in 0..5) {
    $dp = "$p6." + $now.AddSeconds($s).ToString('yyyyMMdd-HHmmss') + '.bak'
    if (-not (Test-Path -LiteralPath $dp)) { [System.IO.File]::WriteAllText($dp, 'decoy', $coordUtf8); $decoys += $dp }
}
$r = Invoke-Brief @{ Track = 'T2'; Force = $true; Ledger = $L6 }
$baks = @(Get-Baks)
Assert-Coord 'B6 a decoy of the same second forces a -1.bak (the -k suffix ran)' (@(Get-ChildItem -LiteralPath (Split-Path -Parent $p6) -File -Filter '*-1.bak').Count -ge 1) ((Get-BriefFiles $L6) -join ', ')
Assert-Coord 'B6 a second -Force keeps both earlier files' ($r.Code -eq 0 -and $baks -ccontains 'hand-filled' -and $baks -ccontains 'second fill') ((Get-BriefFiles $L6) -join ', ')
Assert-Coord 'B6 ... and overwrites no existing .bak of the same second (the -k suffix)' ($decoys.Count -ge 1 -and @($decoys | Where-Object { [System.IO.File]::ReadAllText($_) -cne 'decoy' }).Count -eq 0) ((Get-BriefFiles $L6) -join ', ')

# ---------------------------------------------------------------- B7 -Check
Write-Host '(B7) -Check'
# -Check also needs a registered canonical ledger of today (B16), so B7 runs on one.
$null = New-CoordScratchIndex $root
$L7 = New-CanonBriefLedger 'b7' -Register
$p7 = Get-BriefPath $L7 'C:\Fx\alpha' 'T5' 'T5' $todayStr
$r = Invoke-Brief @{ Track = 'T5'; Check = $true; Ledger = $L7 }
Assert-Coord 'B7 no brief file: refused' ($r.Code -eq 2 -and -not @($r.Lines | Where-Object { $_.StartsWith('BRIEF:') }).Count) $r.Out
$r = Invoke-Brief @{ Track = 'T5'; Ledger = $L7 }
$fresh7 = Read-Text $p7
$r = Invoke-Brief @{ Track = 'T5'; Check = $true; Ledger = $L7 }
Assert-Coord 'B7 slots left: exit 2' ($r.Code -eq 2) $r.Out
foreach ($m in $coordSlots | Where-Object { $_ -cne 'globs' }) {
    Assert-Coord "B7 ... names {$m}" ($r.Out.Contains('{' + $m + '}')) $r.Out
}
Assert-Coord 'B7 ... and prints no pointer line' (-not @($r.Lines | Where-Object { $_.StartsWith('BRIEF:') }).Count) $r.Out
# Each coordinator slot, left alone with every other one filled, refuses by itself.
foreach ($m in @($coordSlots | Where-Object { $_ -cne 'globs' })) {
    [System.IO.File]::WriteAllText($p7, (Set-SlotsFilled $fresh7 -Names @($coordSlots | Where-Object { $_ -cne $m })), $coordUtf8)
    $r = Invoke-Brief @{ Track = 'T5'; Check = $true; Ledger = $L7 }
    $named = @([regex]::Matches($r.Out, '\{[^{}]+\}') | ForEach-Object { $_.Value })
    Assert-Coord "B7 only {$m} left: exit 2 naming only it" ($r.Code -eq 2 -and ($named -join '|') -ceq ('{' + $m + '}') -and -not @($r.Lines | Where-Object { $_.StartsWith('BRIEF:') }).Count) $r.Out
}
$filled7 = Set-SlotsFilled $fresh7
[System.IO.File]::WriteAllText($p7, $filled7, $coordUtf8)
$h7 = Get-FileHashHex $p7
$r = Invoke-Brief @{ Track = 'T5'; Check = $true; Ledger = $L7 }
Assert-Coord 'B7 none left, braces and a $ inside the filled text: exit 0' ($r.Code -eq 0) $r.Out
Assert-Coord 'B7 ... exactly one line, the pointer line the skill names' ($r.Lines.Count -eq 1 -and $r.Lines[0] -ceq "BRIEF: $p7; reply `"ACK T5`" when read") ($r.Lines -join "`n")
Assert-Coord 'B7 -Check changes no file' ((Get-FileHashHex $p7) -eq $h7 -and (Read-Text $p7) -ceq $filled7)
# A slot damaged by an edit still refuses: a lost closing brace, a lost opening
# one, spaces inside, another case. (A group that closes on its line is another group: B20.)
foreach ($bad in @('{their words', 'their words}', '{ their   words }', '{THEIR WORDS}', '{Their Words')) {
    $damaged = Set-SlotsFilled ($fresh7.Replace('{their words}', $bad)) -Names @($coordSlots | Where-Object { $_ -cne 'their words' })
    [System.IO.File]::WriteAllText($p7, $damaged, $coordUtf8)
    $r = Invoke-Brief @{ Track = 'T5'; Check = $true; Ledger = $L7 }
    Assert-Coord "B7 a damaged slot '$bad' still refuses, naming a slot" ((Test-CheckRefused $r) -and $r.Out.Contains('slot(s) left')) $r.Out
}
# ... but ordinary words of the same kind in filled text do not.
[System.IO.File]::WriteAllText($p7, (Set-SlotsFilled $fresh7 -With 'quote their words as they came {see below}'), $coordUtf8)
$r = Invoke-Brief @{ Track = 'T5'; Check = $true; Ledger = $L7 }
Assert-Coord 'B7 filled text that holds the words of a slot, with no brace next to them, passes' (Test-CheckPointer $r $p7) $r.Out

# ---------------------------------------------------------------- B8 ledger problems
Write-Host '(B8) ledger problems'
$r = Invoke-Brief @{ Track = 'T1'; Ledger = (Join-Path $root 'nowhere\2026-10-15.md') }
Assert-Coord 'B8 a missing ledger refuses' ($r.Code -eq 2) $r.Out
Assert-Coord 'B8 ... and creates no folder' (-not (Test-Path -LiteralPath (Join-Path $root 'nowhere')))
$L8 = New-BriefLedger 'b8a' -NoCoordinator
$r = Invoke-Brief @{ Track = 'T2'; Ledger = $L8 }
Assert-Coord 'B8 no Coordinator line refuses' ($r.Code -eq 2 -and $r.Out.Contains('Coordinator')) $r.Out
Assert-Coord 'B8 ... nothing written' ((Get-BriefFiles $L8).Count -eq 0)
$L8 = New-BriefLedger 'b8d' -CoordinatorLine 'Coordinator: session "<name>", cwd `<path>`.'
$r = Invoke-Brief @{ Track = 'T2'; Ledger = $L8 }
Assert-Coord 'B8 the ledger template''s <name> placeholder in the Coordinator line refuses, naming it' ($r.Code -eq 2 -and $r.Out.Contains('<name>') -and (Get-BriefFiles $L8).Count -eq 0) $r.Out
$L8 = New-BriefLedger 'b8e' -CoordinatorLine 'Coordinator: session `local_abc` ("Old Form", cwd `C:\x`).'
$r = Invoke-Brief @{ Track = 'T2'; Ledger = $L8 }
Assert-Coord 'B8 the private Coordinator line form (an id in backticks) is not the public `session "<name>"`: refused' ($r.Code -eq 2 -and $r.Out.Contains('Coordinator') -and (Get-BriefFiles $L8).Count -eq 0) $r.Out
$L8 = New-BriefLedger 'b8b' -Rows @('| T2 | C:\Fx\alpha | s | m | w | br | x/** | none |')
$r = Invoke-Brief @{ Track = 'T2'; Ledger = $L8 }
Assert-Coord 'B8 a ragged Tracks row refuses' ($r.Code -eq 2 -and $r.Out.Contains('cells')) $r.Out
Assert-Coord 'B8 ... nothing written' ((Get-BriefFiles $L8).Count -eq 0)
$L8 = New-BriefLedger 'b8c' -NoBaseline
$r = Invoke-Brief @{ Track = 'T2'; Ledger = $L8 }
$p8 = Get-BriefPath $L8 'C:\Fx\alpha' 'T2' 'T2'
$t8 = Read-Text $p8
Assert-Coord 'B8 no Baseline row: renders with the Baseline slots left' ($r.Code -eq 0 -and (@($baselineSlots | Where-Object { -not $t8.Contains('{' + $_ + '}') }).Count -eq 0)) "$($r.Out)`n$t8"
$r = Invoke-Brief @{ Track = 'T2'; Check = $true; Ledger = $L8 }
Assert-Coord 'B8 ... which -Check names' ($r.Code -eq 2 -and $r.Out.Contains('{origin/main sha}')) $r.Out

# ---------------------------------------------------------------- B9 real ledger template
Write-Host '(B9) the real ledger-template.md'
$ltText = [System.IO.File]::ReadAllText((Join-Path $coordTemplatesDir 'ledger-template.md'), [System.Text.Encoding]::UTF8)
$ltText = $ltText.Replace('session "<name>"', 'session "Template Coord"')
$ltLines = [System.Collections.Generic.List[string]]@($ltText -split "`r?`n")
$hi = $ltLines.FindIndex([Predicate[string]] { param($x) $x -match '^\|\s*Track\s*\|' })
$ltLines.Insert($hi + 2, (New-Row 'TT' 'C:\Fx\alpha' 's-tt' 'C:\Fx\wt' 'br-tt' 't/**' 'none' 'briefed'))
$d9 = Join-Path $root 'b9'
[void][IO.Directory]::CreateDirectory($d9)
$L9 = Join-Path $d9 '2026-10-15.md'
[System.IO.File]::WriteAllText($L9, ($ltLines -join "`r`n"), $coordUtf8)
$r = Invoke-Brief @{ Track = 'TT'; Ledger = $L9 }
$p9 = Get-BriefPath $L9 'C:\Fx\alpha' 'TT' 'TT'
Assert-Coord 'B9 renders from the template ledger with one row' ($r.Code -eq 0 -and (Test-Path -LiteralPath $p9)) "hi=$hi`n$($r.Out)"
Assert-Coord 'B9 ... the template''s own Coordinator line parses' ((Read-Text $p9).Contains('Coordination brief from Template Coord.'))
Assert-Coord 'B9 ... its empty Baseline gives the Baseline slots' (@($baselineSlots | Where-Object { -not (Read-Text $p9).Contains('{' + $_ + '}') }).Count -eq 0)
$ltRaw = [System.IO.File]::ReadAllText((Join-Path $coordTemplatesDir 'ledger-template.md'), [System.Text.Encoding]::UTF8)
$rawLines = [System.Collections.Generic.List[string]]@($ltRaw -split "`r?`n")
$rawLines.Insert($rawLines.FindIndex([Predicate[string]] { param($x) $x -match '^\|\s*Track\s*\|' }) + 2, (New-Row 'TT' 'C:\Fx\alpha' 's-tt' 'C:\Fx\wt' 'br-tt' 't/**' 'none' 'briefed'))
$L9b = Join-Path (Join-Path $root 'b9b') '2026-10-15.md'
Set-CoordTextFile $L9b ($rawLines -join "`r`n")
$r = Invoke-Brief @{ Track = 'TT'; Ledger = $L9b }
Assert-Coord 'B9 the template ledger as it stands (its Coordinator line still holds <name>) is refused for the placeholder' ($r.Code -eq 2 -and $r.Out.Contains('<name>') -and (Get-BriefFiles $L9b).Count -eq 0) $r.Out

# ---------------------------------------------------------------- B10 date
Write-Host '(B10) the date in the file name'
$L10 = New-BriefLedger 'b10' -Date '2026-09-30'
$r = Invoke-Brief @{ Track = 'T2'; Ledger = $L10 }
Assert-Coord 'B10 the ledger''s date, not today''s' ($r.Code -eq 0 -and (Test-Path -LiteralPath (Get-BriefPath $L10 'C:\Fx\alpha' 'T2' 'T2' '2026-09-30'))) "$($r.Out)`n$((Get-BriefFiles $L10) -join ', ')"
$L10b = New-BriefLedger 'b10b' -Date 'not-a-date'
$r = Invoke-Brief @{ Track = 'T2'; Ledger = $L10b }
Assert-Coord 'B10 a ledger file name that is no date: today''s' ($r.Code -eq 0 -and (Test-Path -LiteralPath (Get-BriefPath $L10b 'C:\Fx\alpha' 'T2' 'T2' $todayStr))) "$($r.Out)`n$((Get-BriefFiles $L10b) -join ', ')"

# ---------------------------------------------------------------- B11 baseline cell
Write-Host '(B11) a Baseline cell with several shas'
$L11 = New-BriefLedger 'b11' -BaselineRows @('| alpha | 3c4d5e6 (#60 day close); 7f8e9d0 after #61; 2b3a4c5 after #65 | none | yes | 08:21 |')
$r = Invoke-Brief @{ Track = 'T2'; Ledger = $L11 }
$t11 = Read-Text (Get-BriefPath $L11 'C:\Fx\alpha' 'T2' 'T2')
Assert-Coord 'B11 the cell is copied whole' ($r.Code -eq 0 -and $t11.Contains('origin/main = 3c4d5e6 (#60 day close); 7f8e9d0 after #61; 2b3a4c5 after #65')) $t11
Assert-Coord 'B11 no "branch from" is guessed; the {branch-from sha} slot stays' (-not $t11.Contains('branch from 3c4d5e6') -and $t11.Contains('{branch-from sha}')) $t11
$L11b = New-BriefLedger 'b11b' -BaselineRows @('| alpha | 3c4d5e6 (#60); 2B3A4C5 after #65 | none | yes | 08:21 |')
$r = Invoke-Brief @{ Track = 'T2'; Ledger = $L11b }
$t11b = Read-Text (Get-BriefPath $L11b 'C:\Fx\alpha' 'T2' 'T2')
Assert-Coord 'B11 an upper-case second sha still counts: the slot, not the oldest' ($r.Code -eq 0 -and -not $t11b.Contains('branch from 3c4d5e6') -and $t11b.Contains('{branch-from sha}')) $t11b
# Two repos with the leaf "alpha": a leaf-named Baseline row fits neither.
$twoRows = @((New-Row 'T1' 'C:\Fx\alpha' 's1' 'C:\w1' 'br1' 'a/**' 'none' 'briefed'), (New-Row 'T1' 'C:\Fy\alpha' 's2' 'C:\w2' 'br2' 'b/**' 'none' 'briefed'))
$L11c = New-BriefLedger 'b11c' -Rows $twoRows -BaselineRows @('| alpha | 1111111 | none | yes | 08:21 |', '| C:\Fy\alpha | 2222222 | none | yes | 08:22 |')
$r1 = Invoke-Brief @{ Track = 'T1'; Repo = 'C:\Fx\alpha'; Ledger = $L11c }
$r2 = Invoke-Brief @{ Track = 'T1'; Repo = 'C:\Fy\alpha'; Ledger = $L11c }
$tx = Read-Text (Get-BriefPath $L11c 'C:\Fx\alpha' 'T1' 'T1')
$ty = Read-Text (Get-BriefPath $L11c 'C:\Fy\alpha' 'T1' 'T1')
Assert-Coord 'B11 a leaf-named Baseline row shared by two live repos is not used: the Baseline slots stay' ($r1.Code -eq 0 -and $tx.Contains('{origin/main sha}') -and -not $tx.Contains('1111111')) $tx
Assert-Coord 'B11 ... and, by the freeze, for every track: the full-path repo gets the slots too' ($r2.Code -eq 0 -and $ty.Contains('{origin/main sha}') -and -not $ty.Contains('1111111') -and -not $ty.Contains('2222222')) $ty
$L11d = New-BriefLedger 'b11d' -BaselineRows @('| alpha (C:\Work\alpha) | 1234567 | none | yes | 08:21 |')
$r = Invoke-Brief @{ Track = 'T2'; Ledger = $L11d }
Assert-Coord 'B11 a Baseline Repo cell holding a path in parentheses: the Baseline slots stay (the freeze), not an unexpected error' ($r.Code -eq 0 -and (Read-Text (Get-BriefPath $L11d 'C:\Fx\alpha' 'T2' 'T2')).Contains('{origin/main sha}')) $r.Out
# The freeze: one unreadable or annotated Baseline Repo cell leaves the slots; an
# older clean row never wins.
foreach ($bad in @('alpha (C:\Work\alpha)', 'alpha (main)', '')) {
    $Lf = New-BriefLedger ('b11f-' + [Guid]::NewGuid().ToString('N').Substring(0, 6)) -BaselineRows @('| alpha | 3c4d5e6 | none | yes | 08:21 |', "| $bad | 2b3a4c5 | none | yes | 09:40 |")
    $r = Invoke-Brief @{ Track = 'T2'; Ledger = $Lf }
    $tf = Read-Text (Get-BriefPath $Lf 'C:\Fx\alpha' 'T2' 'T2')
    Assert-Coord "B11 a clean row beside an unreadable Repo cell '$bad': the Baseline slots stay, never the clean row's sha" ($r.Code -eq 0 -and $tf.Contains('{origin/main sha}') -and -not $tf.Contains('3c4d5e6')) $tf
}
$Lg = New-BriefLedger 'b11g' -BaselineRows @('| alpha | 3c4d5e6 | none | yes | 08:21 |', '| beta | e4f5a6b | none | yes | 08:22 |', '| C:\Other\Thing | 1234567 | none | yes | 08:23 |')
$r = Invoke-Brief @{ Track = 'T2'; Ledger = $Lg }
Assert-Coord 'B11 clean rows of other repos (a leaf, a full path) do not trip the freeze' ($r.Code -eq 0 -and (Read-Text (Get-BriefPath $Lg 'C:\Fx\alpha' 'T2' 'T2')).Contains('branch from 3c4d5e6')) $r.Out
$L11e = New-BriefLedger 'b11e' -Rows $twoRows -BaselineRows @('| C:\Fx\alpha | 1111111 | none | yes | 08:21 |', '| C:\Fy\alpha | 2222222 | none | yes | 08:22 |')
$r2 = Invoke-Brief @{ Track = 'T1'; Repo = 'C:\Fy\alpha'; Ledger = $L11e }
$ty = Read-Text (Get-BriefPath $L11e 'C:\Fy\alpha' 'T1' 'T1')
Assert-Coord 'B11 full-path Baseline rows: each used for its own repo only' ($r2.Code -eq 0 -and $ty.Contains('branch from 2222222') -and -not $ty.Contains('1111111')) $ty
$L11h = New-BriefLedger 'b11h' -BaselineRows @('| alpha | 3c4d5e6 |  | yes |  |')
$r = Invoke-Brief @{ Track = 'T2'; Ledger = $L11h }
$th = Read-Text (Get-BriefPath $L11h 'C:\Fx\alpha' 'T2' 'T2')
Assert-Coord 'B11 a Baseline row with an empty Open PRs and Verified at cell fills the others and leaves those two slots' ($r.Code -eq 0 -and $th.Contains('{list or none}') -and $th.Contains('{verified at}') -and $th.Contains('origin/main = 3c4d5e6') -and $th.Contains('branch from 3c4d5e6')) $th

# ---------------------------------------------------------------- B12 bad Repo cell
Write-Host '(B12) a Repo cell that is no usable path'
$L12 = New-BriefLedger 'b12' -Rows @((New-Row 'T2' 'C:\Fx\alpha' 's' 'C:\w' 'br' 'a/**' 'none' 'briefed'), (New-Row 'X' 'C:\Work\a, C:\Work\b' 's' 'C:\wx' 'bx' 'x/**' 'none' 'running'))
$r = Invoke-Brief @{ Track = 'T2'; Ledger = $L12 }
Assert-Coord 'B12 another row''s bad Repo cell: refused with exit 2, naming the row, not a raw error' ($r.Code -eq 2 -and $r.Out.Contains('NOT WRITTEN') -and $r.Out.Contains("'X'")) $r.Out
Assert-Coord 'B12 ... nothing written' ((Get-BriefFiles $L12).Count -eq 0)
foreach ($bad in @('/c/Fx/alpha', 'Fx\alpha', 'C:\Fx\alpha (main)', 'C:alpha', 'C:\a; C:\b')) {
    $Lb = New-BriefLedger ('b12-' + [Guid]::NewGuid().ToString('N').Substring(0, 6)) -Rows @((New-Row 'T2' 'C:\Fx\alpha' 's' 'C:\w' 'br' 'a/**' 'none' 'briefed'), (New-Row 'X' $bad 's' 'C:\wx' 'bx' 'x/**' 'none' 'running'))
    $r = Invoke-Brief @{ Track = 'T2'; Ledger = $Lb }
    Assert-Coord "B12 a sibling Repo cell '$bad' refuses (never silently dropped)" ($r.Code -eq 2 -and $r.Out.Contains("'X'") -and (Get-BriefFiles $Lb).Count -eq 0) $r.Out
}

# ---------------------------------------------------------------- B15 fence, before B14 writes there
Write-Host '(B15) the fence'
Assert-Coord 'B15 no call so far wrote into the fixture repo''s own .claude\coordination' (-not (Test-Path -LiteralPath $fxCoord))

# ---------------------------------------------------------------- B14 default ledger
Write-Host '(B14) without -Ledger'
$today = $todayStr
$own = New-BriefLedger 'b14src' -Date $today
[void][IO.Directory]::CreateDirectory($fxCoord)
$L14 = Join-Path $fxCoord "$today.md"
Copy-Item -LiteralPath $own -Destination $L14
$wt = Join-Path $root 'fxwt'
Invoke-HookTestGit $fxRepo @('worktree', 'add', '--quiet', '-b', 'side', $wt)
$r = Invoke-Brief @{ Track = 'T2' } -Cwd $wt
Assert-Coord 'B14 from a linked worktree: refused' ($r.Code -eq 2 -and $r.Out.Contains('-Ledger')) $r.Out
Assert-Coord 'B14 ... nothing written' (-not (Test-Path -LiteralPath (Join-Path $fxCoord 'briefs')))
$staleDir = Join-Path $wt '.claude\coordination'
[void][IO.Directory]::CreateDirectory($staleDir)
Copy-Item -LiteralPath $own -Destination (Join-Path $staleDir "$today.md")
$r = Invoke-Brief @{ Track = 'T2'; Ledger = (Join-Path $staleDir "$today.md") } -Cwd $fxRepo
Assert-Coord 'B13 a -Ledger inside a linked worktree (the stale copy) refuses' ($r.Code -eq 2 -and $r.Out.Contains('linked worktree')) $r.Out
Assert-Coord 'B13 ... nothing written' (-not (Test-Path -LiteralPath (Join-Path $staleDir 'briefs')))
$strayDir = Join-Path $fxRepo '.claude\worktrees\stray\.claude\coordination'
[void][IO.Directory]::CreateDirectory($strayDir)
Copy-Item -LiteralPath $own -Destination (Join-Path $strayDir "$today.md")
$r = Invoke-Brief @{ Track = 'T2'; Ledger = (Join-Path $strayDir "$today.md") } -Cwd $fxRepo
Assert-Coord 'B13 a ledger under .claude\worktrees\ of the main checkout (a stray worktree folder) refuses' ($r.Code -eq 2 -and $r.Out.Contains('worktree')) $r.Out
$dang = Join-Path $fxRepo '.claude\worktrees\dang'
Invoke-HookTestGit $fxRepo @('worktree', 'add', '--quiet', '-b', 'dang', $dang)
$dangDir = Join-Path $dang '.claude\coordination'
[void][IO.Directory]::CreateDirectory($dangDir)
Copy-Item -LiteralPath $own -Destination (Join-Path $dangDir "$today.md")
[IO.Directory]::Delete((Join-Path $fxRepo '.git\worktrees\dang'), $true)
$r = Invoke-Brief @{ Track = 'T2'; Ledger = (Join-Path $dangDir "$today.md") } -Cwd $fxRepo
Assert-Coord 'B13 a worktree folder whose .git file dangles (git exits 128 there) still refuses' ($r.Code -eq 2 -and $r.Out.Contains('worktree') -and -not (Test-Path -LiteralPath (Join-Path $dangDir 'briefs'))) $r.Out
$r = Invoke-Brief @{ Track = 'T2' } -Cwd $fxRepo
Assert-Coord 'B14 from the main checkout: today''s ledger there' ($r.Code -eq 0 -and (Test-Path -LiteralPath (Get-BriefPath $L14 'C:\Fx\alpha' 'T2' 'T2' $today))) "$($r.Out)`n$((Get-BriefFiles $L14) -join ', ')"
Assert-Coord 'B15 the fixture coordination folder holds only the ledger and briefs\' (((@(Get-ChildItem -LiteralPath $fxCoord -Force | ForEach-Object { $_.Name }) | Sort-Object) -join ',') -ceq "$today.md,briefs")

# ---------------------------------------------------------------- B16 -Check and the scope guard index
Write-Host '(B16) -Check refuses a ledger the scope guard would not read'
# Every row has the same ledger content (New-BriefLedger's) and a control: the
# ledger passes -Check before (or after) the one change that makes it refuse, so
# a refusal here is that change's.
$fillLine = '10:00 filler line of the append-only log, long enough to pad the file out 0123456789abcdef' + "`r`n"

# B16a: the passing case.
$null = New-CoordScratchIndex $root
$LA = New-CanonBriefLedger 'b16a' -Register
$pA = New-FilledBrief $LA
$idxA = Get-CoordIndexPath
$hIdx = Get-CoordFileHashOrAbsent $idxA
$hLed = Get-FileHashHex $LA
$hBrief = Get-FileHashHex $pA
$r = Invoke-BriefCheck $LA
Assert-Coord 'B16 a registered, trusted, well-formed canonical ledger of today: -Check prints exactly the pointer line' (Test-CheckPointer $r $pA) $r.Out
Assert-Coord 'B16 ... and -Check changes neither the index, the ledger nor the brief' ((Get-CoordFileHashOrAbsent $idxA) -eq $hIdx -and (Get-FileHashHex $LA) -eq $hLed -and (Get-FileHashHex $pA) -eq $hBrief)

# B16b: not registered.
$null = New-CoordScratchIndex $root
$LB = New-CanonBriefLedger 'b16b'
$pB = New-FilledBrief $LB
$r = Invoke-BriefCheck $LB
Assert-Coord 'B16 a ledger that is not in the index (no index at all): refused, no pointer line, the message names -Register' ((Test-CheckRefused $r) -and $r.Out.Contains('-Register')) $r.Out
$reg = Register-CoordLedger -Ledger $LB -Date $todayStr
$r = Invoke-BriefCheck $LB
Assert-Coord 'B16 ... the same ledger once registered passes (the refusal was the missing registration)' ($reg.Ok -and (Test-CheckPointer $r $pB)) "reg=$($reg.Ok) $($r.Out)"

# B16c: listed in today's index by hand, but not canonical for today.
$null = New-CoordScratchIndex $root
$repoC = New-CoordCanonRepo $root 'b16c'
$dirC = Split-Path -Parent (Get-CoordLedgerPath $repoC $todayStr)
$LC = New-BriefLedger 'b16c' -Date '2026-01-01' -LedgerDir $dirC
$pC = New-FilledBrief $LC -Date '2026-01-01'
$null = Set-IdxText ($LC + "`n")
$r = Invoke-BriefCheck $LC
Assert-Coord 'B16 the main checkout''s ledger of another day, listed in today''s index: refused (not canonical for today), no pointer line' (Test-CheckRefused $r) $r.Out
$null = New-CoordScratchIndex $root
$LC2 = New-BriefLedger 'b16c2' -Date $todayStr
$pC2 = New-FilledBrief $LC2
$null = Set-IdxText ($LC2 + "`n")
$r = Invoke-BriefCheck $LC2
Assert-Coord 'B16 a scratch ledger outside any repo, listed in the index: refused (not canonical), no pointer line' ((Test-CheckRefused $r) -and $r.Out.Contains('canonical ledger')) $r.Out

# B16s: the stale copy a tool makes in a linked worktree (already refused by the worktree rule).
$null = New-CoordScratchIndex $root
$LS = New-CanonBriefLedger 'b16s' -Register -Commit
$pS = New-FilledBrief $LS
$wtS = Join-Path $root 'b16s-wt'
New-HookTestWorktree -Repo (Join-Path $root 'b16s') -Path $wtS -Branch 'b16s-wt'
$staleS = Join-Path $wtS ".claude\coordination\$todayStr.md"
Set-CoordTextFile $staleS ([System.IO.File]::ReadAllText($LS))
Set-CoordTextFile (Join-Path $wtS (".claude\coordination\briefs\" + (Split-Path -Leaf $pS))) ([System.IO.File]::ReadAllText($pS))
$null = Set-IdxText ($staleS + "`n")
$r = Invoke-BriefCheck $staleS
Assert-Coord 'B16 the stale copy in a linked worktree, listed in the index: refused, no pointer line' ((Test-CheckRefused $r) -and $r.Out.Contains('worktree')) $r.Out

# B16d: tracked in the repo.
$null = New-CoordScratchIndex $root
$LD = New-CanonBriefLedger 'b16d' -Register
$pD = New-FilledBrief $LD
$repoD = Join-Path $root 'b16d'
$rCtl = Invoke-BriefCheck $LD
Invoke-HookTestGit $repoD @('-c', 'core.autocrlf=false', 'add', '-A')
Invoke-HookTestGit $repoD @('-c', 'core.autocrlf=false', 'commit', '--quiet', '-m', 'ship a ledger')
$r = Invoke-BriefCheck $LD
Assert-Coord 'B16 a registered ledger that is committed to the repo: refused, no pointer line (it passed before the commit)' ((Test-CheckPointer $rCtl $pD) -and (Test-CheckRefused $r)) "before: $($rCtl.Out)`nafter: $($r.Out)"

# B16e: .claude\coordination behind a junction.
$null = New-CoordScratchIndex $root
$LE = New-CanonBriefLedger 'b16e' -Register
$pE = New-FilledBrief $LE
$rCtl = Invoke-BriefCheck $LE
$coordE = Split-Path -Parent $LE
$tgtE = Join-Path $root 'b16e-target'
[void][IO.Directory]::CreateDirectory($tgtE)
Move-Item -LiteralPath $coordE -Destination (Join-Path $tgtE 'coordination')
if (New-CoordJunction $coordE (Join-Path $tgtE 'coordination')) {
    $r = Invoke-BriefCheck $LE
    Remove-CoordJunction $coordE
    Assert-Coord 'B16 a registered ledger whose .claude\coordination is a junction: refused, no pointer line (it passed as a plain folder)' ((Test-CheckPointer $rCtl $pE) -and (Test-CheckRefused $r)) "before: $($rCtl.Out)`nafter: $($r.Out)"
}
else { Write-CoordUnchecked 'B16 junctioned coordination' 'could not create a junction' }

# B16f: a Tracks table that ends the file, no line after it.
$null = New-CoordScratchIndex $root
$LF = New-CanonBriefLedger 'b16f' -Register
$pF = New-FilledBrief $LF
$full = [System.IO.File]::ReadAllText($LF)
$cut = $full.IndexOf("`r`n`r`n## Merge slots")
$rCtl = Invoke-BriefCheck $LF
[System.IO.File]::WriteAllText($LF, $full.Substring(0, [Math]::Max($cut, 0)) + "`r`n", $coordUtf8)
$r = Invoke-BriefCheck $LF
Assert-Coord 'B16 a Tracks table with nothing after it before end of file (malformed for the guard): refused, no pointer line (the full ledger passed)' ($cut -gt 0 -and (Test-CheckPointer $rCtl $pF) -and (Test-CheckRefused $r)) "cut=$cut before: $($rCtl.Out)`nafter: $($r.Out)"
[System.IO.File]::WriteAllText($LF, $full, $coordUtf8)
$r = Invoke-BriefCheck $LF
Assert-Coord 'B16 ... and with the rest of the ledger put back it passes again' (Test-CheckPointer $r $pF) $r.Out

# B16g: the Tracks heading lies after the 1 MiB the guard reads.
$null = New-CoordScratchIndex $root
$LG = New-CanonBriefLedger 'b16g' -Register
$pG = New-FilledBrief $LG
$full = [System.IO.File]::ReadAllText($LG)
$rCtl = Invoke-BriefCheck $LG
$padded = $full.Replace("`r`n## Tracks`r`n", "`r`n" + ($fillLine * 13500) + "## Tracks`r`n")
[System.IO.File]::WriteAllText($LG, $padded, $coordUtf8)
$r = Invoke-BriefCheck $LG
Assert-Coord 'B16 a Tracks heading after the first 1 MiB: refused, no pointer line (it passed with the table at the top)' ($padded.Length -gt 1048576 -and (Test-CheckPointer $rCtl $pG) -and (Test-CheckRefused $r)) "length=$($padded.Length) before: $($rCtl.Out)`nafter: $($r.Out)"

# B16h: a 900 KiB ledger with Tracks near the top is read.
$null = New-CoordScratchIndex $root
$LH = New-CanonBriefLedger 'b16h' -Register
$pH = New-FilledBrief $LH
$full = [System.IO.File]::ReadAllText($LH)
$big = $full.Replace('08:00 ledger created', '08:00 ledger created' + "`r`n" + ($fillLine * 10200))
[System.IO.File]::WriteAllText($LH, $big, $coordUtf8)
$r = Invoke-BriefCheck $LH
Assert-Coord 'B16 a ledger of about 900 KiB with Tracks near the top: -Check prints the pointer line' ($big.Length -gt 900000 -and (Test-CheckPointer $r $pH)) "length=$($big.Length) $($r.Out)"

# B16i: the index's own limits, on one ledger.
$null = New-CoordScratchIndex $root
$LI = New-CanonBriefLedger 'b16i'
$pI = New-FilledBrief $LI
$fakeI = @(1..8 | ForEach-Object { "C:\Seed\r$_\.claude\coordination\$todayStr.md" })
$many64 = ((1..6600 | ForEach-Object { 'C:\Seed\a.md' }) -join "`n") + "`n"
$idxCases = @(
    @('only this ledger', ($LI + "`n"), $true),
    @('this ledger with CRLF line ends', ($LI + "`r`n"), $true),
    @('this ledger spelled in upper case with / separators', ($LI.ToUpperInvariant().Replace('\', '/') + "`n"), $true),
    @('seven other ledgers, then this one (the eighth)', ((($fakeI[0..6] + $LI) -join "`n") + "`n"), $true),
    @('this one first, then eight others (nine entries)', (((@($LI) + $fakeI) -join "`n") + "`n"), $true),
    @('eight other ledgers, then this one (the ninth)', ((($fakeI + $LI) -join "`n") + "`n"), $false),
    @('one path repeated past 64 KiB, then this ledger', ($many64 + $LI + "`n"), $false),
    @('this ledger as a last line with no newline (torn)', ($LI), $false),
    @('another ledger only', ($fakeI[0] + "`n"), $false)
)
foreach ($c in $idxCases) {
    $null = Set-IdxText $c[1]
    $r = Invoke-BriefCheck $LI
    $ok = if ($c[2]) { Test-CheckPointer $r $pI } else { Test-CheckRefused $r }
    Assert-Coord "B16 index holding $($c[0]): -Check $(if ($c[2]) { 'prints the pointer line' } else { 'refuses, no pointer line' })" $ok $r.Out
}

# B16j: the briefed row's Repo cell must be a local full path the guard can
# bind. Control: the same ledger with the row on C:\ passes (B16a).
$null = New-CoordScratchIndex $root
$uncRepo = '\\localhost\share\alpha'
$rowsUnc = @($rowsStd | ForEach-Object { if ($_ -like '| T5 *') { $_.Replace('C:\Fx\alpha', $uncRepo) } else { $_ } })
$LU = New-CanonBriefLedger 'b16u' -Rows $rowsUnc -Register
$pU = New-FilledBrief $LU -Repo $uncRepo
$r = Invoke-BriefCheck $LU -Repo $uncRepo
Assert-Coord 'B16 a briefed row whose Repo cell is a UNC path: -Check refuses with "not a full path on a local fixed drive", no pointer line' ((Test-CheckRefused $r) -and $r.Out.Contains('not a full path on a local fixed drive') -and (Test-Path -LiteralPath $pU)) $r.Out
$rowsBare = @($rowsStd | ForEach-Object { if ($_ -like '| T5 *') { $_.Replace('C:\Fx\alpha', 'alpha') } else { $_ } })
$LBare = New-CanonBriefLedger 'b16bare' -Rows $rowsBare -Register
$r = Invoke-Brief @{ Track = 'T5'; Check = $true; Ledger = $LBare }
Assert-Coord 'B16 a briefed row whose Repo cell is a bare folder name: -Check refuses, no pointer line (the rooted-path rule refuses it, naming the row)' ((Test-CheckRefused $r) -and $r.Out.Contains('not one rooted path')) $r.Out

# ---------------------------------------------------------------- B18 the public walkthrough
Write-Host '(B18) the public walkthrough, end to end'
# The coordinator's day as the skill tells it: the ledger from the template, the
# ledger registered, a Baseline row and a Tracks row, the brief rendered, every
# slot filled, -Check, the pointer line.
$null = New-CoordScratchIndex $root
$wRepo = New-CoordCanonRepo $root 'walk-repo' -Commit
$wLedger = Get-CoordLedgerPath $wRepo $todayStr
$wl = $ltText.Replace('# Coordination ledger - YYYY-MM-DD', "# Coordination ledger - $todayStr")
$wLines = [System.Collections.Generic.List[string]]@($wl -split "`r?`n")
$wb = $wLines.FindIndex([Predicate[string]] { param($x) $x -match '^\|\s*Repo\s*\|\s*origin/main' })
$wLines.Insert($wb + 2, '| walk-repo | 1a2b3c4 (day start) | none | none | 09:00 snapshot |')
$wt2 = $wLines.FindIndex([Predicate[string]] { param($x) $x -match '^\|\s*Track\s*\|' })
$wLines.Insert($wt2 + 2, (New-Row 'walk' $wRepo 'walk-session' $wRepo 'walk-branch' 'scripts/**, tests/**' 'none yet' 'working'))
$wLines.Insert($wt2 + 3, (New-Row 'sibling' $wRepo 'sibling-session' $wRepo 'sib-branch' 'docs/**' 'none yet' 'working'))
Set-CoordTextFile $wLedger ($wLines -join "`r`n")
$logScript = Join-Path $coordScriptsDir 'coord-log.ps1'
Push-Location -LiteralPath $wRepo
try {
    $global:LASTEXITCODE = 0
    $regOut = @(& $logScript -Register 2>&1 | ForEach-Object { [string]$_ })
    $regCode = $LASTEXITCODE
}
finally { Pop-Location }
Assert-Coord 'B18 coord-log.ps1 -Register registers the new day''s ledger' ($regCode -eq 0 -and ($regOut -join "`n").Contains('COORD-LOG REGISTERED')) ($regOut -join "`n")
$r = Invoke-Brief @{ Track = 'walk' } -Cwd $wRepo
$pw = Get-BriefPath $wLedger $wRepo 'walk' 'walk' $todayStr
Assert-Coord 'B18 the brief renders from the main checkout with no -Ledger' ($r.Code -eq 0 -and (Test-Path -LiteralPath $pw)) $r.Out
$tw = Read-Text $pw
Assert-Coord 'B18 ... with the Baseline row of the repo, its one sha as the branch-from sha, and the sibling' ($tw.Contains('BASELINE, verified 09:00 snapshot: walk-repo origin/main = 1a2b3c4 (day start); open PRs: none; branch from 1a2b3c4.') -and $tw.Contains('"sibling-session", branch sib-branch, owns docs/**')) $tw
$r = Invoke-Brief @{ Track = 'walk'; Check = $true } -Cwd $wRepo
Assert-Coord 'B18 -Check refuses it while the slots are open, naming them' ($r.Code -eq 2 -and $r.Out.Contains('{their words}')) $r.Out
# Filled the way the skill says: the SUPERSEDES line and the CROSS-REPO block
# deleted, every other coordinator slot replaced.
$keep = @($tw -split "`r?`n" | Where-Object { -not $_.StartsWith('SUPERSEDES:') -and -not $_.Contains('{target repo}') -and -not $_.Contains('{its merge command}') })
[System.IO.File]::WriteAllText($pw, (Set-SlotsFilled ($keep -join "`r`n")), $coordUtf8)
$r = Invoke-Brief @{ Track = 'walk'; Check = $true } -Cwd $wRepo
Assert-Coord 'B18 once every slot is filled and the two optional blocks deleted, -Check prints exactly the pointer line the skill names' (Test-CheckPointer $r $pw 'walk') "$($r.Out)`nleft: $((Get-OpenSlotNames (Read-Text $pw)) -join ' | ')"

# ---------------------------------------------------------------- B19 template, script and skill agree
Write-Host '(B19) template, script and skill'
$scriptText = [System.IO.File]::ReadAllText($ScriptPath, [System.Text.Encoding]::UTF8)
$skillText = [System.IO.File]::ReadAllText((Join-Path (Join-Path (Split-Path -Parent $coordScriptsDir) 'skills\coordinate') 'SKILL.md'), [System.Text.Encoding]::UTF8)
$fillKeysInScript = @()
if ($scriptText -match '(?s)\$fillKeys = @\((.*?)\)') { $fillKeysInScript = @([regex]::Matches($Matches[1], "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }) }
Assert-Coord 'B19 the script''s own list of the slots it fills is the one this suite assumes' ((($fillKeysInScript | Sort-Object) -join '|') -ceq (($scriptSlots | Sort-Object) -join '|')) "script: $($fillKeysInScript -join ' | ')`nsuite: $($scriptSlots -join ' | ')"
Assert-Coord 'B19 every slot the script fills by name is a slot of the template' (@($fillKeysInScript | Where-Object { $tplSlots -cnotcontains $_ }).Count -eq 0) (($fillKeysInScript | Where-Object { $tplSlots -cnotcontains $_ }) -join ', ')
Assert-Coord 'B19 the template''s intro and the skill name the script' ($tplText.Contains('scripts/coord-brief.ps1') -and $skillText.Contains('scripts/coord-brief.ps1'))
$skillCall = if ($skillText -match '(?m)`(& "\$\{CLAUDE_PLUGIN_ROOT\}/scripts/coord-brief\.ps1" -Track [^`]*)`') { $Matches[1] } else { '<none>' }
$headerCall = ($skillCall -replace [regex]::Escape('${CLAUDE_PLUGIN_ROOT}'), '<plugin root>')
$headerCall = $headerCall -replace " -Check\z", ''
Assert-Coord 'B19 the skill''s call is the script header''s call, with the plugin root spelled out' ($skillCall -ne '<none>' -and $scriptText.Contains('#   ' + ($headerCall -replace "'<track>'", "'<name>'"))) "skill: $skillCall"
Assert-Coord 'B19 the skill''s pointer line is the one -Check prints' ($skillText.Contains('BRIEF: {absolute path}; reply "ACK {track}" when read'))
Assert-Coord 'B19 the script no longer knows the private marker or the private ACK form' (-not $scriptText.Contains('<<FILL') -and -not $scriptText.Contains('side-session-notes'))

# ---------------------------------------------------------------- B20 review round 1
Write-Host '(B20) damaged slots of one word, a stripped brief, edited templates, odd cells'
$null = New-CoordScratchIndex $root
$L20 = New-CanonBriefLedger 'b20' -Register
$r = Invoke-Brief @{ Track = 'T5'; Repo = 'C:\Fx\alpha'; Ledger = $L20 }
$p20 = Get-BriefPath $L20 'C:\Fx\alpha' 'T5' 'T5' $todayStr
$fresh20 = Read-Text $p20
$others20 = @($coordSlots | Where-Object { $_ -cne 'HH:MM' -and $_ -cne 'location' })
foreach ($bad in @('{hh:mm}', '{HH:MM', 'HH:MM}', '{ HH:MM }')) {
    $damaged = Set-SlotsFilled ($fresh20.Replace('{HH:MM}', $bad)) -Names $others20 -With 'plain filler'
    $damaged = $damaged.Replace('{location}', 'x')
    [System.IO.File]::WriteAllText($p20, $damaged, $coordUtf8)
    $r = Invoke-BriefCheck $L20
    Assert-Coord "B20 a damaged one-word slot '$bad' still refuses, naming a slot" ((Test-CheckRefused $r) -and $r.Out.Contains('slot(s) left')) $r.Out
}
foreach ($bad in @('{Location', 'location}', '{ location }')) {
    $damaged = Set-SlotsFilled ($fresh20.Replace('{location}', $bad)) -Names $others20 -With 'plain filler'
    $damaged = $damaged.Replace('{HH:MM}', 'x')
    [System.IO.File]::WriteAllText($p20, $damaged, $coordUtf8)
    $r = Invoke-BriefCheck $L20
    Assert-Coord "B20 a damaged one-word slot '$bad' still refuses, naming a slot" ((Test-CheckRefused $r) -and $r.Out.Contains('slot(s) left')) $r.Out
}
$long20 = @($coordSlots | Where-Object { $_ -like 'old brief path*' })[0]
$damaged = Set-SlotsFilled ($fresh20.Replace('{' + $long20 + '}', '{old brief path, and what was carried')) -Names @($coordSlots | Where-Object { $_ -cne $long20 }) -With 'plain filler'
[System.IO.File]::WriteAllText($p20, $damaged, $coordUtf8)
$r = Invoke-BriefCheck $L20
Assert-Coord 'B20 a long slot cut short after its first words still refuses, naming a slot' ((Test-CheckRefused $r) -and $r.Out.Contains('slot(s) left')) $r.Out
# A glob that starts like a script slot name is not a slot.
[System.IO.File]::WriteAllText($p20, (Set-SlotsFilled $fresh20 -With 'see src/{branch-a,b}/** and {repo-x,y}'), $coordUtf8)
$r = Invoke-BriefCheck $L20
Assert-Coord 'B20 {branch-a,b} and {repo-x,y} (globs) are not taken for the script''s {branch} and {repo} slots' (Test-CheckPointer $r $p20) $r.Out
# ... nor are groups that close on their line and start or end like a coordinator slot.
[System.IO.File]::WriteAllText($p20, (Set-SlotsFilled $fresh20 -With 'see lib/{location,auth}/** and src/{auth,location}/** and {HH:MM-x} and {their words, other} and {location.reload()}'), $coordUtf8)
$r = Invoke-BriefCheck $L20
Assert-Coord 'B20 lib/{location,auth}/**, src/{auth,location}/**, {HH:MM-x}, {their words, other} in filled text are not damaged slots' (Test-CheckPointer $r $p20) $r.Out
# A slot opened and left open still refuses when another brace follows it on its line.
$unclosed20 = Set-SlotsFilled ($fresh20.Replace('{which session}', '{which session, filled, see src/{a,b}/**')) -Names @($coordSlots | Where-Object { $_ -cne 'which session' }) -With 'plain filler'
[System.IO.File]::WriteAllText($p20, $unclosed20, $coordUtf8)
$r = Invoke-BriefCheck $L20
Assert-Coord 'B20 an unclosed {which session followed by a glob group on its line still refuses, naming it' ((Test-CheckRefused $r) -and $r.Out.Contains('{which session}')) $r.Out
# Text on other lines is other text: code whose closing brace starts a later line.
$multi20 = "see: return `$location`r`n}`r`nand @{`r`n  HH:MM = 1`r`n}"
[System.IO.File]::WriteAllText($p20, (Set-SlotsFilled $fresh20 -With $multi20), $coordUtf8)
$r = Invoke-BriefCheck $L20
Assert-Coord 'B20 filled code with `location` before a line that starts with } and `{` before a line that starts HH:MM is not a damaged slot' (Test-CheckPointer $r $p20) $r.Out
# The brief cut down to a few lines does not pass: every fixed line must be there.
$filled20 = Set-SlotsFilled $fresh20
[System.IO.File]::WriteAllText($p20, (($filled20 -split "`r?`n")[0..2] -join "`r`n"), $coordUtf8)
$r = Invoke-BriefCheck $L20
Assert-Coord 'B20 a brief cut down to its first lines: refused, naming the lost lines' ((Test-CheckRefused $r) -and $r.Out.Contains('lost') -and $r.Out.Contains('WIP')) $r.Out
[System.IO.File]::WriteAllText($p20, (@($filled20 -split "`r?`n" | Where-Object { -not $_.StartsWith('WIP:') }) -join "`r`n"), $coordUtf8)
$r = Invoke-BriefCheck $L20
Assert-Coord 'B20 a brief with the WIP line deleted: refused' ((Test-CheckRefused $r) -and $r.Out.Contains('WIP')) $r.Out
$noOptional20 = @($fresh20 -split "`r?`n" | Where-Object { -not $_.StartsWith('SUPERSEDES:') -and -not $_.StartsWith('CROSS-REPO') -and -not $_.StartsWith('and merge with') }) -join "`r`n"
Assert-Coord 'B20 (control) the optional lines are really gone from the text under test' ($noOptional20 -notmatch 'SUPERSEDES|CROSS-REPO|and merge with' -and $noOptional20.Contains('WIP:'))
[System.IO.File]::WriteAllText($p20, (Set-SlotsFilled $noOptional20), $coordUtf8)
$r = Invoke-BriefCheck $L20
Assert-Coord 'B20 ... and with the SUPERSEDES line and the CROSS-REPO block deleted, -Check passes' (Test-CheckPointer $r $p20) $r.Out
# A fixed line rewritten away (here LIVE TRACKS) is refused too, like a deleted one.
[System.IO.File]::WriteAllText($p20, (Set-SlotsFilled ($fresh20.Replace('LIVE TRACKS:', 'LIVE ROWS:'))), $coordUtf8)
$r = Invoke-BriefCheck $L20
Assert-Coord 'B20 a fixed line whose label was rewritten (LIVE TRACKS -> LIVE ROWS): refused, naming it' ((Test-CheckRefused $r) -and $r.Out.Contains('LIVE TRACKS')) $r.Out

# Cells that would break the brief.
$L20b = New-BriefLedger 'b20b' -Rows @(
    (New-Row 'nobr' 'C:\Fx\alpha' 's-nb' 'C:\w' '' 'a/**' 'none' 'briefed'),
    (New-Row 'q"t' 'C:\Fx\alpha' 's-q' 'C:\w' 'br-q' 'a/**' 'none' 'briefed'),
    (New-Row 'brc' 'C:\Fx\alpha' 's-brc' 'C:\w' 'br-brc' '{branch}, src/{a,b}/**' 'none' 'briefed'))
$r = Invoke-Brief @{ Track = 'nobr'; Ledger = $L20b }
Assert-Coord 'B20 a row with no Branch refuses, naming it' ($r.Code -eq 2 -and $r.Out.Contains('Branch') -and (Get-BriefFiles $L20b).Count -eq 0) $r.Out
$r = Invoke-Brief @{ Track = 'q"t'; Ledger = $L20b }
Assert-Coord 'B20 a Track cell holding a double quote refuses (it would break the pointer line)' ($r.Code -eq 2 -and $r.Out.Contains('double quote') -and (Get-BriefFiles $L20b).Count -eq 0) $r.Out
$r = Invoke-Brief @{ Track = 'brc'; Ledger = $L20b }
$tb = Read-Text (Get-BriefPath $L20b 'C:\Fx\alpha' 'brc' 'brc')
Assert-Coord 'B20 a ledger value that holds {slot} text is copied, never expanded' ($r.Code -eq 0 -and $tb.Contains('FILE SCOPE, yours: {branch}, src/{a,b}/**. NOT yours:') -and $tb.Contains('TRACK: brc, in C:\Fx\alpha, branch br-brc,')) $tb

# An edited template: a refusal, never a quiet wrong fill. Each row runs a copy of
# the script with its own templates\ folder.
$tplN = 0
function New-TemplateVariant([string]$Text) {
    $script:tplN++
    $dir = Join-Path $root "tplv$script:tplN"
    [void][IO.Directory]::CreateDirectory((Join-Path $dir 'scripts'))
    [void][IO.Directory]::CreateDirectory((Join-Path $dir 'templates'))
    Copy-Item -LiteralPath $ScriptPath -Destination (Join-Path $dir 'scripts\coord-brief.ps1')
    Copy-Item -LiteralPath (Join-Path $coordScriptsDir 'coord-common.ps1') -Destination (Join-Path $dir 'scripts\coord-common.ps1')
    [System.IO.File]::WriteAllText((Join-Path $dir 'templates\brief-template.md'), $Text, $coordUtf8)
    return (Join-Path $dir 'scripts\coord-brief.ps1')
}
$Lt = New-BriefLedger 'b20t'
$tplNL = ($tplText -replace "`r`n", "`n")
$variants = @(
    @('the real template, unchanged (control)', $tplNL, $true, ''),
    @('an empty fenced block', ($tplNL -replace '(?s)```\n.*\n```\n', ('```' + "`n" + '```' + "`n")), $false, 'empty fenced block'),
    @('the real template with CRLF line ends', ($tplNL -replace "`n", "`r`n"), $true, ''),
    @('no fenced block', ($tplNL -replace '(?m)^```.*\n', ''), $false, 'fence'),
    @('a second fenced block', ($tplNL + "`n" + '```text' + "`nextra`n" + '```' + "`n"), $false, 'fence'),
    @('no LIVE TRACKS: line', $tplNL.Replace('LIVE TRACKS:', 'LIVE ROWS:'), $false, 'LIVE TRACKS'),
    @('the {track} slot renamed', $tplNL.Replace('{track}', '{trk}'), $false, '{track}'),
    @('the {your globs} slot removed', $tplNL.Replace('{your globs}', 'everything'), $false, '{your globs}')
)
foreach ($v in $variants) {
    $sp = New-TemplateVariant $v[1]
    $r = Invoke-Brief @{ Track = 'T2'; Ledger = $Lt; Force = $true } -Script $sp
    $okRun = if ($v[2]) { $r.Code -eq 0 } else { $r.Code -eq 2 -and $r.Out.Contains($v[3]) }
    Assert-Coord "B20 template variant: $($v[0]) -> $(if ($v[2]) { 'renders' } else { 'refused, naming ' + $v[3] })" $okRun $r.Out
}

# ---------------------------------------------------------------- B17 the real index folder
# After every row that registers a ledger (B18's coord-log.ps1 -Register, B20), as the header says.
Write-Host '(B17) the real index folder'
Assert-Coord 'B17 the real index folder (COORD_INDEX_DIR as before this run, else $HOME/.claude/coordination: its listing and the SHA-256 of every file outside sessions/, or still absent) is unchanged by this run' ((Get-CoordRealIndexDigest) -ceq $realIndexBefore) "before:`n$realIndexBefore`nafter:`n$(Get-CoordRealIndexDigest)"

Write-CoordUncheckedSummary
Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Passed: $script:coordPass  Failed: $script:coordFail"
if ($script:coordFail -gt 0) { exit 1 }
exit 0
