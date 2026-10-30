# Shared by the suites under tests/scripts. Dot-sourced AFTER the caller has
# loaded hook-test-fixture.ps1 and called Clear-HookRunnerGitEnv: every fixture
# repo is built through New-HookTestRepo / Invoke-HookTestGit, so a runner
# started inside a git hook cannot write into the real repo.
# Ported from the private coordinate toolkit (coord-test-fixture.ps1), 2026-10-18.
#
# A fixture is three directories under one case folder:
#   origin.git  a bare repo standing in for GitHub (branches, refs/pull/<n>/head)
#   launch      the main checkout the scripts examine (its origin is origin.git)
#   work        a second clone that makes branches and pushes them
# gh is the stub in tests\stubs (gh.cmd -> gh-coord-stub.ps1), put first on PATH
# for each script run and answered from a per-run rules file.
#
# Folders the suites read: $coordScriptsDir (scripts\), $coordTemplatesDir
# (templates\, the real ledger and brief templates), $coordStubDir (tests\stubs).

$coordScriptsDir = (Resolve-Path (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path '..' 'scripts'))).Path
$coordTemplatesDir = (Resolve-Path (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path '..' 'templates'))).Path
$coordStubDir = (Resolve-Path (Join-Path (Join-Path $PSScriptRoot '..') 'stubs')).Path
$coordUtf8 = New-Object System.Text.UTF8Encoding($false)

function Get-CoordGitOut {
    param([string]$Repo, [string[]]$GitArgs)
    $out = @(& git -C $Repo @GitArgs 2>$null)
    if ($LASTEXITCODE -ne 0) { throw "fixture git failed (exit $LASTEXITCODE): git -C $Repo $($GitArgs -join ' ')" }
    return (($out | ForEach-Object { [string]$_ }) -join "`n").Trim()
}

function Set-CoordFile {
    param([string]$Repo, [string]$Rel, [string]$Text)
    $p = Join-Path $Repo $Rel
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $p))
    [System.IO.File]::WriteAllText($p, $Text, $coordUtf8)
}

function New-CoordFixture {
    param([string]$Root, [string]$Name)
    $base = Join-Path $Root $Name
    [void][IO.Directory]::CreateDirectory($base)
    $origin = Join-Path $base 'origin.git'
    $launch = Join-Path $base 'launch'
    $work = Join-Path $base 'work'
    Invoke-HookTestGit $base @('init', '--quiet', '--bare', '--initial-branch=main', $origin)
    # core.longpaths in all three repos: under a long TMP the object paths pass
    # MAX_PATH (a 150-file push died with "Filename too long").
    Invoke-HookTestGit $origin @('config', 'core.longpaths', 'true')
    New-HookTestRepo $launch
    Invoke-HookTestGit $launch @('config', 'core.longpaths', 'true')
    Set-CoordFile $launch 'README.md' "readme`n"
    Set-CoordFile $launch 'docs/a.md' "a`n"
    Set-CoordFile $launch 'src/app.txt' "line1`nline2`nline3`n"
    Invoke-HookTestGit $launch @('-c', 'core.autocrlf=false', 'add', '-A')
    Invoke-HookTestGit $launch @('-c', 'core.autocrlf=false', 'commit', '--quiet', '-m', 'base')
    Invoke-HookTestGit $launch @('remote', 'add', 'origin', $origin)
    Invoke-HookTestGit $launch @('push', '--quiet', '-u', 'origin', 'main')
    # The work clone keeps LF: under a global core.autocrlf=true its checkouts
    # would turn every file into a CRLF "change". (The launch checkout gets no
    # local autocrlf on purpose: a stray one is something merge-verify flags.)
    Invoke-HookTestGit $base @('clone', '--quiet', '-c', 'core.autocrlf=false', '-c', 'core.longpaths=true', $origin, $work)
    Invoke-HookTestGit $work @('config', 'core.longpaths', 'true')
    Invoke-HookTestGit $work @('config', 'user.email', 'test@example.com')
    Invoke-HookTestGit $work @('config', 'user.name', 'coord test')
    Disable-HookTestRepoHooks $work
    return [pscustomobject]@{ Base = $base; Origin = $origin; Launch = $launch; Work = $work }
}

# Makes $Branch in the work clone from $From, writes and removes files,
# commits, and (unless -NoPush) pushes it. Returns the commit sha.
function New-CoordBranch {
    param($Fx, [string]$Branch, [hashtable]$Write = @{}, [string[]]$Remove = @(), [string[]]$Move = @(),
        [string]$From = 'origin/main', [switch]$NoPush)
    Invoke-HookTestGit $Fx.Work @('fetch', '--quiet', 'origin')
    Invoke-HookTestGit $Fx.Work @('checkout', '--quiet', '-B', $Branch, $From)
    foreach ($k in $Write.Keys) { Set-CoordFile $Fx.Work $k $Write[$k] }
    foreach ($k in $Remove) { Invoke-HookTestGit $Fx.Work @('rm', '--quiet', '--', $k) }
    for ($i = 0; $i + 1 -lt $Move.Count; $i += 2) {
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent (Join-Path $Fx.Work $Move[$i + 1])))
        Invoke-HookTestGit $Fx.Work @('mv', '--', $Move[$i], $Move[$i + 1])
    }
    Invoke-HookTestGit $Fx.Work @('-c', 'core.autocrlf=false', 'add', '-A')
    Invoke-HookTestGit $Fx.Work @('-c', 'core.autocrlf=false', 'commit', '--quiet', '--allow-empty', '-m', "branch $Branch")
    if (-not $NoPush) { Invoke-HookTestGit $Fx.Work @('push', '--quiet', '--force', 'origin', "HEAD:refs/heads/$Branch") }
    return (Get-CoordGitOut $Fx.Work @('rev-parse', 'HEAD'))
}

function Publish-CoordPullRef {
    param($Fx, [int]$Number, [string]$Sha)
    Invoke-HookTestGit $Fx.Work @('push', '--quiet', '--force', 'origin', "${Sha}:refs/pull/$Number/head")
}

# Merges $Sha into origin/main from the work clone with a merge commit
# (--no-ff) and returns the merge commit's sha.
function Merge-CoordIntoMain {
    param($Fx, [string]$Sha)
    Invoke-HookTestGit $Fx.Work @('fetch', '--quiet', 'origin')
    Invoke-HookTestGit $Fx.Work @('checkout', '--quiet', '-B', 'main', 'origin/main')
    Invoke-HookTestGit $Fx.Work @('-c', 'core.autocrlf=false', 'merge', '--quiet', '--no-ff', '--no-edit', $Sha)
    Invoke-HookTestGit $Fx.Work @('push', '--quiet', 'origin', 'main')
    return (Get-CoordGitOut $Fx.Work @('rev-parse', 'HEAD'))
}

function Get-CoordRemoteRef {
    param($Fx, [string]$Ref)
    $out = @(& git -C $Fx.Origin for-each-ref --format='%(objectname)' $Ref 2>$null)
    return (($out -join '').Trim())
}

function New-CoordCheckRun([string]$Name, [string]$Status = 'COMPLETED', [string]$Conclusion = 'SUCCESS') {
    return [ordered]@{ __typename = 'CheckRun'; name = $Name; status = $Status; conclusion = $Conclusion }
}
function New-CoordStatusContext([string]$Context, [string]$State = 'SUCCESS') {
    return [ordered]@{ __typename = 'StatusContext'; context = $Context; state = $State }
}

function New-CoordPrJson {
    param([int]$Number, [string]$Head, [string]$HeadRef, [string]$State = 'OPEN', [string]$Base = 'main',
        [bool]$Draft = $false, [string]$Mergeable = 'MERGEABLE', [object[]]$Checks = @(), [string]$MergeCommit = '',
        [bool]$Cross = $false, [string]$MergeState = 'CLEAN')
    $o = [ordered]@{
        number = $Number; state = $State; isDraft = $Draft; mergeable = $Mergeable; mergeStateStatus = $MergeState
        headRefName = $HeadRef; headRefOid = $Head; baseRefName = $Base
        statusCheckRollup = @($Checks); isCrossRepository = $Cross
        mergeCommit = $(if ($MergeCommit) { [ordered]@{ oid = $MergeCommit } } else { $null })
    }
    return (ConvertTo-Json -InputObject $o -Depth 10 -Compress)
}

function New-CoordRule([string]$Match, [string]$Stdout = '', [int]$Exit = 0) {
    return [ordered]@{ match = $Match; stdout = $Stdout; exit = $Exit }
}

# Runs one coordinate script with the gh stub first on PATH. Returns
# { Code; Out; Err; Last (last non-empty stdout line); Calls (gh calls) }.
# The stub directory is joined to PATH with the platform's separator, and the
# stub is Windows-only (gh.cmd), so this helper is Windows-only today.
function Invoke-CoordScript {
    param([string]$Name, [string]$Cwd, [string]$ScriptArgs = '', [object[]]$Rules = @(), [hashtable]$ExtraEnv = @{},
        [string]$ScriptPath = '')
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('coord-run-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    [void][IO.Directory]::CreateDirectory($tmp)
    $rulesFile = Join-Path $tmp 'rules.json'
    $logFile = Join-Path $tmp 'gh.log'
    [System.IO.File]::WriteAllText($rulesFile, (ConvertTo-Json -InputObject @($Rules) -Depth 20), $coordUtf8)
    $envs = @{ PATH = ($coordStubDir + [System.IO.Path]::PathSeparator + $env:PATH); GH_COORD_RESPONSES = $rulesFile; GH_COORD_LOG = $logFile }
    foreach ($k in $ExtraEnv.Keys) { $envs[$k] = $ExtraEnv[$k] }
    $script = if ($ScriptPath) { $ScriptPath } else { Join-Path $coordScriptsDir $Name }
    $r = Invoke-HookTestPowerShell -Script $script -StartDir $Cwd -ExtraEnv $envs -ScriptArgs $ScriptArgs -Seconds 180
    $calls = @()
    if (Test-Path -LiteralPath $logFile) { $calls = @(Get-Content -LiteralPath $logFile -Encoding UTF8) }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    $lines = @(([string]$r.Out) -split "`r?`n" | Where-Object { $_.Trim() })
    $last = if ($lines.Count) { $lines[$lines.Count - 1] } else { '' }
    return [pscustomobject]@{ Code = $r.Code; Out = [string]$r.Out; Err = [string]$r.Err; Last = $last; Calls = $calls }
}

$script:coordPass = 0
$script:coordFail = 0
function Assert-Coord {
    param([string]$Label, [bool]$Cond, [string]$Detail = '')
    if ($Cond) { $script:coordPass++; Write-Host "  PASS: $Label" -ForegroundColor Green }
    else {
        $script:coordFail++
        Write-Host "  FAIL: $Label" -ForegroundColor Red
        if ($Detail) { Write-Host ("    " + ($Detail -replace "`n", "`n    ")) }
    }
}

# ---- index and canonical-ledger helpers ----
# The suites that run coord-log.ps1 or the index helpers point COORD_INDEX_DIR
# at a scratch folder for their whole run and end by comparing the REAL index
# folder ($coordRealIndexDir below: the COORD_INDEX_DIR value from before the
# suite overrides it, else $HOME/.claude/coordination) with a snapshot taken at
# their start.

$script:coordUnchecked = 0
# A row that could not run on this machine (no symlink right, no 8.3 names): the
# suite prints it and counts it apart from PASS and FAIL.
function Write-CoordUnchecked {
    param([string]$Label, [string]$Reason)
    $script:coordUnchecked++
    Write-Host "  UNCHECKED: $Label ($Reason)" -ForegroundColor Yellow
}
function Write-CoordUncheckedSummary {
    if ($script:coordUnchecked -gt 0) { Write-Host "Unchecked: $script:coordUnchecked (see the UNCHECKED lines above)" -ForegroundColor Yellow }
}

# The user's real index folder, as it is when this fixture is loaded (before a
# suite points COORD_INDEX_DIR at a scratch folder): the COORD_INDEX_DIR value if
# one is set, else $HOME/.claude/coordination. Get-CoordRealIndexSnapshot and Get-CoordRealIndexLeak protect it.
$coordRealIndexDir = Join-Path (Join-Path $HOME '.claude') 'coordination'
if ($env:COORD_INDEX_DIR) {
    try { $coordRealIndexDir = [System.IO.Path]::GetFullPath($env:COORD_INDEX_DIR) } catch { $coordRealIndexDir = [string]$env:COORD_INDEX_DIR }
}

# The real index folder ($coordRealIndexDir) as relative path -> text for every file under it EXCEPT the sessions/
# subfolder and what is in it (an absent folder is an empty snapshot). A scope guard that is live on the host writes
# its anchor files in sessions/ whenever any session starts, so a fence that read sessions/ failed at random while the
# suite touched nothing. The top-level files (the *.ledgers index files and any other) and the other subfolders are
# covered. A file that cannot be read (locked by a live coordinator mid-write) is stored as null and skipped by
# Get-CoordRealIndexLeak, never reported as rewritten.
function Get-CoordRealIndexSnapshot {
    param([string]$Dir = $coordRealIndexDir)
    $snap = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $snap }
    $items = @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object FullName)
    foreach ($f in $items) {
        $rel = $f.FullName.Substring($Dir.Length)
        if ($rel.TrimStart('\', '/') -match '^sessions[\\/]') { continue }
        $text = $null
        try {
            $fs = [IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite')
            try { $text = (New-Object IO.StreamReader($fs, (New-Object Text.UTF8Encoding($false)))).ReadToEnd() } finally { $fs.Dispose() }
        } catch { }
        $snap[$rel] = $text
    }
    return $snap
}

# '' when the index folder shows nothing this run wrote, else one line per problem. This is weaker than the byte digest it
# replaced, on purpose: a coordinator session running beside the suite may append to a file or register a new one, so
# appended text and new files are tolerated. What it flags: a file removed (re-checked once after 300 ms, for a
# coordinator's replace-by-rename), an earlier byte changed, and added text that names $Marker (this run's scratch root,
# either slash, any case). A suite write that names no scratch path is NOT caught.
function Get-CoordRealIndexLeak {
    param($Before, [string]$Marker, [string]$Dir = $coordRealIndexDir)
    $after = Get-CoordRealIndexSnapshot -Dir $Dir
    if (@($Before.Keys | Where-Object { -not $after.Contains($_) }).Count) { Start-Sleep -Milliseconds 300; $after = Get-CoordRealIndexSnapshot -Dir $Dir }
    $marks = @($Marker, $Marker.Replace('\', '/')) | Where-Object { $_ }
    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($k in $Before.Keys) {
        if (-not $after.Contains($k)) { $problems.Add("removed: $k"); continue }
        if ($null -eq $Before[$k] -or $null -eq $after[$k]) { continue }
        if (-not $after[$k].StartsWith([string]$Before[$k], [StringComparison]::Ordinal)) { $problems.Add("rewritten: $k") }
    }
    foreach ($k in $after.Keys) {
        if ($null -eq $after[$k]) { continue }
        $b = if ($Before.Contains($k) -and $null -ne $Before[$k] -and $after[$k].StartsWith([string]$Before[$k], [StringComparison]::Ordinal)) { [string]$Before[$k] } else { '' }
        $added = $after[$k].Substring($b.Length)
        foreach ($m in $marks) { if ($added.IndexOf($m, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $problems.Add("names this run's scratch root: $k"); break } }
    }
    return ($problems -join "`n")
}

# Points COORD_INDEX_DIR at a new, not yet created folder under $Root and returns
# it. Each call starts a fresh index (the production index holds 8 ledgers).
$script:coordScratchIndexN = 0
function New-CoordScratchIndex {
    param([string]$Root)
    $script:coordScratchIndexN++
    $d = Join-Path $Root ('index' + $script:coordScratchIndexN)
    $env:COORD_INDEX_DIR = $d
    return $d
}

function Set-CoordTextFile {
    param([string]$Path, [string]$Text)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [System.IO.File]::WriteAllText($Path, $Text, $coordUtf8)
}

function Get-CoordFileHashOrAbsent([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
    return 'absent'
}

# A fixture main checkout under $Root\$Name (hooks off, identity set). With
# -Commit it holds one commit, which a linked worktree needs. Needs
# Clear-HookRunnerGitEnv to have run (New-HookTestRepo refuses otherwise).
function New-CoordCanonRepo {
    param([string]$Root, [string]$Name, [switch]$Commit)
    $repo = Join-Path $Root $Name
    New-HookTestRepo $repo
    if ($Commit) {
        Set-CoordFile $repo 'README.md' "readme`n"
        Invoke-HookTestGit $repo @('-c', 'core.autocrlf=false', 'add', '-A')
        Invoke-HookTestGit $repo @('-c', 'core.autocrlf=false', 'commit', '--quiet', '-m', 'base')
    }
    return $repo
}

# Writes the ledger of $Date at the canonical path of $Repo's main checkout
# (spelled the way git spells it, which a %TEMP% in 8.3 form would otherwise
# change) and returns that path. Needs coord-common.ps1 dot-sourced.
function New-CoordCanonLedger {
    param([string]$Repo, [string]$Date, [string]$Text = '')
    $p = Get-CoordLedgerPath $Repo $Date
    if (-not $p) { throw "fixture: $Repo has no main checkout" }
    if (-not $Text) { $Text = "# Coordination ledger - $Date`n" }
    Set-CoordTextFile $p $Text
    return $p
}

# A directory junction $Link -> $Target. $false when the machine refuses.
function New-CoordJunction {
    param([string]$Link, [string]$Target)
    try { New-Item -ItemType Junction -Path $Link -Target $Target -ErrorAction Stop | Out-Null } catch { return $false }
    $item = Get-Item -LiteralPath $Link -Force -ErrorAction SilentlyContinue
    return [bool]($item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint))
}
# Removes the junction itself, never what it points at.
function Remove-CoordJunction([string]$Link) {
    if (Test-Path -LiteralPath $Link) { [System.IO.Directory]::Delete($Link) }
}
