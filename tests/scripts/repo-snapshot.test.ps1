# Tests for scripts/repo-snapshot.ps1: the start-of-window read of one or more
# repos. Ported from the private coordinate toolkit (repo-snapshot.test.ps1),
# 2026-10-28. gh is the stub in tests\stubs; git runs for real against a bare
# origin. The rows keep their private names (N0-N15) so one can be traced to its
# twin; N16-N18 are new (the last line against what the skill names, a handover
# row, and the ledger left alone).
#
#   N0  every section header is printed
#   N1  no ledger -> "-- tracks: no ledger"; open PRs get files, checks and a
#       conflict preview, and are marked "not in ledger"
#   N2  ledger tracks: an out-of-scope file is flagged, a conflict lists its
#       path, a clean branch reads "no conflicts"
#   N3  a track branch without a PR -> "no PR yet", with its head
#   N4  stale merged local branches: listed; one checked out in a worktree is
#       marked "held by worktree"; a reused name whose tip differs from the
#       merged head is shown, not flagged (N4b); a squash-merged branch (tip =
#       the PR's headRefOid, not on main) is flagged (N4c)
#   N5  worktree locks: pid alive, pid not running (flagged), unlocked
#   N6  -Ledger from another place: Repo as a full path (a), as a unique folder
#       name (b); a folder name two repos share -> "ambiguous ledger row",
#       attributed to neither (c)
#   N7  the last line is "SNAPSHOT: <n> repo(s); attention: ..." naming each item
#   N8  read-only: local branches, HEAD, index and working tree unchanged
#   N9  gh failing -> "unknown (gh failed)", never "(none)"; malformed gh JSON ->
#       "unknown (gh output invalid)"; unrelated history -> "preview failed",
#       never "no conflicts"
#   N10 the default ledger is found from a linked worktree (the main checkout's)
#   N11 a failed fetch is printed and named in attention
#   N12 a failing check on a PR not in the ledger reaches attention
#   N13 a PR head not fetched here reads "unknown" and "preview failed"; that
#       unknown preview is not an attention item (the PR's "not in ledger"
#       still is, when a ledger exists)
#   N14 a local branch named origin/main does not shadow the remote ref
#   N15 branch names match case-sensitively (TRK-OK is not the track trk-ok)
#   N16 the last line is the one the skill names (SKILL.md, Start of a
#       coordination window): the skill's line with <n> and the items filled in
#       is the output's last line, byte for byte, with and without attention
#   N17 the newest handover is named (the newest .md file of .claude/handovers,
#       README.md excluded); none, and no folder, read as such
#   N18 the ledger and the handovers folder are byte-unchanged by a run
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\scripts\repo-snapshot.test.ps1 [-ScriptPath <mutant copy>]
# Exit: 0 = all passed, 1 = a case failed.
param([string]$ScriptPath = '')

try { . (Join-Path $PSScriptRoot '../fixtures/hook-test-fixture.ps1') } catch { Write-Error "could not load hook-test-fixture.ps1: $_"; exit 1 }
Clear-HookRunnerGitEnv
. (Join-Path $PSScriptRoot '../fixtures/coord-test-fixture.ps1')
$ErrorActionPreference = 'Stop'

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('repo-snapshot-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory($root)
$today = [DateTime]::Now.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)

# ---- fixture ---------------------------------------------------------------
$fx = New-CoordFixture $root 'fx'
$ok = New-CoordBranch $fx 'trk-ok' -Write @{ 'docs/t.md' = "t`n" }
$out = New-CoordBranch $fx 'trk-out' -Write @{ 'docs/o.md' = "o`n"; 'src/out.txt' = "x`n" }
$baseBefore = Get-CoordGitOut $fx.Work @('rev-parse', 'origin/main')
$a = New-CoordBranch $fx 'pre-a' -Write @{ 'src/app.txt' = "line1`nA`nline3`n" }
$null = Merge-CoordIntoMain $fx $a
$conf = New-CoordBranch $fx 'trk-conf' -From $baseBefore -Write @{ 'src/app.txt' = "line1`nB`nline3`n" }
$stray = New-CoordBranch $fx 'stray' -Write @{ 'docs/s.md' = "s`n" }
Invoke-HookTestGit $fx.Work @('checkout', '--quiet', '--orphan', 'trk-orphan')
Invoke-HookTestGit $fx.Work @('rm', '--quiet', '-r', '-f', '--', '.')
Set-CoordFile $fx.Work 'lonely.txt' "l`n"
Invoke-HookTestGit $fx.Work @('-c', 'core.autocrlf=false', 'add', '-A')
Invoke-HookTestGit $fx.Work @('-c', 'core.autocrlf=false', 'commit', '--quiet', '-m', 'orphan')
Invoke-HookTestGit $fx.Work @('push', '--quiet', 'origin', 'HEAD:refs/heads/trk-orphan')

Invoke-HookTestGit $fx.Launch @('branch', 'old-done')
Invoke-HookTestGit $fx.Launch @('branch', 'held-done')
# `reused`: same name as merged PR #8, but it carries a commit that is on
# neither origin/main nor that PR's head (new work, must not be flagged).
Invoke-HookTestGit $fx.Launch @('fetch', '--quiet', 'origin')
Invoke-HookTestGit $fx.Launch @('branch', 'reused', $stray)
# `squashed`: merged PR #9 by squash: its head commit ($ok, from trk-ok) is NOT
# on origin/main, but the local tip IS that PR's headRefOid -> stale.
Invoke-HookTestGit $fx.Launch @('branch', 'squashed', $ok)
$wtA = Join-Path $fx.Base 'wtA'
$wtB = Join-Path $fx.Base 'wtB'
$wtC = Join-Path $fx.Base 'wtC'
Invoke-HookTestGit $fx.Launch @('worktree', 'add', '--quiet', $wtA, 'held-done')
New-HookTestWorktree -Repo $fx.Launch -Path $wtB -Branch 'wt-b'
New-HookTestWorktree -Repo $fx.Launch -Path $wtC -Branch 'wt-c'
Invoke-HookTestGit $fx.Launch @('worktree', 'lock', '--reason', "claude session a (pid $PID)", $wtA)
Invoke-HookTestGit $fx.Launch @('worktree', 'lock', '--reason', 'claude session b (pid 999999)', $wtB)

$green = @((New-CoordCheckRun 'build'))
$red = @((New-CoordCheckRun 'build'), (New-CoordCheckRun 'unit' 'COMPLETED' 'FAILURE'))
function New-ListItem([int]$N, [string]$Ref, [string]$Sha, [object[]]$Checks, [string]$State = 'OPEN') {
    return [ordered]@{ number = $N; title = "t$N"; state = $State; headRefName = $Ref; headRefOid = $Sha; isDraft = $false; statusCheckRollup = @($Checks) }
}
function ConvertTo-J($o) { return (ConvertTo-Json -InputObject @($o) -Depth 10 -Compress) }
$openJson = ConvertTo-J @((New-ListItem 21 'trk-ok' $ok $green), (New-ListItem 22 'trk-out' $out $red), (New-ListItem 30 'stray' $stray $green))
$rulesOk = @(
    (New-CoordRule '^pr list .*--head trk-ok\b' (ConvertTo-J @((New-ListItem 21 'trk-ok' $ok $green)))),
    (New-CoordRule '^pr list .*--head trk-out\b' (ConvertTo-J @((New-ListItem 22 'trk-out' $out $red)))),
    (New-CoordRule '^pr list .*--head ' '[]'),
    (New-CoordRule '^pr list .*--state open' $openJson),
    (New-CoordRule '^pr list .*--state merged' (ConvertTo-J @([ordered]@{ number = 5; headRefName = 'old-done'; headRefOid = ('1' * 40) }, [ordered]@{ number = 6; headRefName = 'held-done'; headRefOid = ('2' * 40) }, [ordered]@{ number = 8; headRefName = 'reused'; headRefOid = ('3' * 40) }, [ordered]@{ number = 9; headRefName = 'squashed'; headRefOid = $ok }))),
    (New-CoordRule '^run list' '[]')
)

$ledgerPath = Join-Path $fx.Launch ".claude\coordination\$today.md"
function Set-SnapLedger([string]$Path, [string[]]$Rows) {
    $t = "# Coordination ledger`n`n## Tracks`n`n| Track | Repo | Session | Cwd | Branch | Scope | PR | Status |`n|---|---|---|---|---|---|---|---|`n" + (($Rows | ForEach-Object { "$_`n" }) -join '')
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [System.IO.File]::WriteAllText($Path, $t, $coordUtf8)
}

function Invoke-Snap {
    param([string]$Cwd = $fx.Launch, [string]$Extra = '', [object[]]$Rules = $rulesOk)
    return (Invoke-CoordScript -Name 'repo-snapshot.ps1' -Cwd $Cwd -ScriptArgs $Extra -Rules $Rules -ScriptPath $ScriptPath)
}

function Get-State($Repo) {
    return ((Get-CoordGitOut $Repo @('for-each-ref', '--format=%(refname) %(objectname)', 'refs/heads')) + '|' +
        (Get-CoordGitOut $Repo @('rev-parse', 'HEAD')) + '|' + (Get-CoordGitOut $Repo @('status', '--porcelain')))
}

function Assert-Has([string]$Case, $R, [string]$Pattern) {
    Assert-Coord "$Case output matches /$Pattern/" ($R.Out -match $Pattern) "exit=$($R.Code)`n$($R.Out)`nerr: $($R.Err)"
}
function Assert-HasNot([string]$Case, $R, [string]$Pattern) {
    Assert-Coord "$Case output does not match /$Pattern/" (-not ($R.Out -match $Pattern)) $R.Out
}

# ---- N0, N1: no ledger ----------------------------------------------------
Write-Host "(N0, N1) no ledger"
$before = Get-State $fx.Launch
$r = Invoke-Snap
Assert-Coord 'N1 exits 0' ($r.Code -eq 0) "$($r.Code) $($r.Err)"
foreach ($h in '-- origin/main', '-- local:', '-- open PRs', '-- remote branches', '-- worktrees', '-- newest handover', '-- latest CI run on main') {
    Assert-Coord "N0 keeps the v1 section '$h'" ($r.Out.Contains($h)) $r.Out
}
Assert-Has 'N1' $r '(?m)^-- tracks: no ledger'
Assert-Has 'N1' $r '(?m)^\s+#21 .*not in ledger'
Assert-Has 'N1' $r '(?m)^\s+#22 .*not in ledger'
Assert-Has 'N1 #22 files' $r '(?ms)#22 .*?files: 2 changed'
Assert-Has 'N1 #22 checks' $r '(?ms)#22 .*?checks: 1 passed, 0 pending, 1 failing'
Assert-Has 'N1 #21 preview' $r '(?ms)#21 .*?conflict preview: no conflicts'
Assert-Coord 'N12 a failing check on a PR not in the ledger reaches attention' ($r.Last.Contains('PR #22 failing')) $r.Last
Assert-Coord 'N1 without a ledger, "not in ledger" is not an attention item' (-not $r.Last.Contains('not in ledger')) $r.Last
Assert-Coord 'N8 read-only (no ledger run)' ((Get-State $fx.Launch) -ceq $before)

# ---- N2-N5, N7: with today's ledger -----------------------------------------
Write-Host "(N2-N5, N7) with today's ledger"
Set-SnapLedger $ledgerPath @(
    "| T1 | $($fx.Launch) | s1 | c1 | trk-ok | docs/** | #21 | live |",
    "| T2 | $($fx.Launch) | s2 | c2 | trk-out | docs/** | #22 | live |",
    "| T3 | $($fx.Launch) | s3 | c3 | trk-conf | src/** | | live |"
)
$before = Get-State $fx.Launch
$r = Invoke-Snap
Assert-Coord 'N2 exits 0' ($r.Code -eq 0) "$($r.Code) $($r.Err)"
Assert-Has 'N2 tracks header names the ledger' $r ('(?m)^-- tracks \(ledger .*' + [regex]::Escape("$today.md"))
Assert-Has 'N2 T1 clean' $r '(?ms)\[T1\] trk-ok.*?conflict preview: no conflicts'
Assert-Has 'N2 T1 in scope' $r '(?ms)\[T1\] trk-ok.*?files: 1 changed, 0 out of scope'
Assert-Has 'N2 T2 out of scope' $r '(?ms)\[T2\] trk-out.*?files: 2 changed, 1 out of scope: src/out\.txt'
Assert-Has 'N2 T2 failing check' $r '(?ms)\[T2\] trk-out.*?checks: 1 passed, 0 pending, 1 failing'
Assert-Has 'N2 T3 conflict' $r '(?ms)\[T3\] trk-conf.*?conflict preview: 1 conflicted: src/app\.txt'
Assert-Has 'N3 T3 no PR' $r ('(?ms)\[T3\] trk-conf @ ' + $conf.Substring(0, 12) + '.*?PR: no PR yet')
Assert-Has 'N2 #30 is not in the ledger' $r '(?m)^\s+#30 .*not in ledger'
Assert-HasNot 'N2 #21 is in the ledger' $r '(?m)^\s+#21 .*not in ledger'
Assert-Has 'N4 old-done stale' $r '(?m)^\s+old-done \(PR #5 merged\)\s*$'
Assert-Has 'N4 held-done held' $r ('(?m)^\s+held-done \(PR #6 merged\), held by worktree .*wtA')
Assert-Has 'N4b a reused name with new work is shown, not flagged' $r '(?m)^\s+reused - name matches merged PR #8, but the tip \w+ differs'
Assert-Coord 'N4b reused is not an attention item' (-not $r.Last.Contains('stale merged branch reused')) $r.Last
Assert-Has 'N4c a squash-merged branch (tip = the PR head, not on main) is stale' $r '(?m)^\s+squashed \(PR #9 merged\)\s*$'
Assert-Coord 'N4c it is an attention item' ($r.Last.Contains('stale merged branch squashed')) $r.Last
Assert-Has 'N5 wtA live lock' $r '(?m)wtA .*locked: claude session a \(pid \d+\) - pid alive'
Assert-Has 'N5 wtB dead lock' $r '(?m)wtB .*locked: claude session b \(pid 999999\) - pid 999999 not running'
Assert-Has 'N5 wtC unlocked' $r '(?m)wtC .*unlocked'
$last = $r.Last
Assert-Coord 'N7 last line is SNAPSHOT' ($last -match '^SNAPSHOT: 1 repo\(s\); attention: ') $last
foreach ($item in 'T2 out of scope', 'T3 conflict', 'T2 failing', 'stale lock wtB', 'stale merged branch old-done', 'PR #30 not in ledger') {
    Assert-Coord "N7 attention names '$item'" ($last.Contains($item)) $last
}
Assert-Coord 'N7 attention does not name T1' (-not $last.Contains('T1')) $last
Assert-Coord 'N8 read-only (ledger run)' ((Get-State $fx.Launch) -ceq $before)

# ---- N10: from a linked worktree --------------------------------------------
Write-Host "(N10) default ledger from a linked worktree"
$r = Invoke-Snap -Cwd $wtC -Extra "-Repos `"$($fx.Launch)`""
Assert-Has 'N10' $r ('(?m)^-- tracks \(ledger .*' + [regex]::Escape("launch\.claude\coordination\$today.md"))
Assert-Has 'N10 T2 seen' $r '\[T2\] trk-out'

# ---- N6: ledger repo matching -------------------------------------------------
Write-Host "(N6) ledger repo matching"
$fx2 = New-CoordFixture $root 'fx2'
$elsewhere = Join-Path $root 'ledger-elsewhere.md'
Set-SnapLedger $elsewhere @("| T9 | $($fx.Launch)\ | s | c | trk-out | docs/** | | live |", "| TX | C:\Elsewhere\other | s | c | x | ** | | live |")
$r = Invoke-Snap -Extra "-Repos `"$($fx.Launch)`" -Ledger `"$elsewhere`""
Assert-Has 'N6a full path with a trailing separator' $r '(?ms)\[T9\] trk-out.*?1 out of scope'
Assert-Has 'N6a rows for other repos are counted' $r '(?m)^-- ledger .* : 2 track row\(s\), 1 for repos not in -Repos'
Set-SnapLedger $elsewhere @("| T8 | launch | s | c | trk-out | docs/** | | live |")
$r = Invoke-Snap -Extra "-Repos `"$($fx.Launch)`" -Ledger `"$elsewhere`""
Assert-Has 'N6b unique folder name' $r '(?ms)\[T8\] trk-out.*?1 out of scope'
$r = Invoke-Snap -Extra "-Repos `"$($fx.Launch)`",`"$($fx2.Launch)`" -Ledger `"$elsewhere`""
Assert-HasNot 'N6c not attributed' $r '\[T8\] trk-out'
Assert-Has 'N6c ambiguous row reported' $r "ambiguous ledger row 'T8'"
Assert-Coord 'N6c attention names it' ($r.Last.Contains("ambiguous ledger row 'T8'")) $r.Last
Assert-Coord 'N6c two repos counted' ($r.Last -match '^SNAPSHOT: 2 repo\(s\)') $r.Last

# ---- N9: failures are unknown, never none ----------------------------------------
Write-Host "(N9) failures"
Set-SnapLedger $ledgerPath @(
    "| T1 | $($fx.Launch) | s1 | c1 | trk-ok | docs/** | #21 | live |",
    "| T7 | $($fx.Launch) | s7 | c7 | trk-orphan | ** | | live |"
)
$r = Invoke-Snap -Rules @((New-CoordRule '.' '' 1))
Assert-Has 'N9a open PRs unknown' $r '(?m)^-- open PRs\s*\r?\n\s+unknown \(gh failed\)'
Assert-Has 'N9a track PR unknown' $r '(?ms)\[T1\] trk-ok.*?PR: unknown \(gh failed\)'
Assert-Has 'N9a stale branches unknown' $r '(?m)^-- stale merged local branches\s*\r?\n\s+unknown \(gh failed\)'
Assert-HasNot 'N9a never (none) for PRs' $r '(?m)^-- open PRs\s*\r?\n\s+\(none\)'
Assert-Has 'N9b orphan preview failed' $r '(?ms)\[T7\] trk-orphan.*?conflict preview: preview failed'
Assert-HasNot 'N9b orphan never no conflicts' $r '(?ms)\[T7\] trk-orphan[^\[]*no conflicts'
Assert-Has 'N9b orphan files unknown' $r '(?ms)\[T7\] trk-orphan.*?files: unknown'
$r = Invoke-Snap -Rules @((New-CoordRule '^pr list' '{"not": "a list"'), (New-CoordRule '^run list' '[]'))
Assert-Has 'N9c malformed list JSON' $r '(?m)^-- open PRs\s*\r?\n\s+unknown \(gh output invalid\)'
Assert-Has 'N9c track PR invalid' $r '(?ms)\[T1\] trk-ok.*?PR: unknown \(gh output invalid\)'
# N9d: a list item without statusCheckRollup is invalid, not "0 checks".
$noRollup = '[{"number":21,"title":"t","headRefName":"trk-ok","headRefOid":"' + $ok + '","isDraft":false}]'
$r = Invoke-Snap -Rules @((New-CoordRule '^pr list .*--state open' $noRollup), (New-CoordRule '^pr list' '[]'), (New-CoordRule '^run list' '[]'))
Assert-Has 'N9d missing statusCheckRollup' $r '(?m)^-- open PRs\s*\r?\n\s+unknown \(gh output invalid\)'

# ---- N13, N15: PR heads read from headRefOid; case-sensitive branch match ----
Write-Host "(N13, N15) unknown PR head, case-only branch name"
Set-SnapLedger $ledgerPath @("| T1 | $($fx.Launch) | s1 | c1 | trk-ok | docs/** | #21 | live |")
$openOdd = ConvertTo-J @((New-ListItem 40 'fork-branch' ('e' * 40) $green), (New-ListItem 50 'TRK-OK' $ok $green))
$r = Invoke-Snap -Rules @((New-CoordRule '^pr list .*--state open' $openOdd), (New-CoordRule '^pr list' '[]'), (New-CoordRule '^run list' '[]'))
Assert-Has 'N13 a head not fetched here is unknown' $r '(?ms)#40 .*?files: unknown \(head eeeeeeeeeeee not fetched here\)'
Assert-Has 'N13 and its preview reads failed, never no conflicts' $r '(?ms)#40 .*?conflict preview: preview failed'
Assert-Coord 'N13 the unknown preview of an unfetched (fork) head is not an attention item' (-not $r.Last.Contains('PR #40 preview failed')) $r.Last
Assert-Has 'N15 TRK-OK is not the track trk-ok' $r '(?m)^\s+#50 TRK-OK .*not in ledger'

# ---- N11: fetch failure -----------------------------------------------------
Write-Host "(N11) fetch failure"
Invoke-HookTestGit $fx2.Launch @('remote', 'set-url', 'origin', (Join-Path $root 'no-such-origin.git'))
$r = Invoke-Snap -Cwd $fx2.Launch -Rules @((New-CoordRule '^pr list' '[]'), (New-CoordRule '^run list' '[]'))
Assert-Has 'N11 the failed fetch is printed' $r '(?m)^-- fetch: FAILED'
Assert-Coord 'N11 attention names it' ($r.Last.Contains('fetch failed')) $r.Last

# ---- N14: a local branch named origin/main does not shadow the remote ref ------
Write-Host "(N14) local branch origin/main"
Set-SnapLedger $ledgerPath @("| T2 | $($fx.Launch) | s2 | c2 | trk-out | docs/** | #22 | live |")
Invoke-HookTestGit $fx.Launch @('branch', 'origin/main', $out)
$r = Invoke-Snap
Assert-Has 'N14 T2 still diffs against the real origin/main' $r '(?ms)\[T2\] trk-out.*?files: 2 changed, 1 out of scope: src/out\.txt'
Invoke-HookTestGit $fx.Launch @('branch', '-D', 'origin/main')

# ---- N16-N18: the last line against the skill, the handover row, read-only ------
Write-Host "(N16-N18) skill line, newest handover, nothing written"
$fx3 = New-CoordFixture $root 'fx3'
$quiet = @((New-CoordRule '^pr list' '[]'), (New-CoordRule '^run list' '[]'))
$skillText = [System.IO.File]::ReadAllText((Join-Path (Split-Path -Parent $coordScriptsDir) 'skills/coordinate/SKILL.md'), $coordUtf8)
$sm = [regex]::Match($skillText, '(?m)^\s*(SNAPSHOT: <n> repo\(s\); attention: <items \| none>)\s*$')
Assert-Coord 'N16 the skill names the last line' $sm.Success
$r = Invoke-Snap -Cwd $fx3.Launch -Rules $quiet
if ($sm.Success) {
    $want = $sm.Groups[1].Value.Replace('<n>', '1').Replace('<items | none>', 'none')
    Assert-Coord 'N16 a clean repo ends with the skill''s line, attention: none' ($r.Last -ceq $want) "want: $want`nlast: $($r.Last)"
    $r2 = Invoke-Snap -Cwd $fx2.Launch -Rules $quiet
    $prefix = $sm.Groups[1].Value.Replace('<n>', '1').Replace('<items | none>', '')
    Assert-Coord 'N16 a repo with something to look at starts with the skill''s line' ($r2.Last.StartsWith($prefix, [StringComparison]::Ordinal) -and $r2.Last.Length -gt $prefix.Length -and -not $r2.Last.EndsWith('none')) $r2.Last
}
$hoDir = Join-Path $fx3.Launch '.claude\handovers'
Assert-Has 'N17 no handovers folder' $r '(?m)^-- newest handover\s*\r?\n\s+\(no \.claude/handovers\)'
[void][IO.Directory]::CreateDirectory($hoDir)
Set-CoordFile $hoDir 'README.md' "r`n"
$r = Invoke-Snap -Cwd $fx3.Launch -Rules $quiet
Assert-Has 'N17 only README.md in the folder' $r '(?m)^-- newest handover\s*\r?\n\s+\(none\)'
Set-CoordFile $hoDir 'older.md' "o`n"
Set-CoordFile $hoDir 'newer.md' "n`n"
(Get-Item -LiteralPath (Join-Path $hoDir 'older.md')).LastWriteTime = [DateTime]'2026-01-02 03:04:00'
(Get-Item -LiteralPath (Join-Path $hoDir 'newer.md')).LastWriteTime = [DateTime]'2026-02-03 04:05:00'
(Get-Item -LiteralPath (Join-Path $hoDir 'README.md')).LastWriteTime = [DateTime]'2026-03-04 05:06:00'
$digestBefore = (Get-ChildItem -LiteralPath (Join-Path $fx3.Launch '.claude') -Recurse -File | Sort-Object FullName | ForEach-Object { "$($_.FullName) $((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" }) -join "`n"
$r = Invoke-Snap -Cwd $fx3.Launch -Rules $quiet
Assert-Has 'N17 the newest .md, README.md left out' $r '(?m)^-- newest handover\s*\r?\n\s+2026-02-03 04:05 newer\.md\s*$'
$digestAfter = (Get-ChildItem -LiteralPath (Join-Path $fx3.Launch '.claude') -Recurse -File | Sort-Object FullName | ForEach-Object { "$($_.FullName) $((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" }) -join "`n"
Assert-Coord 'N18 the handovers folder is byte-unchanged by a run' ($digestAfter -ceq $digestBefore) "$digestBefore`n---`n$digestAfter"
Set-SnapLedger (Join-Path $fx3.Launch ".claude\coordination\$today.md") @("| T1 | $($fx3.Launch) | s1 | c1 | nobranch | docs/** | | live |")
$digestBefore = (Get-ChildItem -LiteralPath (Join-Path $fx3.Launch '.claude') -Recurse -File | Sort-Object FullName | ForEach-Object { "$($_.FullName) $((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" }) -join "`n"
$r = Invoke-Snap -Cwd $fx3.Launch -Rules $quiet
Assert-Has 'N18 the ledger was read' $r '\[T1\] nobranch: branch not found on origin or locally'
$digestAfter = (Get-ChildItem -LiteralPath (Join-Path $fx3.Launch '.claude') -Recurse -File | Sort-Object FullName | ForEach-Object { "$($_.FullName) $((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" }) -join "`n"
Assert-Coord 'N18 the ledger is byte-unchanged by a run' ($digestAfter -ceq $digestBefore)

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "Passed: $script:coordPass  Failed: $script:coordFail"
if ($script:coordFail -gt 0) { exit 1 }
exit 0
