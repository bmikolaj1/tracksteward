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
# P16 a commit that a replace ref (git replace) hides behind a clean one: scanned
#     as itself and refused
# P17 a push URL that url.<mirror>.insteadOf would rewrite for ls-remote (a
#     pushInsteadOf keeps the push itself on the real remote): refused before
#     any scan
# P18 a lightweight tag whose name holds the entry, on a commit the remote already
#     has (0 new commits): refused, the tag not on the remote
# P19 a tag whose name holds a two-word entry parted by a no-break space: refused
# P20 a push from a linked worktree whose branch has no hook of its own, under
#     the absolute core.hooksPath of the main checkout (the README setup): a
#     commit with the entry is refused, a clean one is pushed
# P21 a remote that advertises a chain of 1100 more commits (a range longer than
#     a Windows command line), pushes on top of its last one: a commit with the
#     entry is scanned and refused, a clean one is scanned and pushed (the range
#     goes on stdin)
# P22 a deletion of a ref whose name holds the entry: allowed, and the hook's
#     deletion line names the ref by its position, not by its name
# P23 a tag on a blob, and a forced push over a commit this clone does not have,
#     to refs whose names hold the entry: refused, by position, not by name
#     (P1 also checks that the closing refusal line names no checkout path)
# P24 a scrub run that fails without a FAIL line (the suite file missing, so
#     powershell.exe names its absolute path): refused, and the hook prints none
#     of that output
# P25 a suite that stops on an error record (its indented CategoryInfo line names
#     a path), alone and after a FAIL line with its detail: refused; the FAIL
#     line and detail are shown, no line of the error record is
# S1  the copy's scrub suite run without -History, TRACKSTEWARD_SCRUB_DENYLIST
#     unset: exit 0 with a loud NOT CHECKED line (a clone without the private file)
# S2  the same, the variable set to a missing file: exit 1
# S3  the same as S1 with -Strict: exit 1
# S4  -HistoryStdin with nothing on stdin, the denylist set: exit 1
# S5  -History and -HistoryStdin together: exit 1
# Not covered (reasoned, no row): an ls-remote that fails (refused); a push of so
# many refs that their names pass the command-line limit (-PushRefs is still an
# argument; the push is refused); and a stalled scan (no timeout of its own; git
# waits).
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
$entry2 = 'zz' + 'r19a zz' + 'r19b'
[System.IO.File]::WriteAllText($deny, "# test denylist`n$entry`n$entry2`n", $coordUtf8)
$origin = Join-Path $tmp 'origin.git'
$work = Join-Path $tmp 'work'
$scrubEnv = @('TRACKSTEWARD_SCRUB_STRICT', 'TRACKSTEWARD_SCRUB_HISTORY', 'TRACKSTEWARD_SCRUB_REPOS')

# Runs `git -C $work push <args>` in a child PowerShell (so a hung hook is killed,
# not waited on) with the test denylist set, or with no denylist variable at all.
function Invoke-TestPush([string[]]$PushArgs, [switch]$NoDenylist, [string]$AllowIdentFile = '', [string]$From = $work) {
    $file = Join-Path $tmp ('push-' + [Guid]::NewGuid().ToString('N').Substring(0, 6) + '.ps1')
    $q = { param($s) "'" + ($s -replace "'", "''") + "'" }
    $argText = ($PushArgs | ForEach-Object { & $q $_ }) -join ', '
    $body = "`$a = @($argText)`r`n& git -C $(& $q $From) push @a 2>&1 | ForEach-Object { [string]`$_ }`r`nexit `$LASTEXITCODE`r`n"
    [System.IO.File]::WriteAllText($file, $body, (New-Object System.Text.UTF8Encoding($false)))
    $extra = @{}
    $remove = $scrubEnv
    if ($NoDenylist) { $remove = $scrubEnv + 'TRACKSTEWARD_SCRUB_DENYLIST' } else { $extra['TRACKSTEWARD_SCRUB_DENYLIST'] = $deny }
    if ($AllowIdentFile) { $extra['TRACKSTEWARD_SCRUB_ALLOW_IDENT'] = $AllowIdentFile } else { $remove = $remove + 'TRACKSTEWARD_SCRUB_ALLOW_IDENT' }
    return Invoke-HookTestPowerShell -Script $file -StartDir $From -ExtraEnv $extra -RemoveEnv $remove -Seconds 600
}
# Runs the copy's scrub suite (no -History) in a child PowerShell, with the
# denylist variable unset or set to $Denylist.
function Invoke-CopyScrub([string]$Denylist = '', [string]$ScriptArgs = '', [string]$StdinText = '') {
    $extra = @{}
    $remove = $scrubEnv + 'TRACKSTEWARD_SCRUB_ALLOW_IDENT'
    if ($Denylist) { $extra['TRACKSTEWARD_SCRUB_DENYLIST'] = $Denylist } else { $remove = $remove + 'TRACKSTEWARD_SCRUB_DENYLIST' }
    return Invoke-HookTestPowerShell -Script (Join-Path $work 'tests\scrub.test.ps1') -StartDir $work -ExtraEnv $extra -RemoveEnv $remove -ScriptArgs $ScriptArgs -StdinText $StdinText -Seconds 600
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
    $workFwd = $work.Replace('\', '/')
    Assert-Coord 'P1 the refusal names no path of the checkout (a path can hold a private name)' (($r.Out -match 'refused the push: the scrub suite failed') -and -not $r.Out.Contains($work) -and -not $r.Out.Contains($workFwd)) (Format-Push $r)

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
    Assert-Coord 'P6 deleting a remote branch is allowed with nothing to scan' (($r.Code -eq 0) -and -not (Get-RemoteRef 'refs/heads/p6') -and ($r.Out -match 'pre-push: deletion 1 of the push: nothing to scan') -and ($r.Out -notmatch 'scanning')) (Format-Push $r)

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

    Write-Host '(P16) a replace ref'
    New-TestCommit 'p16' $base "replaced $entry" @{ 'r16.md' = "a note about $entry`n" }
    $p16 = Get-LocalRef 'p16'
    New-TestCommit 'p16clean' $base 'clean' @{ 'r16.md' = "nothing private`n" }
    Invoke-HookTestGit $work @('replace', $p16, (Get-LocalRef 'p16clean'))
    try { $r = Invoke-TestPush @('origin', 'p16') }
    finally { Invoke-HookTestGit $work @('replace', '-d', $p16) }
    Assert-Coord 'P16 a commit with a replace ref (git replace) is scanned as itself and refused' (($r.Code -ne 0) -and -not (Get-RemoteRef 'refs/heads/p16') -and ($r.Out -match 'denylist entry 1')) (Format-Push $r)

    Write-Host '(P17) a push URL that insteadOf rewrites for ls-remote'
    $mirror = Join-Path $tmp 'mirror.git'
    Invoke-HookTestGit $tmp @('init', '--bare', '--quiet', 'mirror.git')
    Invoke-HookTestGit $work @('push', '--quiet', '--no-verify', $mirror, 'p3:refs/heads/p17')
    Invoke-HookTestGit $work @('config', "url.$mirror.insteadOf", $origin)
    Invoke-HookTestGit $work @('config', "url.$origin.pushInsteadOf", $origin)
    New-TestCommit 'p17' 'p3' 'clean on p3' @{ 'c17.md' = "nothing private`n" }
    try { $r = Invoke-TestPush @('origin', 'p17') }
    finally {
        Invoke-HookTestGit $work @('config', '--unset', "url.$mirror.insteadOf")
        Invoke-HookTestGit $work @('config', '--unset', "url.$origin.pushInsteadOf")
    }
    Assert-Coord 'P17 a push whose URL git would rewrite for ls-remote (insteadOf a mirror) is refused before any scan' (($r.Code -ne 0) -and -not (Get-RemoteRef 'refs/heads/p17') -and ($r.Out -match 'insteadOf') -and ($r.Out -notmatch 'scanning')) (Format-Push $r)

    Write-Host '(P18) a tag name with the entry, on a commit the remote has'
    Invoke-HookTestGit $work @('tag', "t18-$entry", $base)
    $r = Invoke-TestPush @('origin', "refs/tags/t18-$entry")
    Assert-Coord 'P18 a tag whose name holds the entry, on a commit the remote already has (0 new commits), is refused' (($r.Code -ne 0) -and -not (Get-RemoteRef "refs/tags/t18-$entry") -and ($r.Out -match 'scanning 0 commit') -and ($r.Out -match 'pushed ref name 1:1: denylist entry 1')) (Format-Push $r)

    Write-Host '(P19) a tag name with a no-break space'
    $t19 = 't19-' + $entry2.Replace(' ', [string][char]0x00A0)
    Invoke-HookTestGit $work @('tag', $t19, $base)
    # The push names it by an ASCII glob: Invoke-TestPush writes its arguments
    # into a script file, which Windows PowerShell 5.1 reads as ANSI.
    $prevOutEnc = [Console]::OutputEncoding
    [Console]::OutputEncoding = $coordUtf8
    try { $localT19 = (& git -C $work for-each-ref --format='%(refname)' 'refs/tags/t19-*' | Out-String).Trim() } finally { [Console]::OutputEncoding = $prevOutEnc }
    Assert-Coord 'P19 control: the local tag name holds the no-break space' ($localT19 -ceq "refs/tags/$t19") "local=$localT19"
    $r = Invoke-TestPush @('origin', 'refs/tags/t19-*:refs/tags/t19-*')
    $remoteT19 = (& git --git-dir $origin for-each-ref --format='%(refname)' 'refs/tags/t19-*' | Out-String).Trim()
    Assert-Coord 'P19 a tag whose name holds a two-word entry parted by a no-break space is refused' (($r.Code -ne 0) -and -not $remoteT19 -and ($r.Out -match 'pushed ref name 1:1: denylist entry 2')) (Format-Push $r)
    Invoke-HookTestGit $work @('checkout', '--quiet', 'main')

    Write-Host '(P20) a push from a linked worktree under the absolute core.hooksPath'
    # The README setup: core.hooksPath in the main checkout names its .githooks by
    # absolute path, and a worktree whose branch predates the hook (here: has no
    # .githooks at all) runs the main checkout's hook and scrub suite.
    $wt = Join-Path $tmp 'wt20'
    Invoke-HookTestGit $work @('worktree', 'add', '--quiet', '-b', 'p20', $wt, $base)
    Invoke-HookTestGit $wt @('rm', '-r', '--quiet', '--', '.githooks')
    Invoke-HookTestGit $wt @('commit', '--quiet', '-m', 'a branch without the hook')
    Invoke-HookTestGit $work @('config', 'core.hooksPath', (Join-Path $work '.githooks'))
    try {
        # git prints the value as UTF-8: read it so (a non-ASCII temp path would
        # read back garbled under the console code page), as the fixture does.
        $prevOutEnc = [Console]::OutputEncoding
        try { [Console]::OutputEncoding = $coordUtf8; $wtHooks = (& git -C $wt config core.hooksPath | Out-String).Trim() } finally { [Console]::OutputEncoding = $prevOutEnc }
        Assert-Coord 'P20 control: the worktree has no .githooks of its own and reads the absolute core.hooksPath' ((-not (Test-Path -LiteralPath (Join-Path $wt '.githooks'))) -and ($wtHooks -ceq (Join-Path $work '.githooks'))) "read=$wtHooks"
        [System.IO.File]::WriteAllText((Join-Path $wt 'w20.md'), "a note about $entry`n", $coordUtf8)
        Invoke-HookTestGit $wt @('-c', 'core.safecrlf=false', 'add', '--', 'w20.md')
        Invoke-HookTestGit $wt @('commit', '--quiet', '-m', 'a worktree note')
        $r = Invoke-TestPush @('origin', 'p20') -From $wt
        Assert-Coord 'P20 a push from the linked worktree of a commit with the entry runs the main checkout''s hook and is refused' (($r.Code -ne 0) -and -not (Get-RemoteRef 'refs/heads/p20') -and ($r.Out -match 'w20\.md \(blob [0-9a-f]{7}\):1: denylist entry 1')) (Format-Push $r)
        Invoke-HookTestGit $wt @('reset', '--quiet', '--hard', 'HEAD~1')
        [System.IO.File]::WriteAllText((Join-Path $wt 'c20.md'), "nothing private`n", $coordUtf8)
        Invoke-HookTestGit $wt @('-c', 'core.safecrlf=false', 'add', '--', 'c20.md')
        Invoke-HookTestGit $wt @('commit', '--quiet', '-m', 'a clean worktree change')
        $r = Invoke-TestPush @('origin', 'p20') -From $wt
        Assert-Coord 'P20 a clean push from the linked worktree is scanned (2 commits) and pushed' (($r.Code -eq 0) -and ((Get-RemoteRef 'refs/heads/p20') -ceq (Get-LocalRef 'p20')) -and ($r.Out -match 'scanning 2 commit')) (Format-Push $r)
    }
    finally {
        Invoke-HookTestGit $work @('config', 'core.hooksPath', '.githooks')
        Invoke-HookTestGit $work @('worktree', 'remove', '--force', $wt)
    }

    Write-Host '(P21) a remote that advertises more commits than fit on a command line'
    # A chain of 1100 commits on the base, each on its own remote branch (a busy
    # remote's refs/pull/* advertise this many), made with fast-import from a
    # file (a PowerShell pipe would put a BOM in front of the stream). The pushes
    # build on the last one, so only its exclusion keeps the count at 1.
    $fi = New-Object System.Text.StringBuilder
    for ($i = 1; $i -le 1100; $i++) {
        $msg = "m$i"
        $from = if ($i -eq 1) { $base } else { ':' + ($i - 1) }
        [void]$fi.Append("commit refs/heads/many/$i`nmark :$i`ncommitter t <t@example.invalid> 1700000000 +0000`ndata $($msg.Length)`n$msg`nfrom $from`n`n")
    }
    $fiFile = Join-Path $tmp 'many.fi'
    [System.IO.File]::WriteAllText($fiFile, $fi.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    $fiOut = (& cmd.exe /d /c "git -C `"$work`" fast-import --quiet < `"$fiFile`" 2>&1" | Out-String).Trim()
    Invoke-HookTestGit $work @('push', '--quiet', '--no-verify', 'origin', 'refs/heads/many/*:refs/heads/many/*')
    $advertised = @((& git -C $work ls-remote origin 'refs/heads/many/*' | Out-String) -split "`r?`n" | Where-Object { $_ }).Count
    Assert-Coord 'P21 control: the remote advertises 1100 more commits (a range of more than 32767 characters)' ($advertised -eq 1100) "advertised=$advertised fast-import=$fiOut"
    New-TestCommit 'p21d' 'refs/heads/many/1100' "note $entry at scale"
    $r = Invoke-TestPush @('origin', 'p21d')
    Assert-Coord 'P21 at that scale a commit whose message holds the entry is scanned (1 commit) and refused, not on the remote' (($r.Code -ne 0) -and -not (Get-RemoteRef 'refs/heads/p21d') -and ($r.Out -match 'scanning 1 commit') -and ($r.Out -match 'commit message [0-9a-f]{7}:1: denylist entry 1')) (Format-Push $r)
    New-TestCommit 'p21' 'refs/heads/many/1100' 'a clean change' @{ 'c21.md' = "nothing private`n" }
    $r = Invoke-TestPush @('origin', 'p21')
    Assert-Coord 'P21 a clean push on top of the 1100 advertised commits is scanned (1 commit) and pushed' (($r.Code -eq 0) -and ((Get-RemoteRef 'refs/heads/p21') -ceq (Get-LocalRef 'p21')) -and ($r.Out -match 'scanning 1 commit')) (Format-Push $r)
    Invoke-HookTestGit $work @('checkout', '--quiet', 'main')

    # The hook's own lines (git's own push output names the refs too; only what
    # the hook prints is checked).
    function Get-HookLines($R) { return @(($R.Out -split "`r?`n") | Where-Object { $_ -match '^pre-push: ' }) }

    Write-Host '(P22) a deletion of a ref whose name holds the entry'
    Invoke-HookTestGit $tmp @('--git-dir', $origin, 'branch', "del-$entry", $base)
    $r = Invoke-TestPush @('origin', '--delete', "del-$entry")
    $hl = Get-HookLines $r
    Assert-Coord 'P22 a deletion of a ref whose name holds the entry is allowed, and the hook names it by its position, not its name' (($r.Code -eq 0) -and -not (Get-RemoteRef "refs/heads/del-$entry") -and @($hl | Where-Object { $_ -match '^pre-push: deletion 1 of the push: nothing to scan$' }).Count -eq 1 -and @($hl | Where-Object { $_.Contains($entry) }).Count -eq 0) (Format-Push $r)

    Write-Host '(P23) refusals of refs whose names hold the entry'
    Invoke-HookTestGit $work @('tag', "t23-$entry", $blob)
    $r = Invoke-TestPush @('origin', "refs/tags/t23-$entry")
    $hl = Get-HookLines $r
    Assert-Coord 'P23 a tag on a blob whose name holds the entry is refused, and the refusal names it by its position, not its name' (($r.Code -ne 0) -and -not (Get-RemoteRef "refs/tags/t23-$entry") -and @($hl | Where-Object { $_ -match 'not a commit' }).Count -eq 1 -and @($hl | Where-Object { $_.Contains($entry) }).Count -eq 0) (Format-Push $r)
    Invoke-HookTestGit $tmp @('--git-dir', $origin, 'update-ref', "refs/heads/f23-$entry", $foreign)
    $r = Invoke-TestPush @('--force', 'origin', "p3:refs/heads/f23-$entry")
    $hl = Get-HookLines $r
    Assert-Coord 'P23 a forced push over a commit this clone does not have, to a ref whose name holds the entry, is refused by position, not by name' (($r.Code -ne 0) -and ((Get-RemoteRef "refs/heads/f23-$entry") -ceq $foreign) -and @($hl | Where-Object { $_ -match 'fetch first' }).Count -eq 1 -and @($hl | Where-Object { $_.Contains($entry) }).Count -eq 0) (Format-Push $r)

    Write-Host '(P24) a scrub suite that fails without a FAIL line'
    # The suite file is missing: powershell.exe prints an error that names its
    # absolute path, and no FAIL line. The hook refuses without printing it.
    $suiteFile = Join-Path $work 'tests\scrub.test.ps1'
    $suiteAside = Join-Path $tmp 'scrub.test.ps1.aside'
    [System.IO.File]::Move($suiteFile, $suiteAside)
    try {
        New-TestCommit 'p24' $base 'a clean change' @{ 'c24.md' = "nothing private`n" }
        $r = Invoke-TestPush @('origin', 'p24')
    }
    finally { [System.IO.File]::Move($suiteAside, $suiteFile) }
    Assert-Coord 'P24 a scrub run that fails with no FAIL line refuses the push, and the hook prints none of its output (it can name the checkout path)' (($r.Code -ne 0) -and -not (Get-RemoteRef 'refs/heads/p24') -and ($r.Out -match 'printed no FAIL line') -and -not $r.Out.Contains($work) -and -not $r.Out.Contains($workFwd)) (Format-Push $r)
    Invoke-HookTestGit $work @('checkout', '--quiet', 'main')

    Write-Host '(P25) a scrub suite that stops on an error record'
    # The suite replaced by a stub that stops on a terminating error: PowerShell
    # prints an error record whose indented "+ CategoryInfo" line names the
    # absolute path. Once alone, once after a FAIL line and its detail: the FAIL
    # line and its detail are shown, the error record is not.
    $stubPlain = "Get-Item -LiteralPath (Join-Path `$PSScriptRoot 'no-such-file') -ErrorAction Stop`r`nexit 0`r`n"
    $stubFail = "Write-Host '  FAIL: a stub row'`r`nWrite-Host '    the stub detail'`r`n" + $stubPlain
    $r25 = @()
    [System.IO.File]::Move($suiteFile, $suiteAside)
    try {
        New-TestCommit 'p25' $base 'a clean change' @{ 'c25.md' = "nothing private`n" }
        foreach ($stub in @($stubPlain, $stubFail)) {
            [System.IO.File]::WriteAllText($suiteFile, $stub, (New-Object System.Text.UTF8Encoding($false)))
            $r25 += , (Invoke-TestPush @('origin', 'p25'))
        }
    }
    finally {
        if (Test-Path -LiteralPath $suiteFile) { Remove-Item -LiteralPath $suiteFile -Force }
        [System.IO.File]::Move($suiteAside, $suiteFile)
    }
    $r = $r25[0]
    Assert-Coord 'P25 a suite that stops on an error record (no FAIL line) refuses the push, and no line of the record is shown' (($r.Code -ne 0) -and -not (Get-RemoteRef 'refs/heads/p25') -and ($r.Out -match 'printed no FAIL line') -and ($r.Out -notmatch 'CategoryInfo') -and -not $r.Out.Contains($work) -and -not $r.Out.Contains($workFwd)) (Format-Push $r)
    $r = $r25[1]
    Assert-Coord 'P25 after a FAIL line and its detail, the FAIL line and the detail are shown, the error record is not' (($r.Code -ne 0) -and -not (Get-RemoteRef 'refs/heads/p25') -and ($r.Out -match 'FAIL: a stub row') -and ($r.Out -match 'the stub detail') -and ($r.Out -notmatch 'CategoryInfo') -and -not $r.Out.Contains($work) -and -not $r.Out.Contains($workFwd)) (Format-Push $r)
    Invoke-HookTestGit $work @('checkout', '--quiet', 'main')

    Write-Host '(S1-S3) the copy''s scrub suite with no -History'
    $r = Invoke-CopyScrub
    Assert-Coord 'S1 without -History and with TRACKSTEWARD_SCRUB_DENYLIST unset the scrub suite exits 0 and says NOT CHECKED (a clone without the private file)' (($r.Code -eq 0) -and ($r.Out -match 'NOT CHECKED: denylist absent')) (Format-Push $r)
    $r = Invoke-CopyScrub (Join-Path $tmp 'no-such-denylist.txt')
    Assert-Coord 'S2 the variable set to a missing file: exit 1' (($r.Code -eq 1) -and ($r.Out -match 'TRACKSTEWARD_SCRUB_DENYLIST is set')) (Format-Push $r)
    $r = Invoke-CopyScrub '' '-Strict'
    Assert-Coord 'S3 unset with -Strict: exit 1' (($r.Code -eq 1) -and ($r.Out -match 'strict mode')) (Format-Push $r)
    $r = Invoke-CopyScrub $deny '-HistoryStdin -AllowEmptyRange'
    Assert-Coord 'S4 -HistoryStdin with nothing on stdin: exit 1 (a gate run with no range is not a pass)' (($r.Code -eq 1) -and ($r.Out -match 'stdin held no revision')) (Format-Push $r)
    $r = Invoke-CopyScrub $deny ('-History ' + $base + ' -HistoryStdin') ($base + "`n")
    Assert-Coord 'S5 -History and -HistoryStdin together: exit 1' (($r.Code -eq 1) -and ($r.Out -match 'not both')) (Format-Push $r)
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
