# Tests for scripts/merge-verify.ps1: the verdict after a merge, and the opt-in
# branch delete. Ported from the private coordinate toolkit
# (merge-verify.test.ps1), 2026-10-28. gh is the stub in tests\stubs; git runs
# for real against a bare origin. Each case builds its own fixture: a branch
# `feat` merged into origin/main with a merge commit while the launch checkout
# is still one commit behind.
#
# What changed from the private suite (D5 of docs/plans/2026-10-18-script-port.md):
#   - the remote branch is deleted only under -DeleteBranch. Invoke-Verify adds
#     it to every call unless -NoDeleteFlag is given, so V1-V23 keep their
#     meaning; the private -KeepBranch switch is gone (keeping is the default).
#     New rows D1-D7 cover the default: a delete without -DeleteBranch is
#     impossible, the "would run" command is printed, every guard still applies
#     under the flag, and a branch whose tip moved is never deleted.
#   - the notes are written for the user, not for a named person.
#
#   V1   happy path: merge verified on origin/main, remote branch deleted,
#        launch checkout fast-forwarded, config ok -> OK, exit 0
#   V2   gh says OPEN -> NOT MERGED, exit 1, nothing deleted, no fast-forward
#   V3   gh's merge commit is not on origin/main -> PROBLEM, branch kept, no ff
#   V4   the branch tip moved after the merge -> kept (new work), still OK
#   V5   the branch is already gone -> "already gone", OK
#   V6   a tracked change in the launch checkout -> ff skipped, file and HEAD
#        unchanged, OK
#   V7   untracked files only -> ff happens
#   V8   launch checkout on another branch, or -Repo a linked worktree -> ff skipped
#   V9   local commits ahead of origin -> ff skipped (diverged)
#   V10  -NoFastForward -> skipped; no -DeleteBranch -> branch kept (see D1)
#   V11  config: a local core.bare=true, core.autocrlf or diff.* -> WARN, PROBLEM,
#        exit 1; core.hooksPath `.githooks` or `<main>\.githooks` -> ok, a
#        foreign one (with a .githooks folder present) -> WARN; an empty
#        effective user.name -> WARN
#   V12  a fork PR (isCrossRepository) -> branch untouched
#   V13  gh fails, or origin cannot be fetched -> exit 2
#   V14  a head branch named main, master, or equal to baseRefName -> never deleted
#   V15  a sibling x/feat on origin is neither read as feat's tip nor deleted
#   V16  a delete that fails -> PROBLEM, never "deleted": origin rejects it
#        (V16a), or the lease breaks because feat moves on origin between the
#        tip read and the push (V16b, a receive-pack wrapper)
#   V17  malformed JSON, MERGED without mergeCommit, a non-hex headRefOid, a
#        missing or non-boolean isCrossRepository -> exit 2, nothing deleted,
#        no fast-forward
#   V18  an open PR still uses the branch as its base (stacked) or head -> kept
#   V19  origin's default branch (origin's own HEAD, no local origin/HEAD) -> kept;
#        origin's HEAD unborn, so ls-remote names no branch -> unknown,
#        PROBLEM, kept (V19b)
#   V20  a local branch named origin/main does not shadow the remote ref
#   V21  the open-PR check fails (gh) -> unknown, PROBLEM, branch kept
#   V22  the push URL differs from the fetch URL (pushInsteadOf) -> kept, PROBLEM
#   V23  two push URLs, the first equal to the fetch URL -> kept, PROBLEM
#   Not covered by a row: a delete whose push exits non-zero while the re-read
#   shows the ref gone ("unknown: ..."); no fixture produces it.
#   N1-N13 (NOTIFY lines after an OK verdict; -Ledger scratch
#   fixtures): N1 lines for live rows only, before the verdict; N2 finished rows
#   print none; N3 PROBLEM / NOT MERGED print none; N4 no ledger, output identical;
#   N5 advanced base tip; N6 non-main base; N7 branch + tag named origin/main do not
#   shadow the tip; N8 unreadable ledger; N9 malformed table; N10 bad mergedAt;
#   N11 no session id; N12 default ledger from a linked worktree; N13 odd Repo cell.
#   Not covered by a row: the failing-rev-parse branch of the tip check, and the
#   [datetime] branch of mergedAt (Windows PowerShell 5.1 reads it as a string).
#
#   D1   no -DeleteBranch: the branch stays, the verdict is OK, the line says
#        "-DeleteBranch not given; would run: git push ..." with the lease on
#        the merged head, and no push reaches origin (a pre-receive hook that
#        logs every push stays silent)
#   D2   the same case with -DeleteBranch deletes it, and the push log then
#        holds exactly one ref update
#   D3   no -DeleteBranch: every guard still names its own reason (tip moved,
#        stacked PR, default branch, fork PR) instead of the "would run" line,
#        and the remote branch survives
#   D4   -DeleteBranch with the tip moved -> kept, never deleted
#   D5   -DeleteBranch widens nothing the guards keep: a head named main, a
#        fork PR, a differing push URL (the base and the main/master rule are
#        isolated by V14, which also runs with the flag)
#   D6   a text lint of the script: its push is built once, run by one call
#        that sits in the else of the -not $DeleteBranch test, and no other
#        non-comment line holds the single-quoted token 'push' (a lint, not
#        proof; D1 is the proof)
#   D7   a branch name a shell would act on (feat;calc): no command is printed
#        without the flag, and the flag still deletes it
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\scripts\merge-verify.test.ps1 [-ScriptPath <mutant copy>]
# Exit: 0 = all passed, 1 = a case failed.
param([string]$ScriptPath = '')

try { . (Join-Path $PSScriptRoot '../fixtures/hook-test-fixture.ps1') } catch { Write-Error "could not load hook-test-fixture.ps1: $_"; exit 1 }
Clear-HookRunnerGitEnv
. (Join-Path $PSScriptRoot '../fixtures/coord-test-fixture.ps1')
$ErrorActionPreference = 'Stop'

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('merge-verify-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory($root)
$verdictRx = '^MERGE-VERIFY #(\d+): (OK|PROBLEM|NOT MERGED) - \S'

# A fixture with `feat` merged into origin/main; the launch checkout is at the
# pre-merge main.
function New-MergedCase {
    param([string]$Name, [string]$Branch = 'feat')
    $fx = New-CoordFixture $root $Name
    $before = Get-CoordGitOut $fx.Launch @('rev-parse', 'HEAD')
    $br = New-CoordBranch $fx $Branch -Write @{ 'docs/x.md' = "x`n" }
    $m = Merge-CoordIntoMain $fx $br
    return [pscustomobject]@{ Fx = $fx; Head = $br; Merge = $m; Before = $before; Branch = $Branch }
}

function Get-MergedJson {
    param($C, [string]$State = 'MERGED', [string]$MergeCommit = $C.Merge, [string]$HeadRef = $C.Branch,
        [string]$Base = 'main', [bool]$Cross = $false, [string]$Head = $C.Head)
    return (New-CoordPrJson -Number 7 -Head $Head -HeadRef $HeadRef -State $State -Base $Base -MergeCommit $MergeCommit -Cross $Cross)
}

# By default no open PR uses the branch (`pr list ... --base/--head` -> []).
# -ListRules replaces those answers.
function Invoke-Verify {
    param($C, [string]$Json, [string]$Extra = '', [int]$GhExit = 0, [string]$Cwd = $C.Fx.Launch, [hashtable]$ExtraEnv = @{},
        [object[]]$ListRules = @((New-CoordRule '^pr list ' '[]')), [switch]$NoDeleteFlag)
    $rules = @((New-CoordRule '^pr view 7\b' $Json $GhExit)) + $ListRules
    $flag = if ($NoDeleteFlag) { '' } else { '-DeleteBranch ' }
    return (Invoke-CoordScript -Name 'merge-verify.ps1' -Cwd $Cwd -ScriptArgs ("-Pr 7 $flag$Extra").Trim() -Rules $rules -ExtraEnv $ExtraEnv -ScriptPath $ScriptPath)
}

function Get-LaunchHead($C) { return (Get-CoordGitOut $C.Fx.Launch @('rev-parse', 'HEAD')) }
function Test-RemoteBranch($C, [string]$B = $C.Branch) { return [bool](Get-CoordRemoteRef $C.Fx "refs/heads/$B") }

function Assert-Verify {
    param([string]$Case, $R, [string]$Verdict, [int]$Code, [string[]]$Mentions = @())
    $detail = "exit=$($R.Code)`nout: $($R.Out)`nerr: $($R.Err)"
    $m = [regex]::Match($R.Last, $verdictRx)
    Assert-Coord "$Case last line is one verdict line" $m.Success $detail
    Assert-Coord "$Case verdict $Verdict" ($m.Success -and $m.Groups[2].Value -ceq $Verdict) $detail
    Assert-Coord "$Case exits $Code" ($R.Code -eq $Code) $detail
    foreach ($s in $Mentions) { Assert-Coord "$Case verdict mentions '$s'" ($R.Last.Contains($s)) $detail }
}

function Assert-CouldNotCheck {
    param([string]$Case, $R, [string]$Mention = '')
    $detail = "exit=$($R.Code)`nout: $($R.Out)`nerr: $($R.Err)"
    Assert-Coord "$Case exits 2" ($R.Code -eq 2) $detail
    Assert-Coord "$Case last line is a COULD NOT CHECK verdict" ($R.Last -match '^MERGE-VERIFY #7: COULD NOT CHECK - \S') $detail
    Assert-Coord "$Case never says OK" (-not ($R.Out -match ': OK - ')) $detail
    if ($Mention) { Assert-Coord "$Case mentions '$Mention'" ($R.Out.Contains($Mention)) $detail }
}

function Assert-Untouched {
    param([string]$Case, $C)
    Assert-Coord "$Case leaves the remote branch" (Test-RemoteBranch $C)
    Assert-Coord "$Case leaves the launch HEAD" ((Get-LaunchHead $C) -ceq $C.Before)
}

Write-Host "(V1) happy path"
$c = New-MergedCase 'v1'
$r = Invoke-Verify $c (Get-MergedJson $c)
Assert-Verify 'V1' $r 'OK' 0 @("merge $($c.Merge.Substring(0, 12)) on origin/main", 'branch deleted', "checkout ff $($c.Before.Substring(0, 12))..$($c.Merge.Substring(0, 12))", 'config ok')
Assert-Coord 'V1 the remote branch is gone' (-not (Test-RemoteBranch $c))
Assert-Coord 'V1 the launch checkout is at the merge commit' ((Get-LaunchHead $c) -ceq $c.Merge)
$r = Invoke-Verify $c (Get-MergedJson $c)
Assert-Verify 'V1-rerun' $r 'OK' 0 @('already gone', 'checkout current')

Write-Host "(V2) not merged"
$c = New-MergedCase 'v2'
$r = Invoke-Verify $c (Get-MergedJson $c -State 'OPEN' -MergeCommit '')
Assert-Verify 'V2' $r 'NOT MERGED' 1 @('OPEN')
Assert-Untouched 'V2' $c

Write-Host "(V3) merge commit not on origin"
$c = New-MergedCase 'v3'
$r = Invoke-Verify $c (Get-MergedJson $c -MergeCommit ('c' * 40))
Assert-Verify 'V3' $r 'PROBLEM' 1 @('not on origin/main')
Assert-Untouched 'V3' $c

Write-Host "(V4) tip moved after the merge"
$c = New-MergedCase 'v4'
$moved = New-CoordBranch $c.Fx 'feat' -From $c.Head -Write @{ 'docs/late.md' = "late`n" }
$r = Invoke-Verify $c (Get-MergedJson $c)
Assert-Verify 'V4' $r 'OK' 0 @('kept', 'tip moved')
Assert-Coord 'V4 the remote branch still holds the new commit' ((Get-CoordRemoteRef $c.Fx 'refs/heads/feat') -ceq $moved)

Write-Host "(V5) already gone"
$c = New-MergedCase 'v5'
Invoke-HookTestGit $c.Fx.Work @('push', '--quiet', 'origin', '--delete', 'feat')
$r = Invoke-Verify $c (Get-MergedJson $c)
Assert-Verify 'V5' $r 'OK' 0 @('already gone')

Write-Host "(V6, V7) launch checkout state"
$c = New-MergedCase 'v6'
Set-CoordFile $c.Fx.Launch 'README.md' "edited`n"
$r = Invoke-Verify $c (Get-MergedJson $c)
Assert-Verify 'V6' $r 'OK' 0 @('skipped', 'tracked change')
Assert-Coord 'V6 HEAD unchanged' ((Get-LaunchHead $c) -ceq $c.Before)
Assert-Coord 'V6 the edited file is untouched' ([System.IO.File]::ReadAllText((Join-Path $c.Fx.Launch 'README.md')) -ceq "edited`n")
$c = New-MergedCase 'v7'
Set-CoordFile $c.Fx.Launch 'scratch/untracked.txt' "u`n"
$r = Invoke-Verify $c (Get-MergedJson $c)
Assert-Verify 'V7' $r 'OK' 0 @('checkout ff')
Assert-Coord 'V7 fast-forwarded' ((Get-LaunchHead $c) -ceq $c.Merge)
Assert-Coord 'V7 the untracked file survives' (Test-Path (Join-Path $c.Fx.Launch 'scratch/untracked.txt'))

Write-Host "(V8) other branch, linked worktree"
$c = New-MergedCase 'v8a'
Invoke-HookTestGit $c.Fx.Launch @('checkout', '--quiet', '-b', 'side')
$r = Invoke-Verify $c (Get-MergedJson $c)
Assert-Verify 'V8a' $r 'OK' 0 @('skipped', 'not on main')
Assert-Coord 'V8a HEAD unchanged' ((Get-LaunchHead $c) -ceq $c.Before)
$c = New-MergedCase 'v8b'
$wt = Join-Path $c.Fx.Base 'wt'
New-HookTestWorktree -Repo $c.Fx.Launch -Path $wt -Branch 'v8b-wt'
$r = Invoke-Verify $c (Get-MergedJson $c) -Extra "-Repo `"$wt`""
Assert-Verify 'V8b' $r 'OK' 0 @('skipped', 'linked worktree')
Assert-Coord 'V8b the main checkout HEAD unchanged' ((Get-LaunchHead $c) -ceq $c.Before)

Write-Host "(V9) diverged"
$c = New-MergedCase 'v9'
Set-CoordFile $c.Fx.Launch 'local.txt' "l`n"
Invoke-HookTestGit $c.Fx.Launch @('-c', 'core.autocrlf=false', 'add', '-A')
Invoke-HookTestGit $c.Fx.Launch @('-c', 'core.autocrlf=false', 'commit', '--quiet', '-m', 'local')
$localHead = Get-LaunchHead $c
$r = Invoke-Verify $c (Get-MergedJson $c)
Assert-Verify 'V9' $r 'OK' 0 @('skipped', 'diverged')
Assert-Coord 'V9 HEAD unchanged' ((Get-LaunchHead $c) -ceq $localHead)

Write-Host "(V10) opt-outs"
$c = New-MergedCase 'v10'
$r = Invoke-Verify $c (Get-MergedJson $c) -Extra '-NoFastForward' -NoDeleteFlag
Assert-Verify 'V10' $r 'OK' 0 @('-DeleteBranch not given', '-NoFastForward')
Assert-Untouched 'V10' $c

Write-Host "(V11) git-config sanity"
$c = New-MergedCase 'v11a'
Invoke-HookTestGit $c.Fx.Launch @('config', 'core.autocrlf', 'true')
$r = Invoke-Verify $c (Get-MergedJson $c)
Assert-Verify 'V11-autocrlf' $r 'PROBLEM' 1 @('WARN', 'core.autocrlf')
$c = New-MergedCase 'v11b'
Invoke-HookTestGit $c.Fx.Launch @('config', 'diff.hide.textconv', 'cat')
$r = Invoke-Verify $c (Get-MergedJson $c)
Assert-Verify 'V11-diff' $r 'PROBLEM' 1 @('WARN', 'diff.hide.textconv')
$c = New-MergedCase 'v11c'
Invoke-HookTestGit $c.Fx.Launch @('config', 'core.bare', 'true')
$r = Invoke-Verify $c (Get-MergedJson $c)
Assert-Coord 'V11-bare exits 1 or 2, never 0' ($r.Code -eq 1 -or $r.Code -eq 2) "exit=$($r.Code) $($r.Out)"
Assert-Coord 'V11-bare names core.bare' ($r.Out.Contains('core.bare')) $r.Out
$c = New-MergedCase 'v11d'
[void][IO.Directory]::CreateDirectory((Join-Path $c.Fx.Launch '.githooks'))
Invoke-HookTestGit $c.Fx.Launch @('config', 'core.hooksPath', (Join-Path $c.Fx.Launch '.githooks'))
$r = Invoke-Verify $c (Get-MergedJson $c)
Assert-Verify 'V11-hooksPath-absolute-main' $r 'OK' 0 @('config ok')
Invoke-HookTestGit $c.Fx.Launch @('config', 'core.hooksPath', '.githooks')
$r = Invoke-Verify $c (Get-MergedJson $c)
Assert-Verify 'V11-hooksPath-relative' $r 'OK' 0 @('config ok')
Invoke-HookTestGit $c.Fx.Launch @('config', 'core.hooksPath', (Join-Path $c.Fx.Base 'elsewhere-hooks'))
$r = Invoke-Verify $c (Get-MergedJson $c)
Assert-Verify 'V11-hooksPath-foreign' $r 'PROBLEM' 1 @('WARN', 'core.hooksPath')
$c = New-MergedCase 'v11e'
Invoke-HookTestGit $c.Fx.Launch @('config', '--unset', 'user.name')
$emptyGlobal = Join-Path $c.Fx.Base 'empty.gitconfig'
[System.IO.File]::WriteAllText($emptyGlobal, '', $coordUtf8)
$r = Invoke-Verify $c (Get-MergedJson $c) -ExtraEnv @{ GIT_CONFIG_GLOBAL = $emptyGlobal; GIT_CONFIG_NOSYSTEM = '1' }
Assert-Verify 'V11-no-user-name' $r 'PROBLEM' 1 @('WARN', 'user.name')

Write-Host "(V12) fork PR"
$c = New-MergedCase 'v12'
$r = Invoke-Verify $c (Get-MergedJson $c -Cross $true)
Assert-Verify 'V12' $r 'OK' 0 @('kept', 'fork')
Assert-Coord 'V12 the remote branch is untouched' (Test-RemoteBranch $c)

Write-Host "(V13) gh and fetch failures"
$c = New-MergedCase 'v13'
$r = Invoke-Verify $c '' -GhExit 1
Assert-CouldNotCheck 'V13-gh' $r 'gh'
Assert-Untouched 'V13-gh' $c
Invoke-HookTestGit $c.Fx.Launch @('remote', 'set-url', 'origin', (Join-Path $c.Fx.Base 'no-such-origin.git'))
$r = Invoke-Verify $c (Get-MergedJson $c)
Assert-CouldNotCheck 'V13-fetch' $r 'fetch'
Assert-Untouched 'V13-fetch' $c

Write-Host "(V14) protected branch names"
foreach ($name in 'main', 'master') {
    $c = New-MergedCase "v14-$name"
    $r = Invoke-Verify $c (Get-MergedJson $c -HeadRef $name)
    Assert-Verify "V14-$name" $r 'OK' 0 @('kept')
    Assert-Coord "V14-$name origin main still exists" (Test-RemoteBranch $c 'main')
}
$c = New-MergedCase 'v14-develop' -Branch 'develop'
Invoke-HookTestGit $c.Fx.Work @('push', '--quiet', '--force', 'origin', "$($c.Merge):refs/heads/develop")
$r = Invoke-Verify $c (Get-MergedJson $c -HeadRef 'develop' -Base 'develop' -Head $c.Merge)
Assert-Verify 'V14-base-develop' $r 'OK' 0 @('kept', 'base')
Assert-Coord 'V14-base-develop origin develop still exists' (Test-RemoteBranch $c 'develop')
# V14b: head `main` into base `develop`, tip == head: only the main/master
# guard stands between it and a delete (not the base guard, not tip-moved).
$c = New-MergedCase 'v14b'
Invoke-HookTestGit $c.Fx.Work @('push', '--quiet', '--force', 'origin', "$($c.Merge):refs/heads/develop")
# origin's default branch is develop here, so the default-branch guard does
# not shadow the main/master guard.
Invoke-HookTestGit $c.Fx.Origin @('symbolic-ref', 'HEAD', 'refs/heads/develop')
$r = Invoke-Verify $c (Get-MergedJson $c -HeadRef 'main' -Base 'develop' -Head $c.Merge)
Assert-Verify 'V14b-main-into-develop' $r 'OK' 0 @("kept: 'main' is a protected name")
Assert-Coord 'V14b origin main still exists' (Test-RemoteBranch $c 'main')

Write-Host "(V18, V19, V21) open PRs on the branch, origin's default branch, gh failing there"
$c = New-MergedCase 'v18'
$r = Invoke-Verify $c (Get-MergedJson $c) -ListRules @((New-CoordRule '^pr list .*--base feat\b' '[{"number":44}]'), (New-CoordRule '^pr list ' '[]'))
Assert-Verify 'V18-stacked-pr' $r 'OK' 0 @('kept: open PR(s) #44')
Assert-Coord 'V18 the branch is still there' (Test-RemoteBranch $c)
$c = New-MergedCase 'v18b'
$r = Invoke-Verify $c (Get-MergedJson $c) -ListRules @((New-CoordRule '^pr list .*--head feat\b' '[{"number":45}]'), (New-CoordRule '^pr list ' '[]'))
Assert-Verify 'V18b-reopened-pr-on-head' $r 'OK' 0 @('kept: open PR(s) #45')
Assert-Coord 'V18b the branch is still there' (Test-RemoteBranch $c)
# V19: origin's own HEAD names trunk (read with ls-remote --symref; no local
# origin/HEAD is set in this fixture).
$c = New-MergedCase 'v19' -Branch 'trunk'
Invoke-HookTestGit $c.Fx.Origin @('symbolic-ref', 'HEAD', 'refs/heads/trunk')
$r = Invoke-Verify $c (Get-MergedJson $c)
Assert-Verify 'V19-default-branch' $r 'OK' 0 @("kept: 'trunk' is origin's default branch")
Assert-Coord 'V19 trunk is still there' (Test-RemoteBranch $c)
# V19b: origin's HEAD names a branch that does not exist (unborn), so
# `ls-remote --symref` exits 0 with no `ref:` line: the default branch is
# unknown, and feat is not deleted.
$c = New-MergedCase 'v19b'
Invoke-HookTestGit $c.Fx.Origin @('symbolic-ref', 'HEAD', 'refs/heads/nosuch')
$r = Invoke-Verify $c (Get-MergedJson $c)
Assert-Verify 'V19b-default-branch-unborn' $r 'PROBLEM' 1 @("unknown: origin's default branch could not be read (git ls-remote --symref named no branch)")
Assert-Coord 'V19b feat is still there' (Test-RemoteBranch $c)
$c = New-MergedCase 'v21'
$r = Invoke-Verify $c (Get-MergedJson $c) -ListRules @((New-CoordRule '^pr list ' '' 1))
Assert-Verify 'V21-open-pr-check-fails' $r 'PROBLEM' 1 @('unknown: could not list open PRs')
Assert-Coord 'V21 the branch is still there' (Test-RemoteBranch $c)

Write-Host "(V20) a local branch named origin/main does not shadow the remote ref"
$c = New-MergedCase 'v20'
Invoke-HookTestGit $c.Fx.Launch @('fetch', '--quiet', 'origin')
# An unpushed commit on top of the merge commit, built without a checkout (a
# checkout of `origin/main` would print git's ambiguity warning).
$unpushed = Get-CoordGitOut $c.Fx.Launch @('commit-tree', "$($c.Merge)^{tree}", '-p', $c.Merge, '-m', 'unpushed')
Invoke-HookTestGit $c.Fx.Launch @('branch', 'origin/main', $unpushed)
$r = Invoke-Verify $c (Get-MergedJson $c)
Assert-Verify 'V20' $r 'OK' 0 @('checkout ff')
Assert-Coord 'V20 main moved to the real merge commit, not the unpushed one' ((Get-LaunchHead $c) -ceq $c.Merge) "head=$(Get-LaunchHead $c) unpushed=$unpushed"

Write-Host "(V15) sibling x/feat"
$c = New-MergedCase 'v15'
$sib = New-CoordBranch $c.Fx 'x/feat' -Write @{ 'docs/sib.md' = "s`n" }
$r = Invoke-Verify $c (Get-MergedJson $c)
Assert-Verify 'V15' $r 'OK' 0 @('branch deleted')
Assert-Coord 'V15 feat is gone' (-not (Test-RemoteBranch $c))
Assert-Coord 'V15 x/feat is untouched' ((Get-CoordRemoteRef $c.Fx 'refs/heads/x/feat') -ceq $sib)
$c = New-MergedCase 'v15b'
Invoke-HookTestGit $c.Fx.Work @('push', '--quiet', 'origin', '--delete', 'feat')
$sib = New-CoordBranch $c.Fx 'x/feat' -From $c.Head
$r = Invoke-Verify $c (Get-MergedJson $c)
Assert-Verify 'V15b' $r 'OK' 0 @('already gone')
Assert-Coord 'V15b x/feat is untouched' ((Get-CoordRemoteRef $c.Fx 'refs/heads/x/feat') -ceq $sib)

Write-Host "(V16) a delete that fails"
$c = New-MergedCase 'v16a'
$hooks = Join-Path $c.Fx.Origin 'hooks'
[System.IO.File]::WriteAllText((Join-Path $hooks 'pre-receive'), "#!/bin/sh`necho 'rejected by test hook' >&2`nexit 1`n", $coordUtf8)
Invoke-HookTestGit $c.Fx.Origin @('config', 'core.hooksPath', $hooks)
$r = Invoke-Verify $c (Get-MergedJson $c)
Assert-Verify 'V16a' $r 'PROBLEM' 1 @('branch')
Assert-Coord 'V16a never claims deleted' (-not $r.Last.Contains('branch deleted')) $r.Last
Assert-Coord 'V16a the remote branch is still there' (Test-RemoteBranch $c)
# V16b, the lease: a receive-pack wrapper moves feat on origin right before the
# push negotiates (after the script read the tip), the way a racing push
# would. The lease on the merged head must refuse the delete.
$c = New-MergedCase 'v16b'
$late = New-CoordBranch $c.Fx 'feat' -From $c.Head -Write @{ 'docs/late.md' = "late`n" } -NoPush
Invoke-HookTestGit $c.Fx.Work @('push', '--quiet', 'origin', "${late}:refs/heads/feat-late-carrier")
$wrapper = "sh -c 'git --git-dir=`"`$1`" update-ref refs/heads/feat $late && exec git receive-pack `"`$1`"' x"
Invoke-HookTestGit $c.Fx.Launch @('config', 'remote.origin.receivepack', $wrapper)
$r = Invoke-Verify $c (Get-MergedJson $c)
Assert-Verify 'V16b-lease' $r 'PROBLEM' 1 @('delete failed')
Assert-Coord 'V16b never claims deleted' (-not $r.Last.Contains('branch deleted')) $r.Last
Assert-Coord 'V16b the moved branch survives on origin (lease held)' ((Get-CoordRemoteRef $c.Fx 'refs/heads/feat') -ceq $late) "tip=$(Get-CoordRemoteRef $c.Fx 'refs/heads/feat')"

# V22: the push goes (pushInsteadOf) to a second bare repo: push URL differs
# from the fetch URL, so no delete is tried anywhere.
$c = New-MergedCase 'v22'
$other = Join-Path $c.Fx.Base 'push-target.git'
Invoke-HookTestGit $c.Fx.Base @('clone', '--quiet', '--bare', $c.Fx.Origin, $other)
Invoke-HookTestGit $c.Fx.Launch @('config', "url.$other.pushInsteadOf", $c.Fx.Origin)
$r = Invoke-Verify $c (Get-MergedJson $c)
Assert-Verify 'V22-push-url-differs' $r 'PROBLEM' 1 @('not exactly its fetch URL')
Assert-Coord 'V22 the branch in the push target survives' ([bool](@(& git -C $other for-each-ref --format='%(objectname)' refs/heads/feat 2>$null) -join '').Trim())
Assert-Coord 'V22 the branch on origin survives' (Test-RemoteBranch $c)

# V23: two push URLs, the first equal to the fetch URL: no delete.
$c = New-MergedCase 'v23'
$mirror = Join-Path $c.Fx.Base 'mirror.git'
Invoke-HookTestGit $c.Fx.Base @('clone', '--quiet', '--bare', $c.Fx.Origin, $mirror)
Invoke-HookTestGit $c.Fx.Launch @('remote', 'set-url', '--add', '--push', 'origin', $c.Fx.Origin)
Invoke-HookTestGit $c.Fx.Launch @('remote', 'set-url', '--add', '--push', 'origin', $mirror)
$r = Invoke-Verify $c (Get-MergedJson $c)
Assert-Verify 'V23-two-push-urls' $r 'PROBLEM' 1 @('2 URL(s)')
Assert-Coord 'V23 the branch on origin survives' (Test-RemoteBranch $c)
Assert-Coord 'V23 the branch on the mirror survives' ([bool](@(& git -C $mirror for-each-ref --format='%(objectname)' refs/heads/feat 2>$null) -join '').Trim())

Write-Host "(V17) gh output validation"
$c = New-MergedCase 'v17'
$r = Invoke-Verify $c '{"state":'
Assert-CouldNotCheck 'V17-malformed' $r 'invalid JSON'
Assert-Untouched 'V17-malformed' $c
$r = Invoke-Verify $c (Get-MergedJson $c -MergeCommit '')
Assert-CouldNotCheck 'V17-no-merge-commit' $r 'mergeCommit'
Assert-Untouched 'V17-no-merge-commit' $c
$r = Invoke-Verify $c (Get-MergedJson $c -Head 'not-a-sha')
Assert-CouldNotCheck 'V17-bad-head' $r 'headRefOid'
Assert-Untouched 'V17-bad-head' $c
$noFork = (Get-MergedJson $c) -replace ',"isCrossRepository":(true|false)', ''
$r = Invoke-Verify $c $noFork
Assert-CouldNotCheck 'V17-no-isCrossRepository' $r 'isCrossRepository'
Assert-Untouched 'V17-no-isCrossRepository' $c
$strFork = (Get-MergedJson $c) -replace '"isCrossRepository":false', '"isCrossRepository":"false"'
$r = Invoke-Verify $c $strFork
Assert-CouldNotCheck 'V17-string-isCrossRepository' $r 'isCrossRepository'
Assert-Untouched 'V17-string-isCrossRepository' $c

# ---- D1-D6: the delete is opt-in (D5 of the port plan) ----
Write-Host "(D1-D6) -DeleteBranch is the only way to a delete"
# A pre-receive hook on origin that logs every push that reaches it: the proof
# that no push left the script, not only that the branch is still there.
function Add-PushLog($C) {
    $hooks = Join-Path $C.Fx.Origin 'hooks'
    $log = Join-Path $C.Fx.Base 'pushes.log'
    $unixLog = $log.Replace('\', '/')
    [System.IO.File]::WriteAllText((Join-Path $hooks 'pre-receive'), "#!/bin/sh`ncat >> '$unixLog'`nexit 0`n", $coordUtf8)
    Invoke-HookTestGit $C.Fx.Origin @('config', 'core.hooksPath', $hooks)
    return $log
}
$c = New-MergedCase 'd1'
$pushLog = Add-PushLog $c
$r = Invoke-Verify $c (Get-MergedJson $c) -NoDeleteFlag
Assert-Verify 'D1' $r 'OK' 0 @('kept: -DeleteBranch not given; would run: git push', "--force-with-lease=refs/heads/feat:$($c.Head)", ':refs/heads/feat')
Assert-Coord 'D1 never says deleted' (-not $r.Last.Contains('branch deleted')) $r.Last
Assert-Coord 'D1 the remote branch is still there' (Test-RemoteBranch $c)
Assert-Coord 'D1 no push reached origin' (-not (Test-Path -LiteralPath $pushLog)) "log: $pushLog"
# D2: the same case with the flag deletes, through the lease the printed command names.
$r = Invoke-Verify $c (Get-MergedJson $c)
Assert-Verify 'D2' $r 'OK' 0 @('branch deleted')
Assert-Coord 'D2 the remote branch is gone' (-not (Test-RemoteBranch $c))
$pushedRefs = if (Test-Path -LiteralPath $pushLog) { @(Get-Content -LiteralPath $pushLog | Where-Object { $_.Trim() }) } else { @() }
Assert-Coord 'D2 the push log holds exactly one ref update' ($pushedRefs.Count -eq 1) "log: $($pushedRefs -join ' || ')"

# D3: without the flag each guard keeps its own reason.
$c = New-MergedCase 'd3a'
$moved = New-CoordBranch $c.Fx 'feat' -From $c.Head -Write @{ 'docs/late.md' = "late`n" }
$r = Invoke-Verify $c (Get-MergedJson $c) -NoDeleteFlag
Assert-Verify 'D3-tip-moved' $r 'OK' 0 @('kept: tip moved')
Assert-Coord 'D3-tip-moved never offers a delete command' (-not $r.Out.Contains('would run')) $r.Out
Assert-Coord 'D3-tip-moved the moved branch survives' ((Get-CoordRemoteRef $c.Fx 'refs/heads/feat') -ceq $moved)
$c = New-MergedCase 'd3b'
$r = Invoke-Verify $c (Get-MergedJson $c) -NoDeleteFlag -ListRules @((New-CoordRule '^pr list .*--base feat\b' '[{"number":44}]'), (New-CoordRule '^pr list ' '[]'))
Assert-Verify 'D3-stacked-pr' $r 'OK' 0 @('kept: open PR(s) #44')
Assert-Coord 'D3-stacked-pr never offers a delete command' (-not $r.Out.Contains('would run')) $r.Out
Assert-Coord 'D3-stacked-pr the branch survives' (Test-RemoteBranch $c)
$c = New-MergedCase 'd3c' -Branch 'trunk'
Invoke-HookTestGit $c.Fx.Origin @('symbolic-ref', 'HEAD', 'refs/heads/trunk')
$r = Invoke-Verify $c (Get-MergedJson $c) -NoDeleteFlag
Assert-Verify 'D3-default-branch' $r 'OK' 0 @("kept: 'trunk' is origin's default branch")
Assert-Coord 'D3-default-branch never offers a delete command' (-not $r.Out.Contains('would run')) $r.Out
Assert-Coord 'D3-default-branch the branch survives' (Test-RemoteBranch $c)
$c = New-MergedCase 'd3d'
$r = Invoke-Verify $c (Get-MergedJson $c -Cross $true) -NoDeleteFlag
Assert-Verify 'D3-fork' $r 'OK' 0 @('kept: fork PR')
Assert-Coord 'D3-fork the branch survives' (Test-RemoteBranch $c)
$c = New-MergedCase 'd3e'
Invoke-HookTestGit $c.Fx.Work @('push', '--quiet', 'origin', '--delete', 'feat')
$r = Invoke-Verify $c (Get-MergedJson $c) -NoDeleteFlag
Assert-Verify 'D3-already-gone' $r 'OK' 0 @('already gone')

# D4: the tip moved and the flag is given: the new work survives on origin.
$c = New-MergedCase 'd4'
$moved = New-CoordBranch $c.Fx 'feat' -From $c.Head -Write @{ 'docs/late.md' = "late`n" }
$r = Invoke-Verify $c (Get-MergedJson $c)
Assert-Verify 'D4' $r 'OK' 0 @('kept: tip moved')
Assert-Coord 'D4 the moved branch survives' ((Get-CoordRemoteRef $c.Fx 'refs/heads/feat') -ceq $moved)

# D5: the flag does not widen what is deletable.
$c = New-MergedCase 'd5a'
$r = Invoke-Verify $c (Get-MergedJson $c -HeadRef 'main')
Assert-Verify 'D5-main' $r 'OK' 0 @('kept')
Assert-Coord 'D5-main origin main still exists' (Test-RemoteBranch $c 'main')
$c = New-MergedCase 'd5b'
$r = Invoke-Verify $c (Get-MergedJson $c -Cross $true)
Assert-Verify 'D5-fork' $r 'OK' 0 @('kept: fork PR')
Assert-Coord 'D5-fork the branch survives' (Test-RemoteBranch $c)
$c = New-MergedCase 'd5c'
$other = Join-Path $c.Fx.Base 'push-target.git'
Invoke-HookTestGit $c.Fx.Base @('clone', '--quiet', '--bare', $c.Fx.Origin, $other)
Invoke-HookTestGit $c.Fx.Launch @('config', "url.$other.pushInsteadOf", $c.Fx.Origin)
$r = Invoke-Verify $c (Get-MergedJson $c)
Assert-Verify 'D5-push-url' $r 'PROBLEM' 1 @('not exactly its fetch URL')
Assert-Coord 'D5-push-url the branch on origin survives' (Test-RemoteBranch $c)

# D6: a text lint, not proof (D1 and the mutants are the proof): the script
# holds the single-quoted token 'push' on one non-comment line, runs the delete arguments from one
# call, and that call is the else of the -not $DeleteBranch test of the
# branch chain (no other branch of the chain sits between them). It reads the
# script under test, mutant copies included, and it is layout-sensitive.
$scriptUnderTest = if ($ScriptPath) { $ScriptPath } else { Join-Path $coordScriptsDir 'merge-verify.ps1' }
$src = [System.IO.File]::ReadAllText($scriptUnderTest)
$code = (($src -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
$pushNames = [regex]::Matches($code, "(?m)^.*'push'.*$")
Assert-Coord "D6 one non-comment line holds the token 'push'" ($pushNames.Count -eq 1) "found $($pushNames.Count)"
$pushCalls = [regex]::Matches($code, '(?m)^.*Invoke-CoordGit[^\r\n]*\$deleteArgs.*$')
Assert-Coord 'D6 exactly one call runs the delete arguments' ($pushCalls.Count -eq 1) "found $($pushCalls.Count)"
$gateAt = $code.IndexOf('elseif (-not $DeleteBranch) {')
$runAt = $code.IndexOf('$del = Invoke-CoordGit $repoRoot $deleteArgs')
$between = if ($gateAt -ge 0 -and $runAt -gt $gateAt) { $code.Substring($gateAt + 1, $runAt - $gateAt - 1) } else { '' }
Assert-Coord 'D6 the call follows the -not $DeleteBranch test' ($gateAt -ge 0 -and $runAt -gt $gateAt)
Assert-Coord 'D6 it is the else of that test, with no other elseif of the chain in between' ($between.Contains("`n        else {") -and -not $between.Contains("`n        elseif")) $between

# D7: a branch name a shell would act on (git allows ; & $ ( ) in ref names):
# without the flag no paste-ready command is printed; with it, it is deleted.
$c = New-MergedCase 'd7' -Branch 'feat;calc'
$r = Invoke-Verify $c (Get-MergedJson $c) -NoDeleteFlag
Assert-Verify 'D7-no-flag' $r 'OK' 0 @('kept: -DeleteBranch not given', 'no command is printed')
Assert-Coord 'D7-no-flag prints no command' (-not $r.Out.Contains('would run') -and -not $r.Out.Contains('push --quiet')) $r.Out
Assert-Coord 'D7-no-flag the branch survives' (Test-RemoteBranch $c 'feat;calc')
$r = Invoke-Verify $c (Get-MergedJson $c)
Assert-Verify 'D7-flag' $r 'OK' 0 @('branch deleted')
Assert-Coord 'D7-flag the branch is gone' (-not (Test-RemoteBranch $c 'feat;calc'))

# ---- NOTIFY lines after an OK verdict ----
# Every case passes its own scratch ledger with -Ledger (never the live one).
Write-Host "(N1-N13) NOTIFY lines"
$inv = [System.Globalization.CultureInfo]::InvariantCulture
$mergedAtUtc = [DateTime]::UtcNow.AddHours(-5).AddMinutes(-17).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $inv)
$mergedAtLocal = [DateTimeOffset]::Parse($mergedAtUtc, $inv).ToLocalTime().ToString('HH:mm', $inv)

function Get-NotifyJson {
    param($C, [string]$MergedAt = $mergedAtUtc, [string]$Base = 'main', [string]$State = 'MERGED', [string]$MergeCommit = $C.Merge)
    $j = Get-MergedJson $C -Base $Base -State $State -MergeCommit $MergeCommit
    if ($MergedAt) { $j = $j.Substring(0, $j.Length - 1) + ',"mergedAt":"' + $MergedAt + '"}' }
    return $j
}
function New-NotifyRow([string]$Track, [string]$Repo, [string]$Session, [string]$Branch, [string]$Status) {
    return "| $Track | $Repo | $Session | Opus 5.5 high | C:\x | $Branch | docs/** | | $Status |"
}
function New-NotifyLedger {
    param($C, [string]$Name, [string[]]$Rows,
        [string]$Header = '| Track | Repo | Session | Model | Cwd | Branch | Scope | PR | Status |')
    $p = Join-Path $C.Fx.Base "ledger-$Name.md"
    $sep = '|' + (('---|') * ($Header.Split('|').Count - 2))
    $text = "# Coordination ledger - fixture`n`n## Tracks`n`n$Header`n$sep`n" + ($Rows -join "`n") + "`n`n## Merge slots`n`n1. (none)`n"
    [System.IO.File]::WriteAllText($p, $text, $coordUtf8)
    return $p
}
function Invoke-Notify {
    param($C, [string]$Json, [string]$Ledger, [string]$Extra = '', [switch]$NoDeleteFlag)
    $a = "-Ledger `"$Ledger`" $Extra".Trim()
    return (Invoke-Verify $C $Json -Extra $a -NoDeleteFlag:$NoDeleteFlag)
}
function Get-NotifyLines($R) { return , @(([string]$R.Out -split "`r?`n") | Where-Object { $_ -like 'NOTIFY*' }) }
function Get-ExpectedNotify($C, [string]$Track, [string]$Session, [string]$MergeSha, [string]$Tip, [string]$Base = 'main') {
    $leaf = Split-Path -Leaf $C.Fx.Launch
    return "NOTIFY $Track ($Session): #7 merged $mergedAtLocal as $($MergeSha.Substring(0, 12)); $leaf $Base is now $($Tip.Substring(0, 12)); fetch + merge origin/$Base before your next push"
}
function Assert-NoNotify([string]$Case, $R) {
    Assert-Coord "$Case prints no NOTIFY text" (-not ([string]$R.Out).Contains('NOTIFY')) $R.Out
}
function Assert-NoneLine([string]$Case, $R) {
    $n = Get-NotifyLines $R
    Assert-Coord "$Case prints exactly one NOTIFY line" ($n.Count -eq 1) $R.Out
    Assert-Coord "$Case that line is 'NOTIFY: none printed - <reason>'" ($n.Count -eq 1 -and $n[0] -match '^NOTIFY: none printed - \S') $R.Out
}


# N1: two other live rows (one "NOT MERGED", one led by a later "DONE" word) get a line; the merged track's own
# row, DONE and MERGED rows, another repo's row and a bare-folder-name Repo cell do not.
$c = New-MergedCase 'n1'
$launchUpper = $c.Fx.Launch.ToUpper() + '\'
$rows = @(
    (New-NotifyRow 'self' $c.Fx.Launch 'local_self' 'feat' 'running'),
    (New-NotifyRow 'rc-a' $c.Fx.Launch 'local_aaa' 'a-branch' 'running; round 1 DONE'),
    (New-NotifyRow 'rc-b' $launchUpper 'local_bbb' 'b-branch' 'NOT MERGED: conflicts'),
    (New-NotifyRow 'rc-c' $c.Fx.Launch 'local_ccc' 'c-branch' 'DONE; report placed'),
    (New-NotifyRow 'rc-d' $c.Fx.Launch 'local_ddd' 'd-branch' 'MERGED abc1234 13:05'),
    (New-NotifyRow 'rc-e' 'C:\Elsewhere\other-repo' 'local_eee' 'e-branch' 'running'),
    (New-NotifyRow 'rc-f' 'launch' 'local_fff' 'f-branch' 'running'))
$led = New-NotifyLedger $c 'n1' $rows
$r = Invoke-Notify $c (Get-NotifyJson $c) $led
Assert-Verify 'N1' $r 'OK' 0
$n = Get-NotifyLines $r
Assert-Coord 'N1 two NOTIFY lines' ($n.Count -eq 2) $r.Out
Assert-Coord 'N1 rc-a line (merge sha and new base sha, fixture time)' ($n.Count -ge 1 -and $n[0] -ceq (Get-ExpectedNotify $c 'rc-a' 'local_aaa' $c.Merge $c.Merge)) "got: $($n -join ' || ')`nwant: $(Get-ExpectedNotify $c 'rc-a' 'local_aaa' $c.Merge $c.Merge)"
Assert-Coord 'N1 rc-b line (NOT MERGED row is live; Repo cell compared case-insensitively)' ($n.Count -ge 2 -and $n[1] -ceq (Get-ExpectedNotify $c 'rc-b' 'local_bbb' $c.Merge $c.Merge)) "got: $($n -join ' || ')"
$lines = @(([string]$r.Out) -split "`r?`n" | Where-Object { $_.Trim() })
$verdictAt = [array]::LastIndexOf($lines, $r.Last)
$lastNotifyAt = -1; for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -like 'NOTIFY*') { $lastNotifyAt = $i } }
Assert-Coord 'N1 NOTIFY lines come before the verdict line' ($lastNotifyAt -ge 0 -and $lastNotifyAt -lt $verdictAt) $r.Out
Assert-Coord 'N1 gh was asked for mergedAt' (@($r.Calls | Where-Object { $_ -match '^ARGS=pr view ' -and $_ -match 'mergedAt' }).Count -ge 1) ($r.Calls -join "`n")
$r2 = Invoke-Notify $c (Get-NotifyJson $c) $led
Assert-Verify 'N1-rerun' $r2 'OK' 0 @('already gone')
Assert-Coord 'N1-rerun reprints the same NOTIFY lines' ((((Get-NotifyLines $r2) -join "`n")) -ceq ($n -join "`n")) ((Get-NotifyLines $r2) -join ' || ')

# N2: only finished rows besides the merged track's own: nothing printed.
$c = New-MergedCase 'n2'
$led = New-NotifyLedger $c 'n2' @(
    (New-NotifyRow 'self' $c.Fx.Launch 'local_self' 'feat' 'running'),
    (New-NotifyRow 'rc-c' $c.Fx.Launch 'local_ccc' 'c-branch' 'DONE'),
    (New-NotifyRow 'rc-d' $c.Fx.Launch 'local_ddd' 'd-branch' 'MERGED abc1234'))
$r = Invoke-Notify $c (Get-NotifyJson $c) $led
Assert-Verify 'N2' $r 'OK' 0
Assert-NoNotify 'N2' $r

# N3: a verdict that is not OK prints no NOTIFY line, whatever the ledger holds.
$c = New-MergedCase 'n3a'
$led = New-NotifyLedger $c 'n3a' @((New-NotifyRow 'rc-a' $c.Fx.Launch 'local_aaa' 'a-branch' 'running'))
$r = Invoke-Notify $c (Get-NotifyJson $c -MergeCommit ('c' * 40)) $led
Assert-Verify 'N3-problem' $r 'PROBLEM' 1
Assert-NoNotify 'N3-problem' $r
$c = New-MergedCase 'n3b'
$led = New-NotifyLedger $c 'n3b' @((New-NotifyRow 'rc-a' $c.Fx.Launch 'local_aaa' 'a-branch' 'running'))
$r = Invoke-Notify $c (Get-NotifyJson $c -State 'OPEN' -MergeCommit '') $led
Assert-Verify 'N3-not-merged' $r 'NOT MERGED' 1
Assert-NoNotify 'N3-not-merged' $r
$c = New-MergedCase 'n3c'
Invoke-HookTestGit $c.Fx.Launch @('config', 'core.autocrlf', 'true')
$led = New-NotifyLedger $c 'n3c' @((New-NotifyRow 'rc-a' $c.Fx.Launch 'local_aaa' 'a-branch' 'running'))
$r = Invoke-Notify $c (Get-NotifyJson $c) $led
Assert-Verify 'N3-config-warn' $r 'PROBLEM' 1 @('WARN')
Assert-NoNotify 'N3-config-warn' $r

# N4: no ledger (the default location in the fixture does not exist; an explicit -Ledger names no file): nothing
# printed and the whole output is byte-identical to the run that never heard of -Ledger.
$c = New-MergedCase 'n4'
$flags = '-NoFastForward'
$base4 = Invoke-Verify $c (Get-NotifyJson $c) -Extra $flags -NoDeleteFlag
Assert-Verify 'N4-default' $base4 'OK' 0
Assert-NoNotify 'N4-default' $base4
$r = Invoke-Notify $c (Get-NotifyJson $c) (Join-Path $c.Fx.Base 'no-such-ledger.md') $flags -NoDeleteFlag
Assert-Verify 'N4-explicit-missing' $r 'OK' 0
Assert-Coord 'N4 output identical to the run without -Ledger' ([string]$r.Out -ceq [string]$base4.Out) "with: $($r.Out)`nwithout: $($base4.Out)"

# N5: origin/main advanced past the merge: the newer tip is printed, still with the merge sha.
$c = New-MergedCase 'n5'
$adv = New-CoordBranch $c.Fx 'advance' -Write @{ 'docs/adv.md' = "adv`n" }
Invoke-HookTestGit $c.Fx.Work @('push', '--quiet', 'origin', "${adv}:refs/heads/main")
$led = New-NotifyLedger $c 'n5' @((New-NotifyRow 'rc-a' $c.Fx.Launch 'local_aaa' 'a-branch' 'running'))
$r = Invoke-Notify $c (Get-NotifyJson $c) $led
Assert-Verify 'N5' $r 'OK' 0
$n = Get-NotifyLines $r
Assert-Coord 'N5 one line with the merge sha and the newer base tip' ($n.Count -eq 1 -and $n[0] -ceq (Get-ExpectedNotify $c 'rc-a' 'local_aaa' $c.Merge $adv)) "got: $($n -join ' || ')`nwant: $(Get-ExpectedNotify $c 'rc-a' 'local_aaa' $c.Merge $adv)"

# N6: a non-main base is named, from gh's baseRefName.
$c = New-MergedCase 'n6'
Invoke-HookTestGit $c.Fx.Work @('push', '--quiet', '--force', 'origin', "$($c.Merge):refs/heads/develop")
$led = New-NotifyLedger $c 'n6' @((New-NotifyRow 'rc-a' $c.Fx.Launch 'local_aaa' 'a-branch' 'running'))
$r = Invoke-Notify $c (Get-NotifyJson $c -Base 'develop') $led
Assert-Verify 'N6' $r 'OK' 0 @('on origin/develop')
$n = Get-NotifyLines $r
Assert-Coord 'N6 the line names develop' ($n.Count -eq 1 -and $n[0] -ceq (Get-ExpectedNotify $c 'rc-a' 'local_aaa' $c.Merge $c.Merge 'develop')) "got: $($n -join ' || ')"

# N7: a local branch AND a tag named origin/main, both elsewhere, do not change the printed tip.
$c = New-MergedCase 'n7'
Invoke-HookTestGit $c.Fx.Launch @('fetch', '--quiet', 'origin')
$unpushed = Get-CoordGitOut $c.Fx.Launch @('commit-tree', "$($c.Merge)^{tree}", '-p', $c.Merge, '-m', 'unpushed')
Invoke-HookTestGit $c.Fx.Launch @('branch', 'origin/main', $unpushed)
Invoke-HookTestGit $c.Fx.Launch @('tag', 'origin/main', $c.Before)
$led = New-NotifyLedger $c 'n7' @((New-NotifyRow 'rc-a' $c.Fx.Launch 'local_aaa' 'a-branch' 'running'))
$r = Invoke-Notify $c (Get-NotifyJson $c) $led
Assert-Verify 'N7' $r 'OK' 0
$n = Get-NotifyLines $r
Assert-Coord 'N7 the tip is the remote-tracking ref, not the branch or the tag' ($n.Count -eq 1 -and $n[0] -ceq (Get-ExpectedNotify $c 'rc-a' 'local_aaa' $c.Merge $c.Merge)) "got: $($n -join ' || ')`nunpushed=$unpushed tag=$($c.Before)"

# N8: a ledger that exists but cannot be read (held open exclusively; a folder in its place): one 'none printed'
# line, and the verdict line and exit code are what the run without a ledger gives.
$c = New-MergedCase 'n8'
$base8 = Invoke-Verify $c (Get-NotifyJson $c) -Extra $flags -NoDeleteFlag
$led = New-NotifyLedger $c 'n8' @((New-NotifyRow 'rc-a' $c.Fx.Launch 'local_aaa' 'a-branch' 'running'))
$fs = [System.IO.File]::Open($led, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
try { $r = Invoke-Notify $c (Get-NotifyJson $c) $led $flags -NoDeleteFlag } finally { $fs.Dispose() }
Assert-Verify 'N8-locked' $r 'OK' 0
Assert-NoneLine 'N8-locked' $r
Assert-Coord 'N8-locked verdict line unchanged' ($r.Last -ceq $base8.Last) "got: $($r.Last)`nwant: $($base8.Last)"
$dirLed = Join-Path $c.Fx.Base 'ledger-n8-dir.md'
[void][IO.Directory]::CreateDirectory($dirLed)
$r = Invoke-Notify $c (Get-NotifyJson $c) $dirLed $flags -NoDeleteFlag
Assert-Verify 'N8-folder' $r 'OK' 0
Assert-NoneLine 'N8-folder' $r
Assert-Coord 'N8-folder verdict line unchanged' ($r.Last -ceq $base8.Last) "got: $($r.Last)"

# N9: a malformed Tracks table (a row with an extra cell; no Scope column): the same one line, verdict unchanged.
$c = New-MergedCase 'n9'
$base9 = Invoke-Verify $c (Get-NotifyJson $c) -Extra $flags -NoDeleteFlag
$led = New-NotifyLedger $c 'n9a' @(((New-NotifyRow 'rc-a' $c.Fx.Launch 'local_aaa' 'a-branch' 'running') + ' extra |'))
$r = Invoke-Notify $c (Get-NotifyJson $c) $led $flags -NoDeleteFlag
Assert-Verify 'N9-extra-cell' $r 'OK' 0
Assert-NoneLine 'N9-extra-cell' $r
Assert-Coord 'N9-extra-cell verdict line unchanged' ($r.Last -ceq $base9.Last) "got: $($r.Last)"
$led = New-NotifyLedger $c 'n9b' @("| rc-a | $($c.Fx.Launch) | a-branch | running |") -Header '| Track | Repo | Branch | Status |'
$r = Invoke-Notify $c (Get-NotifyJson $c) $led $flags -NoDeleteFlag
Assert-Verify 'N9-no-scope-column' $r 'OK' 0
Assert-NoneLine 'N9-no-scope-column' $r
Assert-Coord 'N9-no-scope-column verdict line unchanged' ($r.Last -ceq $base9.Last) "got: $($r.Last)"

# N10: gh's mergedAt missing or not a time while a live row waits: the one 'none printed' line naming mergedAt;
# with no live row to tell, nothing is printed at all.
$c = New-MergedCase 'n10'
$led = New-NotifyLedger $c 'n10' @((New-NotifyRow 'rc-a' $c.Fx.Launch 'local_aaa' 'a-branch' 'running'))
$r = Invoke-Notify $c (Get-NotifyJson $c -MergedAt '') $led
Assert-Verify 'N10-missing' $r 'OK' 0
Assert-NoneLine 'N10-missing' $r
Assert-Coord 'N10-missing names mergedAt' ((Get-NotifyLines $r)[0] -match 'mergedAt') $r.Out
$r = Invoke-Notify $c (Get-NotifyJson $c -MergedAt 'yesterday-ish') $led
Assert-Verify 'N10-garbage' $r 'OK' 0
Assert-NoneLine 'N10-garbage' $r
# '10/16' is a date to DateTimeOffset.TryParse; only an ISO timestamp is a mergedAt.
$r = Invoke-Notify $c (Get-NotifyJson $c -MergedAt '10/16') $led
Assert-Verify 'N10-date-not-iso' $r 'OK' 0
Assert-NoneLine 'N10-date-not-iso' $r
$ledEmpty = New-NotifyLedger $c 'n10e' @((New-NotifyRow 'self' $c.Fx.Launch 'local_self' 'feat' 'running'))
$r = Invoke-Notify $c (Get-NotifyJson $c -MergedAt '') $ledEmpty
Assert-Verify 'N10-no-live-row' $r 'OK' 0
Assert-NoNotify 'N10-no-live-row' $r

# N11: a live row without a session id still gets a line.
$c = New-MergedCase 'n11'
$led = New-NotifyLedger $c 'n11' @((New-NotifyRow 'rc-a' $c.Fx.Launch '' 'a-branch' 'running'))
$r = Invoke-Notify $c (Get-NotifyJson $c) $led
Assert-Verify 'N11' $r 'OK' 0
$n = Get-NotifyLines $r
Assert-Coord 'N11 the line says there is no session id' ($n.Count -eq 1 -and $n[0].StartsWith('NOTIFY rc-a (no session id): #7 merged ')) "got: $($n -join ' || ')"

# N12: the default ledger (no -Ledger): today's, at the canonical place of the repo that holds the current
# directory, here run from a linked worktree whose ledger lives in the main checkout.
$c = New-MergedCase 'n12'
$wt12 = Join-Path $c.Fx.Base 'wt12'
New-HookTestWorktree -Repo $c.Fx.Launch -Path $wt12 -Branch 'n12-wt'
$todayName = [DateTime]::Now.ToString('yyyy-MM-dd', $inv) + '.md'
$defLed = Join-Path $c.Fx.Launch ('.claude\coordination\' + $todayName)
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $defLed))
$src12 = New-NotifyLedger $c 'n12src' @((New-NotifyRow 'rc-a' $c.Fx.Launch 'local_aaa' 'a-branch' 'running'))
Copy-Item -LiteralPath $src12 -Destination $defLed
$r = Invoke-Verify $c (Get-NotifyJson $c) -Cwd $wt12
Assert-Verify 'N12' $r 'OK' 0
$n = Get-NotifyLines $r
Assert-Coord 'N12 the default ledger is found from a linked worktree' ($n.Count -eq 1 -and $n[0] -ceq (Get-ExpectedNotify $c 'rc-a' 'local_aaa' $c.Merge $c.Merge)) "got: $($n -join ' || ')`n$($r.Out)"

# N13: a live row whose Repo cell GetFullPath rejects (Windows PowerShell 5.1) is skipped with its own line; the
# good row still gets its line and the verdict is unchanged.
$c = New-MergedCase 'n13'
$led = New-NotifyLedger $c 'n13' @(
    (New-NotifyRow 'rc-bad' 'C:\odd<repo>\x' 'local_bad' 'bad-branch' 'running'),
    (New-NotifyRow 'rc-a' $c.Fx.Launch 'local_aaa' 'a-branch' 'running'))
$r = Invoke-Notify $c (Get-NotifyJson $c) $led
Assert-Verify 'N13' $r 'OK' 0
$n = Get-NotifyLines $r
Assert-Coord 'N13 the good row gets its line, then one none-printed line names the odd row' ($n.Count -eq 2 -and $n[0] -ceq (Get-ExpectedNotify $c 'rc-a' 'local_aaa' $c.Merge $c.Merge) -and $n[1] -ceq "NOTIFY: none printed - row 'rc-bad': its Repo cell is not a usable path") "got: $($n -join ' || ')"
Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "Passed: $script:coordPass  Failed: $script:coordFail"
if ($script:coordFail -gt 0) { exit 1 }
exit 0
