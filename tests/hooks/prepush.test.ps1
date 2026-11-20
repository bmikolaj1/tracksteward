# Pre-push gate suite: .githooks/pre-push runs the scrub suite once per push, with
# -History over the commits the push sends that the remote does not advertise
# (SG6: every commit message, author and committer line, file name and blob those
# commits add or change, and every annotated tag pushed) and with the pushed ref
# names, and refuses the push when that run fails, a missing denylist included.
# The rows make real `git push` calls into a bare repo, from a copy of this repo's
# shippable files (the hook runs the COPY's own tests\scrub.test.ps1), with a
# throwaway denylist whose one entry is built at run time, so this file never
# holds it. Each scanned push runs the scrub suite once (about 20 s here).
#
# P0  fixture sanity: the copy has the hook, the hooks are on, the base push landed
# P1  a new branch whose commit message holds the entry: refused, not on the remote
# P2  a file with the entry, added and removed again before the push (the tip is
#     clean): refused
# P3  a clean commit on a new branch: pushed, and the hook says it scanned
# P4  TRACKSTEWARD_SCRUB_DENYLIST unset: refused (a push is never let through unscanned)
# P5  a new lightweight tag on a commit the remote already has: pushed, 0 commits
#     scanned (its name is still scanned)
# P6  a remote branch deleted: allowed, nothing to scan
# P7  an existing remote branch moved forward by a commit whose message holds the
#     entry: refused, the remote branch unchanged
# P8  a stale origin/main (the remote was rewound behind it): a branch at the old
#     commit, which holds the entry, is refused (the range comes from what the
#     remote advertises, not from the local tracking refs)
# P9  a UTF-16 LE blob with no BOM (NUL bytes) that holds the entry: refused (a
#     -History run allows no unread blob)
# P10 an annotated tag whose message holds the entry, on a commit the remote has:
#     refused, the tag not on the remote
# P11 a tag on a blob, plain or annotated: refused before any scan
# P12 two branches in one push, the second one dirty: refused, neither on the remote
# P13 a forced push over a remote commit this clone does not have: refused (fetch first)
# P14 a clean commit on a branch whose name holds the entry: refused
# P15 a clean commit whose author line holds the entry: refused; with that exact
#     identity in the file TRACKSTEWARD_SCRUB_ALLOW_IDENT names: pushed
# S1  the copy's scrub suite run without -History, TRACKSTEWARD_SCRUB_DENYLIST
#     unset: exit 0 with a loud NOT CHECKED line (a clone without the private file)
# S2  the same, the variable set to a missing file: exit 1
# S3  the same as S1 with -Strict: exit 1
# Not covered: a remote that advertises so many commits that the -History argument
# passes the Windows command-line limit (the scrub suite then does not start, its
# exit is not 0 and the push is refused; reasoned, no row), and a stalled scan (no
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
function Invoke-TestPush([string[]]$PushArgs, [switch]$NoDenylist, [string]$AllowIdentFile = '') {
    $file = Join-Path $tmp ('push-' + [Guid]::NewGuid().ToString('N').Substring(0, 6) + '.ps1')
    $q = { param($s) "'" + ($s -replace "'", "''") + "'" }
    $argText = ($PushArgs | ForEach-Object { & $q $_ }) -join ', '
    $body = "`$a = @($argText)`r`n& git -C $(& $q $work) push @a 2>&1 | ForEach-Object { [string]`$_ }`r`nexit `$LASTEXITCODE`r`n"
    [System.IO.File]::WriteAllText($file, $body, (New-Object System.Text.UTF8Encoding($false)))
    $extra = @{}
    $remove = $scrubEnv
    if ($NoDenylist) { $remove = $scrubEnv + 'TRACKSTEWARD_SCRUB_DENYLIST' } else { $extra['TRACKSTEWARD_SCRUB_DENYLIST'] = $deny }
    if ($AllowIdentFile) { $extra['TRACKSTEWARD_SCRUB_ALLOW_IDENT'] = $AllowIdentFile } else { $remove = $remove + 'TRACKSTEWARD_SCRUB_ALLOW_IDENT' }
    return Invoke-HookTestPowerShell -Script $file -StartDir $work -ExtraEnv $extra -RemoveEnv $remove -Seconds 600
}
# Runs the copy's scrub suite (no -History) in a child PowerShell, with the
# denylist variable unset or set to $Denylist.
function Invoke-CopyScrub([string]$Denylist = '', [string]$ScriptArgs = '') {
    $extra = @{}
    $remove = $scrubEnv + 'TRACKSTEWARD_SCRUB_ALLOW_IDENT'
    if ($Denylist) { $extra['TRACKSTEWARD_SCRUB_DENYLIST'] = $Denylist } else { $remove = $remove + 'TRACKSTEWARD_SCRUB_DENYLIST' }
    return Invoke-HookTestPowerShell -Script (Join-Path $work 'tests\scrub.test.ps1') -StartDir $work -ExtraEnv $extra -RemoveEnv $remove -ScriptArgs $ScriptArgs -Seconds 600
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
    Assert-Coord 'P5 a new lightweight tag on a commit the remote already has is pushed, 0 commits scanned (its name still is)' (($r.Code -eq 0) -and ((Get-RemoteRef 'refs/tags/t5') -ceq $base) -and ($r.Out -match 'scanning 0 commit')) (Format-Push $r)

    Write-Host '(P6) a deletion'
    Invoke-HookTestGit $tmp @('--git-dir', $origin, 'branch', 'p6', $base)
    $r = Invoke-TestPush @('origin', '--delete', 'p6')
    Assert-Coord 'P6 deleting a remote branch is allowed with nothing to scan' (($r.Code -eq 0) -and -not (Get-RemoteRef 'refs/heads/p6') -and ($r.Out -match 'a deletion') -and ($r.Out -notmatch 'scanning')) (Format-Push $r)

    Write-Host '(P7) an existing remote branch moved forward'
    $p3Remote = Get-RemoteRef 'refs/heads/p3'
    New-TestCommit 'p3' 'p3' "follow-up for $entry"
    $r = Invoke-TestPush @('origin', 'p3')
    Assert-Coord 'P7 moving an existing remote branch forward by a commit whose message holds the entry is refused, the remote branch unchanged' (($r.Code -ne 0) -and ((Get-RemoteRef 'refs/heads/p3') -ceq $p3Remote) -and ($r.Out -match 'commit message [0-9a-f]{7}:1: denylist entry 1') -and ($r.Out -match 'refused')) (Format-Push $r)

    Write-Host '(P8) a stale origin/main'
    New-TestCommit 'p8' $base "old $entry"
    $p8 = Get-LocalRef 'p8'
    Invoke-HookTestGit $work @('update-ref', 'refs/remotes/origin/main', $p8)
    try { $r = Invoke-TestPush @('origin', 'p8') }
    finally { Invoke-HookTestGit $work @('update-ref', 'refs/remotes/origin/main', $base) }
    Assert-Coord 'P8 with origin/main stale at a commit the remote does not have, a branch at that commit is scanned and refused' (($r.Code -ne 0) -and -not (Get-RemoteRef 'refs/heads/p8') -and ($r.Out -match 'commit message [0-9a-f]{7}:1: denylist entry 1')) (Format-Push $r)

    Write-Host '(P9) a UTF-16 LE blob with no BOM'
    Invoke-HookTestGit $work @('checkout', '--quiet', '-B', 'p9', $base)
    [System.IO.File]::WriteAllBytes((Join-Path $work 'wide.txt'), [System.Text.Encoding]::Unicode.GetBytes("a $entry b`n"))
    Invoke-HookTestGit $work @('-c', 'core.safecrlf=false', 'add', '--', 'wide.txt')
    Invoke-HookTestGit $work @('commit', '--quiet', '-m', 'a wide file')
    $r = Invoke-TestPush @('origin', 'p9')
    Assert-Coord 'P9 a blob with NUL bytes and no BOM is refused (a -History run reads every blob or fails)' (($r.Code -ne 0) -and -not (Get-RemoteRef 'refs/heads/p9') -and ($r.Out -match 'NUL bytes')) (Format-Push $r)
    Invoke-HookTestGit $work @('checkout', '--quiet', 'main')

    Write-Host '(P10) an annotated tag message'
    Invoke-HookTestGit $work @('tag', '-a', 't10', '-m', "release $entry", $base)
    $r = Invoke-TestPush @('origin', 'refs/tags/t10')
    Assert-Coord 'P10 an annotated tag whose message holds the entry is refused, on a commit the remote already has' (($r.Code -ne 0) -and -not (Get-RemoteRef 'refs/tags/t10') -and ($r.Out -match 'tag [0-9a-f]{7}:\d+: denylist entry 1')) (Format-Push $r)

    Write-Host '(P11) tags on a blob'
    $blob = (& git -C $work rev-parse "${base}:README.md" | Out-String).Trim()
    Invoke-HookTestGit $work @('tag', 't11', $blob)
    Invoke-HookTestGit $work @('tag', '-a', 't11a', '-m', 'x', $blob)
    $r = Invoke-TestPush @('origin', 'refs/tags/t11')
    $ra = Invoke-TestPush @('origin', 'refs/tags/t11a')
    Assert-Coord 'P11 a tag on a blob, plain or annotated, is refused before any scan' (($r.Code -ne 0) -and ($ra.Code -ne 0) -and -not (Get-RemoteRef 'refs/tags/t11') -and -not (Get-RemoteRef 'refs/tags/t11a') -and ($r.Out -match 'not a commit') -and ($ra.Out -match 'not a commit') -and ($r.Out -notmatch 'scanning') -and ($ra.Out -notmatch 'scanning')) ((Format-Push $r) + "`n----`n" + (Format-Push $ra))

    Write-Host '(P12) two branches in one push'
    New-TestCommit 'p12a' $base 'clean a' @{ 'a12.md' = "nothing private`n" }
    New-TestCommit 'p12b' $base "dirty $entry"
    $r = Invoke-TestPush @('origin', 'p12a', 'p12b')
    Assert-Coord 'P12 a push of a clean and a dirty branch is refused whole: neither branch reaches the remote' (($r.Code -ne 0) -and -not (Get-RemoteRef 'refs/heads/p12a') -and -not (Get-RemoteRef 'refs/heads/p12b') -and ($r.Out -match 'denylist entry 1')) (Format-Push $r)

    Write-Host '(P13) a forced push over a commit this clone does not have'
    $tree = (& git --git-dir $origin rev-parse "${base}^{tree}" | Out-String).Trim()
    $foreign = (& git --git-dir $origin -c user.name=t -c user.email=t@example.invalid commit-tree $tree -p $base -m 'made on the remote' | Out-String).Trim()
    Invoke-HookTestGit $tmp @('--git-dir', $origin, 'update-ref', 'refs/heads/p13', $foreign)
    # git's "could not get object info" on stderr would end the suite under Stop
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $haveIt = (& git -C $work cat-file -t $foreign 2>$null | Out-String).Trim() } finally { $ErrorActionPreference = $prevEap }
    Assert-Coord 'P13 control: the remote has a commit this clone does not have' (($foreign -match '^[0-9a-f]{40}$') -and -not $haveIt) "foreign=$foreign local type=$haveIt"
    $r = Invoke-TestPush @('--force', 'origin', 'p3:refs/heads/p13')
    Assert-Coord 'P13 a forced push over a remote commit this clone does not have is refused (fetch first), the remote branch unchanged' (($r.Code -ne 0) -and ((Get-RemoteRef 'refs/heads/p13') -ceq $foreign) -and ($r.Out -match 'fetch first')) (Format-Push $r)

    Write-Host '(P14) a ref name with the entry'
    New-TestCommit "fix-$entry" $base 'clean fix' @{ 'c14.md' = "nothing private`n" }
    $r = Invoke-TestPush @('origin', "fix-$entry")
    Assert-Coord 'P14 a clean commit on a branch whose name holds the entry is refused' (($r.Code -ne 0) -and -not (Get-RemoteRef "refs/heads/fix-$entry") -and ($r.Out -match 'pushed ref name 1:1: denylist entry 1')) (Format-Push $r)

    Write-Host '(P15) an author line with the entry'
    $ident = "Q $entry <q@example.invalid>"
    Invoke-HookTestGit $work @('checkout', '--quiet', '-B', 'p15', $base)
    Invoke-HookTestGit $work @('commit', '--quiet', '--allow-empty', '--author', $ident, '-m', 'clean message')
    $r = Invoke-TestPush @('origin', 'p15')
    Assert-Coord 'P15 a clean commit whose author line holds the entry is refused (no allowed identity set)' (($r.Code -ne 0) -and -not (Get-RemoteRef 'refs/heads/p15') -and ($r.Out -match 'author of commit [0-9a-f]{7}:1: denylist entry 1')) (Format-Push $r)
    $allow = Join-Path $tmp 'allow.txt'
    [System.IO.File]::WriteAllText($allow, "# allowed identities`n$ident`n", $coordUtf8)
    $r = Invoke-TestPush @('origin', 'p15') -AllowIdentFile $allow
    Assert-Coord 'P15 the same push with that exact identity in the allowed-identity file is pushed' (($r.Code -eq 0) -and ((Get-RemoteRef 'refs/heads/p15') -ceq (Get-LocalRef 'p15'))) (Format-Push $r)
    Invoke-HookTestGit $work @('checkout', '--quiet', 'main')

    Write-Host '(S1-S3) the copy''s scrub suite with no -History'
    $r = Invoke-CopyScrub
    Assert-Coord 'S1 without -History and with TRACKSTEWARD_SCRUB_DENYLIST unset the scrub suite exits 0 and says NOT CHECKED (a clone without the private file)' (($r.Code -eq 0) -and ($r.Out -match 'NOT CHECKED: denylist absent')) (Format-Push $r)
    $r = Invoke-CopyScrub (Join-Path $tmp 'no-such-denylist.txt')
    Assert-Coord 'S2 the variable set to a missing file: exit 1' (($r.Code -eq 1) -and ($r.Out -match 'TRACKSTEWARD_SCRUB_DENYLIST is set')) (Format-Push $r)
    $r = Invoke-CopyScrub '' '-Strict'
    Assert-Coord 'S3 unset with -Strict: exit 1' (($r.Code -eq 1) -and ($r.Out -match 'strict mode')) (Format-Push $r)
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
