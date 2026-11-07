# Tests for scripts/prune-scan.ps1. Ported from the private coordinate toolkit
# (prune-scan.test.ps1), 2026-11-05. gh is the stub in tests\stubs; git runs
# for real against a bare origin in a scratch folder. Every run passes a scratch
# -Ledger except the P18 runs, which pass none, point COORD_INDEX_DIR at a scratch
# index and run from a folder that is not a repo: the live ledger is never read.
#
# What changed from the private suite it was ported from: the fixtures load from tests\fixtures; the fixture
# names are neutral; the generated-file rows stage the two files Flutter regenerates (the private suite had a
# third, a lints pubspec.lock; no row stages a pubspec.lock now, and the script treats one as not disposable);
# the case ids P27-P29 were other ids there; P9 runs with GIT_OPTIONAL_LOCKS=1 in the environment, so the
# script has to set it to 0 itself.
#
#   P1  a clean worktree on a branch merged at its tip -> worktree, branch and
#       remote branch SAFE
#   P2  a tip that moved past the merged head -> branch and remote KEEP, and the
#       worktree holding it KEEP
#   P3  ignored files: _inbox/ and CODE-REVIEW.md KEEP; build/, .dart_tool/ and a
#       .worktreeinclude copy identical to main's are disposable (SAFE); a
#       changed copy is KEEP (P14)
#   P4  an untracked file or a tracked change -> KEEP
#   P5  a -SessionCwds folder inside a worktree -> KEEP; a live ledger row's Cwd
#       and Branch -> KEEP; a MERGED row protects nothing
#   P6  locked, detached and the main checkout -> KEEP
#   P7  main / master / origin's default branch never SAFE; an open PR on the
#       branch as head or base -> KEEP; a cross-repository merged PR does not
#       count; no merged PR -> KEEP
#   P8  gh failing or invalid -> KEEP unknown, never SAFE
#   P9  read-only without -Apply: refs, worktrees, files and every index unchanged
#   P10 -Apply removes SAFE worktrees, then local and remote branches; KEEP items
#       stay; the last line counts them
#   P12 not a git repo, a failed fetch, an unreadable ledger -> exit 2, no SAFE
#   P13 junctions: a worktree holding one, or reached through one -> KEEP
#   P15 origin's default branch unknown -> every branch KEEP; a default branch
#       other than main is KEEP
#   P5b-d (round 1) a live row whose Repo cell is a worktree path or no repo still
#       protects, one naming another existing repo does not; a live session's
#       worktree keeps its remote branch; the `ledger:` line names the ledger
#   P11 (round 1) a remote tip moved during -Apply (a reference-transaction hook)
#       is not deleted: FAILED, exit 1
#   P16 two worktrees on one branch, one dirty: the clean one, the branch and its
#       remote are KEEP; P6 also: a prunable worktree is KEEP
#   P17 a session cwd through a junction makes every worktree KEEP
#   P18 without -Ledger the index's ledgers are read; none at all is said
#   P19 the main checkout on a branch, a PR merged into a stacked base, `Master`,
#       two push URLs -> KEEP
#   P5e, P18c-d, P19e, P20, P21 (round 2) a bare-name Repo cell; an unreadable
#       index; a ledger with no Tracks section; a stacked base whose tip reached
#       main; a branch mid-rebase; a remote tracked under another name
#   P17b-c, P18e-f, P20b, P22-P24 (round 3) a ledger row cwd through a junction; a
#       ledger Branch in another case; a bare cell naming another scanned repo (no
#       protection there); an index overflow; a listed ledger that is a folder; a
#       stacked base in rebase-merge/update-refs; an assume-unchanged edit; an
#       unreadable worktree git dir and a prunable detached worktree (local and
#       origin KEEP); two local branches differing only in case
#   P12d, P25 (round 4) a Tracks table split by a blank line; a worktree added on a
#       SAFE branch during -Apply: the local and its origin branch stay; P25b (Codex)
#       one added on a KEEP local whose origin branch is SAFE keeps the origin branch
#   P26 (Codex round 2) a symbolic branch ref to main is KEEP; main survives -Apply
#   F37-F39 (ported from the private toolkit's fixes)
#       F37 a worktree switched to another branch (at the same commit), moved on by a commit, detached or
#       locked between the scan and the apply is FAILED, untouched, its branch skipped (a git shim first on PATH acts
#       at the apply's content re-read); an unchanged one is still removed
#       F39 remote.origin.fetch narrowed to one other branch leaves origin/main stale: the default branch is
#       fetched by name, so a branch merged into a stacked base that reached main is SAFE
#       F38 a listed ledger in a folder this user is denied is COULD NOT CHECK (exit 2, icacls deny); one that
#       does not exist is still skipped
#   NOT covered: -Apply refused off Windows (exit 2); an 8.3 short-name path; a FILE change caught by the
#       content re-read right before `git worktree remove` (not staged: the F37 shim changes branch, HEAD
#       or lock only); rebase-apply/head-name and
#       BISECT_START (read like head-name, not staged); a failed for-each-ref or
#       worktree list; gh
#       missing; a cwd on a subst or mapped drive; F37: the worktree list unreadable at the
#       apply re-read, or the entry gone (untested, fail closed); F39: the by-name fetch of the
#       default branch failing (COULD NOT CHECK, not staged); F38: the -Ledger path access-denied
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\scripts\prune-scan.test.ps1 [-ScriptPath <mutant copy>]
# Exit: 0 = all passed, 1 = a case failed.
param([string]$ScriptPath = '')

try { . (Join-Path $PSScriptRoot '../fixtures/hook-test-fixture.ps1') } catch { Write-Error "could not load hook-test-fixture.ps1: $_"; exit 1 }
Clear-HookRunnerGitEnv
. (Join-Path $PSScriptRoot '../fixtures/coord-test-fixture.ps1')
$ErrorActionPreference = 'Stop'

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('prune-scan-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory($root)

# ---- fixture ---------------------------------------------------------------
$fx = New-CoordFixture $root 'fx'
# main gets a .gitignore and a .worktreeinclude, as the real repos have.
Invoke-HookTestGit $fx.Work @('checkout', '--quiet', 'main')
Set-CoordFile $fx.Work '.gitignore' "_inbox/`nbuild/`n.dart_tool/`nandroid/key.properties`nCODE-REVIEW.md`nandroid/local.properties`nandroid/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java`n.claude/audit/`nother/local.properties`n"
Set-CoordFile $fx.Work '.worktreeinclude' "android/key.properties`n"
Invoke-HookTestGit $fx.Work @('-c', 'core.autocrlf=false', 'add', '-A')
Invoke-HookTestGit $fx.Work @('-c', 'core.autocrlf=false', 'commit', '--quiet', '-m', 'ignore rules')
Invoke-HookTestGit $fx.Work @('push', '--quiet', 'origin', 'main')
Invoke-HookTestGit $fx.Launch @('pull', '--quiet', '--ff-only', 'origin', 'main')
Set-CoordFile $fx.Launch 'android/key.properties' "storePassword=fixture`n"

$tip = @{}
foreach ($b in 'done-a', 'inbox', 'review', 'cache', 'keydiff', 'untracked', 'tracked', 'sess', 'ledg', 'ledgb', 'ledgdone', 'locked', 'openhead', 'openbase', 'forked', 'nopr', 'junc', 'jr', 'master', 'ledwt', 'ledslug', 'ledother', 'prun', 'twice', 'ledbare', 'assume', 'flut', 'flutk', 'audit', 'lookalike', 'held', 'propsx', 'dirent') {
    $tip[$b] = New-CoordBranch $fx $b -Write @{ "docs/$b.md" = "$b`n" }
}
$tip['moved-merged'] = New-CoordBranch $fx 'moved' -Write @{ 'docs/moved.md' = "1`n" }
$tip['moved'] = New-CoordBranch $fx 'moved' -From 'origin/moved' -Write @{ 'docs/moved.md' = "2`n" }
Invoke-HookTestGit $fx.Launch @('fetch', '--quiet', 'origin')
foreach ($b in @($tip.Keys | Where-Object { $_ -ne 'moved-merged' })) { Invoke-HookTestGit $fx.Launch @('branch', '--quiet', $b, "origin/$b") }

function Add-Wt([string]$Name, [string]$Branch) {
    $p = Join-Path $fx.Base $Name
    Invoke-HookTestGit $fx.Launch @('worktree', 'add', '--quiet', $p, $Branch)
    return $p
}
$wtA = Add-Wt 'wtA' 'done-a'
$wtM = Add-Wt 'wtM' 'moved'
$wtI = Add-Wt 'wtI' 'inbox'
Set-CoordFile $wtI '_inbox/designer.zip' "zip`n"
$wtR = Add-Wt 'wtR' 'review'
Set-CoordFile $wtR 'CODE-REVIEW.md' "review`n"
$wtC = Add-Wt 'wtC' 'cache'
Set-CoordFile $wtC 'build/out.bin' "bin`n"
Set-CoordFile $wtC '.dart_tool/pkg.json' "{}`n"
Set-CoordFile $wtC 'android/key.properties' "storePassword=fixture`n"
$wtK = Add-Wt 'wtK' 'keydiff'
Set-CoordFile $wtK 'android/key.properties' "storePassword=changed`n"
$wtU = Add-Wt 'wtU' 'untracked'
Set-CoordFile $wtU 'notes.txt' "n`n"
$wtT = Add-Wt 'wtT' 'tracked'
Set-CoordFile $wtT 'README.md' "changed`n"
$wtS = Add-Wt 'wtS' 'sess'
[void][IO.Directory]::CreateDirectory((Join-Path $wtS 'docs\sub'))
$wtL = Add-Wt 'wtL' 'ledg'
$wtLk = Add-Wt 'wtLk' 'locked'
Invoke-HookTestGit $fx.Launch @('worktree', 'lock', '--reason', 'claude session x (pid 999999)', $wtLk)
$wtX = Join-Path $fx.Base 'wtX'
Invoke-HookTestGit $fx.Launch @('worktree', 'add', '--quiet', '--detach', $wtX, 'origin/main')
$wtJ = Add-Wt 'wtJ' 'junc'
[void][IO.Directory]::CreateDirectory((Join-Path $wtJ 'build'))
[void][IO.Directory]::CreateDirectory((Join-Path $root 'outside'))
$junctionOk = New-CoordJunction (Join-Path $wtJ 'build\link') (Join-Path $root 'outside')
# git records a worktree's real path, so a junction alias given to `worktree add`
# never reaches the list. The case that does: a folder on the recorded path later
# moved away and replaced by a junction to it.
$wtJr = Join-Path $fx.Base 'jdir\wtJr'
Invoke-HookTestGit $fx.Launch @('worktree', 'add', '--quiet', $wtJr, 'jr')
[System.IO.Directory]::Move((Join-Path $fx.Base 'jdir'), (Join-Path $fx.Base 'realdir'))
$throughOk = New-CoordJunction (Join-Path $fx.Base 'jdir') (Join-Path $fx.Base 'realdir')
# prunable: the folder of a registered worktree is gone.
$wtP = Add-Wt 'wtP' 'prun'
Remove-Item -LiteralPath $wtP -Recurse -Force
# two worktrees on one branch (`worktree add -f`): one dirty, one clean.
$wtTw1 = Add-Wt 'wtTw1' 'twice'
Set-CoordFile $wtTw1 'docs/twice.md' "edited`n"
$wtTw2 = Join-Path $fx.Base 'wtTw2'
Invoke-HookTestGit $fx.Launch @('worktree', 'add', '--quiet', '-f', $wtTw2, 'twice')
# an edit to a file flagged assume-unchanged: git status shows nothing.
$wtAu = Add-Wt 'wtAu' 'assume'
Invoke-HookTestGit $wtAu @('update-index', '--assume-unchanged', 'docs/assume.md')
Set-CoordFile $wtAu 'docs/assume.md' "edited, invisible`n"
# P28: Flutter's generated ignored files. flut: only the two generated paths (SAFE);
# flutk: the same plus _inbox/ (KEEP); audit: .claude/audit/ alone (KEEP, unknown content);
# lookalike: a file named local.properties in another folder (KEEP, matched whole, not by name).
$genFiles = @{ 'android/local.properties' = "sdk.dir=C:\\sdk`n"; 'android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java' = "// generated`n" }
$wtF = Add-Wt 'wtF' 'flut'
foreach ($k in $genFiles.Keys) { Set-CoordFile $wtF $k $genFiles[$k] }
$wtFk = Add-Wt 'wtFk' 'flutk'
foreach ($k in $genFiles.Keys) { Set-CoordFile $wtFk $k $genFiles[$k] }
Set-CoordFile $wtFk '_inbox/designer.zip' "zip`n"
$wtAud = Add-Wt 'wtAud' 'audit'
Set-CoordFile $wtAud '.claude/audit/x.jsonl' "{}`n"
$wtLk2 = Add-Wt 'wtLook' 'lookalike'
Set-CoordFile $wtLk2 'other/local.properties' "x`n"
# propsx: android/local.properties with a hand-written line besides Flutter's own keys (KEEP);
# dirent: an ignored DIRECTORY named like a generated file (KEEP: only a file matches).
$wtPx = Add-Wt 'wtPx' 'propsx'
Set-CoordFile $wtPx 'android/local.properties' "sdk.dir=C:\\sdk`nflutter.sdk=C:\\flutter`nMAPS_API_KEY=abc`n"
$wtDe = Add-Wt 'wtDe' 'dirent'
Set-CoordFile $wtDe 'android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java/inner.txt' "x`n"
# P29: a clean, merged worktree whose folder is the cwd of a process the scan does not know of
# (not in -SessionCwds): `git worktree remove` deletes the files and the entry, cannot delete the
# folder, and exits 255 (measured). The process is stopped at the end of the P10 -Apply run.
$wtH = Add-Wt 'wtH' 'held'
$heldProc = $null
# another repo, for a ledger row that names it (and later for P12b).
$fx2 = New-CoordFixture $root 'fx2'

# ---- gh rules ----------------------------------------------------------------
function ConvertTo-J($o) { return (ConvertTo-Json -InputObject @($o) -Depth 10 -Compress) }
function New-Merged([int]$N, [string]$Sha, [bool]$Cross = $false, [string]$Base = 'main') {
    return [ordered]@{ number = $N; headRefOid = $Sha; isCrossRepository = $Cross; baseRefName = $Base }
}
$mergedRules = New-Object System.Collections.Generic.List[object]
$n = 1
foreach ($b in 'done-a', 'inbox', 'review', 'cache', 'keydiff', 'untracked', 'tracked', 'sess', 'ledg', 'ledgb', 'ledgdone', 'locked', 'openhead', 'openbase', 'junc', 'jr', 'master', 'ledwt', 'ledslug', 'ledother', 'prun', 'twice', 'ledbare', 'assume', 'flut', 'flutk', 'audit', 'lookalike', 'held', 'propsx', 'dirent') {
    $mergedRules.Add((New-CoordRule "--state merged --head $([regex]::Escape($b)) " (ConvertTo-J @((New-Merged $n $tip[$b])))))
    $n++
}
$mergedRules.Add((New-CoordRule '--state merged --head moved ' (ConvertTo-J @((New-Merged 54 $tip['moved-merged'])))))
$mergedRules.Add((New-CoordRule '--state merged --head forked ' (ConvertTo-J @((New-Merged 60 $tip['forked'] $true)))))
$rulesOk = @(
    (New-CoordRule '--state open --head openhead ' (ConvertTo-J @([ordered]@{ number = 70 }))),
    (New-CoordRule '--state open --base openbase ' (ConvertTo-J @([ordered]@{ number = 71 }))),
    (New-CoordRule '--state open ' '[]')
) + $mergedRules.ToArray() + @((New-CoordRule '--state merged ' '[]'))

# ---- ledger ------------------------------------------------------------------
$ledger = Join-Path $root 'ledger.md'
function Set-PruneLedger([string[]]$Rows, [string]$Header = '| Track | Repo | Session | Cwd | Branch | Scope | PR | Status |', [string]$Path = $ledger) {
    $t = "# Coordination ledger`n`n## Tracks`n`n$Header`n|---|---|---|---|---|---|---|---|`n" + (($Rows | ForEach-Object { "$_`n" }) -join '') + "`n## Merge slots`n"
    [System.IO.File]::WriteAllText($Path, $t, $coordUtf8)
}
Set-PruneLedger @(
    "| L1 | $($fx.Launch) | s1 | $wtL | ledg-other | docs/** | | RUNNING |",
    "| L2 | $($fx.Launch) | s2 | C:\nowhere | ledgb | docs/** | | PR-OPEN |",
    "| L3 | $($fx.Launch) | s3 | $wtA | ledgdone | docs/** | #9 | MERGED 17:00 |",
    "| L4 | $wtU | s4 |  | ledwt | docs/** | | RUNNING |",
    "| L5 | owner/fx | s5 |  | ledslug | docs/** | | RUNNING |",
    "| L6 | $($fx2.Launch) | s6 |  | ledother | docs/** | | RUNNING |",
    "| L7 | tools (job 7) | s7 |  | ledbare | docs/** | | RUNNING |"
)

function Invoke-Prune {
    param([string]$Extra = '', [object[]]$Rules = $rulesOk, [string]$Cwd = $fx.Base, [string]$Repos = $fx.Launch, [switch]$NoLedger, [hashtable]$Env = @{})
    $l = if ($NoLedger) { '' } else { "-Ledger `"$ledger`"" }
    $a = "-Repos `"$Repos`" $l $Extra"
    return (Invoke-CoordScript -Name 'prune-scan.ps1' -Cwd $Cwd -ScriptArgs $a -Rules $Rules -ScriptPath $ScriptPath -ExtraEnv $Env)
}
function Get-State {
    $wt = Get-CoordGitOut $fx.Launch @('worktree', 'list', '--porcelain')
    $refs = Get-CoordGitOut $fx.Launch @('for-each-ref', '--format=%(refname) %(objectname)', 'refs/heads')
    $orefs = Get-CoordGitOut $fx.Origin @('for-each-ref', '--format=%(refname) %(objectname)', 'refs/heads')
    $files = @(Get-ChildItem -LiteralPath $fx.Base -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\(\.git|origin\.git|work)\\' } | ForEach-Object { "$($_.FullName)=$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" }) -join '|'
    return "$wt`n$refs`n$orefs`n$files"
}
function Assert-Has([string]$Case, $R, [string]$Pattern) {
    Assert-Coord "$Case output matches /$Pattern/" ($R.Out -match $Pattern) "exit=$($R.Code)`n$($R.Out)`nerr: $($R.Err)"
}
function Assert-HasNot([string]$Case, $R, [string]$Pattern) {
    Assert-Coord "$Case output does not match /$Pattern/" (-not ($R.Out -match $Pattern)) $R.Out
}
function Wt([string]$Path) { return '(?m)^worktree ' + [regex]::Escape($Path) + ' \[[^\]]*\]: ' }
function Br([string]$Name) { return '(?m)^branch ' + [regex]::Escape($Name) + ' @[0-9a-f]{12}: ' }
function Rb([string]$Name) { return '(?m)^remote origin/' + [regex]::Escape($Name) + ' @[0-9a-f]{12}: ' }

# ---- scan --------------------------------------------------------------------
Write-Host "(P1-P9, P13) scan"
# A tracked file whose mtime moved with no change in content: `git status` would refresh the index of its worktree.
(Get-Item -LiteralPath (Join-Path $wtA 'docs\done-a.md')).LastWriteTime = [DateTime]::Now.AddMinutes(7)
function Get-IndexHashes { return (@(Get-ChildItem -LiteralPath (Join-Path $fx.Launch '.git') -Recurse -Force -File -Filter 'index' | Sort-Object FullName | ForEach-Object { "$($_.FullName)=$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" }) -join '|') }
$indexBefore = Get-IndexHashes
$before = Get-State
$r = Invoke-Prune -Extra "-SessionCwds `"$(Join-Path $wtS 'docs\sub')`"" -Env @{ GIT_OPTIONAL_LOCKS = '1' }   # the script must set it to 0 itself
Assert-Coord 'scan exits 0' ($r.Code -eq 0) "exit=$($r.Code)`n$($r.Out)`nerr: $($r.Err)"
Assert-Has 'P1 worktree SAFE' $r ((Wt $wtA) + 'SAFE')
Assert-Has 'P1 branch SAFE' $r ((Br 'done-a') + 'SAFE')
Assert-Has 'P1 remote SAFE' $r ((Rb 'done-a') + 'SAFE')
Assert-Has 'P2 branch KEEP' $r ((Br 'moved') + 'KEEP .*moved past .*#54')
Assert-Has 'P2 remote KEEP' $r ((Rb 'moved') + 'KEEP .*moved past .*#54')
Assert-Has 'P2 worktree KEEP' $r ((Wt $wtM) + 'KEEP branch moved is KEEP')
Assert-Has 'P3 _inbox KEEP' $r ((Wt $wtI) + 'KEEP .*not disposable: _inbox/')
Assert-Has 'P3 CODE-REVIEW.md KEEP' $r ((Wt $wtR) + 'KEEP .*not disposable: CODE-REVIEW\.md')
Assert-Has 'P3 caches and identical key copy SAFE' $r ((Wt $wtC) + 'SAFE')
Assert-Has 'P14 changed key copy KEEP' $r ((Wt $wtK) + 'KEEP .*not disposable: android/key\.properties')
Assert-Has 'P4 untracked KEEP' $r ((Wt $wtU) + 'KEEP .*uncommitted or untracked.*notes\.txt')
Assert-Has 'P4 tracked change KEEP' $r ((Wt $wtT) + 'KEEP .*uncommitted or untracked.*README\.md')
Assert-Has 'P5 session cwd inside KEEP' $r ((Wt $wtS) + 'KEEP live session cwd')
Assert-Has 'P5 ledger Cwd KEEP' $r ((Wt $wtL) + "KEEP live ledger row 'L1' cwd")
Assert-Has 'P5 ledger Branch KEEP' $r ((Br 'ledgb') + "KEEP live ledger row 'L2' branch")
Assert-Has 'P5 ledger Branch KEEP on origin too' $r ((Rb 'ledgb') + "KEEP live ledger row 'L2' branch")
Assert-Has 'P5 MERGED row protects nothing (branch)' $r ((Br 'ledgdone') + 'SAFE')
Assert-Has 'P5 MERGED row protects nothing (cwd)' $r ((Wt $wtA) + 'SAFE')
Assert-Has 'P6 locked KEEP' $r ((Wt $wtLk) + 'KEEP locked.*pid 999999 not running')
Assert-Has 'P6 detached KEEP' $r ((Wt $wtX) + 'KEEP detached HEAD')
Assert-Has 'P6 main checkout KEEP' $r ((Wt $fx.Launch) + 'KEEP main checkout')
Assert-Has 'P7 main KEEP' $r ((Br 'main') + 'KEEP ')
Assert-Has 'P7 origin/main KEEP' $r ((Rb 'main') + 'KEEP ')
Assert-Has 'P7 master KEEP' $r ((Br 'master') + 'KEEP protected name')
Assert-Has 'P7 open PR head KEEP' $r ((Br 'openhead') + 'KEEP open PR #70')
Assert-Has 'P7 open PR base KEEP' $r ((Br 'openbase') + 'KEEP open PR #71')
Assert-Has 'P7 fork KEEP' $r ((Br 'forked') + 'KEEP .*cross-repository')
Assert-Has 'P7 no merged PR KEEP' $r ((Br 'nopr') + 'KEEP no merged PR')
if ($junctionOk) { Assert-Has 'P13 worktree holding a junction KEEP' $r ((Wt $wtJ) + 'KEEP .*junction') }
else { Write-CoordUnchecked 'P13 worktree holding a junction' 'no junction right' }
if ($throughOk) { Assert-Coord 'P13 worktree reached through a junction KEEP' ($r.Out -match '(?m)^worktree .*wtJr \[jr\]: KEEP .*junction') $r.Out }
else { Write-CoordUnchecked 'P13 worktree through a junction' 'no junction right' }
Assert-Has 'P5b a ledger row whose Repo cell is a worktree of this repo protects' $r ((Br 'ledwt') + "KEEP live ledger row 'L4' branch")
Assert-Has 'P5b a ledger row whose Repo cell resolves to no repo protects' $r ((Br 'ledslug') + "KEEP live ledger row 'L5' branch")
Assert-Has 'P5b a ledger row of another existing repo does not' $r ((Br 'ledother') + 'SAFE')
Assert-Has 'P5e a bare-name Repo cell that names no scanned repo protects' $r ((Br 'ledbare') + "KEEP live ledger row 'L7' branch")
Assert-Has 'P5c a live session worktree keeps its remote branch' $r ((Rb 'sess') + 'KEEP worktree .*wtS on the local sess is KEEP')
Assert-Has 'P5d the ledger line names the ledger' $r ('(?m)^ledger: ' + [regex]::Escape($ledger))
Assert-Has 'P6 prunable KEEP' $r ((Wt $wtP) + 'KEEP prunable')
Assert-Has 'P16 a clean second worktree on a branch a dirty one holds is KEEP' $r ((Wt $wtTw2) + 'KEEP branch twice is KEEP')
Assert-Has 'P16 that branch is KEEP' $r ((Br 'twice') + 'KEEP held by worktree .*wtTw1')
Assert-Has 'P16 and so is its remote' $r ((Rb 'twice') + 'KEEP worktree .*wtTw1')
Assert-Has 'P22 an assume-unchanged edit is KEEP' $r ((Wt $wtAu) + 'KEEP 1 file\(s\) flagged assume-unchanged or skip-worktree.*docs/assume\.md')
Assert-Has 'P28 a worktree with only the two generated Flutter files is SAFE' $r ((Wt $wtF) + 'SAFE')
Assert-Has 'P28 the same plus _inbox/ is still KEEP' $r ((Wt $wtFk) + 'KEEP .*not disposable: _inbox/')
Assert-HasNot 'P28 and the generated files are not what it names' $r ((Wt $wtFk) + 'KEEP .*(local\.properties|GeneratedPluginRegistrant)')
Assert-Has 'P28 .claude/audit/ alone is KEEP' $r ((Wt $wtAud) + 'KEEP .*not disposable: \.claude/audit/')
Assert-Has 'P28 a local.properties in another folder is KEEP' $r ((Wt $wtLk2) + 'KEEP .*not disposable: other/local\.properties')
Assert-Has 'P28 a local.properties with a hand-written line is KEEP' $r ((Wt $wtPx) + 'KEEP .*not disposable: android/local\.properties')
Assert-Has 'P28 an ignored directory named like a generated file is KEEP' $r ((Wt $wtDe) + 'KEEP .*not disposable: android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant\.java/')
Assert-HasNot 'P9 no APPLY lines without -Apply' $r '(?m)^APPLY '
Assert-Coord 'P9 last line counts' ($r.Last -match '^PRUNE-SCAN: \d+ SAFE, \d+ KEEP$') $r.Last
Assert-Coord 'P9 read-only' ((Get-State) -ceq $before) 'state changed'
Assert-Coord 'P9 the scan leaves every index alone (git runs without optional locks)' ((Get-IndexHashes) -ceq $indexBefore) 'an index file changed'
Assert-Coord 'P9 gh merged lookups are per branch' (@($r.Calls | Where-Object { $_ -match '--state merged --head done-a ' }).Count -eq 1) ($r.Calls -join "`n")

# ---- P8: gh failures -----------------------------------------------------------
Write-Host "(P8) gh failing or invalid"
$r = Invoke-Prune -Rules @((New-CoordRule '.' '' 1))
Assert-Has 'P8a branch unknown' $r ((Br 'done-a') + 'KEEP unknown \(gh')
Assert-Has 'P8a worktree KEEP' $r ((Wt $wtA) + 'KEEP ')
Assert-HasNot 'P8a nothing SAFE' $r '(?m): SAFE'
$r = Invoke-Prune -Rules @((New-CoordRule '--state merged ' '[{"number":1,"headRefOid":"nothex"}]'), (New-CoordRule '.' '[]'))
Assert-Has 'P8b invalid item' $r ((Br 'done-a') + 'KEEP unknown \(gh output invalid')
$r = Invoke-Prune -Rules @((New-CoordRule '--state open ' '{"x":1}'), (New-CoordRule '.' (ConvertTo-J @((New-Merged 1 $tip['done-a'])))))
Assert-Has 'P8c open list not an array' $r ((Br 'done-a') + 'KEEP unknown \(gh')
Assert-HasNot 'P8c nothing SAFE' $r '(?m): SAFE'

# ---- P17: a session cwd through a junction; P18: the default ledgers ---------------
Write-Host "(P17, P18) junction cwd, default ledgers"
$alias = Join-Path $fx.Base 'alias-a'
if (New-CoordJunction $alias $wtA) {
    $r = Invoke-Prune -Extra "-SessionCwds `"$alias\docs`""
    Assert-Has 'P17 a session cwd through a junction makes worktrees KEEP' $r ((Wt $wtA) + 'KEEP session cwd .*junction')
    Assert-HasNot 'P17 no worktree SAFE' $r '(?m)^worktree .*: SAFE'
    Set-PruneLedger @("| LJ | $($fx.Launch) | s | $alias\docs | ljx | ** | | RUNNING |")
    $r = Invoke-Prune
    Assert-Has 'P17b a live ledger row cwd through a junction makes worktrees KEEP' $r ((Wt $wtA) + "KEEP live ledger row 'LJ' cwd goes through a junction")
    Remove-CoordJunction $alias
} else { Write-CoordUnchecked 'P17 junction session cwd' 'no junction right' }
# A ledger Branch in another case protects; a bare Repo cell naming another scanned repo does not.
$otherRepo = Join-Path $root 'otherrepo'
Invoke-HookTestGit $root @('clone', '--quiet', $fx2.Origin, $otherRepo)
Set-PruneLedger @("| LC | $($fx.Launch) | s | | DONE-A | ** | | RUNNING |", "| LB | otherrepo | s | | ledbare | ** | | RUNNING |")
$r = Invoke-Prune -Repos "$($fx.Launch),$otherRepo"
Assert-Coord 'P17c two repos scanned, exit 0' ($r.Code -eq 0) "exit=$($r.Code)`n$($r.Out)`nerr: $($r.Err)"
Assert-Has 'P17c a ledger Branch in another case protects' $r ((Br 'done-a') + "KEEP live ledger row 'LC' branch")
Assert-Has 'P17c a bare Repo cell naming another scanned repo does not protect here' $r ((Br 'ledbare') + 'SAFE')
Set-PruneLedger @(
    "| L1 | $($fx.Launch) | s1 | $wtL | ledg-other | docs/** | | RUNNING |",
    "| L2 | $($fx.Launch) | s2 | C:\nowhere | ledgb | docs/** | | PR-OPEN |",
    "| L3 | $($fx.Launch) | s3 | $wtA | ledgdone | docs/** | #9 | MERGED 17:00 |",
    "| L4 | $wtU | s4 |  | ledwt | docs/** | | RUNNING |",
    "| L5 | owner/fx | s5 |  | ledslug | docs/** | | RUNNING |",
    "| L6 | $($fx2.Launch) | s6 |  | ledother | docs/** | | RUNNING |",
    "| L7 | tools (job 7) | s7 |  | ledbare | docs/** | | RUNNING |"
)
$idx = Join-Path $root 'index'
$idxLedger = Join-Path $root 'indexed-ledger.md'
$today = [DateTime]::Now.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
[void][IO.Directory]::CreateDirectory($idx)
[System.IO.File]::WriteAllText($idxLedger, "# L`n`n## Tracks`n`n| Track | Repo | Session | Cwd | Branch | Scope | PR | Status |`n|---|---|---|---|---|---|---|---|`n| IX | $($fx.Launch) | s | | done-a | ** | | RUNNING |`n`n## Log`n", $coordUtf8)
[System.IO.File]::WriteAllText((Join-Path $idx "$today.ledgers"), "$idxLedger`n", $coordUtf8)
$r = Invoke-Prune -NoLedger -Env @{ COORD_INDEX_DIR = $idx }
Assert-Has 'P18a no -Ledger: a ledger the index lists is read' $r ('(?m)^ledger: .*' + [regex]::Escape($idxLedger))
Assert-Has 'P18a and its live row protects' $r ((Br 'done-a') + "KEEP live ledger row 'IX' branch")
Remove-Item -LiteralPath (Join-Path $idx "$today.ledgers")
$r = Invoke-Prune -NoLedger -Env @{ COORD_INDEX_DIR = $idx }
Assert-Has 'P18b no ledger anywhere is said, not silent' $r '(?m)^ledger: none \('
Assert-Coord 'P18b and the scan still runs' ($r.Code -eq 0) "exit=$($r.Code)"
[void][IO.Directory]::CreateDirectory((Join-Path $idx "$today.ledgers"))
$r = Invoke-Prune -NoLedger -Env @{ COORD_INDEX_DIR = $idx }
Assert-Coord 'P18c an index that cannot be read -> exit 2' ($r.Code -eq 2) "exit=$($r.Code)`n$($r.Out)"
Assert-HasNot 'P18c nothing SAFE' $r '(?m): SAFE'
Remove-Item -LiteralPath (Join-Path $idx "$today.ledgers") -Recurse -Force
$torn = Join-Path $root 'torn-ledger.md'
[System.IO.File]::WriteAllText($torn, "# Coordination ledger`n`n| Track | Repo |`n", $coordUtf8)
[System.IO.File]::WriteAllText((Join-Path $idx "$today.ledgers"), "$torn`n", $coordUtf8)
$r = Invoke-Prune -NoLedger -Env @{ COORD_INDEX_DIR = $idx }
Assert-Coord 'P18d a ledger with no Tracks section -> exit 2' ($r.Code -eq 2 -and $r.Last -match 'Tracks') "exit=$($r.Code)`n$($r.Last)"
[System.IO.File]::WriteAllText((Join-Path $idx "$today.ledgers"), ((1..9 | ForEach-Object { Join-Path $root "nowhere-$_.md" }) -join "`n") + "`n", $coordUtf8)
$r = Invoke-Prune -NoLedger -Env @{ COORD_INDEX_DIR = $idx }
Assert-Coord 'P18e an index listing 9 ledgers (overflow) -> exit 2' ($r.Code -eq 2 -and $r.Last -match 'over 8 ledgers') "exit=$($r.Code)`n$($r.Last)"
$ledgerDir = Join-Path $root 'ledger-folder.md'
[void][IO.Directory]::CreateDirectory($ledgerDir)
[System.IO.File]::WriteAllText((Join-Path $idx "$today.ledgers"), "$ledgerDir`n", $coordUtf8)
$r = Invoke-Prune -NoLedger -Env @{ COORD_INDEX_DIR = $idx }
Assert-Coord 'P18f a listed ledger that is a folder -> exit 2' ($r.Code -eq 2 -and $r.Last -match 'is not a file') "exit=$($r.Code)`n$($r.Last)"
Remove-Item -LiteralPath (Join-Path $idx "$today.ledgers")

# ---- P27: a live yesterday row stops protecting only when today's ledger has a MERGED/DONE row for the same track ----
Write-Host "(P27) yesterday's rows"
$yesterday = [DateTime]::Now.AddDays(-1).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
$ledToday = Join-Path $root 'p27-today.md'
$ledToday2 = Join-Path $root 'p27-today2.md'
$ledYest = Join-Path $root 'p27-yesterday.md'
function Set-P27([string[]]$TodayRows, [string[]]$YestRows, [string[]]$TodayRows2 = @()) {
    Set-PruneLedger $TodayRows -Path $ledToday
    Set-PruneLedger $YestRows -Path $ledYest
    $t = "$ledToday`n"
    if ($TodayRows2.Count) { Set-PruneLedger $TodayRows2 -Path $ledToday2; $t += "$ledToday2`n" }
    [System.IO.File]::WriteAllText((Join-Path $idx "$today.ledgers"), $t, $coordUtf8)
    [System.IO.File]::WriteAllText((Join-Path $idx "$yesterday.ledgers"), "$ledYest`n", $coordUtf8)
}
$lc = $fx.Launch
$fx2l = $fx2.Launch
# a: yesterday RUNNING (Branch + Cwd), today MERGED, same Track (other case) and Repo: protects nothing.
# b: yesterday RUNNING, today has no row for that Track: still protects.
# c: same Track in today's ledger but another Repo: yesterday's row still protects.
# d: yesterday MERGED, today RUNNING (same Track and Repo): today's row is live.
# g: yesterday RUNNING on one branch, today RUNNING on another (a reused Track name): both protect.
# h: no Track cell in either ledger: nothing identifies the track, so nothing is dropped.
# (a also spells the Repo cell in another case.)
Set-P27 -TodayRows @(
    "| qa | $($lc.ToUpperInvariant()) | s | | | ** | | MERGED 09:00 |",
    "| QC | $fx2l | s | | | ** | | MERGED 09:00 |",
    "| QD | $lc | s | | review | ** | | RUNNING |",
    "| QG | $lc | s | | tracked | ** | | RUNNING |",
    "|  | $lc | s | | | ** | | MERGED 09:00 |"
) -YestRows @(
    "| QA | $lc | s | $wtA | done-a | ** | | RUNNING |",
    "| QB | $lc | s | | cache | ** | | RUNNING |",
    "| QC | $lc | s | | ledgdone | ** | | RUNNING |",
    "| QD | $lc | s | | review | ** | | MERGED 08:00 |",
    "| QG | $lc | s | | inbox | ** | | RUNNING |",
    "|  | $lc | s | | junc | ** | | RUNNING |"
)
$r = Invoke-Prune -NoLedger -Env @{ COORD_INDEX_DIR = $idx }
Assert-Has 'P27 the ledger line names both ledgers' $r ('(?m)^ledger: .*' + [regex]::Escape($ledToday) + '.*' + [regex]::Escape($ledYest))
Assert-Has 'P27a yesterday RUNNING ended by today MERGED (Track and Repo in another case): branch SAFE' $r ((Br 'done-a') + 'SAFE')
Assert-Has 'P27a and its worktree (the row cwd protects nothing)' $r ((Wt $wtA) + 'SAFE')
Assert-Has 'P27b yesterday RUNNING with no row today still protects' $r ((Br 'cache') + "KEEP live ledger row 'QB' branch")
Assert-Has 'P27c a today MERGED row of the same Track in another Repo does not end it' $r ((Br 'ledgdone') + "KEEP live ledger row 'QC' branch")
Assert-Has 'P27d today RUNNING over yesterday MERGED protects' $r ((Br 'review') + "KEEP live ledger row 'QD' branch")
Assert-Has 'P27g a yesterday RUNNING row keeps protecting its branch beside a live row of the same Track today' $r ((Br 'inbox') + "KEEP live ledger row 'QG' branch")
Assert-Has 'P27g and today row protects its own branch' $r ((Br 'tracked') + "KEEP live ledger row 'QG' branch")
Assert-Has 'P27h a row with no Track cell is never dropped' $r ((Br 'junc') + "KEEP live ledger row 'junc' branch")
# e: two ledgers of the SAME day are equals: neither ends the other (live listed first, MERGED second).
Set-P27 -TodayRows @("| QE | $lc | s | | tracked | ** | | RUNNING |") -YestRows @() -TodayRows2 @("| QE | $lc | s | | tracked | ** | | MERGED 09:00 |")
$r = Invoke-Prune -NoLedger -Env @{ COORD_INDEX_DIR = $idx }
Assert-Has 'P27e two ledgers of one day: a live row there still protects' $r ((Br 'tracked') + "KEEP live ledger row 'QE' branch")
# f: -Ledger reads that file only, every row at the same age.
Set-PruneLedger @("| QF | $lc | s | | cache | ** | | RUNNING |", "| QF | $lc | s | | cache | ** | | MERGED 09:00 |") -Path $ledToday
$r = Invoke-Prune -NoLedger -Extra "-Ledger `"$ledToday`""
Assert-Has 'P27f one -Ledger file: no row ends another' $r ((Br 'cache') + "KEEP live ledger row 'QF' branch")
Remove-Item -LiteralPath (Join-Path $idx "$today.ledgers"), (Join-Path $idx "$yesterday.ledgers") -ErrorAction SilentlyContinue

# ---- P12: could not check --------------------------------------------------------
Write-Host "(P12) could not check"
$plain = Join-Path $root 'plain'
[void][IO.Directory]::CreateDirectory($plain)
$r = Invoke-Prune -Repos $plain
Assert-Coord 'P12a not a repo -> exit 2' ($r.Code -eq 2) "exit=$($r.Code)`n$($r.Out)"
Assert-Coord 'P12a last line names it' ($r.Last -match 'COULD NOT CHECK: .*plain') $r.Last
Invoke-HookTestGit $fx2.Launch @('remote', 'set-url', 'origin', (Join-Path $root 'no-such-origin.git'))
$r = Invoke-Prune -Repos $fx2.Launch
Assert-Coord 'P12b fetch failed -> exit 2' ($r.Code -eq 2) "exit=$($r.Code)`n$($r.Out)"
Assert-Coord 'P12b reason' ($r.Last -match 'COULD NOT CHECK: .*fetch') $r.Last
Assert-HasNot 'P12b nothing SAFE' $r '(?m): SAFE'
Set-PruneLedger @("| L1 | x |") -Header '| Track | Repo |'
$before = Get-State
$r = Invoke-Prune -Extra '-Apply'
Assert-Coord 'P12c unreadable ledger -> exit 2' ($r.Code -eq 2) "exit=$($r.Code)`n$($r.Out)"
Assert-Coord 'P12c reason' ($r.Last -match 'COULD NOT CHECK: .*ledger') $r.Last
Assert-HasNot 'P12c nothing SAFE' $r '(?m): SAFE'
Assert-Coord 'P12c nothing applied' ((Get-State) -ceq $before) 'state changed'
Set-PruneLedger @("| L2 | $($fx.Launch) | s2 | | ledgb | docs/** | | PR-OPEN |", '', "| LZ | $($fx.Launch) | s | | done-a | docs/** | | RUNNING |")
$r = Invoke-Prune
Assert-Coord 'P12d a Tracks table split by a blank line -> exit 2' ($r.Code -eq 2 -and $r.Last -match 'split by a non-table line') "exit=$($r.Code)`n$($r.Last)"
Assert-HasNot 'P12d nothing SAFE' $r '(?m): SAFE'

# ---- P15: origin's default branch --------------------------------------------------
Write-Host "(P15) default branch"
Set-PruneLedger @()
$fx3 = New-CoordFixture $root 'fx3'
$t3 = New-CoordBranch $fx3 'trunk' -Write @{ 'docs/t.md' = "t`n" }
$d3 = New-CoordBranch $fx3 'feat' -Write @{ 'docs/f.md' = "f`n" }
Invoke-HookTestGit $fx3.Origin @('symbolic-ref', 'HEAD', 'refs/heads/trunk')
$rules3 = @((New-CoordRule '--state open ' '[]'), (New-CoordRule '--head trunk ' (ConvertTo-J @((New-Merged 1 $t3 $false 'trunk')))), (New-CoordRule '--head feat ' (ConvertTo-J @((New-Merged 2 $d3 $false 'trunk')))), (New-CoordRule '.' '[]'))
$r = Invoke-Prune -Repos $fx3.Launch -Rules $rules3
Assert-Has 'P15a default branch trunk KEEP' $r ((Rb 'trunk') + "KEEP origin's default branch")
Assert-Has 'P15a feat SAFE' $r ((Rb 'feat') + 'SAFE')
Invoke-HookTestGit $fx3.Origin @('symbolic-ref', 'HEAD', 'refs/heads/unborn')
$r = Invoke-Prune -Repos $fx3.Launch -Rules $rules3
Assert-Has 'P15b default unknown -> KEEP' $r ((Rb 'feat') + "KEEP origin's default branch unknown")
Assert-HasNot 'P15b nothing SAFE' $r '(?m): SAFE'
# P23: a worktree whose git dir cannot be read may be mid-rebase of any branch.
Invoke-HookTestGit $fx3.Origin @('symbolic-ref', 'HEAD', 'refs/heads/trunk')
Invoke-HookTestGit $fx3.Launch @('fetch', '--quiet', 'origin')
Invoke-HookTestGit $fx3.Launch @('branch', '--quiet', 'feat', 'origin/feat')
$wtBad = Join-Path $fx3.Base 'wtBad'
Invoke-HookTestGit $fx3.Launch @('worktree', 'add', '--quiet', '--detach', $wtBad, 'origin/main')
[System.IO.File]::SetAttributes((Join-Path $wtBad '.git'), [System.IO.FileAttributes]::Normal)   # git hides it; a hidden file refuses WriteAllText
[System.IO.File]::WriteAllText((Join-Path $wtBad '.git'), "not a gitfile`n", $coordUtf8)
$r = Invoke-Prune -Repos $fx3.Launch -Rules $rules3
Assert-Has 'P23 an unreadable worktree git dir makes local branches KEEP' $r ((Br 'feat') + 'KEEP unknown \(the git dir of worktree')
Assert-Has 'P23 and origin branches too' $r ((Rb 'feat') + 'KEEP unknown \(the git dir of worktree')
Remove-Item -LiteralPath $wtBad -Recurse -Force
$r = Invoke-Prune -Repos $fx3.Launch -Rules $rules3
Assert-Has 'P23b a prunable detached worktree makes branches KEEP' $r ((Rb 'feat') + 'KEEP unknown \(worktree .*wtBad is prunable and detached')
Assert-Has 'P23b local ones too' $r ((Br 'feat') + 'KEEP unknown \(worktree .*wtBad is prunable and detached')

# ---- P19: the main checkout on a branch, a stacked base, Master, push URLs, the lease ----
Write-Host "(P19) main checkout holder, stacked base, push URLs, lease"
$fx4 = New-CoordFixture $root 'fx4'
$t4 = @{}
foreach ($b in 'onmain', 'stacked', 'Master', 'leaseb', 'rbx', 'upb', 'urb', 'caseb', 'zlate', 'kfeat') { $t4[$b] = New-CoordBranch $fx4 $b -Write @{ "docs/$b.md" = "$b`n" } }
Invoke-HookTestGit $fx4.Launch @('fetch', '--quiet', 'origin')
Invoke-HookTestGit $fx4.Launch @('checkout', '--quiet', '-b', 'onmain', 'origin/onmain')
Invoke-HookTestGit $fx4.Launch @('branch', '--quiet', 'leaseb', 'origin/leaseb')
Invoke-HookTestGit $fx4.Launch @('branch', '--quiet', 'zlate', 'origin/zlate')
# kfeat: the local is one commit past the merged head (KEEP), origin/kfeat sits at it (SAFE).
$kTree = Get-CoordGitOut $fx4.Launch @('rev-parse', "$($t4['kfeat'])^{tree}")
$kNext = Get-CoordGitOut $fx4.Launch @('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit-tree', $kTree, '-p', $t4['kfeat'], '-m', 'local only')
Invoke-HookTestGit $fx4.Launch @('branch', '--quiet', 'kfeat', $kNext)
$wtOn = Join-Path $fx4.Base 'wtOn'
Invoke-HookTestGit $fx4.Launch @('worktree', 'add', '--quiet', '-f', $wtOn, 'onmain')
# stacked2: merged into a stacked base, but its tip did reach main.
$t4['stacked2'] = New-CoordBranch $fx4 'stacked2' -Write @{ 'docs/s2.md' = "s2`n" }
$null = Merge-CoordIntoMain $fx4 $t4['stacked2']
Invoke-HookTestGit $fx4.Launch @('fetch', '--quiet', 'origin')
# rbx: a worktree mid-rebase shows as detached; the branch is named in its git dir.
Invoke-HookTestGit $fx4.Launch @('branch', '--quiet', 'rbx', 'origin/rbx')
$wtRb = Join-Path $fx4.Base 'wtRb'
Invoke-HookTestGit $fx4.Launch @('worktree', 'add', '--quiet', $wtRb, 'rbx')
Invoke-HookTestGit $wtRb @('checkout', '--quiet', '--detach')
$rbDir = Get-CoordGitOut $wtRb @('rev-parse', '--absolute-git-dir')
Set-CoordFile $rbDir 'rebase-merge/head-name' "refs/heads/rbx`n"
# urb: a stacked base that rebase (rebase -i --update-refs) also rewrites; named in update-refs.
Invoke-HookTestGit $fx4.Launch @('branch', '--quiet', 'urb', 'origin/urb')
Set-CoordFile $rbDir 'rebase-merge/update-refs' "refs/heads/urb`n$($t4['urb'])`n$($t4['urb'])`n"
# caseb packed, CaseB loose, one tip: on Windows `update-ref -d` of caseb removed both (measured).
Invoke-HookTestGit $fx4.Launch @('branch', '--quiet', 'caseb', 'origin/caseb')
Invoke-HookTestGit $fx4.Launch @('pack-refs', '--all')
Invoke-HookTestGit $fx4.Launch @('branch', '--quiet', 'CaseB', 'caseb')
# loc tracks origin/upb under another name; its worktree holds a live session.
Invoke-HookTestGit $fx4.Launch @('branch', '--quiet', '--track', 'loc', 'origin/upb')
$wtLoc = Join-Path $fx4.Base 'wtLoc'
Invoke-HookTestGit $fx4.Launch @('worktree', 'add', '--quiet', $wtLoc, 'loc')
$rules4 = @((New-CoordRule '--state open ' '[]'),
    (New-CoordRule '--head stacked ' (ConvertTo-J @([ordered]@{ number = 3; headRefOid = $t4['stacked']; isCrossRepository = $false; baseRefName = 'stackbase' }))),
    (New-CoordRule '--head onmain ' (ConvertTo-J @((New-Merged 1 $t4['onmain'])))),
    (New-CoordRule '--head Master ' (ConvertTo-J @((New-Merged 2 $t4['Master'])))),
    (New-CoordRule '--head leaseb ' (ConvertTo-J @((New-Merged 4 $t4['leaseb'])))),
    (New-CoordRule '--head stacked2 ' (ConvertTo-J @([ordered]@{ number = 5; headRefOid = $t4['stacked2']; isCrossRepository = $false; baseRefName = 'stackbase' }))),
    (New-CoordRule '--head rbx ' (ConvertTo-J @((New-Merged 6 $t4['rbx'])))),
    (New-CoordRule '--head (upb|loc) ' (ConvertTo-J @((New-Merged 7 $t4['upb'])))),
    (New-CoordRule '--head urb ' (ConvertTo-J @((New-Merged 8 $t4['urb'])))),
    (New-CoordRule '--head caseb ' (ConvertTo-J @((New-Merged 9 $t4['caseb'])))),
    (New-CoordRule '--head zlate ' (ConvertTo-J @((New-Merged 10 $t4['zlate'])))),
    (New-CoordRule '--head kfeat ' (ConvertTo-J @((New-Merged 11 $t4['kfeat'])))),
    (New-CoordRule '.' '[]'))
$r = Invoke-Prune -Repos $fx4.Launch -Rules $rules4 -Extra "-SessionCwds `"$wtLoc`""
Assert-Has 'P19e a stacked base whose tip reached main is SAFE' $r ((Rb 'stacked2') + 'SAFE')
Assert-Has 'P20 a branch mid-rebase in a detached worktree is KEEP' $r ((Br 'rbx') + 'KEEP held by worktree .*wtRb')
Assert-Has 'P20 and so is its remote' $r ((Rb 'rbx') + 'KEEP worktree .*wtRb')
Assert-Has 'P20b a stacked base named in rebase-merge/update-refs is KEEP' $r ((Br 'urb') + 'KEEP held by worktree .*wtRb')
Assert-Has 'P20b and so is its remote' $r ((Rb 'urb') + 'KEEP worktree .*wtRb on the local urb is KEEP')
# Both lines, matched case-sensitively, also show the fixture made both refs.
Assert-Coord 'P24 branches whose names differ only in case are both KEEP' (([regex]::Matches($r.Out, '(?m)^branch (caseb|CaseB) @[0-9a-f]{12}: KEEP another local branch has the same name')).Count -eq 2) $r.Out
Assert-Has 'P21 a remote a KEEP worktree tracks under another name is KEEP' $r ((Rb 'upb') + 'KEEP worktree .*wtLoc on the local loc is KEEP')
Assert-Has 'P19a a branch the main checkout is on is KEEP' $r ((Br 'onmain') + 'KEEP checked out in the main checkout')
Assert-Has 'P19a a second worktree on it is KEEP' $r ((Wt $wtOn) + 'KEEP branch onmain is KEEP')
Assert-Has 'P19a its remote is KEEP' $r ((Rb 'onmain') + 'KEEP worktree ')
Assert-Has 'P19b merged into a stacked base not on main -> KEEP' $r ((Rb 'stacked') + "KEEP merged PR #3 went into 'stackbase'")
Assert-Has 'P19c Master is a protected name' $r ((Rb 'Master') + 'KEEP protected name')
Assert-Has 'P19 leaseb SAFE' $r ((Rb 'leaseb') + 'SAFE')
$other = Join-Path $root 'other-push.git'
Invoke-HookTestGit $fx4.Launch @('remote', 'set-url', '--add', '--push', 'origin', $fx4.Origin)
Invoke-HookTestGit $fx4.Launch @('remote', 'set-url', '--add', '--push', 'origin', $other)
$r = Invoke-Prune -Repos $fx4.Launch -Rules $rules4
Assert-Has 'P19d two push URLs -> remotes KEEP' $r ((Rb 'leaseb') + 'KEEP origin pushes to 2 URL')
Invoke-HookTestGit $fx4.Launch @('config', '--unset-all', 'remote.origin.pushurl')
# The lease: deleting the local leaseb fires this reference-transaction hook, which moves
# origin's leaseb to another commit before the remote delete runs, and (round 4) adds a
# worktree on zlate, SAFE at scan time, before its own delete: zlate and origin/zlate stay.
$hooks = Join-Path $root 'hooks4'
[void][IO.Directory]::CreateDirectory($hooks)
$originSh = $fx4.Origin.Replace('\', '/')
$launchSh = $fx4.Launch.Replace('\', '/')
$wtZ = Join-Path $fx4.Base 'wtZ'
$wtZSh = $wtZ.Replace('\', '/')
$wtK2 = Join-Path $fx4.Base 'wtK2'
$wtK2Sh = $wtK2.Replace('\', '/')
$hook = "#!/bin/sh`n[ `"`$1`" = committed ] || exit 0`nwhile read old new ref; do`n  if [ `"`$ref`" = refs/heads/leaseb ] && [ `"`$new`" = 0000000000000000000000000000000000000000 ]; then`n    git --git-dir=`"$originSh`" update-ref refs/heads/leaseb $($t4['stacked'])`n    (unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR; git -C `"$launchSh`" worktree add --quiet `"$wtZSh`" zlate; git -C `"$launchSh`" worktree add --quiet `"$wtK2Sh`" kfeat) >/dev/null 2>&1`n  fi`ndone`nexit 0`n"
[System.IO.File]::WriteAllText((Join-Path $hooks 'reference-transaction'), $hook, $coordUtf8)
Invoke-HookTestGit $fx4.Launch @('config', 'core.hooksPath', $hooks)
$r = Invoke-Prune -Repos $fx4.Launch -Rules $rules4 -Extra '-Apply'
Assert-Has 'P11 the local branch was deleted' $r '(?m)^APPLY branch leaseb: deleted'
Assert-Has 'P11 a remote tip that moved after the scan is not deleted' $r '(?m)^APPLY remote origin/leaseb: FAILED .*still on origin'
Assert-Coord 'P11 origin keeps the new tip' ((Get-CoordRemoteRef $fx4 'refs/heads/leaseb') -ceq $t4['stacked']) (Get-CoordRemoteRef $fx4 'refs/heads/leaseb')
Assert-Coord 'P11 a failed apply exits 1' ($r.Code -eq 1) "exit=$($r.Code)"
Assert-Coord 'P25 the hook did add the worktree on zlate' (Test-Path -LiteralPath $wtZ) $r.Out
Assert-Has 'P25 a branch a worktree took since the scan is not deleted' $r '(?m)^APPLY branch zlate: FAILED \(skipped: a worktree is on it now\)'
Assert-Has 'P25 and its origin branch stays' $r '(?m)^APPLY remote origin/zlate: FAILED \(skipped: the local zlate stays: a worktree is on it now\)'
Assert-Coord 'P25 origin zlate still there' ((Get-CoordRemoteRef $fx4 'refs/heads/zlate') -ceq $t4['zlate']) ''
Assert-Coord 'P25b the hook did add the worktree on kfeat' (Test-Path -LiteralPath $wtK2) $r.Out
Assert-Has 'P25b origin/kfeat was SAFE at scan time' $r ((Rb 'kfeat') + 'SAFE')
Assert-Has 'P25b a worktree added on its KEEP local keeps it on origin' $r '(?m)^APPLY remote origin/kfeat: FAILED \(skipped: a worktree is on the local kfeat now\)'
Assert-Coord 'P25b origin kfeat still there' ((Get-CoordRemoteRef $fx4 'refs/heads/kfeat') -ceq $t4['kfeat']) ''
Assert-Coord 'P11 the last line counts them' ($r.Last -match '; applied \d+, failed 4$') $r.Last
# P26: a symbolic branch ref to main, at main's tip and "merged" there, is KEEP; main survives -Apply.
Invoke-HookTestGit $fx4.Launch @('config', '--unset', 'core.hooksPath')
Invoke-HookTestGit $fx4.Launch @('symbolic-ref', 'refs/heads/symb', 'refs/heads/main')
$mainTip = Get-CoordGitOut $fx4.Launch @('rev-parse', 'refs/heads/main')
$rules4s = @((New-CoordRule '--head symb ' (ConvertTo-J @((New-Merged 12 $mainTip))))) + $rules4
$r = Invoke-Prune -Repos $fx4.Launch -Rules $rules4s -Extra '-Apply'
Assert-Has 'P26 a symbolic branch ref is KEEP' $r ((Br 'symb') + 'KEEP a symbolic ref to refs/heads/main')
Assert-HasNot 'P26 nothing applied to it' $r '(?m)^APPLY branch symb'
Assert-Coord 'P26 main survives' ((Get-CoordGitOut $fx4.Launch @('rev-parse', '--verify', '--quiet', 'refs/heads/main')) -ceq $mainTip) ''

# ---- P10: -Apply -------------------------------------------------------------------
Write-Host "(P10) -Apply"
Set-PruneLedger @(
    "| L1 | $($fx.Launch) | s1 | $wtL | ledg-other | docs/** | | RUNNING |",
    "| L2 | $($fx.Launch) | s2 | C:\nowhere | ledgb | docs/** | | PR-OPEN |"
)
$heldProc = Start-Process -FilePath 'powershell.exe' -WorkingDirectory $wtH -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 300' -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 2
$r = Invoke-Prune -Extra "-SessionCwds `"$(Join-Path $wtS 'docs\sub')`" -Apply"
if ($heldProc) { try { Stop-Process -Id $heldProc.Id -Force -ErrorAction SilentlyContinue } catch { } }
Assert-Coord 'P10 exits 0' ($r.Code -eq 0) "exit=$($r.Code)`n$($r.Out)`nerr: $($r.Err)"
Assert-Has 'P29 a worktree git removed but for an empty folder a process holds is removed, not FAILED' $r ('(?m)^APPLY worktree ' + [regex]::Escape($wtH) + ': removed \(git exit 255; empty folder left, probably in use\)')
Assert-Has 'P29 its branch is deleted' $r '(?m)^APPLY branch held: deleted'
Assert-Has 'P29 and its origin branch' $r '(?m)^APPLY remote origin/held: deleted'
Assert-Has 'P10 worktree removed' $r ('(?m)^APPLY worktree ' + [regex]::Escape($wtA) + ': removed')
Assert-Has 'P10 branch deleted' $r '(?m)^APPLY branch done-a: deleted'
Assert-Has 'P10 remote deleted' $r '(?m)^APPLY remote origin/done-a: deleted'
Assert-Coord 'P10 wtA folder gone' (-not (Test-Path -LiteralPath $wtA)) $wtA
Assert-Coord 'P10 local done-a gone' (-not (Get-CoordGitOut $fx.Launch @('for-each-ref', 'refs/heads/done-a'))) ''
Assert-Coord 'P10 origin done-a gone' (-not (Get-CoordRemoteRef $fx 'refs/heads/done-a')) ''
Assert-Coord 'P10 cache worktree removed (ignored caches do not block)' (-not (Test-Path -LiteralPath $wtC)) $r.Out
Assert-Coord 'P10 KEEP worktree with _inbox stays' (Test-Path -LiteralPath (Join-Path $wtI '_inbox\designer.zip')) ''
Assert-Coord 'P10 KEEP moved stays locally' ((Get-CoordGitOut $fx.Launch @('rev-parse', 'refs/heads/moved')) -ceq $tip['moved']) ''
Assert-Coord 'P10 KEEP moved stays on origin' ((Get-CoordRemoteRef $fx 'refs/heads/moved') -ceq $tip['moved']) ''
Assert-Coord 'P10 KEEP ledgb stays' ((Get-CoordRemoteRef $fx 'refs/heads/ledgb') -ceq $tip['ledgb']) ''
Assert-Coord 'P10 a live session worktree keeps its remote branch' ((Get-CoordRemoteRef $fx 'refs/heads/sess') -ceq $tip['sess']) ''
Assert-Coord 'P10 the clean twin on a dirty-held branch stays' (Test-Path -LiteralPath $wtTw2) ''
Assert-Coord 'P10 main stays' ([bool](Get-CoordRemoteRef $fx 'refs/heads/main')) ''
Assert-Coord 'P10 last line counts applied' ($r.Last -match '^PRUNE-SCAN: \d+ SAFE, \d+ KEEP; applied \d+, failed 0$') $r.Last
$safeCount = @(([regex]::Matches($r.Out, '(?m)^(worktree|branch|remote) .*: SAFE'))).Count
$applyCount = @(([regex]::Matches($r.Out, '(?m)^APPLY '))).Count
Assert-Coord 'P10 one APPLY line per SAFE item' ($safeCount -gt 0 -and $safeCount -eq $applyCount) "safe=$safeCount apply=$applyCount"
$r = Invoke-Prune -Extra "-SessionCwds `"$(Join-Path $wtS 'docs\sub')`""
Assert-HasNot 'P10 a rerun finds done-a gone' $r '(?m)^(branch|remote origin/)done-a '

# P29 negative: git cannot delete a file inside (a disposable build/ file this process holds open),
# so the folder is left WITH a file in it: still FAILED, the branch and its origin branch stay.
Write-Host "(P29) a leftover folder that is not empty"
$tip['heldfile'] = New-CoordBranch $fx 'heldfile' -Write @{ 'docs/heldfile.md' = "heldfile`n" }
Invoke-HookTestGit $fx.Launch @('fetch', '--quiet', 'origin')
Invoke-HookTestGit $fx.Launch @('branch', '--quiet', 'heldfile', 'origin/heldfile')
$wtHf = Add-Wt 'wtHf' 'heldfile'
Set-CoordFile $wtHf 'build/lock.bin' "x`n"
$lockFs = [System.IO.File]::Open((Join-Path $wtHf 'build\lock.bin'), 'Open', 'Read', 'None')
$rulesF = @((New-CoordRule '--state merged --head heldfile ' (ConvertTo-J @((New-Merged 80 $tip['heldfile']))))) + $rulesOk
try { $r = Invoke-Prune -Rules $rulesF -Extra '-Apply' } finally { $lockFs.Close() }
Assert-Has 'P29 neg: the worktree was SAFE at scan time' $r ((Wt $wtHf) + 'SAFE')
Assert-Has 'P29 neg: a folder that still holds a file is FAILED' $r ('(?m)^APPLY worktree ' + [regex]::Escape($wtHf) + ': FAILED')
Assert-HasNot 'P29 neg: not reported removed' $r ('(?m)^APPLY worktree ' + [regex]::Escape($wtHf) + ': removed')
Assert-Has 'P29 neg: its branch is skipped' $r '(?m)^APPLY branch heldfile: FAILED \(skipped: its worktree was not removed\)'
Assert-Coord 'P29 neg: its branch is still there' ((Get-CoordGitOut $fx.Launch @('rev-parse', 'refs/heads/heldfile')) -ceq $tip['heldfile']) ''
Assert-Coord 'P29 neg: and so is its origin branch' ((Get-CoordRemoteRef $fx 'refs/heads/heldfile') -ceq $tip['heldfile']) ''
Assert-Coord 'P29 neg: a failed apply exits 1' ($r.Code -eq 1) "exit=$($r.Code)"

# ---- F37, F38, F39 (ported from the private toolkit's prune-scan fixes) -----------------------
Set-PruneLedger @()

# F37: a worktree that is not on the scanned branch/HEAD any more when -Apply gets to it. A git shim
# (git.cmd, first on PATH) acts on the SECOND `status --porcelain --untracked-files=all` of the worktree whose
# folder name contains GIT_SHIM_MATCH (the scan makes the first, the apply's content re-read the second): it runs
# GIT_SHIM_ARGS in that worktree, then the status. The tree stays clean either way, so the content re-read passes.
Write-Host "(F37) a worktree changed between the scan and the apply"
$shimDir = Join-Path $root 'gitshim'
[void][IO.Directory]::CreateDirectory($shimDir)
$realGit = [string](@(Get-Command git -CommandType Application)[0].Source)
$shim = "@echo off`r`n" +
    "if /i not `"%~1`"==`"-C`" goto run`r`n" +
    "if /i not `"%~3`"==`"status`" goto run`r`n" +
    "if not `"%~4`"==`"--porcelain`" goto run`r`n" +
    "if not `"%~5`"==`"--untracked-files`" goto run`r`n" +
    "if not `"%~6`"==`"all`" goto run`r`n" +
    "if not `"%~7`"==`"`" goto run`r`n" +
    "echo `"%~2`"| findstr /i /c:`"%GIT_SHIM_MATCH%`" >nul`r`n" +
    "if errorlevel 1 goto run`r`n" +
    "if not exist `"%GIT_SHIM_MARK%`" goto first`r`n" +
    "if exist `"%GIT_SHIM_DONE%`" goto run`r`n" +
    "echo x> `"%GIT_SHIM_DONE%`"`r`n" +
    "`"%GIT_SHIM_REAL%`" -C `"%~2`" %GIT_SHIM_ARGS% >nul 2>&1`r`n" +
    "goto run`r`n" +
    ":first`r`n" +
    "echo x> `"%GIT_SHIM_MARK%`"`r`n" +
    ":run`r`n" +
    "`"%GIT_SHIM_REAL%`" %*`r`n" +
    "exit /b %errorlevel%`r`n"
[System.IO.File]::WriteAllText((Join-Path $shimDir 'git.cmd'), $shim, [System.Text.Encoding]::ASCII)
$fx5 = New-CoordFixture $root 'fx5'
$t5 = @{}
function New-ShimEnv([string]$Match, [string]$Tag, [string]$ShimArgs) {
    return @{ PATH = "$shimDir;$coordStubDir;$env:PATH"; GIT_SHIM_REAL = $realGit; GIT_SHIM_MATCH = $Match; GIT_SHIM_ARGS = $ShimArgs
        GIT_SHIM_MARK = (Join-Path $root "shim-$Tag.mark"); GIT_SHIM_DONE = (Join-Path $root "shim-$Tag.done") }
}
function New-Rules5([string]$Head, [string]$Sha) {
    return @((New-CoordRule '--state open ' '[]'), (New-CoordRule "--head $Head " (ConvertTo-J @((New-Merged 91 $Sha)))), (New-CoordRule '.' '[]'))
}
# A merged branch f37<Tag> on a clean worktree wt<Tag>37; the shim then runs $ShimArgs in it at the apply's content
# re-read. $Why matches what the FAILED line says changed. An empty $Why has no shim match: nothing changes, it is removed.
function Test-F37Case([string]$Tag, [string]$ShimArgs, [string]$Why, [scriptblock]$Prep = $null) {
    $br = "f37$Tag"
    $t5[$br] = New-CoordBranch $fx5 $br -Write @{ "docs/$br.md" = "$br`n" }
    Invoke-HookTestGit $fx5.Launch @('fetch', '--quiet', 'origin')
    Invoke-HookTestGit $fx5.Launch @('branch', '--quiet', $br, "origin/$br")
    if ($Prep) { & $Prep $br }
    $wt = Join-Path $fx5.Base "wt${Tag}37"
    Invoke-HookTestGit $fx5.Launch @('worktree', 'add', '--quiet', $wt, $br)
    $match = if ($Why) { "wt${Tag}37" } else { 'no-such-worktree-name' }
    $sh = New-ShimEnv $match $Tag $ShimArgs
    $r = Invoke-Prune -Repos $fx5.Launch -Rules (New-Rules5 $br $t5[$br]) -Extra '-Apply' -Env $sh
    Assert-Has "F37$Tag the worktree was SAFE at scan time" $r ((Wt $wt) + 'SAFE')
    if (-not $Why) {
        Assert-Has 'F37c an unchanged worktree is still removed' $r ('(?m)^APPLY worktree ' + [regex]::Escape($wt) + ': removed')
        Assert-Has 'F37c and its branch deleted' $r "(?m)^APPLY branch ${br}: deleted"
        Assert-Coord 'F37c exits 0' ($r.Code -eq 0) "exit=$($r.Code)`n$($r.Out)"
        return
    }
    Assert-Coord "F37$Tag the shim acted in the worktree (so the case is not vacuous)" (Test-Path -LiteralPath $sh.GIT_SHIM_DONE) "exit=$($r.Code)`n$($r.Out)`nerr: $($r.Err)"
    Assert-Has "F37$Tag a worktree that changed since the scan is FAILED, untouched, saying what" $r ('(?m)^APPLY worktree ' + [regex]::Escape($wt) + ': FAILED \(changed since the scan: ' + $Why + '; untouched\)')
    Assert-Coord "F37$Tag its folder is still there" (Test-Path -LiteralPath $wt) $r.Out
    Assert-Has "F37$Tag its branch is skipped" $r "(?m)^APPLY branch ${br}: FAILED \(skipped: its worktree was not removed\)"
    Assert-Coord "F37$Tag its origin branch stays" ((Get-CoordRemoteRef $fx5 "refs/heads/$br") -ceq $t5[$br]) ''
    Assert-Coord "F37$Tag a failed apply exits 1" ($r.Code -eq 1) "exit=$($r.Code)"
}
# a: switched to another branch at the SAME commit (only the branch name tells).
Test-F37Case 'a' 'checkout --quiet f37same' 'it is on branch f37same now, not f37a' { param($b) Invoke-HookTestGit $fx5.Launch @('branch', '--quiet', 'f37same', $b) }
# b: still on the branch, but its HEAD moved (a commit made since the scan).
Test-F37Case 'b' '-c user.name=t -c user.email=t@t commit --quiet --allow-empty -m moved' 'its HEAD moved from [0-9a-f]{12} to [0-9a-f]{12}'
# d: detached at the same commit. e: locked.
Test-F37Case 'd' 'checkout --quiet --detach' 'it is detached now'
Test-F37Case 'e' 'worktree lock --reason prune-test .' 'it is locked now'
# c: nothing changes (the shim matches no worktree): removed as before, so the new check blocks nothing it should not.
Test-F37Case 'c' 'checkout --quiet f37same' ''

# F39: remote.origin.fetch narrowed to one other branch: `git fetch --prune origin` leaves origin/main stale.
# stk was merged into stackbase; stackbase then reached main on origin. The truth is SAFE.
Write-Host "(F39) a narrowed fetch refspec"
$fx6 = New-CoordFixture $root 'fx6'
$t6 = @{}
$t6['stk'] = New-CoordBranch $fx6 'stk' -Write @{ 'docs/stk.md' = "stk`n" }
$t6['stackbase'] = New-CoordBranch $fx6 'stackbase' -From 'origin/stk' -Write @{ 'docs/sb.md' = "sb`n" }
Invoke-HookTestGit $fx6.Launch @('fetch', '--quiet', 'origin')
Invoke-HookTestGit $fx6.Launch @('branch', '--quiet', 'stk', 'origin/stk')
Invoke-HookTestGit $fx6.Launch @('config', 'remote.origin.fetch', '+refs/heads/stackbase:refs/remotes/origin/stackbase')
$null = Merge-CoordIntoMain $fx6 $t6['stackbase']
$staleMain = Get-CoordGitOut $fx6.Launch @('rev-parse', 'refs/remotes/origin/main')
$rules6 = @((New-CoordRule '--state open ' '[]'), (New-CoordRule '--head stk ' (ConvertTo-J @([ordered]@{ number = 92; headRefOid = $t6['stk']; isCrossRepository = $false; baseRefName = 'stackbase' }))), (New-CoordRule '.' '[]'))
$r = Invoke-Prune -Repos $fx6.Launch -Rules $rules6
Assert-Coord 'F39 the fixture left origin/main stale before the scan' ($staleMain -cne (Get-CoordRemoteRef $fx6 'refs/heads/main')) "stale=$staleMain"
Assert-Has 'F39 a branch merged into a base that reached main is SAFE although the fetch refspec is narrowed' $r ((Br 'stk') + 'SAFE')
Assert-Has 'F39 and its origin branch' $r ((Rb 'stk') + 'SAFE')
Assert-Coord 'F39 the scan refreshed origin/main by name' ((Get-CoordGitOut $fx6.Launch @('rev-parse', 'refs/remotes/origin/main')) -ceq (Get-CoordRemoteRef $fx6 'refs/heads/main')) ''
Assert-Coord 'F39 exits 0' ($r.Code -eq 0) "exit=$($r.Code)`n$($r.Out)"

# F38: a listed ledger that cannot be seen because access to it is denied is COULD NOT CHECK, not "no ledger".
Write-Host "(F38) an access-denied ledger"
$todayQ = [DateTime]::Now.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
$idx7 = Join-Path $root 'index7'
[void][IO.Directory]::CreateDirectory($idx7)
$denied = Join-Path $root 'denied-ledgers'
[void][IO.Directory]::CreateDirectory($denied)
$deniedLedger = Join-Path $denied 'ledger.md'
[System.IO.File]::WriteAllText($deniedLedger, "# L`n`n## Tracks`n`n| Track | Repo | Session | Cwd | Branch | Scope | PR | Status |`n|---|---|---|---|---|---|---|---|`n| DN | $($fx6.Launch) | s | | stk | ** | | RUNNING |`n`n## Log`n", $coordUtf8)
[System.IO.File]::WriteAllText((Join-Path $idx7 "$todayQ.ledgers"), "$deniedLedger`n", $coordUtf8)
$me = "$env:USERDOMAIN\$env:USERNAME"
$null = & icacls $denied /deny "${me}:(OI)(CI)F" 2>&1
$seen = $true
try { $seen = Test-Path -LiteralPath $deniedLedger -ErrorAction SilentlyContinue } catch { $seen = $false }
if ($seen) { Write-CoordUnchecked 'F38 an access-denied ledger' 'icacls deny did not hide the file from Test-Path on this host'; $null = & icacls $denied /remove:d $me 2>&1 }
else {
    try { $r = Invoke-Prune -Repos $fx6.Launch -Rules $rules6 -NoLedger -Env @{ COORD_INDEX_DIR = $idx7 } }
    finally { $null = & icacls $denied /remove:d $me 2>&1 }
    Assert-Coord 'F38 a listed ledger that is access-denied -> exit 2' ($r.Code -eq 2) "exit=$($r.Code)`n$($r.Out)"
    Assert-Coord 'F38 the last line says the ledger is unreadable' ($r.Last -match 'COULD NOT CHECK: .*ledger .*denied-ledgers.*unreadable') $r.Last
    Assert-HasNot 'F38 nothing SAFE' $r '(?m): SAFE'
    Assert-Coord 'F38 the ACL was restored' ((Test-Path -LiteralPath $deniedLedger)) 'deny ACE still in place'
}
# A listed ledger that simply does not exist is still skipped (the old rule, unchanged).
[System.IO.File]::WriteAllText((Join-Path $idx7 "$todayQ.ledgers"), (Join-Path $root 'no-such-ledger.md') + "`n", $coordUtf8)
$r = Invoke-Prune -Repos $fx6.Launch -Rules $rules6 -NoLedger -Env @{ COORD_INDEX_DIR = $idx7 }
Assert-Has 'F38 neg: a listed ledger that does not exist is skipped, said as no ledger' $r '(?m)^ledger: none \('
Assert-Coord 'F38 neg: and the scan runs' ($r.Code -eq 0) "exit=$($r.Code)`n$($r.Out)"

if (Test-Path -LiteralPath (Join-Path $wtJ 'build\link')) { Remove-CoordJunction (Join-Path $wtJ 'build\link') }
if (Test-Path -LiteralPath (Join-Path $fx.Base 'jdir')) { Remove-CoordJunction (Join-Path $fx.Base 'jdir') }
Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-CoordUncheckedSummary
Write-Host "Passed: $script:coordPass  Failed: $script:coordFail"
if ($script:coordFail -gt 0) { exit 1 }
exit 0
