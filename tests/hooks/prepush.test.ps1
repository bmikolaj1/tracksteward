# Pre-push gate suite: .githooks/pre-push runs the scrub suite with -History over
# the commits a push sends (SG6: every commit message and every blob those commits
# add or change) and refuses the push when that run fails, a missing denylist
# included. The rows make real `git push` calls into a bare repo, from a copy of
# this repo's shippable files (the hook runs the COPY's own tests\scrub.test.ps1),
# with a throwaway denylist whose one entry is built at run time, so this file
# never holds it. Each scanned push runs the scrub suite once (about 20 s here).
#
# P0 fixture sanity: the copy has the hook, the hooks are on, the base push landed
# P1 a new branch whose commit message holds the entry: refused, not on the remote
# P2 a file with the entry, added and removed again before the push (the tip is
#    clean): refused
# P3 a clean commit on a new branch: pushed, and the hook says it scanned
# P4 TRACKSTEWARD_SCRUB_DENYLIST unset: refused (a push is never let through unscanned)
# P5 a new tag on a commit the remote already has: pushed, nothing to scan
# P6 a remote branch deleted: allowed, nothing to scan
# P7 an existing remote branch moved forward by a commit whose message holds the
#    entry: refused, the remote branch unchanged
# Not covered: a push to a remote with no <remote>/HEAD (the hook then scans the
# pushed commit's whole history; reasoned, no row), and a stalled scan (no
# timeout of its own; git waits).
#
# Exit 0 = every row passed; exit 1 = a row failed.
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\hooks\prepush.test.ps1
$ErrorActionPreference = 'Continue'
try { . (Join-Path $PSScriptRoot '..\fixtures\hook-test-fixture.ps1') } catch { Write-Error "could not load hook-test-fixture.ps1: $_"; exit 1 }
Clear-HookRunnerGitEnv
. (Join-Path $PSScriptRoot '..\fixtures\coord-test-fixture.ps1')
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('prepush-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory($tmp)
$entry = 'zz' + 'q30' + 'leak'
$deny = Join-Path $tmp 'denylist.txt'
[System.IO.File]::WriteAllText($deny, "# test denylist`n$entry`n", $coordUtf8)
$origin = Join-Path $tmp 'origin.git'
$work = Join-Path $tmp 'work'
$scrubEnv = @('TRACKSTEWARD_SCRUB_STRICT', 'TRACKSTEWARD_SCRUB_HISTORY', 'TRACKSTEWARD_SCRUB_REPOS')

# Runs `git -C $work push <args>` in a child PowerShell (so a hung hook is killed,
# not waited on) with the test denylist set, or with no denylist variable at all.
function Invoke-TestPush([string[]]$PushArgs, [switch]$NoDenylist) {
    $file = Join-Path $tmp ('push-' + [Guid]::NewGuid().ToString('N').Substring(0, 6) + '.ps1')
    $q = { param($s) "'" + ($s -replace "'", "''") + "'" }
    $argText = ($PushArgs | ForEach-Object { & $q $_ }) -join ', '
    $body = "`$a = @($argText)`r`n& git -C $(& $q $work) push @a 2>&1 | ForEach-Object { [string]`$_ }`r`nexit `$LASTEXITCODE`r`n"
    [System.IO.File]::WriteAllText($file, $body, (New-Object System.Text.UTF8Encoding($false)))
    $extra = @{}
    $remove = $scrubEnv
    if ($NoDenylist) { $remove = $scrubEnv + 'TRACKSTEWARD_SCRUB_DENYLIST' } else { $extra['TRACKSTEWARD_SCRUB_DENYLIST'] = $deny }
    return Invoke-HookTestPowerShell -Script $file -StartDir $work -ExtraEnv $extra -RemoveEnv $remove -Seconds 600
}
function Get-RemoteRef([string]$Ref) {
    $o = (& git -C $origin rev-parse -q --verify $Ref 2>$null | Out-String).Trim()
    return $o
}
function Get-LocalRef([string]$Ref) { return (& git -C $work rev-parse $Ref 2>$null | Out-String).Trim() }
function New-TestCommit([string]$Branch, [string]$From, [string]$Message, [hashtable]$Files = @{}, [string[]]$Remove = @()) {
    Invoke-HookTestGit $work @('checkout', '--quiet', '-B', $Branch, $From)
    foreach ($k in $Files.Keys) { [System.IO.File]::WriteAllText((Join-Path $work $k), $Files[$k], $coordUtf8); Invoke-HookTestGit $work @('-c', 'core.safecrlf=false', 'add', '--', $k) }
    foreach ($k in $Remove) { Invoke-HookTestGit $work @('rm', '--quiet', '--', $k) }
    Invoke-HookTestGit $work @('commit', '--quiet', '--allow-empty', '-m', $Message)
}
function Format-Push($R) { return "code=$($R.Code)`n$($R.Out)`n$($R.Err)" }

try {
    # ---- the fixture: a copy of the files git would ship, committed, pushed with hooks off
    Write-Host '(P0) fixture'
    New-HookTestRepo $work
    $list = & git -C $repoRoot -c core.quotepath=false ls-files -z --cached --others --exclude-standard
    $names = @(($list -join '') -split [char]0 | Where-Object { $_ })
    foreach ($n in $names) {
        $src = Join-Path $repoRoot $n
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { continue }
        $dst = Join-Path $work $n
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $dst))
        [System.IO.File]::Copy($src, $dst, $true)
    }
    Invoke-HookTestGit $work @('-c', 'core.safecrlf=false', 'add', '-A')
    Invoke-HookTestGit $work @('commit', '--quiet', '-m', 'base')
    Invoke-HookTestGit $tmp @('-c', 'init.defaultBranch=main', 'init', '--bare', '--quiet', 'origin.git')
    Invoke-HookTestGit $work @('remote', 'add', 'origin', $origin)
    Invoke-HookTestGit $work @('push', '--quiet', 'origin', 'main')
    Invoke-HookTestGit $work @('remote', 'set-head', 'origin', 'main')
    Invoke-HookTestGit $work @('config', 'core.hooksPath', '.githooks')
    $base = Get-LocalRef 'main'
    Assert-Coord 'P0 the copy holds .githooks/pre-push and the hooks point at .githooks' ((Test-Path -LiteralPath (Join-Path $work '.githooks\pre-push') -PathType Leaf) -and ((& git -C $work config core.hooksPath | Out-String).Trim() -ceq '.githooks'))
    Assert-Coord 'P0 the base push landed and origin/HEAD names main' (((Get-RemoteRef 'refs/heads/main') -ceq $base) -and ((Get-LocalRef 'refs/remotes/origin/HEAD') -ceq $base))

    Write-Host '(P1) a commit message with the entry'
    New-TestCommit 'p1' $base "note $entry here"
    $r = Invoke-TestPush @('origin', 'p1')
    Assert-Coord 'P1 a new branch whose commit message holds a denylist entry is refused and does not reach the remote' (($r.Code -ne 0) -and -not (Get-RemoteRef 'refs/heads/p1') -and ($r.Out -match 'commit message [0-9a-f]{7}:1: denylist entry 1') -and ($r.Out -match 'refused')) (Format-Push $r)

    Write-Host '(P2) file content gone again at the tip'
    New-TestCommit 'p2' $base 'add a note' @{ 'note.md' = "a note about $entry`n" }
    New-TestCommit 'p2' 'p2' 'drop the note' @{} @('note.md')
    $r = Invoke-TestPush @('origin', 'p2')
    Assert-Coord 'P2 a denylist entry in a file the pushed commits add and remove again is refused (the tip alone is clean)' (($r.Code -ne 0) -and -not (Get-RemoteRef 'refs/heads/p2') -and ($r.Out -match 'note\.md \(blob [0-9a-f]{7}\):1: denylist entry 1')) (Format-Push $r)

    Write-Host '(P3) a clean commit'
    New-TestCommit 'p3' $base 'a clean change' @{ 'clean.md' = "nothing private`n" }
    $r = Invoke-TestPush @('origin', 'p3')
    Assert-Coord 'P3 a clean commit on a new branch is pushed, after a scan of that one commit' (($r.Code -eq 0) -and ((Get-RemoteRef 'refs/heads/p3') -ceq (Get-LocalRef 'p3')) -and ($r.Out -match 'scanning 1 commit')) (Format-Push $r)

    Write-Host '(P4) no denylist'
    New-TestCommit 'p4' $base 'another clean change' @{ 'clean4.md' = "nothing private`n" }
    $r = Invoke-TestPush @('origin', 'p4') -NoDenylist
    Assert-Coord 'P4 with TRACKSTEWARD_SCRUB_DENYLIST unset a clean push is refused, never let through unscanned' (($r.Code -ne 0) -and -not (Get-RemoteRef 'refs/heads/p4') -and ($r.Out -match 'denylist absent')) (Format-Push $r)

    Write-Host '(P5) a tag on a commit the remote has'
    Invoke-HookTestGit $work @('tag', 't5', $base)
    $r = Invoke-TestPush @('origin', 't5')
    Assert-Coord 'P5 a new tag on a commit the remote already has is pushed with nothing to scan' (($r.Code -eq 0) -and ((Get-RemoteRef 'refs/tags/t5') -ceq $base) -and ($r.Out -match 'nothing new to scan') -and ($r.Out -notmatch 'scanning')) (Format-Push $r)

    Write-Host '(P6) a deletion'
    Invoke-HookTestGit $tmp @('--git-dir', $origin, 'branch', 'p6', $base)
    $r = Invoke-TestPush @('origin', '--delete', 'p6')
    Assert-Coord 'P6 deleting a remote branch is allowed with nothing to scan' (($r.Code -eq 0) -and -not (Get-RemoteRef 'refs/heads/p6') -and ($r.Out -match 'a deletion') -and ($r.Out -notmatch 'scanning')) (Format-Push $r)

    Write-Host '(P7) an existing remote branch moved forward'
    $p3Remote = Get-RemoteRef 'refs/heads/p3'
    New-TestCommit 'p3' 'p3' "follow-up for $entry"
    $r = Invoke-TestPush @('origin', 'p3')
    Assert-Coord 'P7 moving an existing remote branch forward by a commit whose message holds the entry is refused, the remote branch unchanged' (($r.Code -ne 0) -and ((Get-RemoteRef 'refs/heads/p3') -ceq $p3Remote) -and ($r.Out -match 'commit message [0-9a-f]{7}:1: denylist entry 1') -and ($r.Out -match 'refused')) (Format-Push $r)
}
catch {
    Assert-Coord "the suite ran to its end (it threw: $($_.Exception.Message))" $false ($_.ScriptStackTrace)
}
finally {
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

Write-Host ''
Write-CoordUncheckedSummary
Write-Host "Passed: $script:coordPass  Failed: $script:coordFail"
if ($script:coordFail -gt 0) { exit 1 }
exit 0
