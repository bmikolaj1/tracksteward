# How a suite isolates itself from the repository it is started in and builds
# its throwaway git repos. Dot-sourced by coord-test-fixture.ps1's callers (the
# suites under tests/scripts) and by tests/scrub.test.ps1.
# Ported from the private coordinate toolkit (hook-test-fixture.ps1), 2026-10-18.
#
# Why: run from inside a git hook in a linked worktree, a suite inherits
# GIT_DIR / GIT_INDEX_FILE, and its fixture `git init` / `git config` /
# `git commit` would write core.bare=true, a test identity and core.autocrlf
# into the SHARED .git/config. So every suite that loads this file:
#   1. clears those variables before anything else: Clear-HookRunnerGitEnv;
#   2. builds each fixture with New-HookTestRepo and names it with `git -C`,
#      never a cwd-relative git after a Push-Location. Where a suite must
#      change location it uses `Push-Location -LiteralPath ... -ErrorAction
#      Stop`: a %TEMP% with [brackets] is a wildcard to plain Push-Location,
#      which then fails and, under $ErrorActionPreference = 'Continue', falls
#      through to whatever directory the suite started in;
#   3. gets a repo whose own setup (New-HookTestRepo: init, identity, hooks
#      off) runs through Invoke-HookTestGit, which throws, so a broken fixture
#      repo fails its case.
#
# Kept from the private fixture: everything the coord-common and coord-log
# suites use, plus what the scope guard suite needs:
# StdinText / RemoveEnv on Invoke-HookTestPowerShell, ConvertTo-HookTestAsciiJson
# and Copy-HookTestScripts.
# Dropped: ConvertTo-HookTestMsysPath (Git-Bash path spelling), New-HookTestToolEvent
# and New-HookTestStopEvent (event builders no suite of this repo calls yet).
#
# The fixture is Windows-first: it starts powershell.exe (or pwsh when
# TRACKSTEWARD_TEST_SHELL=pwsh, which tests/run.ps1 -Shell pwsh sets) and ends a
# hung child with taskkill. Not verified off Windows.

$hookTestGitLocalEnvPath = Join-Path $PSScriptRoot 'git-local-env.ps1'
if (-not (Test-Path -LiteralPath $hookTestGitLocalEnvPath)) { throw "git-local-env.ps1 not found at $hookTestGitLocalEnvPath" }
. $hookTestGitLocalEnvPath

# Computed once: the list costs a `git rev-parse` process, and every fixture
# repo checks it.
$hookTestGitLocalEnvVarNames = @(Get-GitLocalEnvVarNames)

# Clears git's repo-local variables for the rest of this suite process. Not
# restored: the suite is its own process, and nothing it runs should see them.
function Clear-HookRunnerGitEnv {
    foreach ($name in $hookTestGitLocalEnvVarNames) {
        [Environment]::SetEnvironmentVariable($name, $null)
    }
}

# The PowerShell host the suites start as a child: powershell.exe (Windows
# PowerShell 5.1) by default, pwsh when TRACKSTEWARD_TEST_SHELL is 'pwsh'.
function Get-HookTestShellPath {
    $name = if ($env:TRACKSTEWARD_TEST_SHELL -eq 'pwsh') { 'pwsh' } else { 'powershell.exe' }
    $found = @(Get-Command $name -CommandType Application -ErrorAction SilentlyContinue)
    if ($found.Count -eq 0) { throw "test shell '$name' not found on PATH" }
    return [string]$found[0].Source
}

# Starts `<shell> -File $Script` from $StartDir with $ExtraEnv added to this
# process's environment and stdin closed, and gives it $Seconds to exit. A
# hang is killed with its process tree and reported as a Code string, never
# waited on: the output reads are bounded too, because a grandchild still
# holding the inherited pipes would block them. Stdout and stderr come back
# separately (Out, Err), which is what a row about WHERE a message is printed
# needs.
# Optional, named: -StdinText is written to the child's stdin as UTF-8 bytes
# with no BOM before stdin is closed (a hook event); -ScriptArgs is appended to
# the command line after the script, already quoted by the caller; -RemoveEnv
# names variables the child must NOT inherit from this process.
function Invoke-HookTestPowerShell {
    param([string]$Script, [string]$StartDir, [hashtable]$ExtraEnv = @{}, [int]$Seconds = 120,
        [string]$StdinText = '', [string]$ScriptArgs = '', [string[]]$RemoveEnv = @())
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Get-HookTestShellPath
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $Script + '"'
    if ($ScriptArgs) { $psi.Arguments = $psi.Arguments + ' ' + $ScriptArgs }
    $psi.WorkingDirectory = $StartDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    foreach ($k in $RemoveEnv) { $psi.EnvironmentVariables.Remove($k) }
    foreach ($k in $ExtraEnv.Keys) { $psi.EnvironmentVariables[$k] = $ExtraEnv[$k] }
    # .NET Framework wraps the child's stdin in a StreamWriter of
    # [Console]::InputEncoding with AutoFlush on, which writes that encoding's
    # preamble at Start: under a UTF-8 console the child read a BOM ahead of the
    # JSON, ConvertFrom-Json failed, and every hook saw "not an event". Claude
    # Code sends no BOM, so Start runs under a BOM-less encoding.
    $prevInputEncoding = $null
    try { $prevInputEncoding = [Console]::InputEncoding; [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
    try { $p = [System.Diagnostics.Process]::Start($psi) }
    finally { if ($prevInputEncoding) { try { [Console]::InputEncoding = $prevInputEncoding } catch { } } }
    if ($StdinText) {
        # Raw bytes through BaseStream, so the writer's encoding cannot change
        # the JSON itself.
        $stdinBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($StdinText)
        $p.StandardInput.BaseStream.Write($stdinBytes, 0, $stdinBytes.Length)
        $p.StandardInput.BaseStream.Flush()
    }
    $p.StandardInput.Close()
    $outRead = $p.StandardOutput.ReadToEndAsync()
    $errRead = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($Seconds * 1000)) {
        & taskkill.exe /T /F /PID $p.Id 2>$null | Out-Null
        return @{ Code = "no exit within ${Seconds}s"; Out = ''; Err = '' }
    }
    $p.WaitForExit()
    $out = if ($outRead.Wait(10000)) { $outRead.Result } else { '<stdout still open 10s after exit>' }
    $err = if ($errRead.Wait(10000)) { $errRead.Result } else { '<stderr still open 10s after exit>' }
    return @{ Code = $p.ExitCode; Out = $out; Err = $err.Trim() }
}

# Runs `git -C $Repo <args>` and throws when git fails, so a broken fixture
# fails its case instead of letting a classifier answer about nothing. The git
# arguments are one array (`Invoke-HookTestGit $r @('add', '--', 'a.md')`):
# PowerShell's binder would eat a bare `--` or read `-c` as a parameter name.
function Invoke-HookTestGit([string]$Repo, [string[]]$GitArgs) {
    $out = & git -C $Repo @GitArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "fixture git failed (exit $LASTEXITCODE): git -C $Repo $($GitArgs -join ' '): $((@($out | ForEach-Object { "$_" }) -join ' ').Trim())"
    }
}

# Points the fixture's core.hooksPath at an empty directory inside its own .git,
# which turns off every hook: its own .git/hooks and any core.hooksPath set in
# the global or system config.
# NOT `git config core.hooksPath ''`: Windows PowerShell 5.1 drops an empty
# string argument to a native command, so that line runs `git config
# core.hooksPath`, which only READS the key (exit 1 when unset) and disables
# nothing.
function Disable-HookTestRepoHooks {
    param([Parameter(Mandatory = $true)][string]$Repo)
    $gitDir = Join-Path $Repo '.git'
    $noHooks = Join-Path $gitDir 'no-hooks'
    [void][IO.Directory]::CreateDirectory($noHooks)
    Invoke-HookTestGit $Repo @('config', 'core.hooksPath', $noHooks)
    # git prints the value as UTF-8; a windowless powershell.exe decodes native
    # output with the OEM code page, so a non-ASCII repo path would read back
    # garbled and never compare equal. Decode as UTF-8 for the read.
    $prevEncoding = $null
    try {
        try { $prevEncoding = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
        $got = (& git -C $Repo config --get core.hooksPath 2>$null | Out-String).Trim()
    }
    finally { if ($prevEncoding) { try { [Console]::OutputEncoding = $prevEncoding } catch { } } }
    if ($got -ne $noHooks) { throw "fixture hooks not disabled in ${Repo}: core.hooksPath is '$got'" }
}

# Creates $Path (if needed) and makes it a fresh repo on branch main, with a
# test identity and its hooks disabled. Refuses to run while any repo-local git
# variable is set: with GIT_DIR set, `git -C $Path init` re-initialises the repo
# GIT_DIR names instead. Checks that the new repo really is at $Path.
function New-HookTestRepo {
    param([Parameter(Mandatory = $true)][string]$Path)
    $set = @($hookTestGitLocalEnvVarNames | Where-Object { $null -ne [Environment]::GetEnvironmentVariable($_) })
    if ($set.Count -gt 0) { throw "refusing to build a fixture repo while $($set -join ', ') is set; call Clear-HookRunnerGitEnv first" }
    [void][IO.Directory]::CreateDirectory($Path)
    Invoke-HookTestGit $Path @('-c', 'init.defaultBranch=main', 'init', '--quiet')
    # rev-parse prints the relative `.git` only from the top of the repo whose
    # git dir that is; a repo found above $Path prints an absolute path.
    $gitDir = (& git -C $Path rev-parse --git-dir 2>$null | Out-String).Trim()
    if ($gitDir -ne '.git') { throw "fixture repo at $Path resolves to git dir '$gitDir', not its own .git" }
    Invoke-HookTestGit $Path @('config', 'user.email', 'test@example.com')
    Invoke-HookTestGit $Path @('config', 'user.name', 'hook test')
    Disable-HookTestRepoHooks $Path
}

# Adds a linked worktree of $Repo at $Path on a new branch. $Repo needs a
# commit. core.hooksPath is shared config, so the empty hooks directory
# New-HookTestRepo set applies to the worktree too. Throws when git fails or
# the result is not a worktree of its own. $Path should NOT be inside $Repo:
# its files would show up as untracked there.
function New-HookTestWorktree {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Branch = 'wt'
    )
    Invoke-HookTestGit $Repo @('worktree', 'add', '--quiet', '-b', $Branch, $Path)
    $dotGit = Join-Path $Path '.git'
    if (-not (Test-Path -LiteralPath $dotGit -PathType Leaf)) { throw "fixture worktree at $Path has no .git file (a linked worktree has one)" }
}

# A hook event is ASCII JSON: a non-ASCII character becomes a \uXXXX escape, so
# the bytes do not depend on the child's console code page.
function ConvertTo-HookTestAsciiJson([string]$Json) {
    return [regex]::Replace($Json, '[^\x00-\x7F]', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) '\u{0:x4}' -f [int][char]$m.Value })
}

# Copies every *.ps1 beside a hook into $DestDir, so a helper the hook loads
# through $PSScriptRoot comes along without this file naming it.
function Copy-HookTestScripts {
    param([Parameter(Mandatory = $true)][string]$SourceDir, [Parameter(Mandatory = $true)][string]$DestDir)
    [void][IO.Directory]::CreateDirectory($DestDir)
    $scripts = @(Get-ChildItem -LiteralPath $SourceDir -Filter '*.ps1' -File)
    if ($scripts.Count -eq 0) { throw "no .ps1 files in $SourceDir" }
    foreach ($s in $scripts) { Copy-Item -LiteralPath $s.FullName -Destination $DestDir -Force }
}
