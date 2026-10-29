# Tests for hooks/coord-scope-guard.ps1, the coordinator's track scope guard.
# Ported from the private coordinate toolkit's guard suite (2026-10-28), with
# the plugin layout (hooks/ beside scripts/), the hooks.json launcher and the
# new S6 rows (anchor policy, off switch, name-only Session cells, no ledger).
#
# The hook runs as a CHILD PROCESS (`powershell.exe -NoProfile
# -ExecutionPolicy Bypass -File <hook>`) with a hook event as JSON on stdin, the
# way Claude Code starts it. A row asserts the exit code, stdout and stderr:
#   allow  exit 0, nothing on stdout, nothing on stderr
#   warn   exit 0, stdout is exactly ONE JSON object whose only property is
#          systemMessage and whose text starts "coord-scope-guard: ", stderr empty
#   block  exit 2, the refusal on stderr, stdout empty
#
# Every run sets COORD_INDEX_DIR to a scratch folder and COORD_TODAY to a fixed
# date (2026-03-05; yesterday is 2026-03-04), so no run can reach the runner's
# real ~/.claude/coordination. The suite snapshots the real folder (names,
# lengths, SHA-256) first and compares it at the end (group Z).
#
# Fixture (all under one scratch root in %TEMP%, no link in its path):
#   repo A  main checkout + linked worktrees A1 (branch a1-branch) and A2
#           (a2-branch); its ledger is the canonical <A>\.claude\coordination\<date>.md
#   repo B  main checkout + linked worktree B1 (b1-branch); no ledger unless a row says so
#   repos C, D (only for the four-ledger runtime row), repo U (unlisted repo),
#   a plain folder (not a repo), an outside folder.
# A ledger is built by Format-Ledger from row objects; its Tracks header is the
# live one: Track | Repo | Session | Model | Cwd | Branch | Scope | PR | Status.
#
# Groups:
#   G0 fixture sanity (the hook file exists, the fixture is what the rows assume)
#   G1 binding: scope, other trees, repo B, rows that do not bind, sequential
#      rows, ambiguity, the cross-repo Session rule and what grants nothing
#   G2 anchors: SessionStart anchor file, desktop and claude -w layouts, bound
#      after a later binding, no anchor file, cross-repo track, different
#      tokens, detached HEAD and unlisted branch (Cwd fallback), duplicate rows,
#      started-outside limit and warning, 4 KiB + 1 anchor, no removal by age
#   G3 paths: file_path / notebook_path, relative, new nested folder, case and
#      separators incl. '!' exclusion, outside every tree, always-allowed folders
#   G4 aliases: junction, symlinked file, new file under a link, temp link
#   G5 index, trust, size: no index (zero git calls), torn / duplicate / past
#      64 KiB entries, tracked and junctioned ledger, 16 / 78 / 900 KiB, Tracks
#      past 1 MiB and unterminated, a row appended between two calls
#   G6 canonical ledger: stale worktree copy alone and beside the canonical one,
#      UNC entry, ledger not named for the day
#   G8 failure and output: malformed, unreadable, git failure after binding,
#      branch keyed not folder, bracketed path runs its own copy, non-events
#   G9 runtime: four 78 KiB ledgers, 9-entry index, sleeping stubs, deadline,
#      Get-CoordMainRoot bounded, a child holding stdout
#   G10 midnight (COORD_TODAY)
#   G11 fixes and stated limits found by the private toolkit's review rounds
#   S6 plugin wiring: hooks.json shape and launcher (space, brackets, backtick; a
#      sibling folder is not run), the ..\scripts layout, the off switch, the
#      anchor policy and pruning, name-only Session cells, no registered ledger
#   Z  the real index folder is byte-unchanged
#
# NOT here (other suites own them): Register-CoordLedger, Test-CoordLedgerTrusted
# called directly, Test-CoordInScope staying case-sensitive, Get-CoordIndexedLedgers
# helper cases, coord-log.ps1 -Register, coord-brief.ps1 -Check (coord-common,
# coord-log and coord-brief tests). The hook `timeout` path (a stalled local
# open) has no fixture; the hook header says so.
#
# Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\hooks\coord-scope-guard.test.ps1 [-ScriptPath <mutant copy>]
#       (a mutant copy needs coord-common.ps1 where the hook looks for it:
#        ..\scripts\ beside the hook's folder)
# Exit 0 = every row passed (SKIPPED rows are printed and counted apart); exit 1 = a row failed.
#       -Group "S6*,G1*" runs only the groups whose name matches one of the wildcards (a mutant run
#       needs only the groups its mutation can change; the full suite is the gate).
param([string]$ScriptPath = '', [string]$Group = '')

$ErrorActionPreference = 'Continue'
# Isolation from the repo this runner lives in: see hook-test-fixture.ps1.
try { . (Join-Path $PSScriptRoot '..\fixtures\hook-test-fixture.ps1') } catch { Write-Error "could not load hook-test-fixture.ps1: $_"; exit 1 }
Clear-HookRunnerGitEnv
. (Join-Path $PSScriptRoot '..\fixtures\coord-test-fixture.ps1')
foreach ($v in 'CLAUDE_PROJECT_DIR', 'COORD_INDEX_DIR', 'COORD_TODAY', 'TRACKSTEWARD_GUARD') { Remove-Item -LiteralPath ('Env:\' + $v) -ErrorAction SilentlyContinue }

if (-not $ScriptPath) { $ScriptPath = Join-Path $PSScriptRoot '..\..\hooks\coord-scope-guard.ps1' }
$hookPath = [System.IO.Path]::GetFullPath($ScriptPath)
$utf8 = New-Object System.Text.UTF8Encoding($false)
$psExe = (Get-Command powershell.exe -CommandType Application | Select-Object -First 1).Source
$realGit = (Get-Command git -CommandType Application | Select-Object -First 1).Source

$root = [System.IO.Path]::GetFullPath((Join-Path ([System.IO.Path]::GetTempPath()) ('csg-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))))
[void][IO.Directory]::CreateDirectory($root)
$passed = 0
$failed = 0
$skipped = 0
function Report([bool]$Ok, [string]$Name, [string]$Detail = '') {
    if ($Ok) { $script:passed++; Write-Host "  PASS: $Name" }
    else { $script:failed++; Write-Host "  FAIL: $Name -- $Detail" }
}
# A row that could not run on this machine: listed (tests/run.ps1 forwards the
# UNCHECKED lines), never counted as passed.
function Skip([string]$Name, [string]$Reason) {
    $script:skipped++
    Write-Host "  UNCHECKED: $Name ($Reason)"
}
function Get-Tail([string]$Text) {
    $t = ([string]$Text -replace "`r?`n", ' | ').Trim()
    if ($t.Length -gt 500) { $t = '...' + $t.Substring($t.Length - 500) }
    return $t
}
$groupFilter = @($Group -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
function Invoke-Group([string]$Name, [scriptblock]$Body) {
    if ($script:groupFilter.Count -gt 0) {
        $wanted = $false
        foreach ($g in $script:groupFilter) { if ($Name -like $g) { $wanted = $true } }
        if (-not $wanted) { return }
    }
    Write-Host "---- $Name"
    try { & $Body } catch { Report $false "$Name crashed" ($_.Exception.Message + ' @ ' + $_.InvocationInfo.PositionMessage) }
}

# ---------------------------------------------------------------------------
# Real index folder: snapshot now, compare in group Z.
# ---------------------------------------------------------------------------
function Get-DirSnapshot([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir)) { return 'absent' }
    $items = @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object FullName)
    $lines = foreach ($i in $items) {
        $h = (Get-FileHash -LiteralPath $i.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
        $i.FullName + '|' + $i.Length + '|' + $h
    }
    return (@($lines) -join "`n")
}
$realCoordDir = Join-Path $HOME '.claude\coordination'
$realSnapshotBefore = Get-DirSnapshot $realCoordDir

# ---------------------------------------------------------------------------
# Process runner: like Invoke-HookTestPowerShell but it also returns the wall
# clock to the child's exit (the pipe reads after it are not counted).
# ---------------------------------------------------------------------------
function Start-TestProcess {
    param([string]$Arguments, [string]$StdinText = '', [hashtable]$ExtraEnv = @{}, [string]$StartDir = '', [int]$Seconds = 90)
    if (-not $StartDir) { $StartDir = $script:root }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $psExe
    $psi.Arguments = $Arguments
    $psi.WorkingDirectory = $StartDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    foreach ($k in $ExtraEnv.Keys) { $psi.EnvironmentVariables[$k] = [string]$ExtraEnv[$k] }
    # No BOM ahead of the event: see Invoke-HookTestPowerShell.
    $prevInputEncoding = $null
    try { $prevInputEncoding = [Console]::InputEncoding; [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try { $p = [System.Diagnostics.Process]::Start($psi) }
    finally { if ($prevInputEncoding) { try { [Console]::InputEncoding = $prevInputEncoding } catch { } } }
    if ($StdinText) {
        $bytes = $utf8.GetBytes($StdinText)
        $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $p.StandardInput.BaseStream.Flush()
    }
    $p.StandardInput.Close()
    $outRead = $p.StandardOutput.ReadToEndAsync()
    $errRead = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($Seconds * 1000)) {
        & taskkill.exe /T /F /PID $p.Id 2>$null | Out-Null
        return @{ Code = "no exit within ${Seconds}s"; Out = ''; Err = ''; Ms = $sw.ElapsedMilliseconds }
    }
    $ms = $sw.ElapsedMilliseconds
    $out = if ($outRead.Wait(10000)) { $outRead.Result } else { '<stdout still open 10s after exit>' }
    $err = if ($errRead.Wait(10000)) { $errRead.Result } else { '<stderr still open 10s after exit>' }
    return @{ Code = $p.ExitCode; Out = $out; Err = $err.Trim(); Ms = $ms }
}

# Startup cost of a bare powershell.exe: the budget bounds what the script does,
# not the process launch, so the timing rows subtract this (median of 3).
function Get-StartupBaselineMs {
    $ms = @()
    for ($i = 0; $i -lt 3; $i++) {
        $r = Start-TestProcess -Arguments '-NoProfile -ExecutionPolicy Bypass -Command "exit 0"' -Seconds 60
        $ms += [int]$r.Ms
    }
    return [int](($ms | Sort-Object)[1])
}
$baselineMs = Get-StartupBaselineMs
Write-Host "info  powershell.exe start-up baseline: $baselineMs ms (median of 3)"

# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------
$today = '2026-03-05'
$yday = '2026-03-04'
$idxDir = Join-Path $root 'index'
$repoA = Join-Path $root 'repoA'
$repoB = Join-Path $root 'repoB'
$repoC = Join-Path $root 'repoC'
$repoD = Join-Path $root 'repoD'
$repoU = Join-Path $root 'repoU'
$wtA1 = Join-Path $root 'wt\A1'
$wtA2 = Join-Path $root 'wt\A2'
$wtB1 = Join-Path $root 'wt\B1'
$plain = Join-Path $root 'plain'
$outside = Join-Path $root 'outside'
# Built at run time: the scrub suite flags a literal desktop-style id in a committed file.
$idp = 'local' + '_'
$tokA1 = $idp + 'a1a1a1a1'
$tokA2 = $idp + 'a2a2a2a2'
$tokB1 = $idp + 'b1b1b1b1'
$scopeA1 = 'src/a1/**, docs/**, !docs/secret/**'
$ledgerCols = @('Track', 'Repo', 'Session', 'Model', 'Cwd', 'Branch', 'Scope', 'PR', 'Status')
$allMains = @($repoA, $repoB, $repoC, $repoD, $repoU)

function New-TestRepo([string]$Path) {
    New-HookTestRepo $Path
    Invoke-HookTestGit $Path @('config', 'commit.gpgsign', 'false')
    Set-CoordFile $Path '.gitignore' ".claude/coordination/`n"
    Set-CoordFile $Path 'README.md' "readme`n"
    Invoke-HookTestGit $Path @('-c', 'core.autocrlf=false', 'add', '-A')
    Invoke-HookTestGit $Path @('-c', 'core.autocrlf=false', 'commit', '--quiet', '-m', 'base')
}

# The first existing component of $Path, from the drive root down, that is a
# junction or symlink; $null when there is none.
function Find-LinkComponent([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $parts = $full.Split('\')
    $cur = $parts[0] + '\'
    for ($i = 1; $i -lt $parts.Length; $i++) {
        $cur = Join-Path $cur $parts[$i]
        if (-not (Test-Path -LiteralPath $cur)) { break }
        if (([System.IO.File]::GetAttributes($cur) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $cur }
    }
    return $null
}

function New-TestJunction([string]$Link, [string]$Target) {
    try { New-Item -ItemType Junction -Path $Link -Target $Target -ErrorAction Stop | Out-Null; return $true } catch { return $false }
}
function New-TestSymlink([string]$Link, [string]$Target) {
    try { New-Item -ItemType SymbolicLink -Path $Link -Target $Target -ErrorAction Stop | Out-Null; return $true } catch { return $false }
}
# Directory.Delete / File.Delete drop a link and leave its target alone.
function Remove-TestLink([string]$Link) {
    try { [System.IO.Directory]::Delete($Link) } catch { try { [System.IO.File]::Delete($Link) } catch { } }
}

$fixtureOk = $true
try {
    [void][IO.Directory]::CreateDirectory($root)
    foreach ($d in $allMains) { New-TestRepo $d }
    New-HookTestWorktree -Repo $repoA -Path $wtA1 -Branch 'a1-branch'
    New-HookTestWorktree -Repo $repoA -Path $wtA2 -Branch 'a2-branch'
    New-HookTestWorktree -Repo $repoB -Path $wtB1 -Branch 'b1-branch'
    foreach ($d in @($plain, $outside, $idxDir)) { [void][IO.Directory]::CreateDirectory($d) }
    Set-CoordFile $wtA1 'src/a1/seed.txt' "seed`n"
    Set-CoordFile $wtA1 'docs/secret/seed.txt' "seed`n"
    Set-CoordFile $wtA2 'src/a2/target.txt' "target`n"
    Set-CoordFile $wtB1 'lib/seed.txt' "seed`n"
}
catch {
    $fixtureOk = $false
    Report $false 'G0 fixture builds' $_.Exception.Message
}

# ---------------------------------------------------------------------------
# Ledger, index and anchor builders
# ---------------------------------------------------------------------------
function New-LedgerRow {
    param([string]$Track, [string]$Repo, [string]$Branch, [string]$Cwd, [string]$Scope, [string]$Session = '', [string]$Status = 'running')
    return [ordered]@{ Track = $Track; Repo = $Repo; Session = $Session; Model = 'Opus 5.5 high'; Cwd = $Cwd; Branch = $Branch; Scope = $Scope; PR = 'none yet'; Status = $Status }
}
function RowA1 { param([string]$Status = 'running', [string]$Session = $tokA1) New-LedgerRow 'A1' $repoA 'a1-branch' $wtA1 $scopeA1 $Session $Status }
function RowA2 { param([string]$Status = 'running', [string]$Session = $tokA2) New-LedgerRow 'A2' $repoA 'a2-branch' $wtA2 'src/a2/**' $Session $Status }
function RowB1 { param([string]$Track = 'TB', [string]$Session = $tokB1, [string]$Status = 'running') New-LedgerRow $Track $repoB 'b1-branch' $wtB1 'lib/**' $Session $Status }

$padLine = '10:00 padding ' + ('x' * 86) + "`n"   # 101 bytes

# Ledger text. A row is an ordered hashtable (one cell per column) or a raw
# string (one raw table line, for malformed rows). TargetBytes pads the Log
# section to at least that many bytes; PadBeforeBytes pads the Baseline section
# above Tracks; Unterminated ends the file right after the last Tracks row.
function Format-Ledger {
    param([object[]]$Rows = @(), [string]$Date, [string[]]$Columns, [int]$TargetBytes = 0, [int]$PadBeforeBytes = 0, [switch]$Unterminated)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("# Coordination ledger - $Date`n`n")
    [void]$sb.Append('Coordinator: session "Coordinator Test", cwd `<repo>`.' + "`n`n")
    [void]$sb.Append("## Baseline`n`n")
    if ($PadBeforeBytes -gt 0) {
        $n = [int][Math]::Ceiling($PadBeforeBytes / 101.0)
        for ($i = 0; $i -lt $n; $i++) { [void]$sb.Append($padLine) }
        [void]$sb.Append("`n")
    }
    [void]$sb.Append("| Repo | origin/main | Open PRs | Verified at |`n|------|-------------|----------|-------------|`n`n")
    [void]$sb.Append("## Tracks`n`n")
    [void]$sb.Append("<!-- Repo: the full path. Status: lead with MERGED or DONE when finished. -->`n`n")
    [void]$sb.Append('| ' + ($Columns -join ' | ') + " |`n")
    [void]$sb.Append('|' + (($Columns | ForEach-Object { '---' }) -join '|') + "|`n")
    foreach ($row in $Rows) {
        if ($row -is [string]) { [void]$sb.Append($row + "`n"); continue }
        $cells = @($Columns | ForEach-Object { [string]$row[$_] })
        [void]$sb.Append('| ' + ($cells -join ' | ') + " |`n")
    }
    if ($Unterminated) { return $sb.ToString() }
    [void]$sb.Append("`n## Merge slots`n`n1. (none)`n`n## Owed checks`n`n- [ ] (none)`n`n## Decisions`n`n## Findings`n`n## Log`n`n")
    if ($TargetBytes -gt $sb.Length) {
        $n = [int][Math]::Ceiling(($TargetBytes - $sb.Length) / 101.0)
        for ($i = 0; $i -lt $n; $i++) { [void]$sb.Append($padLine) }
    }
    return $sb.ToString()
}

function Get-LedgerPath([string]$Repo, [string]$Date) { return (Join-Path $Repo ('.claude\coordination\' + $Date + '.md')) }

function Set-TestLedger {
    param([object[]]$Rows = @(), [string]$Date = $today, [string]$Repo = $repoA, [string[]]$Columns = $ledgerCols, [int]$TargetBytes = 0, [int]$PadBeforeBytes = 0, [switch]$Unterminated)
    $p = Get-LedgerPath $Repo $Date
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $p))
    $text = Format-Ledger -Rows $Rows -Date $Date -Columns $Columns -TargetBytes $TargetBytes -PadBeforeBytes $PadBeforeBytes -Unterminated:$Unterminated
    [System.IO.File]::WriteAllText($p, $text, $utf8)
    return $p
}

function Set-TestIndex {
    param([string]$Date = $today, [string[]]$Paths = @(), [switch]$NoFinalNewline)
    [void][IO.Directory]::CreateDirectory($idxDir)
    $text = ''
    if ($Paths.Count -gt 0) { $text = ($Paths -join "`n"); if (-not $NoFinalNewline) { $text += "`n" } }
    [System.IO.File]::WriteAllText((Join-Path $idxDir ($Date + '.ledgers')), $text, $utf8)
}
function Add-TestIndexEntry([string]$Date, [string]$Path) {
    $f = Join-Path $idxDir ($Date + '.ledgers')
    [System.IO.File]::AppendAllText($f, $Path + "`n", $utf8)
}

# Back to a blank slate: no index, no anchors, no ledger in any fixture repo or worktree.
function Reset-State {
    if (Test-Path -LiteralPath $idxDir) { Remove-Item -LiteralPath $idxDir -Recurse -Force }
    [void][IO.Directory]::CreateDirectory($idxDir)
    foreach ($d in @($repoA, $repoB, $repoC, $repoD, $repoU, $wtA1, $wtA2, $wtB1)) {
        $cd = Join-Path $d '.claude\coordination'
        if (Test-Path -LiteralPath $cd) {
            foreach ($f in @(Get-ChildItem -LiteralPath $cd -File -Filter '*.md' -Force -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $f.FullName -Force }
        }
    }
}

# Reset, write one ledger and list it in that date's index. Returns the ledger path.
function Use-Ledger {
    param([object[]]$Rows = @(), [string]$Date = $today, [string]$Repo = $repoA, [string[]]$Columns = $ledgerCols, [int]$TargetBytes = 0, [int]$PadBeforeBytes = 0, [switch]$Unterminated, [switch]$KeepState)
    if (-not $KeepState) { Reset-State }
    $p = Set-TestLedger -Rows $Rows -Date $Date -Repo $Repo -Columns $Columns -TargetBytes $TargetBytes -PadBeforeBytes $PadBeforeBytes -Unterminated:$Unterminated
    Add-TestIndexEntry $Date $p
    return $p
}

function Write-AnchorFile([string]$Session, [string[]]$Lines) {
    $d = Join-Path $idxDir 'sessions'
    [void][IO.Directory]::CreateDirectory($d)
    $f = Join-Path $d ($Session + '.anchor')
    [System.IO.File]::WriteAllText($f, (($Lines -join "`n") + "`n"), $utf8)
    return $f
}
function Get-AnchorPath([string]$Session) { return (Join-Path (Join-Path $idxDir 'sessions') ($Session + '.anchor')) }

# ---------------------------------------------------------------------------
# Events and runs
# ---------------------------------------------------------------------------
function New-GuardEvent {
    param([string]$Tool = 'Edit', [string]$Path, [string]$Cwd, [string]$Session = 'sess-test', [string]$PathKey = '')
    if (-not $PathKey) { $PathKey = if ($Tool -eq 'NotebookEdit') { 'notebook_path' } else { 'file_path' } }
    $ti = [ordered]@{}
    $ti[$PathKey] = $Path
    if ($Tool -eq 'MultiEdit') { $ti['edits'] = @(@{ old_string = 'a'; new_string = 'b' }) }
    $e = [ordered]@{ session_id = $Session; transcript_path = 'x'; cwd = $Cwd; permission_mode = 'default'; hook_event_name = 'PreToolUse'; tool_name = $Tool; tool_input = $ti }
    return (ConvertTo-HookTestAsciiJson (ConvertTo-Json -InputObject $e -Depth 6 -Compress))
}
function New-SessionStartJson {
    param([string]$Session, [string]$Cwd, [string]$Source = 'startup')
    $e = [ordered]@{ session_id = $Session; transcript_path = 'x'; cwd = $Cwd; hook_event_name = 'SessionStart'; source = $Source }
    return (ConvertTo-HookTestAsciiJson (ConvertTo-Json -InputObject $e -Depth 4 -Compress))
}

# Runs the hook. Launcher 'file' = powershell.exe -File (reads [ ] in a path as a
# wildcard, so it can run a sibling folder's copy); 'escaped' = the hooks.json
# way: -Command, the path wildcard-escaped, the exit code forwarded.
function Invoke-Guard {
    param([string]$Json, [hashtable]$ExtraEnv = @{}, [string]$ProjectDir = '', [string]$StubDir = '', [string]$Script = '', [int]$Seconds = 90, [string]$Launcher = 'file')
    if (-not $Script) { $Script = $hookPath }
    if (-not (Test-Path -LiteralPath $Script)) { return @{ Code = 'hook script missing'; Out = ''; Err = ''; Ms = 0 } }
    $envs = @{ COORD_INDEX_DIR = $idxDir; COORD_TODAY = $today }
    if ($ProjectDir) { $envs['CLAUDE_PROJECT_DIR'] = $ProjectDir }
    if ($StubDir) { $envs['PATH'] = $StubDir + ';' + $env:PATH }
    foreach ($k in $ExtraEnv.Keys) { $envs[$k] = $ExtraEnv[$k] }
    if ($Launcher -eq 'escaped') {
        $q = $Script.Replace("'", "''")
        $cmd = "& ([WildcardPattern]::Escape('$q'.Replace([string][char]96, [string][char]96 * 2))); if (`$null -eq `$LASTEXITCODE) { exit 1 }; exit `$LASTEXITCODE"
        $args1 = '-NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    }
    else { $args1 = '-NoProfile -ExecutionPolicy Bypass -File "' + $Script + '"' }
    return (Start-TestProcess -Arguments $args1 -StdinText $Json -ExtraEnv $envs -Seconds $Seconds)
}
function Invoke-Edit {
    param([string]$Cwd, [string]$Path, [string]$Tool = 'Edit', [string]$Session = 'sess-test', [string]$ProjectDir = '', [hashtable]$ExtraEnv = @{}, [string]$StubDir = '', [string]$Script = '', [string]$Launcher = 'file', [string]$PathKey = '')
    $json = New-GuardEvent -Tool $Tool -Path $Path -Cwd $Cwd -Session $Session -PathKey $PathKey
    return (Invoke-Guard -Json $json -ExtraEnv $ExtraEnv -ProjectDir $ProjectDir -StubDir $StubDir -Script $Script -Launcher $Launcher)
}

# ---------------------------------------------------------------------------
# Verdicts
# ---------------------------------------------------------------------------
function Get-Verdict($R) {
    $v = @{ Kind = 'error'; Msg = ''; Why = '' }
    if ($R.Code -isnot [int]) { $v.Why = "no exit code: $($R.Code)"; return $v }
    $out = ([string]$R.Out).Trim()
    $err = ([string]$R.Err).Trim()
    if ($R.Code -eq 2) {
        if ($out) { $v.Kind = 'bad'; $v.Why = 'block printed on stdout'; return $v }
        if (-not $err) { $v.Kind = 'bad'; $v.Why = 'block with empty stderr'; return $v }
        $v.Kind = 'block'; $v.Msg = $err; return $v
    }
    if ($R.Code -ne 0) { $v.Kind = 'bad'; $v.Why = "exit code $($R.Code)"; return $v }
    if (-not $out) {
        if ($err) { $v.Kind = 'bad'; $v.Why = 'stderr on an exit-0 run'; return $v }
        $v.Kind = 'allow'; return $v
    }
    if ($err) { $v.Kind = 'bad'; $v.Why = 'stderr on an exit-0 run'; return $v }
    try { $o = ConvertFrom-Json -InputObject $out -ErrorAction Stop }
    catch { $v.Kind = 'bad'; $v.Why = 'stdout is not one JSON object'; return $v }
    $names = @($o.PSObject.Properties | ForEach-Object { $_.Name })
    if ($o -is [array] -or $names.Count -ne 1 -or $names[0] -ne 'systemMessage') { $v.Kind = 'bad'; $v.Why = 'stdout JSON is not exactly {systemMessage}'; return $v }
    $msg = [string]$o.systemMessage
    if (-not $msg.StartsWith('coord-scope-guard: ')) { $v.Kind = 'bad'; $v.Why = 'systemMessage does not start with "coord-scope-guard: "'; return $v }
    $v.Kind = 'warn'; $v.Msg = $msg
    return $v
}
function Test-HasAll([string]$Msg, [string[]]$Has) {
    foreach ($h in $Has) { if ($Msg.IndexOf($h, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return "missing: $h" } }
    return ''
}
function Show-Run($R, $V) {
    return ("kind={0} why={1} code={2} ms={3} stdout=[{4}] stderr=[{5}]" -f $V.Kind, $V.Why, $R.Code, $R.Ms, (Get-Tail $R.Out), (Get-Tail $R.Err))
}
function Test-Allow([string]$Name, $R) {
    $v = Get-Verdict $R
    Report ($v.Kind -eq 'allow') "$Name -> silent allow" (Show-Run $R $v)
}
function Test-NoBlock([string]$Name, $R) {
    $v = Get-Verdict $R
    Report ($v.Kind -eq 'allow' -or $v.Kind -eq 'warn') "$Name -> exit 0, not blocked" (Show-Run $R $v)
}
function Test-Warn([string]$Name, $R, [string[]]$Has = @()) {
    $v = Get-Verdict $R
    $miss = if ($v.Kind -eq 'warn') { Test-HasAll $v.Msg $Has } else { 'not a warning' }
    Report ($v.Kind -eq 'warn' -and -not $miss) "$Name -> exit 0 with one systemMessage" ("$miss; " + (Show-Run $R $v))
}
function Test-Block([string]$Name, $R, [string[]]$Has = @()) {
    $v = Get-Verdict $R
    $miss = if ($v.Kind -eq 'block') { Test-HasAll $v.Msg $Has } else { 'not a block' }
    Report ($v.Kind -eq 'block' -and -not $miss) "$Name -> exit 2, refusal on stderr" ("$miss; " + (Show-Run $R $v))
}

function Get-ScopeMsg([string]$Path, [string]$Track, [string]$Globs) {
    return ('coord-scope-guard: ' + $Path + ' is outside track ' + $Track + "'s scope (" + $Globs + '). Ask the coordinator to widen the ledger row, or message the owning track; do not edit it.')
}
function Get-ScopeTail([string]$Track, [string]$Globs) { return ('is outside track ' + $Track + "'s scope (" + $Globs + ').') }

# ---------------------------------------------------------------------------
# git stubs (git.cmd first on PATH)
# ---------------------------------------------------------------------------
$stubRoot = Join-Path $root 'stubs'
[void][IO.Directory]::CreateDirectory($stubRoot)
# Generic: logs each call (CSG_LOG), counts calls (CSG_COUNT), fails the call
# numbered CSG_FAIL_AT, or any call whose arguments contain CSG_FAIL_MATCH or CSG_FAIL_MATCH2 (set together), with exit 128, sleeps CSG_SLEEP_PINGS-1 seconds on every
# call (or only on calls whose arguments contain CSG_SLEEP_MATCH) by pinging the
# unique loopback address CSG_SLEEP_ADDR, then hands the call to the real git
# (CSG_REAL). No parentheses blocks, so an argument holding ')' cannot break it.
$stubGeneric = Join-Path $stubRoot 'generic'
[void][IO.Directory]::CreateDirectory($stubGeneric)
[System.IO.File]::WriteAllText((Join-Path $stubGeneric 'git.cmd'), (@(
    '@echo off',
    'setlocal',
    'if not defined CSG_LOG goto nolog',
    '>>"%CSG_LOG%" echo called',
    ':nolog',
    'set n=0',
    'if not defined CSG_COUNT goto nocount',
    'if exist "%CSG_COUNT%" set /p n=<"%CSG_COUNT%"',
    'set /a n+=1',
    '>"%CSG_COUNT%" echo %n%',
    ':nocount',
    'if "%n%"=="%CSG_FAIL_AT%" goto fail',
    'if not defined CSG_FAIL_MATCH goto nomatch',
    'echo %* | findstr /L /I /C:"%CSG_FAIL_MATCH%" /C:"%CSG_FAIL_MATCH2%" >nul',
    'if not errorlevel 1 goto fail',
    ':nomatch',
    'if not defined CSG_SLEEP_PINGS goto run',
    'if not defined CSG_SLEEP_MATCH goto sleep',
    'echo %* | findstr /L /C:"%CSG_SLEEP_MATCH%" >nul',
    'if errorlevel 1 goto run',
    ':sleep',
    'ping -n %CSG_SLEEP_PINGS% %CSG_SLEEP_ADDR% >nul',
    ':run',
    '"%CSG_REAL%" %*',
    'exit /b %ERRORLEVEL%',
    ':fail',
    'echo fatal: simulated git failure 1>&2',
    'exit /b 128',
    '') -join "`r`n"), (New-Object System.Text.ASCIIEncoding))
# Child holder: logs, starts a ping that keeps the inherited stdout open for ~8 s, exits 0 at once.
$stubChild = Join-Path $stubRoot 'child'
[void][IO.Directory]::CreateDirectory($stubChild)
[System.IO.File]::WriteAllText((Join-Path $stubChild 'git.cmd'), (@(
    '@echo off',
    'if not defined CSG_LOG goto nolog',
    '>>"%CSG_LOG%" echo called',
    ':nolog',
    'start "" /b ping -n 9 %CSG_CHILD_ADDR%',
    'exit /b 0',
    '') -join "`r`n"), (New-Object System.Text.ASCIIEncoding))

function New-StubFiles([string]$Tag) {
    return @{ Log = (Join-Path $root ("stub-$Tag.log")); Count = (Join-Path $root ("stub-$Tag.count")) }
}
function New-LoopbackAddr { return ('127.0.' + (Get-Random -Minimum 1 -Maximum 250) + '.' + (Get-Random -Minimum 1 -Maximum 250)) }
function Get-StubCalls($Files) {
    if (-not (Test-Path -LiteralPath $Files.Count)) { return 0 }
    return [int](([System.IO.File]::ReadAllText($Files.Count)).Trim())
}

# cmd.exe / ping.exe still running that carry one of the markers; $null when the process list cannot be read.
function Get-LeftoverProcs([string[]]$Markers) {
    $found = @()
    try {
        $all = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop | Where-Object { $_.CommandLine -and ($_.Name -eq 'cmd.exe' -or $_.Name -eq 'ping.exe') })
    }
    catch { return $null }
    foreach ($p in $all) {
        foreach ($m in $Markers) {
            if ($p.CommandLine.IndexOf($m, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $found += $p; break }
        }
    }
    return , $found
}
# True when the run produced a real verdict of one of $Kinds (a missing hook gives kind 'error', so a row that
# also requires this cannot pass without the hook).
function Test-Ran($R, [string[]]$Kinds) { return ($Kinds -contains (Get-Verdict $R).Kind) }

function Test-NoLeftover([string]$Name, [string[]]$Markers, $R) {
    if (-not (Test-Ran $R @('allow', 'warn'))) { Report $false "$Name -> no stub process left running" ('the hook did not run to an exit-0 verdict: ' + (Show-Run $R (Get-Verdict $R))); return }
    Start-Sleep -Milliseconds 800
    $left = Get-LeftoverProcs $Markers
    if ($null -eq $left) { Skip $Name 'the process list could not be read (Get-CimInstance failed)'; return }
    $left = @($left)
    foreach ($p in $left) { & taskkill.exe /F /T /PID $p.ProcessId 2>$null | Out-Null }
    Report ($left.Count -eq 0) "$Name -> no stub process left running" ("left: " + (($left | ForEach-Object { $_.Name + ' ' + $_.CommandLine }) -join ' ; '))
}

$stdScopeTail = Get-ScopeTail 'A1' $scopeA1

# ===========================================================================
# G0 fixture sanity
# ===========================================================================
Invoke-Group 'G0 fixture' {
    Report (Test-Path -LiteralPath $hookPath) 'G0-1 the hook script exists' $hookPath
    Report $fixtureOk 'G0-2 fixture repos and worktrees built' ''
    $br = (& git -C $wtA1 branch --show-current 2>$null | Out-String).Trim()
    Report ($br -eq 'a1-branch') 'G0-3 worktree A1 is on a1-branch' "got '$br'"
    $link = Find-LinkComponent $root
    Report ($null -eq $link) 'G0-4 the scratch root has no junction or symlink in its path (else every outside-tree row would block)' "link at $link"
    $linkTemp = Find-LinkComponent ([System.IO.Path]::GetTempPath())
    Report ($null -eq $linkTemp) 'G0-5 the machine scratchpad root (%TEMP%) has no junction or symlink in its path' "link at $linkTemp"
    $projects = Join-Path $HOME '.claude\projects'
    $memLinks = @()
    if (Test-Path -LiteralPath $projects) {
        foreach ($d in @(Get-ChildItem -LiteralPath $projects -Directory -ErrorAction SilentlyContinue | Select-Object -First 60)) {
            $mem = Join-Path $d.FullName 'memory'
            if (Test-Path -LiteralPath $mem) { $l = Find-LinkComponent $mem; if ($l) { $memLinks += $l } }
        }
    }
    $notesRoot = Join-Path $env:APPDATA 'SomeApp\notes'
    $scratchRoot = Join-Path $env:TEMP 'claude'
    foreach ($rt in @(@{ Id = 'G0-7'; Name = 'app-data folder (%APPDATA%\SomeApp\notes)'; Dir = $notesRoot }, @{ Id = 'G0-8'; Name = 'scratchpad root (%TEMP%\claude)'; Dir = $scratchRoot })) {
        $anc = $rt.Dir
        while ($anc -and -not (Test-Path -LiteralPath $anc)) { $anc = Split-Path -Parent $anc }
        $top = (& git -C $anc rev-parse --show-toplevel 2>$null | Out-String).Trim()
        Report ($LASTEXITCODE -ne 0 -and -not $top) ($rt.Id + ' the ' + $rt.Name + ' (nearest existing folder ' + $anc + ') is in no git working tree') "git says the top level is '$top'"
        $lk = Find-LinkComponent $rt.Dir
        Report ($null -eq $lk) ($rt.Id + 'b the ' + $rt.Name + ' has no junction or symlink in its path') "link at $lk"
    }
    Report ($memLinks.Count -eq 0) 'G0-6 no memory folder under ~/.claude/projects has a junction or symlink in its path' ($memLinks -join ', ')
}

# ===========================================================================
# G1 binding
# ===========================================================================
Invoke-Group 'G1 binding' {
    $null = Use-Ledger -Rows @((RowA1), (RowA2))
    $p = Join-Path $wtA1 'src\a1\x.ps1'
    Test-Allow 'G1-1 from A1, an in-scope path' (Invoke-Edit -Cwd $wtA1 -Path $p)
    $po = Join-Path $wtA1 'other\x.txt'
    Test-Block 'G1-2 from A1, an out-of-scope path names the track and globs' (Invoke-Edit -Cwd $wtA1 -Path $po) @((Get-ScopeMsg $po 'A1' $scopeA1))
    Test-Block 'G1-3 from A1, a write into A main checkout (even an in-scope-looking path)' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $repoA 'src\a1\x.ps1')) @($stdScopeTail)
    Test-Block 'G1-4 from A1, a write into sibling A2 worktree' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA2 'src\a2\x.ps1')) @($stdScopeTail)
    Test-Block 'G1-5 from A1, a write into repo B main checkout' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $repoB 'lib\x.ps1')) @($stdScopeTail)
    Test-Block 'G1-6 from A1, a write into repo B linked worktree (no cross-repo row)' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtB1 'lib\x.ps1')) @($stdScopeTail)
    Test-Allow 'G1-7 cwd in A main checkout (branch main has no row): any path' (Invoke-Edit -Cwd $repoA -Path (Join-Path $repoA 'README.md'))
    Test-Allow 'G1-8 cwd in an unlisted repo: any path' (Invoke-Edit -Cwd $repoU -Path (Join-Path $repoU 'f.txt'))
    Test-Allow 'G1-9 cwd in a folder outside every repo: any path' (Invoke-Edit -Cwd $plain -Path (Join-Path $plain 'f.txt'))

    # a track in repo B is guarded by repo A's ledger
    $null = Use-Ledger -Rows @((RowB1))
    Test-Allow 'G1-10 a track in repo B (row in A ledger): in-scope path' (Invoke-Edit -Cwd $wtB1 -Path (Join-Path $wtB1 'lib\x.ps1'))
    Test-Block 'G1-11 a track in repo B (row in A ledger): out-of-scope path' (Invoke-Edit -Cwd $wtB1 -Path (Join-Path $wtB1 'app\x.ps1')) @((Get-ScopeTail 'TB' 'lib/**'))

    # rows that do not bind
    foreach ($st in @('DONE; report placed', 'MERGED abc1234 13:05')) {
        $null = Use-Ledger -Rows @((RowA1 -Status $st))
        Test-Allow "G1-12 row Status '$st': out-of-scope path from A1" (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'other\x.txt'))
    }
    $null = Use-Ledger -Rows @((RowA1))
    Test-Allow 'G1-13 an unlisted branch (A2 worktree, ledger names only A1): any path' (Invoke-Edit -Cwd $wtA2 -Path (Join-Path $wtA2 'other\x.txt'))

    # two sequential rows on one branch: one DONE, one live
    $old = New-LedgerRow 'S1.7.3' $repoA 'a1-branch' $wtA1 'old/**' $tokA1 'DONE; merged'
    $live = New-LedgerRow 'S1.8' $repoA 'a1-branch' $wtA1 'src/a1/**' $tokA1 'running'
    $null = Use-Ledger -Rows @($old, $live)
    Test-Allow 'G1-14 DONE row then live row on one branch: the live scope allows its path' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'src\a1\x.ps1'))
    Test-Block 'G1-15 DONE row then live row on one branch: the DONE row scope grants nothing, block names the live track' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'old\x.ps1')) @((Get-ScopeTail 'S1.8' 'src/a1/**'))

    # two live rows binding one session
    $x1 = New-LedgerRow 'X1' $repoA 'a1-branch' $wtA1 'src/a1/**' ($idp + '11111111') 'running'
    $x2 = New-LedgerRow 'X2' $repoA 'a1-branch' $wtA1 'src/a1/**' ($idp + '22222222') 'running'
    $null = Use-Ledger -Rows @($x1, $x2)
    Test-Block 'G1-16 two live rows on one repo and branch: block naming both' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'src\a1\x.ps1')) @('ambiguous ledger rows bind this session: ', 'X1 (', 'X2 (')

    # cross-repo track: second row (same Session token) in repo B
    $cross = New-LedgerRow 'A1-B' $repoB 'b1-branch' $wtB1 'lib/**' $tokA1 'running'
    $null = Use-Ledger -Rows @((RowA1), $cross)
    Test-Allow 'G1-17 cross-repo second row (same token): its scope in repo B is allowed' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtB1 'lib\x.ps1'))
    Test-Block 'G1-18 cross-repo second row: a path outside its scope in the same repo B worktree (the refusal names the cross-repo row A1-B and its globs)' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtB1 'other\x.ps1')) @((Get-ScopeTail 'A1-B' 'lib/**'))
    Test-Block 'G1-19 cross-repo second row: the same lib path in repo B MAIN checkout (no row names it)' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $repoB 'lib\x.ps1')) @((Get-ScopeTail 'A1' $scopeA1))
    Test-Block 'G1-20 cross-repo second row: sibling A2 worktree stays blocked' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA2 'src\a2\x.ps1')) @((Get-ScopeTail 'A1' $scopeA1))
    Test-Allow 'G1-21 cross-repo second row: A1 own in-scope path still allowed' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'src\a1\x.ps1'))

    # what grants no cross-repo write
    $noSessionCols = @('Track', 'Repo', 'Model', 'Cwd', 'Branch', 'Scope', 'PR', 'Status')
    $null = Use-Ledger -Rows @((RowA1), $cross) -Columns $noSessionCols
    Test-Block 'G1-22 Session column missing: no cross-repo write' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtB1 'lib\x.ps1')) @('coord-scope-guard: ')
    $null = Use-Ledger -Rows @((New-LedgerRow 'A1' $repoA 'a1-branch' $wtA1 $scopeA1 '' 'running'), (New-LedgerRow 'A1-B' $repoB 'b1-branch' $wtB1 'lib/**' '' 'running'))
    Test-Block 'G1-23 two blank Session cells: no cross-repo write' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtB1 'lib\x.ps1')) @('coord-scope-guard: ')
    $null = Use-Ledger -Rows @((New-LedgerRow 'A1' $repoA 'a1-branch' $wtA1 $scopeA1 's-a1' 'running'), (New-LedgerRow 'A1-B' $repoB 'b1-branch' $wtB1 'lib/**' 's-a1' 'running'))
    Test-Block 'G1-24 two equal cells with no local_ token: no cross-repo write' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtB1 'lib\x.ps1')) @('coord-scope-guard: ')
    $null = Use-Ledger -Rows @((New-LedgerRow 'A1' $repoA 'a1-branch' $wtA1 $scopeA1 ($idp + 'abc') 'running'), (New-LedgerRow 'A1-B' $repoB 'b1-branch' $wtB1 'lib/**' ($idp + 'abc') 'running'))
    Test-Block 'G1-25 a local_ token shorter than 8 hex is no token: no cross-repo write' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtB1 'lib\x.ps1')) @('coord-scope-guard: ')
    $bx = New-LedgerRow 'BX' $repoB 'b1-branch' $wtB1 'lib/**' $tokA1 'running'
    $by = New-LedgerRow 'BY' $repoB 'b1-branch' $wtB1 'lib/**' $tokA1 'running'
    $null = Use-Ledger -Rows @((RowA1), $bx, $by)
    Test-Block 'G1-26 two live rows on the target worktree branch, both with the same token: no cross-repo write' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtB1 'lib\x.ps1')) @('coord-scope-guard: ')
    $two = New-LedgerRow 'A1-B' $repoB 'b1-branch' $wtB1 'lib/**' ($tokA1 + ' ' + $idp + 'b2b2b2b2') 'running'
    $null = Use-Ledger -Rows @((RowA1), $two)
    Test-Block 'G1-27 a Session cell holding two tokens grants nothing' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtB1 'lib\x.ps1')) @('coord-scope-guard: ')
    $up = New-LedgerRow 'A1' $repoA 'a1-branch' $wtA1 $scopeA1 ($idp + 'ABCDEF12') 'running'
    $lo = New-LedgerRow 'A1-B' $repoB 'b1-branch' $wtB1 'lib/**' ($idp + 'abcdef12') 'running'
    $null = Use-Ledger -Rows @($up, $lo)
    Test-Allow 'G1-28 tokens equal ignoring case: the cross-repo write is allowed' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtB1 'lib\x.ps1'))
}

# ===========================================================================
# G2 anchors
# ===========================================================================
Invoke-Group 'G2 anchors' {
    # --- SessionStart writes the anchor once (a day with a registered ledger; S6 holds the no-index rows) ---
    $null = Use-Ledger -Rows @((RowA1), (RowA2))
    $f1 = Get-AnchorPath 'sa-1'
    $r = Invoke-Guard -Json (New-SessionStartJson -Session 'sa-1' -Cwd $wtA1 -Source 'startup')
    Test-Allow 'G2-1 SessionStart startup' $r
    $got = if (Test-Path -LiteralPath $f1) { [System.IO.File]::ReadAllText($f1) } else { '<no file>' }
    Report ($got -ceq ($wtA1 + "`n")) 'G2-2 the anchor file holds the event cwd and one LF' ("got [$got]")
    foreach ($src in @('startup', 'resume', 'compact')) {
        $null = Invoke-Guard -Json (New-SessionStartJson -Session 'sa-1' -Cwd $wtA2 -Source $src)
        $got = [System.IO.File]::ReadAllText($f1)
        Report ($got -ceq ($wtA1 + "`n")) "G2-3 a second SessionStart ($src) with another cwd leaves the anchor as it was" ("got [$got]")
    }
    foreach ($bad in @('..\evil', '../evil', 'a b', 'a.b', 'a:b', ('x' * 129))) {
        $null = Use-Ledger -Rows @((RowA1), (RowA2))
        $label = if ($bad.Length -gt 20) { "a $($bad.Length)-character id" } else { "'$bad'" }
        $r = Invoke-Guard -Json (New-SessionStartJson -Session $bad -Cwd $wtA1)
        $made = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.anchor' -Force -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notlike ($root + '\stubs\*') })
        Report ($r.Code -eq 0 -and $made.Count -eq 0) "G2-4 session_id $label writes no anchor file" ("code=$($r.Code); files: " + (($made | ForEach-Object { $_.FullName }) -join ', '))
    }
    $null = Use-Ledger -Rows @((RowA1), (RowA2))
    $r = Invoke-Guard -Json (New-SessionStartJson -Session ('y' * 128) -Cwd $wtA1)
    Report ($r.Code -eq 0 -and (Test-Path -LiteralPath (Get-AnchorPath ('y' * 128)))) 'G2-5 a 128-character session_id is accepted' (Show-Run $r (Get-Verdict $r))

    # --- the guard path never removes an anchor by age (only a SessionStart write prunes, S6-27), and an old one still binds ---
    $null = Use-Ledger -Rows @((RowA1), (RowA2))
    $old = Write-AnchorFile 'sa-old' @($wtA1)
    (Get-Item -LiteralPath $old).LastWriteTime = (Get-Date).AddDays(-400)
    (Get-Item -LiteralPath $old).CreationTime = (Get-Date).AddDays(-400)
    $r = Invoke-Edit -Cwd $plain -Path (Join-Path $wtA1 'other\x.txt') -Session 'sa-old'
    Test-Block 'G2-6 a 400-day-old anchor still binds' $r @($stdScopeTail)
    Report (Test-Path -LiteralPath $old) 'G2-7 the old anchor file is not removed by age' $old

    # --- the desktop layout and the claude -w layout, cwd moved elsewhere ---
    $layouts = @(
        @{ Name = 'desktop (CLAUDE_PROJECT_DIR = A main checkout)'; Project = $repoA },
        @{ Name = 'claude -w (CLAUDE_PROJECT_DIR = A1 worktree)'; Project = $wtA1 })
    $cwds = @(
        @{ Name = 'A main checkout'; Dir = $repoA },
        @{ Name = 'repo B main checkout'; Dir = $repoB },
        @{ Name = 'an unlisted repo'; Dir = $repoU },
        @{ Name = 'a folder outside every repo'; Dir = $plain })
    $null = Use-Ledger -Rows @((RowA1), (RowA2))
    $null = Write-AnchorFile 'sa-desk' @($wtA1)
    foreach ($l in $layouts) {
        foreach ($c in $cwds) {
            $tag = "G2-8 anchor at A1, $($l.Name), cwd in $($c.Name)"
            Test-Block "$tag, absolute out-of-scope path in A1" (Invoke-Edit -Cwd $c.Dir -Path (Join-Path $wtA1 'other\x.txt') -Session 'sa-desk' -ProjectDir $l.Project) @($stdScopeTail)
            Test-Block "$tag, absolute path in A2" (Invoke-Edit -Cwd $c.Dir -Path (Join-Path $wtA2 'src\a2\x.ps1') -Session 'sa-desk' -ProjectDir $l.Project) @($stdScopeTail)
            Test-Allow "$tag, in-scope path in A1" (Invoke-Edit -Cwd $c.Dir -Path (Join-Path $wtA1 'src\a1\x.ps1') -Session 'sa-desk' -ProjectDir $l.Project)
        }
    }

    # --- opened on a main checkout with NO listed ledger (repo B main), later binds B1, stays bound after a cd away ---
    # (A main holds the listed ledger, so a session opened there is a coordinator session and is never bound: F2.)
    $null = Use-Ledger -Rows @((RowA1), (RowA2), (RowB1))
    $af = Write-AnchorFile 'sa-late' @($repoB)
    $r = Invoke-Edit -Cwd $wtB1 -Path (Join-Path $wtB1 'lib\ok.ps1') -Session 'sa-late' -ProjectDir $repoB
    Test-NoBlock 'G2-9 opened on B main (no listed ledger), first edit inside B1 (cwd binds B1)' $r
    $lines = @([System.IO.File]::ReadAllText($af) -split "`n" | Where-Object { $_.Trim() })
    Report ($lines.Count -eq 2 -and [string]::Equals($lines[1].Trim(), $wtB1, [StringComparison]::OrdinalIgnoreCase)) 'G2-10 the first binding appends the worktree root to the anchor file as a second line' ("lines: " + ($lines -join ' / '))
    $startedOutside = "this session started outside track TB's worktree; it is guarded only from its first edit there; start the track in its worktree"
    Test-Warn 'G2-11 after a cd back to B main, an in-scope path in B1 is allowed with the started-outside warning' (Invoke-Edit -Cwd $repoB -Path (Join-Path $wtB1 'lib\ok.ps1') -Session 'sa-late' -ProjectDir $repoB) @($startedOutside)
    Test-Block 'G2-12 after a cd back to B main, an out-of-scope path in B1 is still blocked' (Invoke-Edit -Cwd $repoB -Path (Join-Path $wtB1 'other\x.txt') -Session 'sa-late' -ProjectDir $repoB) @((Get-ScopeTail 'TB' 'lib/**'))

    # --- the stated limit: entered A1 and cd'd back before the first edit ---
    $null = Use-Ledger -Rows @((RowA1), (RowA2))
    $null = Write-AnchorFile 'sa-limit' @($repoA)
    # A's main checkout holds the listed ledger, so this is a coordinator-checkout session: never bound (stated
    # limit), and an edit whose target is in A1's worktree warns, naming A1 (fix-diff round 3, T1).
    Test-Warn 'G2-13 opened on A main, never edited inside A1 (stated limit): an out-of-scope path in A1 is allowed, with the coordinator-checkout warning naming A1' (Invoke-Edit -Cwd $repoA -Path (Join-Path $wtA1 'other\x.txt') -Session 'sa-limit' -ProjectDir $repoA) @("this edit in track A1's worktree is NOT guarded")

    # --- no anchor file: bound by cwd and CLAUDE_PROJECT_DIR ---
    Test-Block 'G2-14 no anchor file: cwd in A1 binds' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'other\x.txt') -Session 'sa-none') @($stdScopeTail)
    Test-Block 'G2-15 no anchor file: CLAUDE_PROJECT_DIR at A1 binds while cwd is in A main' (Invoke-Edit -Cwd $repoA -Path (Join-Path $wtA1 'other\x.txt') -Session 'sa-none' -ProjectDir $wtA1) @($stdScopeTail)
    Test-Allow 'G2-16 no anchor file: cwd and CLAUDE_PROJECT_DIR both at A main bind nothing' (Invoke-Edit -Cwd $repoA -Path (Join-Path $wtA1 'other\x.txt') -Session 'sa-none' -ProjectDir $repoA)

    # --- a cross-repo track: anchor in A, cwd in B ---
    $cross = New-LedgerRow 'A1-B' $repoB 'b1-branch' $wtB1 'lib/**' $tokA1 'running'
    $null = Use-Ledger -Rows @((RowA1), $cross, (RowA2))
    $null = Write-AnchorFile 'sa-x' @($wtA1)
    Test-Allow 'G2-17 cross-repo track (anchor in A1, cwd in B1): A1 scope allowed' (Invoke-Edit -Cwd $wtB1 -Path (Join-Path $wtA1 'src\a1\x.ps1') -Session 'sa-x')
    Test-Allow 'G2-18 cross-repo track (anchor in A1, cwd in B1): B1 scope allowed' (Invoke-Edit -Cwd $wtB1 -Path (Join-Path $wtB1 'lib\x.ps1') -Session 'sa-x')
    Test-Block 'G2-19 cross-repo track: a path outside both scopes (A2 worktree)' (Invoke-Edit -Cwd $wtB1 -Path (Join-Path $wtA2 'src\a2\x.ps1') -Session 'sa-x') @('coord-scope-guard: ')
    Test-Block 'G2-20 cross-repo track: outside the B1 scope in B1' (Invoke-Edit -Cwd $wtB1 -Path (Join-Path $wtB1 'other\x.ps1') -Session 'sa-x') @('coord-scope-guard: ')
    Test-Block 'G2-21 cross-repo track: outside the A1 scope in A1' (Invoke-Edit -Cwd $wtB1 -Path (Join-Path $wtA1 'other\x.ps1') -Session 'sa-x') @('coord-scope-guard: ')

    # --- two anchors binding rows with different tokens, or a token and a blank ---
    $null = Use-Ledger -Rows @((RowA1), (RowA2))
    $null = Write-AnchorFile 'sa-tok' @($wtA1)
    Test-Block 'G2-22 anchor at A1 and cwd in A2 (different tokens): block naming both rows' (Invoke-Edit -Cwd $wtA2 -Path (Join-Path $wtA1 'src\a1\x.ps1') -Session 'sa-tok') @('ambiguous ledger rows bind this session: ', 'A1 (', 'A2 (')
    $null = Use-Ledger -Rows @((RowA1), (RowA2 -Session ''))
    $null = Write-AnchorFile 'sa-tok' @($wtA1)
    Test-Block 'G2-23 anchor at A1 and cwd in A2 (a token and a blank): block naming both rows' (Invoke-Edit -Cwd $wtA2 -Path (Join-Path $wtA1 'src\a1\x.ps1') -Session 'sa-tok') @('ambiguous ledger rows bind this session: ', 'A1 (', 'A2 (')

    # --- detached HEAD and an unlisted branch bind by Cwd, with the warning ---
    $null = Use-Ledger -Rows @((RowA1))
    try {
        Invoke-HookTestGit $wtA1 @('checkout', '--quiet', '--detach')
        Test-Warn 'G2-24 A1 on a detached HEAD: an in-scope path is allowed with the Cwd warning' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'src\a1\x.ps1')) @(" is on detached HEAD, not track A1's branch a1-branch; guarding by its Cwd")
        Test-Block 'G2-25 A1 on a detached HEAD: an out-of-scope path is blocked by the Cwd row' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'other\x.txt')) @($stdScopeTail)
        $dupCwd = New-LedgerRow 'A1x' $repoA 'zz-branch' $wtA1 'zz/**' 's-zz local_zzzzzzzz' 'running'
        $null = Use-Ledger -Rows @((RowA1), $dupCwd)
        Test-Block 'G2-26 A1 on a detached HEAD, one Cwd shared by two live rows: block' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'src\a1\x.ps1')) @('ambiguous ledger rows bind this session: ')
        Invoke-HookTestGit $wtA1 @('checkout', '--quiet', 'a1-branch')
        Invoke-HookTestGit $wtA1 @('checkout', '--quiet', '-b', 'other-branch')
        $null = Use-Ledger -Rows @((RowA1))
        Test-Warn 'G2-27 A1 on an unlisted branch: an in-scope path is allowed with the Cwd warning naming that branch' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'src\a1\x.ps1')) @(" is on other-branch, not track A1's branch a1-branch; guarding by its Cwd")
        Test-Block 'G2-28 A1 on an unlisted branch: an out-of-scope path is blocked' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'other\x.txt')) @($stdScopeTail)
    }
    finally {
        & git -C $wtA1 checkout --quiet a1-branch 2>$null | Out-Null
        & git -C $wtA1 branch -D other-branch 2>$null | Out-Null
    }

    # --- two live rows on A1's repo and branch with ONE token ---
    $dup = New-LedgerRow 'A1dup' $repoA 'a1-branch' $wtA1 'src/a1/**' $tokA1 'running'
    $null = Use-Ledger -Rows @((RowA1), $dup)
    Test-Block 'G2-29 two live rows on one repo and branch with one token, one ledger: even an in-scope edit in A1 is blocked' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'src\a1\x.ps1')) @('ambiguous ledger rows bind this session: ')
    $null = Use-Ledger -Rows @((RowA1))
    $null = Use-Ledger -Rows @($dup) -Repo $repoB -KeepState
    Test-Block 'G2-30 the same two rows across two ledgers: blocked as well' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'src\a1\x.ps1')) @('ambiguous ledger rows bind this session: ')

    # --- anchor file size ---
    $null = Use-Ledger -Rows @((RowA1))
    $pad = { param([int]$Total) $head = $wtA1 + "`n"; [System.IO.File]::WriteAllText((Get-AnchorPath 'sa-size'), ($head + ("`n" * ($Total - $head.Length))), $utf8) }
    [void][IO.Directory]::CreateDirectory((Join-Path $idxDir 'sessions'))
    & $pad 4097
    $len = (Get-Item -LiteralPath (Get-AnchorPath 'sa-size')).Length
    $r = Invoke-Edit -Cwd $repoA -Path (Join-Path $wtA1 'other\x.txt') -Session 'sa-size' -ProjectDir $repoA
    Test-Warn "G2-31 an anchor file of $len bytes (4 KiB + 1) is treated as absent, with a warning" $r @('anchor')
    & $pad 4096
    $len = (Get-Item -LiteralPath (Get-AnchorPath 'sa-size')).Length
    Test-Block "G2-32 an anchor file of $len bytes (4 KiB) is read and binds" (Invoke-Edit -Cwd $repoA -Path (Join-Path $wtA1 'other\x.txt') -Session 'sa-size' -ProjectDir $repoA) @($stdScopeTail)
}

# ===========================================================================
# G3 paths
# ===========================================================================
Invoke-Group 'G3 paths' {
    $null = Use-Ledger -Rows @((RowA1), (RowA2))
    foreach ($tool in @('Edit', 'Write', 'MultiEdit')) {
        Test-Allow "G3-1 $tool reads file_path: in-scope" (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'src\a1\x.ps1') -Tool $tool)
        Test-Block "G3-2 $tool reads file_path: out-of-scope" (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'other\x.ps1') -Tool $tool) @($stdScopeTail)
    }
    Test-Allow 'G3-3 NotebookEdit reads notebook_path: in-scope' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'src\a1\n.ipynb') -Tool 'NotebookEdit')
    Test-Block 'G3-4 NotebookEdit reads notebook_path: out-of-scope' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'other\n.ipynb') -Tool 'NotebookEdit') @($stdScopeTail)

    # relative paths resolve against the event cwd (the process starts elsewhere)
    Test-Allow 'G3-5 relative path src\a1\x.ps1 against cwd A1' (Invoke-Edit -Cwd $wtA1 -Path 'src\a1\x.ps1')
    Test-Allow 'G3-6 relative path src/a1/x.ps1 (forward slashes) against cwd A1' (Invoke-Edit -Cwd $wtA1 -Path 'src/a1/x.ps1')
    Test-Block 'G3-7 relative path other\x.ps1 against cwd A1' (Invoke-Edit -Cwd $wtA1 -Path 'other\x.ps1') @($stdScopeTail)
    Test-Block 'G3-8 relative path ..\other\x.txt against cwd A1\src' (Invoke-Edit -Cwd (Join-Path $wtA1 'src') -Path '..\other\x.txt') @($stdScopeTail)
    Test-Allow 'G3-9 relative path x.ps1 against cwd A1\src\a1' (Invoke-Edit -Cwd (Join-Path $wtA1 'src\a1') -Path 'x.ps1')

    # a Write into a new nested folder is checked through the nearest existing ancestor
    Test-Allow 'G3-10 new nested folder under an in-scope folder' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'src\a1\new1\new2\x.ps1') -Tool 'Write')
    Test-Block 'G3-11 new nested folder under an out-of-scope folder' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'nope\new1\new2\x.ps1') -Tool 'Write') @($stdScopeTail)
    Test-Block 'G3-12 new nested folder inside sibling A2 worktree' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA2 'src\a2\new1\new2\x.ps1') -Tool 'Write') @($stdScopeTail)
    Test-Allow 'G3-13 new nested folder outside every git working tree' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $outside 'new1\new2\x.txt') -Tool 'Write')

    # case and separators, for a positive glob and for a '!' exclusion
    $variantRoot = $wtA1.ToUpperInvariant()
    Test-Allow 'G3-14 upper-case path with forward slashes matches the positive glob src/a1/**' (Invoke-Edit -Cwd $wtA1 -Path ($variantRoot.Replace('\', '/') + '/SRC/A1/X.PS1'))
    Test-Allow 'G3-15 mixed-case folder Docs\Readme.md matches the positive glob docs/**' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'Docs\Readme.md'))
    Test-Block 'G3-16 control: docs/secret/k.txt is blocked by the !docs/secret/** exclusion' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'docs\secret\k.txt')) @($stdScopeTail)
    Test-Block 'G3-17 DOCS\SECRET\K.TXT is blocked by the !docs/secret/** exclusion (exclusion is case-insensitive too)' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'DOCS\SECRET\K.TXT')) @($stdScopeTail)
    Test-Block 'G3-18 docs/Secret/k.txt with forward slashes is blocked by the exclusion' (Invoke-Edit -Cwd $wtA1 -Path ($wtA1.Replace('\', '/') + '/docs/Secret/k.txt')) @($stdScopeTail)

    # outside every git working tree
    Test-Allow 'G3-19 an absolute path outside every git working tree' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $outside 'f.txt'))
    Test-Allow 'G3-20 a relative path that lands outside every git working tree' (Invoke-Edit -Cwd $wtA1 -Path '..\..\outside\f.txt')

    # always in scope
    Test-Allow 'G3-21 .claude/handovers/** is always in scope' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 '.claude\handovers\h.md'))
    Test-Allow 'G3-22 a nested .claude/handovers path is always in scope' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 '.claude\handovers\sub\deep.md'))
    Test-Allow 'G3-23 .claude/coordination/** is always in scope' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 '.claude\coordination\x.md'))
    # The exemption holds only inside a worktree bound to the acting track.
    $coordRel = '.claude\coordination\' + $today + '.md'
    Test-Block 'G3-25 a Write to repo A MAIN checkout .claude\coordination\<date>.md (the live-ledger shape) is blocked' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $repoA $coordRel) -Tool 'Write') @($stdScopeTail)
    Test-Block 'G3-26 a Write to repo A MAIN checkout .claude\handovers\x.md is blocked' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $repoA '.claude\handovers\x.md') -Tool 'Write') @($stdScopeTail)
    Test-Allow 'G3-27 the same ledger-shaped path inside A1 own worktree is allowed' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 $coordRel) -Tool 'Write')
    Test-Allow 'G3-28 .claude\handovers\x.md inside A1 own worktree is allowed' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 '.claude\handovers\x.md') -Tool 'Write')
    Test-Block 'G3-29 .claude\coordination\<date>.md inside sibling A2 worktree is blocked' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA2 $coordRel) -Tool 'Write') @($stdScopeTail)
    Test-Block 'G3-30 .claude\handovers\x.md inside sibling A2 worktree is blocked' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA2 '.claude\handovers\x.md') -Tool 'Write') @($stdScopeTail)
    Test-Block 'G3-24 control: another .claude path is not' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 '.claude\settings.json')) @($stdScopeTail)

    # The case of the RELATIVE part: the hook builds it from git's real-case prefix of the nearest EXISTING folder plus
    # the event's own spelling of the folders that do not exist yet, so only a path into a folder that is not there
    # yet puts the event's case into the match (G3-14 to G3-18 name existing folders and cannot tell a case-sensitive
    # scope match from a case-insensitive one). gen\ and secret\ do not exist in the fixture.
    $null = Use-Ledger -Rows @((New-LedgerRow 'A1' $repoA 'a1-branch' $wtA1 'gen/**' $tokA1 'running'))
    Test-Allow 'G3-31 scope gen/**: a Write to <A1>\GEN\X.PS1 (folder not there yet, upper case) is allowed' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'GEN\X.PS1') -Tool 'Write')
    Test-Allow 'G3-32 scope gen/**: control, the same path in lower case is allowed' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'gen\x.ps1') -Tool 'Write')
    Test-Block 'G3-33 scope gen/**: control, a path outside gen is blocked' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'OTHER\X.PS1') -Tool 'Write') @((Get-ScopeTail 'A1' 'gen/**'))
    $null = Use-Ledger -Rows @((New-LedgerRow 'A1' $repoA 'a1-branch' $wtA1 '**, !secret/**' $tokA1 'running'))
    Test-Block 'G3-34 scope **, !secret/**: a Write to <A1>\SECRET\k.md (folder not there yet, upper case) hits the exclusion' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'SECRET\k.md') -Tool 'Write') @((Get-ScopeTail 'A1' '**, !secret/**'))
    Test-Block 'G3-35 scope **, !secret/**: control, the lower-case path hits the exclusion' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'secret\k.md') -Tool 'Write') @((Get-ScopeTail 'A1' '**, !secret/**'))
    Test-Allow 'G3-36 scope **, !secret/**: control, a path outside the exclusion is allowed' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'public\k.md') -Tool 'Write')
    # Panel on #96: Test-CoordInScope let an LF inside a path dodge a '!' exclusion under a scope such as '**/*'
    # (coord-common C1 holds the red/green rows). The hook never gets that far: GetFullPath refuses an LF inside
    # a path, and the hook blocks with its own text. Pinned as measured; it passes with and without that fix.
    $null = Use-Ledger -Rows @((New-LedgerRow 'A1' $repoA 'a1-branch' $wtA1 '**/*, !secret/**' $tokA1 'running'))
    Test-Block 'G3-40 scope **/*, !secret/**: a Write to <A1>\secret\k<LF>.md (an LF inside the name) is blocked: the path cannot be resolved' (Invoke-Edit -Cwd $wtA1 -Path ((Join-Path $wtA1 'secret\k') + [string][char]10 + '.md') -Tool 'Write') @('cannot be resolved to a full path')
    Test-Allow 'G3-41 scope **/*, !secret/**: control, <A1>\public\k.md is allowed' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'public\k.md') -Tool 'Write')

    # The guard has no glob conversion of its own (it calls Test-CoordInScope, whose anchor is
    # now \z; coord-common C1 holds the red/green rows). It cannot be fed a path ending in LF either:
    # [IO.Path]::GetFullPath trims a final LF, so the hook sees <A1>\README.md. These rows pin that measured
    # behaviour; they pass with and without the \z fix, which only coord-common C1 can see.
    $null = Use-Ledger -Rows @((New-LedgerRow 'A1' $repoA 'a1-branch' $wtA1 'README.md' $tokA1 'running'))
    Test-Allow 'G3-37 scope README.md: control, a Write to <A1>\README.md is allowed' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'README.md') -Tool 'Write')
    Test-Allow 'G3-38 scope README.md: <A1>\README.md plus a final LF reaches the hook as README.md (GetFullPath trims the LF): allowed' (Invoke-Edit -Cwd $wtA1 -Path ((Join-Path $wtA1 'README.md') + [string][char]10) -Tool 'Write')
    Test-Block 'G3-39 scope README.md: control, <A1>\README.md.bak is blocked' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'README.md.bak') -Tool 'Write') @((Get-ScopeTail 'A1' 'README.md'))
}

# ===========================================================================
# G4 aliases
# ===========================================================================
Invoke-Group 'G4 aliases' {
    $null = Use-Ledger -Rows @((RowA1), (RowA2))
    $linkHas = { param($comp, $p) ('coord-scope-guard: ' + $p + ' crosses a junction or symlink at ' + $comp + '; the guard cannot verify where it lands') }

    # junction inside A1's in-scope folder, pointing into sibling A2's worktree
    $jx = Join-Path $wtA1 'src\a1\jx'
    if (New-TestJunction $jx (Join-Path $wtA2 'src\a2')) {
        try {
            $p = Join-Path $jx 'target.txt'
            Test-Block 'G4-1 an in-scope-looking path through a junction into a sibling worktree' (Invoke-Edit -Cwd $wtA1 -Path $p) @((& $linkHas $jx $p))
            $p = Join-Path $jx 'newdir\f.txt'
            Test-Block 'G4-2 a new file beneath a linked folder' (Invoke-Edit -Cwd $wtA1 -Path $p -Tool 'Write') @((& $linkHas $jx $p))
            Test-Block 'G4-3 the junction itself as the target' (Invoke-Edit -Cwd $wtA1 -Path $jx -Tool 'Write') @((& $linkHas $jx $jx))
            Test-Allow 'G4-4 control: the same junction path from a session with no acting row (cwd A main)' (Invoke-Edit -Cwd $repoA -Path (Join-Path $jx 'target.txt'))
        }
        finally { Remove-TestLink $jx }
    }
    else { Skip 'G4-1..4 junction rows' 'New-Item -ItemType Junction failed here' }

    # symlinked file (needs a privilege; skipped when it cannot be created)
    $sl = Join-Path $wtA1 'src\a1\sl.txt'
    if (New-TestSymlink $sl (Join-Path $wtA2 'src\a2\target.txt')) {
        try { Test-Block 'G4-5 a symlinked file' (Invoke-Edit -Cwd $wtA1 -Path $sl) @((& $linkHas $sl $sl)) }
        finally { Remove-TestLink $sl }
    }
    else { Skip 'G4-5 a symlinked file' 'New-Item -ItemType SymbolicLink needs admin or Developer Mode here and could not create the link' }

    # an outside-the-tree path through a linked temp folder into the repo
    $tmpLink = Join-Path $root 'tmplink'
    if (New-TestJunction $tmpLink $wtA2) {
        try {
            $p = Join-Path $tmpLink 'src\a2\x.txt'
            Test-Block 'G4-6 an outside-every-tree path through a linked temp folder that points into a repo' (Invoke-Edit -Cwd $wtA1 -Path $p -Tool 'Write') @((& $linkHas $tmpLink $p))
        }
        finally { Remove-TestLink $tmpLink }
    }
    else { Skip 'G4-6 temp link into the repo' 'New-Item -ItemType Junction failed here' }
}

# ===========================================================================
# G5 index, trust, size
# ===========================================================================
Invoke-Group 'G5 index, trust, size' {
    # no index: allow with zero git calls
    Reset-State
    $files = New-StubFiles 'noindex'
    $env1 = @{ CSG_LOG = $files.Log; CSG_COUNT = $files.Count; CSG_REAL = $realGit }
    $r = Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'other\x.txt') -ExtraEnv $env1 -StubDir $stubGeneric
    Test-Allow 'G5-1 no index file (today or yesterday): out-of-scope path' $r
    Report ((Test-Ran $r @('allow')) -and (Get-StubCalls $files) -eq 0 -and -not (Test-Path -LiteralPath $files.Log)) 'G5-2 no index file: the stub git on PATH was called zero times' ("calls: $(Get-StubCalls $files)")
    # control: the same stub does see calls when an index exists
    $files = New-StubFiles 'withindex'
    $null = Use-Ledger -Rows @((RowA1))
    $r = Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'other\x.txt') -ExtraEnv @{ CSG_LOG = $files.Log; CSG_COUNT = $files.Count; CSG_REAL = $realGit } -StubDir $stubGeneric
    Test-Block 'G5-3 control: with an index, the pass-through stub still lets the guard block' $r @($stdScopeTail)
    Report ((Get-StubCalls $files) -gt 0) 'G5-4 control: with an index the guard does call git (so the zero-call row can fail)' ("calls: $(Get-StubCalls $files)")

    # torn last line, duplicates, entry past 64 KiB
    Reset-State
    $ledger = Set-TestLedger -Rows @((RowA1))
    Set-TestIndex -Date $today -Paths @($ledger) -NoFinalNewline
    Test-Allow 'G5-5 an index line with no newline (torn write) is dropped: out-of-scope path allowed' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'other\x.txt'))
    Set-TestIndex -Date $today -Paths @($ledger)
    Test-Block 'G5-6 control: the same line with its newline is read' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'other\x.txt')) @($stdScopeTail)
    $variant = $ledger.ToUpperInvariant().Replace('\', '/')
    Set-TestIndex -Date $today -Paths @($ledger, $variant)
    Test-Allow 'G5-7 a duplicate in another case with / separators counts once: in-scope edit is not ambiguous' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'src\a1\x.ps1'))
    Test-Block 'G5-8 the duplicate counted once: out-of-scope edit gets the scope refusal' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'other\x.txt')) @($stdScopeTail)
    $decoy = (Join-Path $root 'decoy') + '\.claude\coordination\' + $today + '.md'
    # enough decoy lines to pass 64 KiB whatever the scratch path's length (700 short lines once stayed under it)
    $decoyCount = [int][Math]::Ceiling(70000 / ($decoy.Length + 1))
    $many = @(); for ($i = 0; $i -lt $decoyCount; $i++) { $many += $decoy }
    Set-TestIndex -Date $today -Paths ($many + $ledger)
    Test-Warn 'G5-9 the ledger entry lies past the first 64 KiB of the index: not read, stale-index warning' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'other\x.txt')) @(('ledger index ' + (Join-Path $idxDir ($today + '.ledgers')) + ' holds more than 8 ledgers or 64 KiB; only the first 8 are read'))

    # tracked ledger is skipped
    $null = Use-Ledger -Rows @((RowA1))
    $rel = '.claude/coordination/' + $today + '.md'
    try {
        Invoke-HookTestGit $repoA @('add', '-f', '--', $rel)
        Invoke-HookTestGit $repoA @('-c', 'core.autocrlf=false', 'commit', '--quiet', '-m', 'track the ledger')
        Test-Allow 'G5-10 a tracked ledger is skipped: out-of-scope path allowed' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'other\x.txt'))
    }
    finally {
        & git -C $repoA rm --cached --quiet -- $rel 2>$null | Out-Null
        & git -C $repoA -c core.autocrlf=false commit --quiet -m 'untrack the ledger' 2>$null | Out-Null
    }

    # a ledger behind a junctioned .claude\coordination is skipped
    $null = Use-Ledger -Rows @((RowA1))
    $cd = Join-Path $repoA '.claude\coordination'
    $real = Join-Path $root 'realcoord'
    $moved = $false
    try {
        Move-Item -LiteralPath $cd -Destination $real
        $moved = $true
        if (New-TestJunction $cd $real) {
            # skipped silently (a trust rule) or with the not-canonical warning (git resolves the junction first); never a block
            $r = Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'other\x.txt')
            Report (Test-Ran $r @('allow', 'warn')) 'G5-11 .claude\coordination is a junction: the listed ledger is skipped (allowed; a skipped warning is fine)' ("kind=$((Get-Verdict $r).Kind) code=$($r.Code) stderr=$($r.Err)")
            Remove-TestLink $cd
        }
        else { Skip 'G5-11 junctioned .claude\coordination' 'New-Item -ItemType Junction failed here' }
    }
    finally {
        if ($moved) { if (Test-Path -LiteralPath $cd) { Remove-TestLink $cd }; Move-Item -LiteralPath $real -Destination $cd }
    }

    # ledger sizes with the Tracks table near the top
    foreach ($size in @(16384, 78175, 921600)) {
        $lp = Use-Ledger -Rows @((RowA1), (RowA2)) -TargetBytes $size
        $len = (Get-Item -LiteralPath $lp).Length
        Report ($len -ge $size) "G5-12 fixture ledger is at least $size bytes" "is $len"
        Test-Block "G5-13 a $len-byte ledger is read and guarded: out-of-scope path" (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'other\x.txt')) @($stdScopeTail)
        Test-Allow "G5-14 a $len-byte ledger is read and guarded: in-scope path" (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'src\a1\x.ps1'))
    }

    # Tracks table past the 1 MiB cap, and one that is not ended before end of file
    $lp = Use-Ledger -Rows @((RowA1)) -PadBeforeBytes (1048576 + 4096)
    Test-Warn 'G5-15 the Tracks table lies after the 1 MiB cap: malformed warning, edit allowed' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'other\x.txt')) @(('ledger ' + $lp + ' skipped: '))
    $lp = Use-Ledger -Rows @((RowA1)) -Unterminated
    Test-Warn 'G5-16 the Tracks table is not ended before end of file: malformed warning, edit allowed' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'other\x.txt')) @(('ledger ' + $lp + ' skipped: '))

    # a row appended to Tracks between two calls is seen by the second
    $null = Use-Ledger -Rows @((RowA2))
    Test-Allow 'G5-17 before the row exists: A1 has no live row, out-of-scope path allowed' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'other\x.txt'))
    $null = Set-TestLedger -Rows @((RowA2), (RowA1))
    Test-Block 'G5-18 after the row is appended: the second call sees it and blocks' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'other\x.txt')) @($stdScopeTail)
}

# ===========================================================================
# G6 canonical ledger
# ===========================================================================
Invoke-Group 'G6 canonical ledger' {
    $canonical = Get-LedgerPath $repoA $today
    $staleNote = "is not the canonical ledger; the coordinator's ledger is " + $canonical

    # stale copy alone
    Reset-State
    $stale = Set-TestLedger -Rows @((RowA1)) -Repo $wtA1
    Set-TestIndex -Date $today -Paths @($stale)
    Test-Warn 'G6-1 a stale copy in the A1 worktree, indexed by hand, is skipped alone; the warning names the canonical path' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'other\x.txt')) @($staleNote)

    # stale copy beside the canonical one, conflicting scope
    Reset-State
    $stale = Set-TestLedger -Rows @((New-LedgerRow 'A1' $repoA 'a1-branch' $wtA1 '**' $tokA1 'running')) -Repo $wtA1
    $canon = Set-TestLedger -Rows @((RowA1))
    Set-TestIndex -Date $today -Paths @($stale, $canon)
    Test-Block 'G6-2 stale copy (scope **) beside the canonical ledger (narrow scope): the canonical row decides, out-of-scope path blocked with the canonical globs' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'other\x.txt')) @((Get-ScopeTail 'A1' $scopeA1))
    Test-NoBlock 'G6-3 stale copy beside the canonical ledger: an in-scope path is not blocked (no ambiguity from the copy)' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'src\a1\x.ps1'))

    # conflicting status: the copy says live, the canonical ledger says DONE
    Reset-State
    $stale = Set-TestLedger -Rows @((New-LedgerRow 'A1' $repoA 'a1-branch' $wtA1 'zzz/**' $tokA1 'running')) -Repo $wtA1
    $canon = Set-TestLedger -Rows @((RowA1 -Status 'DONE; merged'))
    Set-TestIndex -Date $today -Paths @($stale, $canon)
    Test-NoBlock 'G6-4 stale copy says live, canonical ledger says DONE: the canonical status decides, out-of-scope path allowed' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'other\x.txt'))

    # a UNC entry is skipped without a stall
    Reset-State
    $canon = Set-TestLedger -Rows @((RowA1))
    $unc = '\\csg-no-such-host.invalid\share\.claude\coordination\' + $today + '.md'
    Set-TestIndex -Date $today -Paths @($unc, $canon)
    $r = Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'other\x.txt')
    Test-Block 'G6-5 a UNC entry in the index is skipped; the canonical ledger after it still guards' $r @($stdScopeTail)
    Report ((Test-Ran $r @('block')) -and $r.Ms -lt ($baselineMs + 3400)) 'G6-6 a UNC entry does not stall the call' ("took $($r.Ms) ms, limit $($baselineMs + 3400) ms")

    # a ledger not named for the index's date
    Reset-State
    $wrongDay = Set-TestLedger -Rows @((RowA1)) -Date $yday
    Set-TestIndex -Date $today -Paths @($wrongDay)
    Test-NoBlock 'G6-7 a ledger file named for yesterday listed in today index is refused: out-of-scope path allowed' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'other\x.txt'))
}

# ===========================================================================
# G8 failure and output
# ===========================================================================
Invoke-Group 'G8 failure and output' {
    $outPath = Join-Path $wtA1 'other\x.txt'

    # malformed Tracks tables
    $lp = Use-Ledger -Rows @((RowA2), '| broken | row |')
    Test-Warn 'G8-1 a Tracks row with the wrong cell count: malformed warning, edit allowed' (Invoke-Edit -Cwd $wtA1 -Path $outPath) @(('ledger ' + $lp + ' skipped: '))
    $noScope = @('Track', 'Repo', 'Session', 'Model', 'Cwd', 'Branch', 'PR', 'Status')
    $lp = Use-Ledger -Rows @((RowA1)) -Columns $noScope
    Test-Warn 'G8-2 a Tracks table with no Scope column: malformed warning, edit allowed' (Invoke-Edit -Cwd $wtA1 -Path $outPath) @(('ledger ' + $lp + ' skipped: '))

    # unreadable listed ledger: another handle holds it with no sharing
    $lp = Use-Ledger -Rows @((RowA1))
    $fs = [System.IO.File]::Open($lp, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try { Test-Warn 'G8-3 an unreadable listed ledger: warning, edit allowed' (Invoke-Edit -Cwd $wtA1 -Path $outPath) @(('ledger ' + $lp + ' skipped: ')) }
    finally { $fs.Dispose() }

    # a git failure after a row has bound the session (G8-4 is only a pass-through calibration of the stub)
    $null = Use-Ledger -Rows @((RowA1))
    $files = New-StubFiles 'calib'
    $rc = Invoke-Edit -Cwd $wtA1 -Path $outPath -ExtraEnv @{ CSG_COUNT = $files.Count; CSG_REAL = $realGit } -StubDir $stubGeneric
    $nCalls = Get-StubCalls $files
    Test-Block 'G8-4 calibration: the pass-through stub does not change the verdict' $rc @($stdScopeTail)
    # Fail by argument: only the target's tree lookup (git -C <A2 folder>) names the A2 worktree; the trust check
    # and the binding of A1 run before it and never mention A2, so a failure here is a failure AFTER binding.
    $a2Path = Join-Path $wtA2 'src\a2\newdir\x.txt'
    $ctl = Invoke-Edit -Cwd $wtA1 -Path $a2Path -Tool 'Write'
    Test-Block 'G8-5a control: a Write into sibling A2 worktree is refused when git works' $ctl @($stdScopeTail)
    $files = New-StubFiles 'failmatch'
    $rf = Invoke-Edit -Cwd $wtA1 -Path $a2Path -Tool 'Write' -ExtraEnv @{ CSG_LOG = $files.Log; CSG_REAL = $realGit; CSG_FAIL_MATCH = $wtA2; CSG_FAIL_MATCH2 = $wtA2.Replace('\', '/') } -StubDir $stubGeneric
    Test-Warn 'G8-5 git fails on the call that names the target worktree (after A1 is bound): warning that the edit is NOT guarded, edit allowed' $rf @('git failed (', '); this edit is NOT guarded')

    # branch keyed, not folder: two worktrees swap folders
    $swA = Join-Path $root 'wt\SW1'
    $swB = Join-Path $root 'wt\SW2'
    try {
        New-HookTestWorktree -Repo $repoA -Path $swA -Branch 'br-x'
        New-HookTestWorktree -Repo $repoA -Path $swB -Branch 'br-y'
        Invoke-HookTestGit $swA @('checkout', '--quiet', '--detach')
        Invoke-HookTestGit $swB @('checkout', '--quiet', 'br-x')
        Invoke-HookTestGit $swA @('checkout', '--quiet', 'br-y')
        $bx = (& git -C $swB branch --show-current 2>$null | Out-String).Trim()
        $by = (& git -C $swA branch --show-current 2>$null | Out-String).Trim()
        Report ($bx -eq 'br-x' -and $by -eq 'br-y') 'G8-6 fixture: SW2 is on br-x and SW1 on br-y (folders swapped)' "SW2=$bx SW1=$by"
        $rx = New-LedgerRow 'X' $repoA 'br-x' $swA 'xx/**' ($idp + '11111111') 'running'
        $ry = New-LedgerRow 'Y' $repoA 'br-y' $swB 'yy/**' ($idp + '22222222') 'running'
        $null = Use-Ledger -Rows @($rx, $ry)
        Test-Allow 'G8-7 SW2 (branch br-x, ledger Cwd says SW1): track X in-scope path' (Invoke-Edit -Cwd $swB -Path (Join-Path $swB 'xx\f.txt'))
        Test-Block 'G8-8 SW2 (branch br-x): track Y scope is not applied, the yy path is blocked as track X' (Invoke-Edit -Cwd $swB -Path (Join-Path $swB 'yy\f.txt')) @((Get-ScopeTail 'X' 'xx/**'))
        Test-Allow 'G8-9 SW1 (branch br-y): track Y in-scope path' (Invoke-Edit -Cwd $swA -Path (Join-Path $swA 'yy\f.txt'))
        Test-Block 'G8-10 SW1 (branch br-y): the xx path is blocked as track Y' (Invoke-Edit -Cwd $swA -Path (Join-Path $swA 'xx\f.txt')) @((Get-ScopeTail 'Y' 'yy/**'))
    }
    finally {
        & git -C $repoA worktree remove --force $swA 2>$null | Out-Null
        & git -C $repoA worktree remove --force $swB 2>$null | Out-Null
    }

    # a bracketed path runs its own copy: feat[1] beside feat1
    $skillDir = Join-Path (Split-Path -Parent (Split-Path -Parent $hookPath)) 'scripts'
    $hookDir = Split-Path -Parent $hookPath
    if ((Test-Path -LiteralPath $skillDir) -and (Test-Path -LiteralPath $hookPath)) {
        $brRoot = Join-Path $root 'br'
        $own = Join-Path $brRoot 'feat[1]'
        $sib = Join-Path $brRoot 'feat1'
        foreach ($c in @($own, $sib)) {
            Copy-HookTestScripts -SourceDir $hookDir -DestDir (Join-Path $c 'hooks')
            Copy-HookTestScripts -SourceDir $skillDir -DestDir (Join-Path $c 'scripts')
        }
        # feat1's coord-common.ps1 is a stand-in: it leaves a marker, then loads the real helper.
        $sibSkills = Join-Path $sib 'scripts'
        $marker = Join-Path $sib 'sibling-ran.txt'
        Move-Item -LiteralPath (Join-Path $sibSkills 'coord-common.ps1') -Destination (Join-Path $sibSkills 'coord-common.real.ps1')
        [System.IO.File]::WriteAllText((Join-Path $sibSkills 'coord-common.ps1'), ("[System.IO.File]::AppendAllText('" + $marker.Replace("'", "''") + "', 'x')`r`n. (Join-Path `$PSScriptRoot 'coord-common.real.ps1')`r`n"), $utf8)
        $null = Use-Ledger -Rows @((RowA1))
        $ownHook = Join-Path $own 'hooks\coord-scope-guard.ps1'
        $r = Invoke-Edit -Cwd $wtA1 -Path $outPath -Script $ownHook -Launcher 'escaped'
        Test-Block 'G8-11 the hook started from feat[1] (hooks.json launcher) loads its own helpers and blocks' $r @($stdScopeTail)
        Report (-not (Test-Path -LiteralPath $marker)) 'G8-12 the sibling feat1 copy of coord-common.ps1 was not loaded' 'the stand-in in feat1 ran'
    }
    else { Report $false 'G8-11 bracketed path' "no hook folder or no scripts folder beside $hookPath" }

    # non-events and unparseable input are silent allows
    $null = Use-Ledger -Rows @((RowA1))
    $stop = ConvertTo-HookTestAsciiJson (ConvertTo-Json -InputObject ([ordered]@{ session_id = 's'; hook_event_name = 'Stop'; cwd = $wtA1 }) -Compress)
    Test-Allow 'G8-13 an event that is neither SessionStart nor PreToolUse' (Invoke-Guard -Json $stop)
    Test-Warn 'G8-14 unparseable stdin: one systemMessage saying the guard did not run' (Invoke-Guard -Json '{not json') @('event could not be read (', 'did not run')
    Test-Allow 'G8-15 empty stdin' (Invoke-Guard -Json '')
    Test-Allow 'G8-16 a parsed PreToolUse event for a tool other than the four stays silent' (Invoke-Edit -Cwd $wtA1 -Path $outPath -Tool 'Bash')
}

# ===========================================================================
# G9 runtime
# ===========================================================================
Invoke-Group 'G9 runtime' {
    $outPath = Join-Path $wtA1 'other\x.txt'
    $limit = $baselineMs + 3400   # wall-clock minus the start-up baseline must stay within 3.4 s (3 s budget + kill + jitter)

    # four listed 78 KiB ledgers
    Reset-State
    $paths = @()
    $paths += Set-TestLedger -Rows @((RowA1), (RowA2)) -Repo $repoA -TargetBytes 80000
    $paths += Set-TestLedger -Rows @((RowB1)) -Repo $repoB -TargetBytes 80000
    $paths += Set-TestLedger -Rows @((New-LedgerRow 'TC' $repoC 'main' $repoC 'lib/**' ($idp + 'c1c1c1c1') 'running')) -Repo $repoC -TargetBytes 80000
    $paths += Set-TestLedger -Rows @((New-LedgerRow 'TD' $repoD 'main' $repoD 'lib/**' ($idp + 'd1d1d1d1') 'running')) -Repo $repoD -TargetBytes 80000
    Set-TestIndex -Date $today -Paths $paths
    $ms = @(); $last = $null
    for ($i = 0; $i -lt 3; $i++) { $last = Invoke-Edit -Cwd $wtA1 -Path $outPath; $ms += [int]$last.Ms }
    $sorted = @($ms | Sort-Object)
    $processing = $sorted[1] - $baselineMs
    Write-Host ("info  four 78 KiB ledgers: wall-clock {0} ms (runs: {1}), start-up baseline {2} ms, processing about {3} ms" -f $sorted[1], ($ms -join '/'), $baselineMs, $processing)
    Test-Block 'G9-1 four listed 78 KiB ledgers: the call still blocks the out-of-scope path' $last @($stdScopeTail)
    Report ((Test-Ran $last @('block')) -and $processing -lt 1000) 'G9-2 four listed 78 KiB ledgers: processing (median wall-clock minus the powershell.exe start-up baseline) under 1 s' "median wall-clock $($sorted[1]) ms, baseline $baselineMs ms"

    # an index of 9 entries reads the first 8 and warns
    Reset-State
    $a = Set-TestLedger -Rows @((RowA1))
    $fill = @(); for ($i = 1; $i -le 8; $i++) { $fill += ((Join-Path $root ('decoy' + $i)) + '\.claude\coordination\' + $today + '.md') }
    Set-TestIndex -Date $today -Paths (@($a) + $fill)
    $warnText = 'ledger index ' + (Join-Path $idxDir ($today + '.ledgers')) + ' holds more than 8 ledgers or 64 KiB; only the first 8 are read'
    Test-Warn 'G9-3 an index of 9 entries: the first 8 are read, the stale-index warning is sent' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'src\a1\x.ps1')) @($warnText)
    # ninth entry holds a row that would make A1 ambiguous if it were read
    Reset-State
    $a = Set-TestLedger -Rows @((RowA1))
    $dupB = Set-TestLedger -Rows @((New-LedgerRow 'A1dup' $repoA 'a1-branch' $wtA1 'zz/**' $tokA1 'running')) -Repo $repoB
    $fill7 = @(); for ($i = 1; $i -le 7; $i++) { $fill7 += ((Join-Path $root ('decoy' + $i)) + '\.claude\coordination\' + $today + '.md') }
    Set-TestIndex -Date $today -Paths (@($fill7) + @($a, $dupB))
    Test-Block 'G9-4 an index of 9 entries: the 8th entry (A ledger) is read, the 9th (a conflicting row) is not' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'other\x.txt')) @($stdScopeTail)

    # a git that sleeps 10 s per call
    $null = Use-Ledger -Rows @((RowA1))
    $addr = New-LoopbackAddr
    $r = Invoke-Edit -Cwd $wtA1 -Path $outPath -StubDir $stubGeneric -ExtraEnv @{ CSG_REAL = $realGit; CSG_SLEEP_PINGS = '11'; CSG_SLEEP_ADDR = $addr }
    Write-Host ("info  git sleeping 10 s per call: wall-clock {0} ms (start-up baseline {1} ms)" -f $r.Ms, $baselineMs)
    Test-Warn 'G9-5 a git that sleeps 10 s: the call allows with the timeout warning' $r @('timed out after ', ' ms (', '); this edit is NOT guarded')
    Report ((Test-Ran $r @('warn')) -and $r.Ms -lt $limit) 'G9-6 a git that sleeps 10 s: the call ends inside the 3 s budget (plus start-up and the kill)' "took $($r.Ms) ms, limit $limit ms"
    Test-NoLeftover 'G9-7 a git that sleeps 10 s' @($addr, $stubGeneric) $r

    # a git that sleeps ~1 s per call: each call is under the 2 s bound, together past the 3 s budget
    $addr = New-LoopbackAddr
    $r = Invoke-Edit -Cwd $wtA1 -Path $outPath -StubDir $stubGeneric -ExtraEnv @{ CSG_REAL = $realGit; CSG_SLEEP_PINGS = '2'; CSG_SLEEP_ADDR = $addr }
    Write-Host ("info  git sleeping about 1 s per call: wall-clock {0} ms (start-up baseline {1} ms)" -f $r.Ms, $baselineMs)
    Test-Warn 'G9-8 a git that sleeps about 1 s per call: the budget runs out, the call allows with the deadline warning' $r @('timed out after ', ' ms (', '); this edit is NOT guarded')
    Report ((Test-Ran $r @('warn')) -and $r.Ms -lt $limit) 'G9-9 a git that sleeps about 1 s per call: the call ends inside the budget' "took $($r.Ms) ms, limit $limit ms"
    Test-NoLeftover 'G9-10 a git that sleeps about 1 s per call' @($addr, $stubGeneric) $r

    # the git call made through Get-CoordMainRoot is bounded the same way
    $addr = New-LoopbackAddr
    $r = Invoke-Edit -Cwd $wtA1 -Path $outPath -StubDir $stubGeneric -ExtraEnv @{ CSG_REAL = $realGit; CSG_SLEEP_PINGS = '11'; CSG_SLEEP_ADDR = $addr; CSG_SLEEP_MATCH = 'worktree list' }
    Write-Host ("info  only 'git worktree list' sleeping 10 s: wall-clock {0} ms" -f $r.Ms)
    Test-Warn 'G9-11 only the Get-CoordMainRoot call (worktree list) sleeps 10 s: timeout warning, edit allowed' $r @('timed out after ', '); this edit is NOT guarded')
    Report ((Test-Ran $r @('warn')) -and $r.Ms -lt $limit) 'G9-12 only the worktree-list call sleeps 10 s: the call ends inside the budget' "took $($r.Ms) ms, limit $limit ms"
    Test-NoLeftover 'G9-13 only the worktree-list call sleeps' @($addr, $stubGeneric) $r

    # a git that starts a child holding its stdout and exits at once
    $addr = New-LoopbackAddr
    $files = New-StubFiles 'child'
    $r = Invoke-Edit -Cwd $wtA1 -Path $outPath -StubDir $stubChild -ExtraEnv @{ CSG_LOG = $files.Log; CSG_CHILD_ADDR = $addr }
    Write-Host ("info  git leaving a child on its stdout (8 s): wall-clock {0} ms" -f $r.Ms)
    Test-NoBlock 'G9-14 a git whose child holds its stdout open' $r
    Report ((Test-Ran $r @('allow', 'warn')) -and $r.Ms -lt $limit) 'G9-15 a git whose child holds its stdout open: the call returns inside the budget, not after the child ends (about 8 s)' "took $($r.Ms) ms, limit $limit ms"
    Report (Test-Path -LiteralPath $files.Log) 'G9-16 the child-holder stub was reached (the row exercises the stdout path)' 'the stub git was never called'
    Start-Sleep -Milliseconds 300
    $left = Get-LeftoverProcs @($addr)
    if ($null -ne $left) { foreach ($p in @($left)) { & taskkill.exe /F /T /PID $p.ProcessId 2>$null | Out-Null } }
}

# ===========================================================================
# G10 midnight (COORD_TODAY)
# ===========================================================================
Invoke-Group 'G10 midnight' {
    $outPath = Join-Path $wtA1 'other\x.txt'
    function Get-RolloverText([string]$Track, [string]$YLedger) {
        return ('track ' + $Track + ' was live yesterday (' + $YLedger + ") and has no row in today's ledgers; edits are NOT guarded until the coordinator carries the row forward or marks it DONE")
    }

    # yesterday's ledger with A1 live; today's index absent
    $yl = Use-Ledger -Rows @((RowA1)) -Date $yday
    Test-Warn "G10-1 no index today, yesterday's ledger has A1 live: warns, yesterday's scope is not enforced" (Invoke-Edit -Cwd $wtA1 -Path $outPath) @((Get-RolloverText 'A1' $yl))

    # today's index empty
    $null = Use-Ledger -Rows @((RowA1)) -Date $yday
    Set-TestIndex -Date $today -Paths @()
    Test-Warn "G10-2 today's index exists and is empty: same warning" (Invoke-Edit -Cwd $wtA1 -Path $outPath) @((Get-RolloverText 'A1' $yl))

    # today's index lists only an untrusted (tracked) ledger
    $null = Use-Ledger -Rows @((RowA1)) -Date $yday
    $tl = Set-TestLedger -Rows @((RowA2)) -Date $today
    Set-TestIndex -Date $today -Paths @($tl)
    $rel = '.claude/coordination/' + $today + '.md'
    try {
        Invoke-HookTestGit $repoA @('add', '-f', '--', $rel)
        Invoke-HookTestGit $repoA @('-c', 'core.autocrlf=false', 'commit', '--quiet', '-m', 'track the ledger')
        Test-Warn "G10-3 today's index lists only an untrusted (tracked) ledger: same warning" (Invoke-Edit -Cwd $wtA1 -Path $outPath) @((Get-RolloverText 'A1' $yl))
    }
    finally {
        & git -C $repoA rm --cached --quiet -- $rel 2>$null | Out-Null
        & git -C $repoA -c core.autocrlf=false commit --quiet -m 'untrack the ledger' 2>$null | Out-Null
    }

    # trusted ledger with an empty Tracks table
    $null = Use-Ledger -Rows @((RowA1)) -Date $yday
    $null = Use-Ledger -Rows @() -Date $today -KeepState
    Test-Warn "G10-4 today's index lists a trusted ledger with an empty Tracks table: same warning" (Invoke-Edit -Cwd $wtA1 -Path $outPath) @((Get-RolloverText 'A1' $yl))

    # an unrelated coordinator's trusted ledger, registered first
    $null = Use-Ledger -Rows @((RowA1)) -Date $yday
    $other = Set-TestLedger -Rows @((RowB1)) -Date $today -Repo $repoB
    Set-TestIndex -Date $today -Paths @($other)
    Test-Warn "G10-5 today's index lists an unrelated coordinator's trusted ledger: same warning" (Invoke-Edit -Cwd $wtA1 -Path $outPath) @((Get-RolloverText 'A1' $yl))

    # partial carry-forward: A2 carried, A1 not
    $null = Use-Ledger -Rows @((RowA1), (RowA2)) -Date $yday
    $null = Use-Ledger -Rows @((RowA2)) -Date $today -KeepState
    Test-Block 'G10-6 today ledger carries A2 only: A2 is guarded' (Invoke-Edit -Cwd $wtA2 -Path (Join-Path $wtA2 'other\x.txt')) @((Get-ScopeTail 'A2' 'src/a2/**'))
    Test-Warn 'G10-7 today ledger carries A2 only: A1 is warned about, not guarded' (Invoke-Edit -Cwd $wtA1 -Path $outPath) @((Get-RolloverText 'A1' $yl))

    # A1 carried forward: guarded, no warning
    $null = Use-Ledger -Rows @((RowA1)) -Date $yday
    $null = Use-Ledger -Rows @((RowA1)) -Date $today -KeepState
    Test-Block 'G10-8 A1 carried forward: guarded (out-of-scope path blocked)' (Invoke-Edit -Cwd $wtA1 -Path $outPath) @($stdScopeTail)
    Test-Allow 'G10-9 A1 carried forward: in-scope path allowed with no warning' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'src\a1\x.ps1'))

    # A1 marked DONE today, or yesterday
    $null = Use-Ledger -Rows @((RowA1)) -Date $yday
    $null = Use-Ledger -Rows @((RowA1 -Status 'DONE; merged')) -Date $today -KeepState
    Test-Allow "G10-10 A1 marked DONE in today's ledger (live yesterday): silent allow" (Invoke-Edit -Cwd $wtA1 -Path $outPath)
    $null = Use-Ledger -Rows @((RowA1 -Status 'DONE; merged')) -Date $yday
    Test-Allow "G10-11 A1 marked DONE in yesterday's ledger, no index today: silent allow" (Invoke-Edit -Cwd $wtA1 -Path $outPath)

    # yesterday's live S1.8, today holds only a DONE S1.7.3 on the same branch
    $s18 = New-LedgerRow 'S1.8' $repoA 'a1-branch' $wtA1 'src/a1/**' $tokA1 'running'
    $s173 = New-LedgerRow 'S1.7.3' $repoA 'a1-branch' $wtA1 'src/a1/**' $tokA1 'DONE; merged'
    $yl = Use-Ledger -Rows @($s18) -Date $yday
    $null = Use-Ledger -Rows @($s173) -Date $today -KeepState
    Test-Warn "G10-12 yesterday's live S1.8, today only a DONE S1.7.3 on the same branch: still warns for S1.8" (Invoke-Edit -Cwd $wtA1 -Path $outPath) @((Get-RolloverText 'S1.8' $yl))

    # neither index: zero git calls
    Reset-State
    $files = New-StubFiles 'midnight-none'
    $r = Invoke-Edit -Cwd $wtA1 -Path $outPath -StubDir $stubGeneric -ExtraEnv @{ CSG_LOG = $files.Log; CSG_COUNT = $files.Count; CSG_REAL = $realGit }
    Test-Allow 'G10-13 neither today nor yesterday has an index' $r
    Report ((Test-Ran $r @('allow')) -and (Get-StubCalls $files) -eq 0) 'G10-14 neither index exists: zero git calls' ("calls: $(Get-StubCalls $files)")

    # an invalid COORD_TODAY is ignored (the real date is used)
    $real = (Get-Date).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    foreach ($bad in @('not-a-date', '2026-02-30', '20261001', '2026-13-45')) {
        $null = Use-Ledger -Rows @((RowA1)) -Date $real
        Test-Block "G10-15 COORD_TODAY='$bad' is ignored, the real date's index is read" (Invoke-Edit -Cwd $wtA1 -Path $outPath -ExtraEnv @{ COORD_TODAY = $bad }) @($stdScopeTail)
    }
}

# ===========================================================================
# G11 diff panel round 1 fixes (F1 to F6) and the coordinator's folders
# ===========================================================================
Invoke-Group 'G11 round-1 fixes' {
    $stdLedger = { $null = Use-Ledger -Rows @((RowA1), (RowA2)) }

    # --- F1: memory and plan folders of the user profile, which is itself a git working tree ---
    & $stdLedger
    $fxHome = Join-Path $root 'home'
    $fxClaude = Join-Path $fxHome '.claude'
    New-TestRepo $fxClaude
    foreach ($rel in @('projects\p\memory\m.md', 'projects\q-r\memory\sub\n.md', 'plans\plan.md', 'skills\x\SKILL.md', 'settings.json', 'projects\p\other\o.md')) { Set-CoordFile $fxClaude $rel "x`n" }
    Invoke-HookTestGit $fxClaude @('-c', 'core.autocrlf=false', 'add', '-A')
    Invoke-HookTestGit $fxClaude @('-c', 'core.autocrlf=false', 'commit', '--quiet', '-m', 'profile files')
    $homeEnv = @{ USERPROFILE = $fxHome; HOME = $fxHome }
    $inTree = (& git -C (Join-Path $fxClaude 'projects') rev-parse --show-toplevel 2>$null | Out-String).Trim()
    Report ($inTree -ne '') 'F1-0 fixture: the fixture profile .claude folder is a git working tree' 'rev-parse printed nothing'
    foreach ($ok in @('projects\p\memory\m.md', 'projects\p\memory\new.md', 'projects\q-r\memory\newdir\z.md', 'plans\plan.md', 'plans\new\p2.md')) {
        Test-Allow "F1-1 a bound track may write ~\.claude\$ok (memory and plans are exempt)" (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $fxClaude $ok) -Tool 'Write' -ExtraEnv $homeEnv)
    }
    foreach ($no in @('skills\x\SKILL.md', 'settings.json', 'projects\p\other\o.md')) {
        Test-Block "F1-2 a bound track may not write ~\.claude\$no (another working tree)" (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $fxClaude $no) -Tool 'Write' -ExtraEnv $homeEnv) @($stdScopeTail)
    }
    Test-Block 'F1-3 control: with the real profile (no USERPROFILE override) the fixture memory path is not exempt' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $fxClaude 'projects\p\memory\m.md') -Tool 'Write') @($stdScopeTail)

    # --- F2: a coordinator checkout session is never bound ---
    & $stdLedger
    $af = Write-AnchorFile 'sa-coord' @($repoA)
    $liveLedger = Get-LedgerPath $repoA $today
    Test-Warn 'F2-1 coordinator (anchor at A main, A ledger indexed) with cwd in A1: an out-of-scope Write is allowed WITH the coordinator-checkout warning naming A1' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'other\x.txt') -Tool 'Write' -Session 'sa-coord' -ProjectDir $repoA) @("this session was opened on the coordinator's checkout", "this edit in track A1's worktree is NOT guarded; start the track in its worktree")
    Test-Allow 'F2-2 coordinator with cwd in A1: a Write to the main checkout ledger (the target is not in a track worktree) is a silent allow' (Invoke-Edit -Cwd $wtA1 -Path $liveLedger -Tool 'Write' -Session 'sa-coord' -ProjectDir $repoA)
    Test-Warn 'T1-1 coordinator with cwd in A main: a Write by absolute path into A1 (a bound track worktree) warns, naming A1' (Invoke-Edit -Cwd $repoA -Path (Join-Path $wtA1 'other\x.txt') -Tool 'Write' -Session 'sa-coord' -ProjectDir $repoA) @("this session was opened on the coordinator's checkout", "this edit in track A1's worktree is NOT guarded; start the track in its worktree")
    Test-Allow 'T1-2 coordinator with cwd in A1: a Write outside every tree is a silent allow' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $outside 'f.txt') -Tool 'Write' -Session 'sa-coord' -ProjectDir $repoA)
    $lines = @([System.IO.File]::ReadAllText($af) -split "`n" | Where-Object { $_.Trim() })
    Report ($lines.Count -eq 1) 'F2-3 the coordinator anchor file keeps one line (no second line is appended)' ("lines: " + ($lines -join ' / '))
    Test-Allow 'F2-6 coordinator with cwd in A main itself editing the ledger: silent allow (the target is not in a linked worktree)' (Invoke-Edit -Cwd $repoA -Path $liveLedger -Tool 'Write' -Session 'sa-coord' -ProjectDir $repoA)
    # control: line 1 is a main checkout but its ledger is NOT listed; the row sits in another listed ledger
    $null = Use-Ledger -Rows @((RowA1)) -Repo $repoB
    $af = Write-AnchorFile 'sa-notcoord' @($repoA)
    Test-Block 'F2-4 control: line 1 is A main but A ledger is not listed: cwd in A1 still binds, out-of-scope Write blocked' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'other\x.txt') -Tool 'Write' -Session 'sa-notcoord' -ProjectDir $repoA) @($stdScopeTail)
    $lines = @([System.IO.File]::ReadAllText($af) -split "`n" | Where-Object { $_.Trim() })
    Report ($lines.Count -eq 2) 'F2-5 control: that session still gets its second anchor line' ("lines: " + ($lines -join ' / '))

    # --- F3: worktree-isolated subagents of the acting repo ---
    & $stdLedger
    $agX = Join-Path $repoA '.claude\worktrees\agent-x'
    $agY = Join-Path $repoA '.claude\worktrees\agent-y'
    try {
        New-HookTestWorktree -Repo $repoA -Path $agX -Branch 'worktree-agent-x'
        New-HookTestWorktree -Repo $repoA -Path $agY -Branch 'feat-y'
        Test-Allow 'F3-1 a target in .claude\worktrees\agent-x on branch worktree-agent-x: in-scope path relative to that worktree is allowed' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $agX 'src\a1\x.ps1') -Tool 'Write')
        Test-Block 'F3-2 the same worktree: an out-of-scope path is blocked' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $agX 'other\x.txt') -Tool 'Write') @($stdScopeTail)
        Test-Block 'F3-3 control: .claude\worktrees\agent-y on a non-agent branch is another working tree, blocked' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $agY 'src\a1\x.ps1') -Tool 'Write') @('coord-scope-guard: ')
    }
    finally {
        & git -C $repoA worktree remove --force $agX 2>$null | Out-Null
        & git -C $repoA worktree remove --force $agY 2>$null | Out-Null
    }

    # --- F5: a failing anchor that binds nothing does not end the run ---
    $null = Use-Ledger -Rows @((RowA1), (RowB1))
    $null = Write-AnchorFile 'sa-f5' @($wtA1)
    $files = New-StubFiles 'f5'
    $failB1 = @{ CSG_LOG = $files.Log; CSG_REAL = $realGit; CSG_FAIL_MATCH = $wtB1; CSG_FAIL_MATCH2 = $wtB1.Replace('\', '/') }
    Test-Block 'F5-1 anchor file binds A1, cwd in B1 whose git calls fail: the out-of-scope Write in A1 still blocks' (Invoke-Edit -Cwd $wtB1 -Path (Join-Path $wtA1 'other\x.txt') -Tool 'Write' -Session 'sa-f5' -StubDir $stubGeneric -ExtraEnv $failB1) @($stdScopeTail)
    Test-Warn 'F5-2 control: no anchor file, the only anchor (cwd B1, a row candidate) fails in git: the git-failed warning, edit allowed' (Invoke-Edit -Cwd $wtB1 -Path (Join-Path $wtB1 'app\x.ps1') -Tool 'Write' -Session 'sa-f5-none' -StubDir $stubGeneric -ExtraEnv $failB1) @('git failed (', '); this edit is NOT guarded')

    # --- R1: every anchor fails in git: fail-open WITH a warning, never silent ---
    $null = Use-Ledger -Rows @((RowA1), (RowA2))
    $null = Write-AnchorFile 'sa-r1' @($wtA1)
    $failA1 = @{ CSG_REAL = $realGit; CSG_FAIL_MATCH = $wtA1; CSG_FAIL_MATCH2 = $wtA1.Replace('\', '/') }
    Test-Warn 'R1-1 the only anchors (file line and cwd) are A1, whose git calls fail: exit 0 with the git-failed warning' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'other\x.txt') -Tool 'Write' -Session 'sa-r1' -StubDir $stubGeneric -ExtraEnv $failA1) @('git failed (', '); this edit is NOT guarded')
    Test-Block 'R1-2 control: the same call with healthy git is blocked by the A1 scope' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'other\x.txt') -Tool 'Write' -Session 'sa-r1') @($stdScopeTail)

    # --- R3: any worktree-agent-* worktree of the row's repo, a sibling's included (the stated limit) ---
    $agS = Join-Path $wtA2 '.claude\worktrees\agent-s'
    try {
        New-HookTestWorktree -Repo $repoA -Path $agS -Branch 'worktree-agent-s'
        Test-Allow 'R3-1 A1 writing an in-scope path in a worktree-agent-* worktree under sibling A2 is allowed (pins the stated limit)' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $agS 'src\a1\x.ps1') -Tool 'Write')
        Test-Block 'R3-2 the same worktree: an out-of-scope path is still blocked' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $agS 'other\x.txt') -Tool 'Write') @($stdScopeTail)
    }
    finally { & git -C $repoA worktree remove --force $agS 2>$null | Out-Null }

    # --- R4: an anchor dropped for a git failure must not hide the track it could have bound ---
    $null = Use-Ledger -Rows @((RowA1), (RowA2))
    $null = Write-AnchorFile 'sa-r4' @($wtA1)
    Test-Warn 'R4-1 anchor file A1 (git fails on it), cwd A2 healthy with another token: judged by A2, the warning names both tracks' (Invoke-Edit -Cwd $wtA2 -Path (Join-Path $wtA2 'src\a2\x.ps1') -Tool 'Write' -Session 'sa-r4' -StubDir $stubGeneric -ExtraEnv $failA1) @('git failed on anchor ', 'which could bind track A1', "judged by track A2's scope")
    Test-Block 'R4-2 the same call with an out-of-scope A2 path is blocked by the A2 scope' (Invoke-Edit -Cwd $wtA2 -Path (Join-Path $wtA2 'other\x.txt') -Tool 'Write' -Session 'sa-r4' -StubDir $stubGeneric -ExtraEnv $failA1) @((Get-ScopeTail 'A2' 'src/a2/**'))

    # --- R1 for real, T2: an anchor with an UNUSUAL layout (a linked worktree whose .git file holds a RELATIVE gitdir)
    #     that git then fails on. The file-read view cannot decide such a folder, so the early "no anchor is in a repo"
    #     exit must still warn (R1); with another anchor binding, the call is judged by that one and warns (T2). ---
    $wtR1 = Join-Path $root 'wt\R1W'
    try {
        New-HookTestWorktree -Repo $repoA -Path $wtR1 -Branch 'r1-branch'
        $gitFile = Join-Path $wtR1 '.git'
        $gdLine = ([System.IO.File]::ReadAllText($gitFile)).Trim()
        $gdLeaf = Split-Path -Leaf ($gdLine.Substring(8).Trim().Replace('/', '\'))
        # git marks a worktree's .git file hidden, and WriteAllText cannot replace a hidden file: clear it first.
        [System.IO.File]::SetAttributes($gitFile, [System.IO.FileAttributes]::Normal)
        [System.IO.File]::WriteAllText($gitFile, ('gitdir: ../../repoA/.git/worktrees/' + $gdLeaf + "`n"), $utf8)
        $topR1 = (& git -C $wtR1 rev-parse --show-toplevel 2>$null | Out-String).Trim()
        Report ($LASTEXITCODE -eq 0 -and $topR1) 'R1-0 fixture: git still resolves the worktree whose .git holds a relative gitdir' "rev-parse: '$topR1'"
        $rowR1 = New-LedgerRow 'R1' $repoA 'r1-branch' $wtR1 'src/r1/**' ($idp + 'a3a3a3a3') 'running'
        $null = Use-Ledger -Rows @((RowA1), (RowA2), $rowR1)
        $null = Write-AnchorFile 'sa-r1u' @($wtR1)
        $failR1 = @{ CSG_REAL = $realGit; CSG_FAIL_MATCH = $wtR1; CSG_FAIL_MATCH2 = $wtR1.Replace('\', '/') }
        Test-Warn 'R1-3 the ONLY anchor is a relative-gitdir worktree whose git calls fail (cwd in a plain folder): exit 0 with the git-failed warning, never a silent allow' (Invoke-Edit -Cwd $plain -Path (Join-Path $wtR1 'other\x.txt') -Tool 'Write' -Session 'sa-r1u' -StubDir $stubGeneric -ExtraEnv $failR1) @('git failed (', '); this edit is NOT guarded')
        Test-Block 'R1-4 control: the same call with healthy git binds R1 through the unusual layout and blocks' (Invoke-Edit -Cwd $plain -Path (Join-Path $wtR1 'other\x.txt') -Tool 'Write' -Session 'sa-r1u') @((Get-ScopeTail 'R1' 'src/r1/**'))
        Test-Warn 'T2-1 anchor file = the failing relative-gitdir worktree, cwd A2 healthy: judged by A2, the warning says the anchor might bind another track' (Invoke-Edit -Cwd $wtA2 -Path (Join-Path $wtA2 'src\a2\x.ps1') -Tool 'Write' -Session 'sa-r1u' -StubDir $stubGeneric -ExtraEnv $failR1) @('git failed on anchor ', 'which might bind another track', "judged by track A2's scope")
        Test-Block 'T2-2 the same call with an out-of-scope A2 path is blocked by the A2 scope' (Invoke-Edit -Cwd $wtA2 -Path (Join-Path $wtA2 'other\x.txt') -Tool 'Write' -Session 'sa-r1u' -StubDir $stubGeneric -ExtraEnv $failR1) @((Get-ScopeTail 'A2' 'src/a2/**'))
    }
    finally { & git -C $repoA worktree remove --force $wtR1 2>$null | Out-Null }

    # --- T2: a cross-repo pair with one token is one track: a dropped anchor of the pair's other row is no R4 warning ---
    $pairB = New-LedgerRow 'A1-B' $repoB 'b1-branch' $wtB1 'lib/**' $tokA1 'running'
    $null = Use-Ledger -Rows @((RowA1), $pairB)
    $null = Write-AnchorFile 'sa-t2' @($wtA1)
    $failA1b = @{ CSG_REAL = $realGit; CSG_FAIL_MATCH = $wtA1; CSG_FAIL_MATCH2 = $wtA1.Replace('\', '/') }
    Test-Allow 'T2-3 anchor file A1 (git fails on it), cwd B1 (its same-token cross-repo row binds): no R4 warning, in-scope B1 path allowed' (Invoke-Edit -Cwd $wtB1 -Path (Join-Path $wtB1 'lib\x.ps1') -Tool 'Write' -Session 'sa-t2' -StubDir $stubGeneric -ExtraEnv $failA1b)

    # --- T3: rollover with a failing anchor that would bind yesterday's row ---
    $null = Use-Ledger -Rows @((RowA1)) -Date $yday
    $null = Use-Ledger -Rows @() -Date $today -KeepState
    Test-Warn "T3-1 today's ledger has no row, yesterday's has A1 live, and the anchor that would bind it fails in git: the git-failed warning, edit allowed" (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'other\x.txt') -Tool 'Write' -StubDir $stubGeneric -ExtraEnv $failA1b) @('git failed (', '); this edit is NOT guarded')

    # --- folders outside every working tree stay allowed for a bound track: an app-data folder and a temp scratchpad ---
    & $stdLedger
    Test-Allow 'N-1 a bound A1 Write to a folder under %APPDATA% (outside every tree)' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $env:APPDATA 'SomeApp\notes\x.md') -Tool 'Write')
    Test-Allow 'N-2 a bound A1 Write to the real scratchpad root %TEMP%\claude\<id>\scratchpad\x.txt' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $env:TEMP 'claude\proj-x\0000\scratchpad\x.txt') -Tool 'Write')
}

# ===========================================================================
# S6 plugin wiring: hooks.json and its launcher, the layout, the off switch,
# the anchor policy, name-only Session cells, a session with no ledger
# ===========================================================================
Invoke-Group 'S6 plugin wiring' {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $hooksJsonPath = Join-Path $repoRoot 'hooks\hooks.json'
    # The launcher text: the plugin root comes from the environment variable Claude Code exports to a hook (no
    # ${...} substitution inside the text, so no quoting of the path), the path is wildcard-escaped so a '[' in it
    # cannot match a sibling folder, and the script's exit code is forwarded (-Command alone turns 2 into 1).
    $launchText = "& ([WildcardPattern]::Escape((`$env:CLAUDE_PLUGIN_ROOT + '/hooks/coord-scope-guard.ps1').Replace([string][char]96, [string][char]96 * 2))); if (`$null -eq `$LASTEXITCODE) { exit 1 }; exit `$LASTEXITCODE"
    $expectArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $launchText)
    $hj = $null
    $hjBytes = @()
    if (Test-Path -LiteralPath $hooksJsonPath) {
        $hjBytes = [System.IO.File]::ReadAllBytes($hooksJsonPath)
        try { $hj = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($hooksJsonPath)) -ErrorAction Stop } catch { $hj = $null }
    }
    Report ($null -ne $hj) 'S6-1 hooks/hooks.json exists and parses' $hooksJsonPath
    $pre = @(); $start = @()
    if ($hj -and $hj.PSObject.Properties['hooks']) {
        if ($hj.hooks.PSObject.Properties['PreToolUse']) { $pre = @($hj.hooks.PreToolUse) }
        if ($hj.hooks.PSObject.Properties['SessionStart']) { $start = @($hj.hooks.SessionStart) }
    }
    Report ($pre.Count -eq 1 -and [string]$pre[0].matcher -ceq 'Edit|Write|MultiEdit|NotebookEdit') 'S6-2 one PreToolUse entry, matcher exactly Edit|Write|MultiEdit|NotebookEdit' (($pre | ForEach-Object { [string]$_.matcher }) -join ';')
    Report ($start.Count -eq 1 -and -not $start[0].PSObject.Properties['matcher']) 'S6-3 one SessionStart entry, no matcher' "entries: $($start.Count)"
    $cmds = @()
    foreach ($e in @($pre + $start)) { foreach ($h in @($e.hooks)) { $cmds += , $h } }
    $shapeOk = ($cmds.Count -eq 2)
    $why = ''
    foreach ($c in $cmds) {
        $a = @($c.args)
        if ([string]$c.type -cne 'command' -or [string]$c.command -cne 'powershell.exe') { $shapeOk = $false; $why = 'type or command' }
        elseif (($a -join [string][char]0) -cne ($expectArgs -join [string][char]0)) { $shapeOk = $false; $why = 'args: ' + ($a -join ' ') }
        elseif ($c.PSObject.Properties['shell']) { $shapeOk = $false; $why = 'a shell property (the exec form ignores it, and a -Command string would lose exit code 2)' }
        elseif ($null -eq $c.timeout -or [int]$c.timeout -lt 1 -or [int]$c.timeout -gt 30) { $shapeOk = $false; $why = 'timeout' }
    }
    Report $shapeOk 'S6-4 both hooks run powershell.exe -NoProfile -ExecutionPolicy Bypass -Command <the escaped, exit-forwarding launcher> (exec form, no shell key, timeout 1..30)' $why
    $nonAscii = @($hjBytes | Where-Object { $_ -gt 127 }).Count
    Report ($hjBytes.Count -gt 0 -and $nonAscii -eq 0) 'S6-5 hooks.json is ASCII' "non-ASCII bytes: $nonAscii"
    Report (Test-Path -LiteralPath (Join-Path $repoRoot 'hooks\coord-scope-guard.ps1')) 'S6-6 the script hooks.json names exists in the repo' ''

    # --- the launcher, as Claude Code starts it, from plugin folders with a space, brackets and a backtick,
    # beside a sibling folder the brackets would match as a wildcard ---
    $plugRoot = Join-Path $root 'plug in [1] b`t'
    $plugHooks = Join-Path $plugRoot 'hooks'
    [void][IO.Directory]::CreateDirectory($plugHooks)
    Copy-Item -LiteralPath $hookPath -Destination (Join-Path $plugHooks 'coord-scope-guard.ps1') -Force
    $scriptsSrc = Join-Path (Split-Path -Parent (Split-Path -Parent $hookPath)) 'scripts'
    if (Test-Path -LiteralPath $scriptsSrc) { Copy-HookTestScripts -SourceDir $scriptsSrc -DestDir (Join-Path $plugRoot 'scripts') }
    # A sibling that '[1]' would match: the launcher must not run its copy (its helper is a stand-in that leaves a marker).
    $plugSib = Join-Path $root 'plug in 1 bt'
    [void][IO.Directory]::CreateDirectory((Join-Path $plugSib 'hooks'))
    Copy-Item -LiteralPath (Join-Path $plugHooks 'coord-scope-guard.ps1') -Destination (Join-Path $plugSib 'hooks') -Force
    $sibMarker = Join-Path $root 'plug-sibling-ran.txt'
    [void][IO.Directory]::CreateDirectory((Join-Path $plugSib 'scripts'))
    [System.IO.File]::WriteAllText((Join-Path $plugSib 'scripts\coord-common.ps1'), ("[System.IO.File]::AppendAllText('" + $sibMarker.Replace("'", "''") + "', 'x')`r`n"), $utf8)
    $launchArgs = '-NoProfile -ExecutionPolicy Bypass -Command "' + $launchText + '"'
    $null = Use-Ledger -Rows @((RowA1))
    $envs = @{ COORD_INDEX_DIR = $idxDir; COORD_TODAY = $today; CLAUDE_PLUGIN_ROOT = $plugRoot }
    $rb = Start-TestProcess -Arguments $launchArgs -StdinText (New-GuardEvent -Tool 'Write' -Path (Join-Path $wtA1 'other\x.txt') -Cwd $wtA1) -ExtraEnv $envs
    Test-Block 'S6-7 the hooks.json launcher, plugin folder "plug in [1] b`t": an out-of-scope Write blocks (exit 2 reaches the caller)' $rb @($stdScopeTail)
    $ra = Start-TestProcess -Arguments $launchArgs -StdinText (New-GuardEvent -Tool 'Write' -Path (Join-Path $wtA1 'src\a1\x.ps1') -Cwd $wtA1) -ExtraEnv $envs
    Test-Allow 'S6-8 the same launcher: an in-scope Write is a silent allow' $ra
    Report (-not (Test-Path -LiteralPath $sibMarker)) 'S6-8b the launcher did not run the sibling folder''s copy that "[1]" matches as a wildcard' 'the sibling stand-in ran'

    # --- the layout: coord-common.ps1 is ..\scripts\ beside the hook's folder, nowhere else ---
    $lone = Join-Path $root 'lone'
    [void][IO.Directory]::CreateDirectory((Join-Path $lone 'hooks'))
    Copy-Item -LiteralPath $hookPath -Destination (Join-Path $lone 'hooks\coord-scope-guard.ps1') -Force
    Test-Warn 'S6-9 no scripts\coord-common.ps1 beside the hook folder: allowed with the not-found warning' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'other\x.txt') -Tool 'Write' -Script (Join-Path $lone 'hooks\coord-scope-guard.ps1')) @('coord-common.ps1 was not found beside the hook', 'this edit is NOT guarded')

    # --- the off switch ---
    $outP = Join-Path $wtA1 'other\x.txt'
    $null = Use-Ledger -Rows @((RowA1))
    Test-Block 'S6-10 control: no switch, an out-of-scope Write blocks' (Invoke-Edit -Cwd $wtA1 -Path $outP -Tool 'Write') @($stdScopeTail)
    foreach ($v in @('off', 'OFF', ' Off ')) {
        Test-Allow ("S6-11 TRACKSTEWARD_GUARD='$v': a silent allow") (Invoke-Edit -Cwd $wtA1 -Path $outP -Tool 'Write' -ExtraEnv @{ TRACKSTEWARD_GUARD = $v })
    }
    foreach ($v in @('on', '0', 'false', 'offf')) {
        Test-Block ("S6-12 TRACKSTEWARD_GUARD='$v' is not the off switch: still blocks") (Invoke-Edit -Cwd $wtA1 -Path $outP -Tool 'Write' -ExtraEnv @{ TRACKSTEWARD_GUARD = $v }) @($stdScopeTail)
    }
    $offFiles = New-StubFiles 'off'
    $roff = Invoke-Edit -Cwd $wtA1 -Path $outP -Tool 'Write' -StubDir $stubGeneric -ExtraEnv @{ TRACKSTEWARD_GUARD = 'off'; CSG_COUNT = $offFiles.Count; CSG_REAL = $realGit }
    Test-Allow 'S6-13 switch off with a bound row: allow' $roff
    Report ((Get-StubCalls $offFiles) -eq 0) 'S6-14 switch off: zero git calls' ('calls: ' + (Get-StubCalls $offFiles))
    $null = Invoke-Guard -Json (New-SessionStartJson -Session 'sa-off' -Cwd $wtA1) -ExtraEnv @{ TRACKSTEWARD_GUARD = 'off' }
    Report (-not (Test-Path -LiteralPath (Get-AnchorPath 'sa-off'))) 'S6-15 switch off: SessionStart writes no anchor even with today''s index' ''
    $null = Invoke-Guard -Json (New-SessionStartJson -Session 'sa-on' -Cwd $wtA1)
    Report (Test-Path -LiteralPath (Get-AnchorPath 'sa-on')) 'S6-16 control: without the switch the same SessionStart writes the anchor' ''

    # --- anchor policy: only a day with a registered coordinator leaves an anchor ---
    Reset-State
    $rs = Invoke-Guard -Json (New-SessionStartJson -Session 'sa-none' -Cwd $wtA1)
    Test-Allow 'S6-17 no index at all: SessionStart is a silent allow' $rs
    Report (@(Get-ChildItem -LiteralPath $idxDir -Force -Recurse -ErrorAction SilentlyContinue).Count -eq 0) 'S6-18 no index: the index folder holds nothing (no anchor, no sessions folder)' ''
    $null = Set-TestLedger -Rows @((RowA1))
    $rs2 = Invoke-Guard -Json (New-SessionStartJson -Session 'sa-unreg' -Cwd $wtA1)
    Test-Allow 'S6-19 a ledger file exists but was never registered (no index): SessionStart is a silent allow' $rs2
    Report (@(Get-ChildItem -LiteralPath $idxDir -Force -Recurse -ErrorAction SilentlyContinue).Count -eq 0) 'S6-20 unregistered ledger: nothing is written to the index folder' ''
    Test-Allow 'S6-21 unregistered ledger: an out-of-scope Write is a silent allow' (Invoke-Edit -Cwd $wtA1 -Path $outP -Tool 'Write')
    Report (@(Get-ChildItem -LiteralPath $idxDir -Force -Recurse -ErrorAction SilentlyContinue).Count -eq 0) 'S6-22 unregistered ledger: the Write event wrote nothing either' ''

    $null = Use-Ledger -Rows @((RowA1))
    $null = Invoke-Guard -Json (New-SessionStartJson -Session 'sa-today' -Cwd $wtA1)
    $apT = Get-AnchorPath 'sa-today'
    Report ((Test-Path -LiteralPath $apT) -and ([System.IO.File]::ReadAllText($apT) -ceq ($wtA1 + "`n"))) 'S6-23 today''s index exists: the anchor holds the event cwd' ''
    $null = Use-Ledger -Rows @((RowA1)) -Date $yday
    $null = Invoke-Guard -Json (New-SessionStartJson -Session 'sa-yday' -Cwd $wtA1)
    Report (Test-Path -LiteralPath (Get-AnchorPath 'sa-yday')) 'S6-24 only yesterday''s index exists: the anchor is written' ''
    $null = Use-Ledger -Rows @((RowA1)) -Date '2026-03-03'
    $null = Invoke-Guard -Json (New-SessionStartJson -Session 'sa-old' -Cwd $wtA1)
    Report (-not (Test-Path -LiteralPath (Get-AnchorPath 'sa-old'))) 'S6-25 only an index two days old exists: no anchor' ''

    # --- pruning on the write path ---
    $null = Use-Ledger -Rows @((RowA1))
    $sd = Join-Path $idxDir 'sessions'
    [void][IO.Directory]::CreateDirectory($sd)
    $oldA = Join-Path $sd 'p-old.anchor'; $freshA = Join-Path $sd 'p-fresh.anchor'; $noteF = Join-Path $sd 'p-old-notes.txt'
    foreach ($f in @($oldA, $freshA, $noteF)) { [System.IO.File]::WriteAllText($f, "x`n", $utf8) }
    [System.IO.File]::SetLastWriteTimeUtc($oldA, [DateTime]::UtcNow.AddDays(-8))
    [System.IO.File]::SetLastWriteTimeUtc($noteF, [DateTime]::UtcNow.AddDays(-8))
    [System.IO.File]::SetLastWriteTimeUtc($freshA, [DateTime]::UtcNow.AddDays(-6))
    $null = Invoke-Guard -Json (New-SessionStartJson -Session 'sa-prune' -Cwd $wtA1)
    Report (Test-Path -LiteralPath (Get-AnchorPath 'sa-prune')) 'S6-26 the new anchor is written' ''
    Report (-not (Test-Path -LiteralPath $oldA)) 'S6-27 an anchor not written for 8 days is pruned' ''
    Report (Test-Path -LiteralPath $freshA) 'S6-28 an anchor written 6 days ago stays' ''
    Report (Test-Path -LiteralPath $noteF) 'S6-29 a file that is not *.anchor stays, however old' ''
    # a session that is still in use: a resume or compact refreshes its anchor's write time, so the prune keeps it
    $null = Invoke-Guard -Json (New-SessionStartJson -Session 'sa-keep' -Cwd $wtA1)
    $keepA = Get-AnchorPath 'sa-keep'
    [System.IO.File]::SetLastWriteTimeUtc($keepA, [DateTime]::UtcNow.AddDays(-9))
    $null = Invoke-Guard -Json (New-SessionStartJson -Session 'sa-keep' -Cwd $wtA2 -Source 'resume')
    $keepAge = ([DateTime]::UtcNow - [System.IO.File]::GetLastWriteTimeUtc($keepA)).TotalMinutes
    Report (([System.IO.File]::ReadAllText($keepA) -ceq ($wtA1 + "`n")) -and $keepAge -lt 5) 'S6-29b a resume of a session with an anchor refreshes its write time and keeps its content' ("age min: $keepAge")
    $staleA = Join-Path $sd 'p-stale.anchor'
    [System.IO.File]::WriteAllText($staleA, "x`n", $utf8)
    [System.IO.File]::SetLastWriteTimeUtc($staleA, [DateTime]::UtcNow.AddDays(-9))
    $null = Invoke-Guard -Json (New-SessionStartJson -Session 'sa-after' -Cwd $wtA1)
    Report ((Test-Path -LiteralPath (Get-AnchorPath 'sa-after')) -and -not (Test-Path -LiteralPath $staleA) -and (Test-Path -LiteralPath $keepA)) 'S6-29c the next session''s write prunes a 9-day-old anchor (so the prune ran) and the refreshed anchor survives it' ''
    Reset-State
    $sd = Join-Path $idxDir 'sessions'
    [void][IO.Directory]::CreateDirectory($sd)
    $oldB = Join-Path $sd 'q-old.anchor'
    [System.IO.File]::WriteAllText($oldB, "x`n", $utf8)
    [System.IO.File]::SetLastWriteTimeUtc($oldB, [DateTime]::UtcNow.AddDays(-30))
    $null = Invoke-Guard -Json (New-SessionStartJson -Session 'sa-noprune' -Cwd $wtA1)
    Report ((Test-Path -LiteralPath $oldB) -and -not (Test-Path -LiteralPath (Get-AnchorPath 'sa-noprune'))) 'S6-30 no index: nothing is written and nothing is pruned' ''
    $null = Invoke-Guard -Json (New-SessionStartJson -Session 'q-old' -Cwd $wtA1 -Source 'resume')
    $oldAge = ([DateTime]::UtcNow - [System.IO.File]::GetLastWriteTimeUtc($oldB)).TotalDays
    Report ($oldAge -gt 29) 'S6-30b no index: a resume of a session that has an old anchor does not refresh it either' ("age days: $oldAge")
    # a cwd that looks full but that GetFullPath rejects (Windows PowerShell 5.1 / .NET Framework): silent with no index
    # (the hook always runs under powershell.exe, whose GetFullPath rejects the '|'; under another host, where GetFullPath accepts it, S6-30c and S6-30e pass trivially and S6-30d fails)
    Test-Allow 'S6-30c no index: a SessionStart whose cwd GetFullPath rejects is still a silent allow' (Invoke-Guard -Json (New-SessionStartJson -Session 'sa-badcwd' -Cwd 'C:\a|b'))
    $null = Use-Ledger -Rows @((RowA1))
    # The warning of a cwd that GetFullPath rejects (its text names GetFullPath): the other two anchor warnings (no full cwd, budget ran out) share the "session anchor not written" text.
    $badR = Invoke-Guard -Json (New-SessionStartJson -Session 'sa-badcwd2' -Cwd 'C:\a|b')
    $badV = Get-Verdict $badR
    Report ($badV.Kind -eq 'warn' -and $badV.Msg -match 'session anchor not written' -and $badV.Msg -match 'GetFullPath' -and $badV.Msg -notmatch 'no full cwd' -and $badV.Msg -notmatch 'budget ran out' -and -not (Test-Path -LiteralPath (Get-AnchorPath 'sa-badcwd2'))) 'S6-30d with an index and no anchor yet: the same cwd warns that the anchor was not written (the GetFullPath rejection, not the no-cwd or budget warning), and writes none' (Show-Run $badR $badV)
    # an anchored session: the refresh comes before the cwd is resolved, so the same cwd is a silent refresh
    $null = Invoke-Guard -Json (New-SessionStartJson -Session 'sa-badcwd3' -Cwd $wtA1)
    $badA = Get-AnchorPath 'sa-badcwd3'
    [System.IO.File]::SetLastWriteTimeUtc($badA, [DateTime]::UtcNow.AddDays(-3))
    $badR3 = Invoke-Guard -Json (New-SessionStartJson -Session 'sa-badcwd3' -Cwd 'C:\a|b' -Source 'resume')
    $badAge = ([DateTime]::UtcNow - [System.IO.File]::GetLastWriteTimeUtc($badA)).TotalMinutes
    Test-Allow 'S6-30e with an index and an anchor: a SessionStart whose cwd GetFullPath rejects is a silent allow' $badR3
    Report (([System.IO.File]::ReadAllText($badA) -ceq ($wtA1 + "`n")) -and $badAge -lt 5) 'S6-30e ... and it refreshes the anchor''s write time and keeps its content' ("age min: $badAge")

    # --- name-only Session cells never bind across repos (only an id-shaped cell is a token) ---
    $nameA = New-LedgerRow 'A1' $repoA 'a1-branch' $wtA1 $scopeA1 'track-a1' 'running'
    $nameB = New-LedgerRow 'A1-B' $repoB 'b1-branch' $wtB1 'lib/**' 'track-a1' 'running'
    $inB = Join-Path $wtB1 'lib\x.ps1'
    $null = Use-Ledger -Rows @($nameA, $nameB)
    Test-Allow 'S6-31 two rows with the same name, A1 writes inside its own scope' (Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA1 'src\a1\x.ps1') -Tool 'Write')
    $rn = Invoke-Edit -Cwd $wtA1 -Path $inB -Tool 'Write'
    Test-Block 'S6-32 the same NAME in repo A and repo B does not bind: a write into B''s in-scope path blocks, and the refusal says why' $rn @('is outside track A1''s scope', 'Track A1-B names that tree', 'holds only a name never binds')
    $null = Use-Ledger -Rows @($nameA, (New-LedgerRow 'A1-B' $repoB 'b1-branch' $wtB1 'lib/**' $tokA1 'running'))
    Test-Block 'S6-33 a name on one row and an id on the other does not bind either' (Invoke-Edit -Cwd $wtA1 -Path $inB -Tool 'Write') @('holds only a name never binds')
    $null = Use-Ledger -Rows @((New-LedgerRow 'A1' $repoA 'a1-branch' $wtA1 $scopeA1 $tokA1 'running'), (New-LedgerRow 'A1-B' $repoB 'b1-branch' $wtB1 'lib/**' $tokA1 'running'))
    Test-Allow 'S6-34 control: the same session id on both rows binds, B''s in-scope path is allowed' (Invoke-Edit -Cwd $wtA1 -Path $inB -Tool 'Write')
    $null = Use-Ledger -Rows @((New-LedgerRow 'A1' $repoA 'a1-branch' $wtA1 $scopeA1 $tokA1 'running'), (New-LedgerRow 'A1-B' $repoB 'b1-branch' $wtB1 'lib/**' $tokB1 'running'))
    $rd = Invoke-Edit -Cwd $wtA1 -Path $inB -Tool 'Write'
    Test-Block 'S6-35 two different ids do not bind across repos' $rd @('Track A1-B names that tree')
    # no row names the target tree: the plain scope refusal, without the cross-row note
    $null = Use-Ledger -Rows @((RowA1))
    $rq = Invoke-Edit -Cwd $wtA1 -Path (Join-Path $wtA2 'src\a2\x.ps1') -Tool 'Write'
    Test-Block 'S6-36 a write into a tree no row names is refused as out of scope' $rq @($stdScopeTail)
    Report (([string]$rq.Err).IndexOf('names that tree') -lt 0) 'S6-36b the refusal carries no cross-row note when no row names the tree' (Get-Tail $rq.Err)
}

# ===========================================================================
# Z the real index folder is byte-unchanged
# ===========================================================================
Invoke-Group 'Z real index' {
    $after = Get-DirSnapshot $realCoordDir
    Report ($after -ceq $realSnapshotBefore) 'Z-1 the real ~/.claude/coordination folder is byte-unchanged by this suite' ("before: [$(Get-Tail $realSnapshotBefore)] after: [$(Get-Tail $after)]")
}

# ---------------------------------------------------------------------------
# Cleanup: links first, so a recursive delete cannot follow one.
# ---------------------------------------------------------------------------
foreach ($l in @((Join-Path $wtA1 'src\a1\jx'), (Join-Path $wtA1 'src\a1\sl.txt'), (Join-Path $root 'tmplink'))) {
    if (Test-Path -LiteralPath $l) { Remove-TestLink $l }
}
Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "Passed: $passed  Failed: $failed"
if ($skipped -gt 0) { Write-Host "Unchecked: $skipped (see the UNCHECKED lines above)" }
if ($failed -gt 0) { exit 1 }
exit 0
