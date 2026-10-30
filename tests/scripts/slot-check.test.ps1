# Tests for scripts/slot-check.ps1: the verdict for one PR's merge slot.
# Ported from the private coordinate toolkit (slot-check.test.ps1), 2026-10-28.
# gh is the stub in tests\stubs; git runs for real against a bare origin with
# refs/pull/<n>/head.
#
# What changed from the private suite (D2 of docs/plans/2026-10-18-script-port.md):
#   - the private temp-ref namespace became refs/tracksteward/slot-check/ (S19)
#   - the public Baseline has a CI column: no checks reported is READY only when
#     the repo is recorded as `CI: none` (the ledger Baseline, or -Ci none) and
#     WAIT otherwise. The private rule (no checks and no workflow files, so
#     READY) is gone, and with it S9b and S9c (WAIT because the base, or the
#     PR, carries workflow files): a repo with workflows and CI off records
#     `CI: none` and is READY. New rows C1-C9 cover the switch.
#   - S1-S19 otherwise keep their names, so a row can be traced to its private
#     twin; no private path, session or incident is named.
#
#   S1   READY: open, in scope, checks green -> exit 0, full 40-char sha
#   S2   a file outside the scope -> HOLD naming it
#   S3   a file matched by a `!` glob -> HOLD
#   S4   a rename out of a foreign path -> HOLD naming the OLD path
#   S5   a failing check -> HOLD naming it; a pending CheckRun or StatusContext
#        -> WAIT; NEUTRAL and SKIPPED pass
#   S6   draft, CONFLICTING, MERGED, CLOSED -> HOLD; mergeable UNKNOWN -> WAIT
#   S7   origin's PR head differs from gh's headRefOid -> WAIT "head moved"
#   S8   gh fails -> exit 2, never READY
#   S9   no checks at all, repo not recorded as CI none -> WAIT, naming "by
#        hand" and the `CI: none` remedy (the private S9 read READY here)
#   S10  scope from today's ledger (no -Scope), matched by repo AND branch:
#        a row -> used; no row -> exit 2; two rows -> exit 2; a same-named
#        branch in another repo's row is not used; rows whose Status is led
#        by MERGED or DONE are skipped (two finished + one live -> the live
#        one; two live -> exit 2; only finished -> exit 2 naming the count;
#        NOT MERGED, "round 1 DONE" and lower-case "merged" stay live)
#   S11  150+ changed files are all checked (local diff, no 100-file cap)
#   S12  every READY/WAIT/HOLD verdict is ONE last line:
#        ^SLOT-CHECK #<n> @<sha40>: (READY|WAIT|HOLD) - <reasons>
#   S13  a missing PR ref on origin, or no merge base -> exit 2, never READY
#   S14  malformed gh JSON, no statusCheckRollup, a short headRefOid, a
#        missing, null or non-boolean isDraft -> exit 2; a check of unknown
#        shape, or a null check entry (alone or beside a pass) -> HOLD
#   S15  a local branch named origin/main does not shadow the remote ref
#   S16  a head that does not contain origin/<base> -> WAIT (behind); one that
#        does -> READY; a git failure in the ancestry check -> exit 2 (S16c)
#   S17  a base other than -Base (default main) -> HOLD; -Base names another
#   S18  mergeStateStatus: BLOCKED/DIRTY/DRAFT -> HOLD; BEHIND, UNKNOWN,
#        missing, null, unrecognized -> WAIT; CLEAN/HAS_HOOKS/UNSTABLE pass;
#        BLOCKED while a check (CheckRun or StatusContext) is pending and none
#        is failing -> WAIT; with a failing check beside it
#        -> HOLD without the pending-check reason; with a file out of scope
#        -> HOLD (the line lists the WAIT reasons after the HOLD ones)
#   S19  the PR head is read from a private ref, never FETCH_HEAD (works when
#        FETCH_HEAD cannot be written); no refs/tracksteward ref is left behind
#   C1   -Ci none: no checks -> READY, saying CI: none; -Ci yes -> WAIT
#   C2   the ledger Baseline CI cell: none (any case) -> READY; yes -> WAIT
#   C3   -Ci wins over the ledger either way
#   C4   not proven none -> WAIT: no ledger, no Baseline row, no CI column, a repeated column name, an unreadable Tracks table, two
#        rows for the repo, a doubtful Repo cell in another row, a cell that is
#        neither yes nor none; a leaf-named row fits the repo, another repo's
#        row does not
#   C5   CI none changes nothing else: a failing check still HOLDs, a pending
#        one WAITs, an out-of-scope file HOLDs, checks that pass are judged as
#        they are (the reason names the checks, not CI: none)
#   C6   -Ci that is neither yes nor none -> exit 2
#   C7   the verdict lines match what the skill names (SKILL.md, Merge protocol)
#   C8   the ledger in the coordinator's checkout, the PR's repo via -Repo
#   C9   the ledger is byte-unchanged by every call
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\scripts\slot-check.test.ps1 [-ScriptPath <mutant copy>]
# Exit: 0 = all passed, 1 = a case failed.
param([string]$ScriptPath = '')

try { . (Join-Path $PSScriptRoot '../fixtures/hook-test-fixture.ps1') } catch { Write-Error "could not load hook-test-fixture.ps1: $_"; exit 1 }
Clear-HookRunnerGitEnv
. (Join-Path $PSScriptRoot '../fixtures/coord-test-fixture.ps1')
$ErrorActionPreference = 'Stop'

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('slot-check-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory($root)
$verdictRx = '^SLOT-CHECK #(\d+) @([0-9a-f]{40}): (READY|WAIT|HOLD) - \S'

$fx = New-CoordFixture $root 'fx'
$feat = New-CoordBranch $fx 'feat' -Write @{ 'docs/x.md' = "x`n"; 'src/new.txt' = "n`n" }
Publish-CoordPullRef $fx 7 $feat
$mv = New-CoordBranch $fx 'mv' -Move @('README.md', 'docs/README.md')
Publish-CoordPullRef $fx 8 $mv
$bulk = @{}
for ($i = 0; $i -lt 150; $i++) { $bulk[('bulk/f{0:D3}.txt' -f $i)] = "$i`n" }
$bulk['other/x.txt'] = "o`n"
$many = New-CoordBranch $fx 'many' -Write $bulk
Publish-CoordPullRef $fx 11 $many
Invoke-HookTestGit $fx.Work @('checkout', '--quiet', '--orphan', 'orphan')
Invoke-HookTestGit $fx.Work @('rm', '--quiet', '-r', '-f', '--', '.')
Set-CoordFile $fx.Work 'lonely.txt' "l`n"
Invoke-HookTestGit $fx.Work @('-c', 'core.autocrlf=false', 'add', '-A')
Invoke-HookTestGit $fx.Work @('-c', 'core.autocrlf=false', 'commit', '--quiet', '-m', 'orphan')
$orphan = Get-CoordGitOut $fx.Work @('rev-parse', 'HEAD')
Publish-CoordPullRef $fx 13 $orphan

$green = @((New-CoordCheckRun 'build'), (New-CoordStatusContext 'ci/lint'))
$scopeAll = '"docs/**,src/**"'

function Invoke-Slot {
    param([int]$Pr, [string]$Json, [string]$Scope = $scopeAll, [int]$GhExit = 0, [string]$Extra = '')
    $a = "-Pr $Pr"
    if ($Scope) { $a += " -Scope $Scope" }
    if ($Extra) { $a += " $Extra" }
    $rules = @((New-CoordRule "^pr view $Pr\b" $Json $GhExit))
    return (Invoke-CoordScript -Name 'slot-check.ps1' -Cwd $fx.Launch -ScriptArgs $a -Rules $rules -ScriptPath $ScriptPath)
}

function Assert-Verdict {
    param([string]$Case, $R, [string]$Verdict, [int]$Pr, [string]$Sha, [string[]]$Mentions = @(), [string[]]$NotMentions = @())
    $detail = "exit=$($R.Code)`nlast: $($R.Last)`nerr: $($R.Err)"
    $m = [regex]::Match($R.Last, $verdictRx)
    Assert-Coord "$Case last line is one verdict line" $m.Success $detail
    Assert-Coord "$Case verdict $Verdict" ($m.Success -and $m.Groups[3].Value -ceq $Verdict) $detail
    Assert-Coord "$Case names PR #$Pr and the full head sha" ($m.Success -and $m.Groups[1].Value -eq "$Pr" -and $m.Groups[2].Value -ceq $Sha) $detail
    $want = if ($Verdict -eq 'READY') { 0 } else { 1 }
    Assert-Coord "$Case exits $want" ($R.Code -eq $want) $detail
    foreach ($s in $Mentions) { Assert-Coord "$Case mentions '$s'" ($R.Out.Contains($s)) $R.Out }
    foreach ($s in $NotMentions) { Assert-Coord "$Case does not mention '$s'" (-not $R.Out.Contains($s)) $R.Out }
}

function Assert-CouldNotCheck {
    param([string]$Case, $R, [string]$Mention = '')
    $detail = "exit=$($R.Code)`nout: $($R.Out)`nerr: $($R.Err)"
    Assert-Coord "$Case exits 2" ($R.Code -eq 2) $detail
    Assert-Coord "$Case never says READY" (-not ($R.Out -match '\bREADY\b')) $detail
    Assert-Coord "$Case last line is a COULD NOT CHECK verdict" ($R.Last -match '^SLOT-CHECK #\d+: COULD NOT CHECK - \S') $detail
    if ($Mention) { Assert-Coord "$Case mentions '$Mention'" ($R.Out.Contains($Mention)) $detail }
}

Write-Host "(S1) ready"
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks $green)
Assert-Verdict 'S1' $r 'READY' 7 $feat

Write-Host "(S2, S3) out of scope"
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks $green) -Scope '"docs/**"'
Assert-Verdict 'S2' $r 'HOLD' 7 $feat @('src/new.txt')
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks $green) -Scope '"docs/**,src/**,!src/new.txt"'
Assert-Verdict 'S3' $r 'HOLD' 7 $feat @('src/new.txt')

Write-Host "(S4) rename out of a foreign path"
$r = Invoke-Slot 8 (New-CoordPrJson -Number 8 -Head $mv -HeadRef 'mv' -Checks $green) -Scope '"docs/**"'
Assert-Verdict 'S4' $r 'HOLD' 8 $mv @('README.md')
Assert-Coord 'S4 lists README.md itself as out of scope (not only docs/README.md)' ($r.Out -match '(?m)^\s+OUT: README\.md\s*$') $r.Out

Write-Host "(S5) check states"
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks @((New-CoordCheckRun 'build'), (New-CoordCheckRun 'tests' 'COMPLETED' 'FAILURE')))
Assert-Verdict 'S5-fail' $r 'HOLD' 7 $feat @('tests')
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks @((New-CoordCheckRun 'build'), (New-CoordCheckRun 'slow' 'IN_PROGRESS' '')))
Assert-Verdict 'S5-pending-run' $r 'WAIT' 7 $feat @('slow')
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks @((New-CoordStatusContext 'ci/ext' 'PENDING')))
Assert-Verdict 'S5-pending-ctx' $r 'WAIT' 7 $feat @('ci/ext')
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks @((New-CoordCheckRun 'n' 'COMPLETED' 'NEUTRAL'), (New-CoordCheckRun 's' 'COMPLETED' 'SKIPPED')))
Assert-Verdict 'S5-neutral-skipped' $r 'READY' 7 $feat

Write-Host "(S6) PR state"
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks $green -Draft $true)
Assert-Verdict 'S6-draft' $r 'HOLD' 7 $feat @('draft')
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks $green -Mergeable 'CONFLICTING')
Assert-Verdict 'S6-conflicting' $r 'HOLD' 7 $feat @('CONFLICTING')
foreach ($st in 'MERGED', 'CLOSED') {
    $r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks $green -State $st)
    Assert-Verdict "S6-$st" $r 'HOLD' 7 $feat @($st)
}
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks $green -Mergeable 'UNKNOWN')
Assert-Verdict 'S6-unknown' $r 'WAIT' 7 $feat @('UNKNOWN')

Write-Host "(S7) head moved"
$other = 'b' * 40
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $other -HeadRef 'feat' -Checks $green)
Assert-Verdict 'S7' $r 'WAIT' 7 $other @('head moved', $feat)

Write-Host "(S8) gh fails"
$r = Invoke-Slot 7 '' -GhExit 1
Assert-CouldNotCheck 'S8' $r 'gh'

Write-Host "(S9) no checks, CI not recorded as none"
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat')
Assert-Verdict 'S9' $r 'WAIT' 7 $feat @('no checks reported', 'CI is not recorded as none', 'by hand', 'CI: none')

Write-Host "(S10) scope from today's ledger"
$ledgerPath = Join-Path $fx.Launch ('.claude\coordination\' + [DateTime]::Now.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) + '.md')
function Set-TracksLedger([string[]]$Rows) {
    $t = "# Coordination ledger`n`n## Tracks`n`n| Track | Repo | Branch | Scope |`n|---|---|---|---|`n" + (($Rows | ForEach-Object { "$_`n" }) -join '')
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $ledgerPath))
    [System.IO.File]::WriteAllText($ledgerPath, $t, $coordUtf8)
}
$launchFull = $fx.Launch
Set-TracksLedger @("| A | $launchFull | feat | docs/**, src/** |")
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks $green) -Scope ''
Assert-Verdict 'S10a' $r 'READY' 7 $feat
Set-TracksLedger @("| A | $launchFull | other | docs/** |")
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks $green) -Scope ''
Assert-CouldNotCheck 'S10b-no-row' $r 'no ledger row'
Set-TracksLedger @("| A | $launchFull | feat | docs/** |", "| B | $launchFull | feat | src/** |")
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks $green) -Scope ''
Assert-CouldNotCheck 'S10c-two-rows' $r '2 live ledger rows'
Set-TracksLedger @("| X | C:\Elsewhere\other-repo | feat | nothing/** |", "| A | $launchFull | feat | docs/**, src/** |")
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks $green) -Scope ''
Assert-Verdict 'S10d-other-repo-row-ignored' $r 'READY' 7 $feat
Set-TracksLedger @("| X | C:\Elsewhere\other-repo | feat | docs/**, src/** |")
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks $green) -Scope ''
Assert-CouldNotCheck 'S10e-only-other-repo' $r 'no ledger row'
# S10h-k: finished rows (Status led by
# MERGED or DONE, Test-CoordRowTerminal) never own the branch; sequential
# tracks share one (two DONE rows and a live one).
function Set-StatusLedger([string[]]$Rows) {
    $t = "# Coordination ledger`n`n## Tracks`n`n| Track | Repo | Branch | Scope | Status |`n|---|---|---|---|---|`n" + (($Rows | ForEach-Object { "$_`n" }) -join '')
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $ledgerPath))
    [System.IO.File]::WriteAllText($ledgerPath, $t, $coordUtf8)
}
Set-StatusLedger @("| S1 | $launchFull | feat | nothing/** | DONE; report placed |", "| S2 | $launchFull | feat | nothing/** | MERGED a1b2c3d 13:05 |", "| S3 | $launchFull | feat | docs/**, src/** | running |")
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks $green) -Scope ''
Assert-Verdict 'S10h-two-finished-one-live' $r 'READY' 7 $feat
Assert-Coord 'S10h ... the scope came from the live row S3' ($r.Out.Contains("ledger row 'S3'")) $r.Out
Set-StatusLedger @("| S1 | $launchFull | feat | docs/** | DONE |", "| S2 | $launchFull | feat | src/** | NOT MERGED: conflicts |", "| S3 | $launchFull | feat | docs/**, src/** | running; round 1 DONE |")
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks $green) -Scope ''
Assert-CouldNotCheck 'S10i-two-live-still-refuse' $r '2 live ledger rows'
Set-StatusLedger @("| S1 | $launchFull | feat | docs/**, src/** | DONE |", "| S2 | $launchFull | feat | docs/**, src/** | MERGED abc1234 |")
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks $green) -Scope ''
Assert-CouldNotCheck 'S10j-only-finished-rows' $r 'no live ledger row'
Assert-Coord 'S10j ... and says how many finished rows it skipped' ($r.Out.Contains('2 finished')) $r.Out
Set-StatusLedger @("| S1 | $launchFull | feat | docs/**, src/** | merged per gh, not verified |")
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks $green) -Scope ''
Assert-Verdict 'S10k-lower-case-merged-is-live' $r 'READY' 7 $feat
Remove-Item -LiteralPath $ledgerPath -Force
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks $green) -Scope ''
Assert-CouldNotCheck 'S10f-no-ledger' $r 'no -Scope'

# S10g: the ledger lives in ANOTHER repo (the coordinator's checkout): run from
# there with -Repo pointing at the PR's repo.
$coord = New-CoordFixture $root 'coord'
$coordLedger = Join-Path $coord.Launch ('.claude\coordination\' + [DateTime]::Now.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) + '.md')
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $coordLedger))
[System.IO.File]::WriteAllText($coordLedger, "## Tracks`n| Track | Repo | Branch | Scope |`n|---|---|---|---|`n| A | $launchFull | feat | docs/**, src/** |`n", $coordUtf8)
$rules = @((New-CoordRule '^pr view 7\b' (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks $green)))
$r = Invoke-CoordScript -Name 'slot-check.ps1' -Cwd $coord.Launch -ScriptArgs "-Pr 7 -Repo `"$($fx.Launch)`"" -Rules $rules -ScriptPath $ScriptPath
Assert-Verdict 'S10g-ledger-in-coordinator-checkout' $r 'READY' 7 $feat
# S10h: a folder-name-only Repo cell is not used by slot-check.
Set-TracksLedger @("| A | launch | feat | docs/**, src/** |")
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks $green) -Scope ''
Assert-CouldNotCheck 'S10h-leaf-only-cell' $r 'full path'
Remove-Item -LiteralPath $ledgerPath -Force

Write-Host "(S15) a local branch named origin/main does not shadow the remote ref"
Invoke-HookTestGit $fx.Launch @('fetch', '--quiet', 'origin')
Invoke-HookTestGit $fx.Launch @('branch', 'origin/main', $feat)
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks $green) -Scope '"docs/**"'
Assert-Verdict 'S15' $r 'HOLD' 7 $feat @('src/new.txt')
Invoke-HookTestGit $fx.Launch @('branch', '-D', 'origin/main')

Write-Host "(S11) more than 100 files"
$r = Invoke-Slot 11 (New-CoordPrJson -Number 11 -Head $many -HeadRef 'many' -Checks $green) -Scope '"bulk/**"'
Assert-Verdict 'S11' $r 'HOLD' 11 $many @('other/x.txt', '151 changed')

Write-Host "(S13) git failures"
$r = Invoke-Slot 9 (New-CoordPrJson -Number 9 -Head $feat -HeadRef 'feat' -Checks $green)
Assert-CouldNotCheck 'S13a-no-pull-ref' $r 'refs/pull/9/head'
$r = Invoke-Slot 13 (New-CoordPrJson -Number 13 -Head $orphan -HeadRef 'orphan' -Checks $green) -Scope '"**"'
Assert-CouldNotCheck 'S13b-no-merge-base' $r 'git diff'

Write-Host "(S14) gh output validation"
$r = Invoke-Slot 7 '{"state": "OPEN", '
Assert-CouldNotCheck 'S14a-malformed' $r 'invalid JSON'
$r = Invoke-Slot 7 ('{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","headRefName":"feat","headRefOid":"' + $feat + '","baseRefName":"main"}')
Assert-CouldNotCheck 'S14b-no-rollup' $r 'statusCheckRollup'
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat.Substring(0, 12) -HeadRef 'feat' -Checks $green)
Assert-CouldNotCheck 'S14c-short-sha' $r 'headRefOid'
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks @([ordered]@{ name = 'odd'; something = 1 }))
Assert-Verdict 'S14d-unknown-check-shape' $r 'HOLD' 7 $feat @('odd')
# S14e-g: isDraft missing, null or not a boolean must never read as "not a
# draft" (the PR is otherwise READY).
$noDraft = '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefName":"feat","headRefOid":"' + $feat + '","baseRefName":"main","statusCheckRollup":[]}'
$r = Invoke-Slot 7 $noDraft
Assert-CouldNotCheck 'S14e-no-isDraft' $r 'isDraft'
$r = Invoke-Slot 7 ($noDraft.Replace('"state":"OPEN"', '"state":"OPEN","isDraft":null'))
Assert-CouldNotCheck 'S14f-null-isDraft' $r 'isDraft'
$r = Invoke-Slot 7 ($noDraft.Replace('"state":"OPEN"', '"state":"OPEN","isDraft":"false"'))
Assert-CouldNotCheck 'S14g-string-isDraft' $r 'isDraft'
# S14h/i: a null check entry fails, alone or next to a passing check; dropping
# it would leave "no checks reported" -> READY.
$withDraft = $noDraft.Replace('"state":"OPEN"', '"state":"OPEN","isDraft":false')
$r = Invoke-Slot 7 ($withDraft.Replace('"statusCheckRollup":[]', '"statusCheckRollup":[null]'))
Assert-Verdict 'S14h-null-check' $r 'HOLD' 7 $feat @('<null check entry>')
$r = Invoke-Slot 7 ($withDraft.Replace('"statusCheckRollup":[]', '"statusCheckRollup":[{"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS"},null]'))
Assert-Verdict 'S14i-pass-and-null-check' $r 'HOLD' 7 $feat @('<null check entry>')

Write-Host "(S16) the head must contain origin/<base>"
$bhx = New-CoordFixture $root 'bhx'
$stale = New-CoordBranch $bhx 'stale' -Write @{ 'docs/s.md' = "s`n" }
Publish-CoordPullRef $bhx 30 $stale
$adv = New-CoordBranch $bhx 'adv' -Write @{ 'docs/adv.md' = "adv`n" }
$advMain = Merge-CoordIntoMain $bhx $adv
$staleJson = New-CoordPrJson -Number 30 -Head $stale -HeadRef 'stale' -Checks $green
$r = Invoke-CoordScript -Name 'slot-check.ps1' -Cwd $bhx.Launch -ScriptArgs '-Pr 30 -Scope "docs/**"' -Rules @((New-CoordRule '^pr view 30\b' $staleJson)) -ScriptPath $ScriptPath
Assert-Verdict 'S16a-behind-main' $r 'WAIT' 30 $stale @('does not contain origin/main', $advMain, 'behind; update the branch and re-run CI')
$fresh = New-CoordBranch $bhx 'fresh' -Write @{ 'docs/f.md' = "f`n" }
Publish-CoordPullRef $bhx 31 $fresh
$r = Invoke-CoordScript -Name 'slot-check.ps1' -Cwd $bhx.Launch -ScriptArgs '-Pr 31 -Scope "docs/**"' -Rules @((New-CoordRule '^pr view 31\b' (New-CoordPrJson -Number 31 -Head $fresh -HeadRef 'fresh' -Checks $green))) -ScriptPath $ScriptPath
Assert-Verdict 'S16b-contains-main' $r 'READY' 31 $fresh @() @('does not contain')

# S16c: a git failure in the ancestry check (exit 128 from a git shim that fails
# only `merge-base --is-ancestor`) is COULD NOT CHECK, never READY.
$shimDir = Join-Path $root 'gitshim'
[void][IO.Directory]::CreateDirectory($shimDir)
$realGit = (Get-Command git -CommandType Application | Select-Object -First 1).Source
# A .ps1 shim, not .cmd: cmd would eat the ^ of `<ref>^{commit}` in the arguments.
[System.IO.File]::WriteAllText((Join-Path $shimDir 'git.ps1'), "if (`$args -contains '--is-ancestor') { exit 128 }`r`n& '$realGit' @args`r`nexit `$LASTEXITCODE`r`n", $coordUtf8)
$r = Invoke-CoordScript -Name 'slot-check.ps1' -Cwd $bhx.Launch -ScriptArgs '-Pr 31 -Scope "docs/**"' -Rules @((New-CoordRule '^pr view 31\b' (New-CoordPrJson -Number 31 -Head $fresh -HeadRef 'fresh' -Checks $green))) -ExtraEnv @{ PATH = "$shimDir;$coordStubDir;$env:PATH" } -ScriptPath $ScriptPath
Assert-CouldNotCheck 'S16c-is-ancestor-fails' $r 'is-ancestor'

Write-Host "(S17) the PR's base must be the expected one (-Base, default main)"
$rel = New-CoordBranch $bhx 'release' -Write @{ 'docs/rel.md' = "rel`n" }
$relfeat = New-CoordBranch $bhx 'relfeat' -From 'origin/release' -Write @{ 'docs/rf.md' = "rf`n" }
Publish-CoordPullRef $bhx 32 $relfeat
$relJson = New-CoordPrJson -Number 32 -Head $relfeat -HeadRef 'relfeat' -Base 'release' -Checks $green
$r = Invoke-CoordScript -Name 'slot-check.ps1' -Cwd $bhx.Launch -ScriptArgs '-Pr 32 -Scope "docs/**"' -Rules @((New-CoordRule '^pr view 32\b' $relJson)) -ScriptPath $ScriptPath
Assert-Verdict 'S17a-base-release' $r 'HOLD' 32 $relfeat @('base is release, not main')
$r = Invoke-CoordScript -Name 'slot-check.ps1' -Cwd $bhx.Launch -ScriptArgs '-Pr 32 -Scope "docs/**" -Base release' -Rules @((New-CoordRule '^pr view 32\b' $relJson)) -ScriptPath $ScriptPath
Assert-Verdict 'S17b-base-release-expected' $r 'READY' 32 $relfeat @() @('base is')
$r = Invoke-CoordScript -Name 'slot-check.ps1' -Cwd $bhx.Launch -ScriptArgs '-Pr 31 -Scope "docs/**" -Base release' -Rules @((New-CoordRule '^pr view 31\b' (New-CoordPrJson -Number 31 -Head $fresh -HeadRef 'fresh' -Checks $green))) -ScriptPath $ScriptPath
Assert-Verdict 'S17c-main-pr-expected-release' $r 'HOLD' 31 $fresh @('base is main, not release')

Write-Host "(S18) mergeStateStatus"
$ok = New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks $green
$r = Invoke-Slot 7 $ok
Assert-Coord 'S18 gh is asked for mergeStateStatus' (@($r.Calls | Where-Object { $_ -match '--json \S*\bmergeStateStatus\b' }).Count -ge 1) ($r.Calls -join "`n")
foreach ($st in 'CLEAN', 'HAS_HOOKS', 'UNSTABLE') {
    $r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks $green -MergeState $st)
    Assert-Verdict "S18-$st" $r 'READY' 7 $feat
}
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks $green -MergeState 'BLOCKED')
Assert-Verdict 'S18-BLOCKED' $r 'HOLD' 7 $feat @('branch protection blocks the merge')
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks $green -MergeState 'DIRTY')
Assert-Verdict 'S18-DIRTY' $r 'HOLD' 7 $feat @('mergeStateStatus DIRTY (')
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks $green -MergeState 'DIRTY' -Mergeable 'CONFLICTING')
Assert-Verdict 'S18-DIRTY-and-CONFLICTING' $r 'HOLD' 7 $feat @('mergeable CONFLICTING') @('mergeStateStatus DIRTY (')
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -MergeState 'BLOCKED' -Checks @((New-CoordCheckRun 'build'), (New-CoordCheckRun 'req' 'IN_PROGRESS' '')))
# BLOCKED while a check is still
# pending is most likely that required check, so WAIT, not HOLD.
Assert-Verdict 'S18-BLOCKED-pending-check' $r 'WAIT' 7 $feat @('mergeStateStatus BLOCKED while checks are pending', 'pending: req') @('branch protection blocks the merge')
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -MergeState 'BLOCKED' -Checks @((New-CoordCheckRun 'build'), (New-CoordStatusContext 'ci/req' 'PENDING')))
Assert-Verdict 'S18-BLOCKED-pending-status-context' $r 'WAIT' 7 $feat @('mergeStateStatus BLOCKED while checks are pending') @('branch protection blocks the merge')
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -MergeState 'BLOCKED' -Checks @((New-CoordCheckRun 'bad' 'COMPLETED' 'FAILURE'), (New-CoordCheckRun 'req' 'IN_PROGRESS' '')))
Assert-Verdict 'S18-BLOCKED-pending-and-failing' $r 'HOLD' 7 $feat @('failing: bad', 'branch protection blocks the merge') @('while checks are pending')
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -MergeState 'BLOCKED' -Checks @((New-CoordCheckRun 'req' 'IN_PROGRESS' ''))) -Scope '"docs/**"'
Assert-Verdict 'S18-BLOCKED-pending-and-out-of-scope' $r 'HOLD' 7 $feat @('out of scope: src/new.txt')
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks $green -MergeState 'BEHIND')
Assert-Verdict 'S18-BEHIND' $r 'WAIT' 7 $feat @('mergeStateStatus BEHIND (')
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks $green -MergeState 'UNKNOWN')
Assert-Verdict 'S18-UNKNOWN' $r 'WAIT' 7 $feat @('mergeStateStatus UNKNOWN (')
$r = Invoke-Slot 7 ($ok.Replace('"mergeStateStatus":"CLEAN",', ''))
Assert-Verdict 'S18-missing' $r 'WAIT' 7 $feat @('mergeStateStatus missing from gh output')
$r = Invoke-Slot 7 ($ok.Replace('"mergeStateStatus":"CLEAN",', '"mergeStateStatus":null,'))
Assert-Verdict 'S18-null' $r 'WAIT' 7 $feat @('mergeStateStatus missing from gh output')
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks $green -MergeState 'SOMETHING_NEW')
Assert-Verdict 'S18-unrecognized' $r 'WAIT' 7 $feat @('mergeStateStatus SOMETHING_NEW not recognized')
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks $green -MergeState 'clean')
Assert-Verdict 'S18-lowercase' $r 'WAIT' 7 $feat @('mergeStateStatus clean not recognized')
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks $green -MergeState 'DRAFT')
Assert-Verdict 'S18-DRAFT' $r 'HOLD' 7 $feat @('draft')
$r = Invoke-Slot 7 (New-CoordPrJson -Number 7 -Head $feat -HeadRef 'feat' -Checks $green -MergeState 'DRAFT' -Draft $true)
Assert-Verdict 'S18-DRAFT-and-isDraft' $r 'HOLD' 7 $feat @('draft')
Assert-Coord 'S18-DRAFT-and-isDraft names the draft once' ([regex]::Matches($r.Last, 'draft').Count -eq 1) $r.Last

Write-Host "(S19) the PR head is read from a private ref, not from FETCH_HEAD"
$fhx = New-CoordFixture $root 'fhx'
$fhf = New-CoordBranch $fhx 'fhf' -Write @{ 'docs/h.md' = "h`n" }
Publish-CoordPullRef $fhx 33 $fhf
# A DIRECTORY named FETCH_HEAD: any fetch that writes the shared file fails, one
# that does not write it (and reads its sha from the private ref) is fine.
$fhDir = Join-Path (Get-CoordGitOut $fhx.Launch @('rev-parse', '--absolute-git-dir')) 'FETCH_HEAD'
Remove-Item -LiteralPath $fhDir -Force -ErrorAction SilentlyContinue
[void][IO.Directory]::CreateDirectory($fhDir)
[System.IO.File]::WriteAllText((Join-Path $fhDir 'keep'), "x`n", $coordUtf8)
$r = Invoke-CoordScript -Name 'slot-check.ps1' -Cwd $fhx.Launch -ScriptArgs '-Pr 33 -Scope "docs/**"' -Rules @((New-CoordRule '^pr view 33\b' (New-CoordPrJson -Number 33 -Head $fhf -HeadRef 'fhf' -Checks $green))) -ScriptPath $ScriptPath
Assert-Verdict 'S19a-no-FETCH_HEAD' $r 'READY' 33 $fhf
foreach ($pair in @(@('fx', $fx.Launch), @('bhx', $bhx.Launch), @('fhx', $fhx.Launch))) {
    $left = Get-CoordGitOut $pair[1] @('for-each-ref', '--format=%(refname)', 'refs/tracksteward/')
    Assert-Coord "S19b no refs/tracksteward ref is left in $($pair[0])" ($left -eq '') $left
}

Write-Host "(C1-C9) CI none"
$today = [DateTime]::Now.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
$cix = New-CoordFixture $root 'cix'
$cif = New-CoordBranch $cix 'cif' -Write @{ 'docs/c.md' = "c`n" }
Publish-CoordPullRef $cix 40 $cif
$cixLeaf = Split-Path -Leaf $cix.Launch
$cixLedger = Join-Path $cix.Launch ".claude\coordination\$today.md"
$noChecks = New-CoordPrJson -Number 40 -Head $cif -HeadRef 'cif'
$tracksTail = "`n## Tracks`n`n| Track | Repo | Session | Model | Cwd | Branch | Scope | PR | Status |`n|---|---|---|---|---|---|---|---|---|`n`n## Log`n"
function Set-BaseLedger([string]$Path, [string]$Header, [string[]]$Rows, [string]$Tail = $tracksTail) {
    $t = "# Coordination ledger - $today`n`n## Baseline`n`n$Header`n" + (($Rows | ForEach-Object { "$_`n" }) -join '') + $Tail
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [System.IO.File]::WriteAllText($Path, $t, $coordUtf8)
}
$ciHead = "| Repo | origin/main | Open PRs | CI | Verified at |`n|------|-------------|----------|----|-------------|"
function Invoke-Ci {
    param([string]$Json = $noChecks, [string]$Extra = '', [string]$Scope = '"docs/**"')
    $a = "-Pr 40 -Scope $Scope"
    if ($Extra) { $a += " $Extra" }
    return (Invoke-CoordScript -Name 'slot-check.ps1' -Cwd $cix.Launch -ScriptArgs $a -Rules @((New-CoordRule '^pr view 40\b' $Json)) -ScriptPath $ScriptPath)
}

# C1: -Ci, no ledger at all.
$r = Invoke-Ci -Extra '-Ci none'
Assert-Verdict 'C1a--Ci-none' $r 'READY' 40 $cif @('no checks reported (CI: none)')
$r = Invoke-Ci -Extra '-Ci yes'
Assert-Verdict 'C1b--Ci-yes' $r 'WAIT' 40 $cif @('no checks reported', 'CI is recorded as yes (-Ci)', 'by hand')
$r = Invoke-Ci -Extra '-Ci NONE'
Assert-Verdict 'C1c--Ci-NONE-any-case' $r 'READY' 40 $cif

# C2, C9: the ledger's Baseline CI cell, folder name or full path; the ledger is
# only read.
foreach ($v in 'none', 'None', ' NONE ') {
    Set-BaseLedger $cixLedger $ciHead @("| $cixLeaf | abc1234 | none | $v | 10:00 |")
    $before = (Get-FileHash -LiteralPath $cixLedger -Algorithm SHA256).Hash
    $r = Invoke-Ci
    Assert-Verdict "C2-cell-'$v'" $r 'READY' 40 $cif @('no checks reported (CI: none)')
    Assert-Coord "C9-cell-'$v' the ledger is byte-unchanged" ((Get-FileHash -LiteralPath $cixLedger -Algorithm SHA256).Hash -ceq $before)
}
Set-BaseLedger $cixLedger $ciHead @("| $($cix.Launch) | abc1234 | none | none | 10:00 |")
$r = Invoke-Ci
Assert-Verdict 'C2-full-path-cell' $r 'READY' 40 $cif
Set-BaseLedger $cixLedger $ciHead @("| $cixLeaf | abc1234 | none | yes | 10:00 |")
$r = Invoke-Ci
Assert-Verdict 'C2-cell-yes' $r 'WAIT' 40 $cif @('CI is recorded as yes (the ledger Baseline)')

# C3: -Ci wins over the ledger, both ways.
$r = Invoke-Ci -Extra '-Ci none'
Assert-Verdict 'C3a-ledger-yes--Ci-none' $r 'READY' 40 $cif
Set-BaseLedger $cixLedger $ciHead @("| $cixLeaf | abc1234 | none | none | 10:00 |")
$r = Invoke-Ci -Extra '-Ci yes'
Assert-Verdict 'C3b-ledger-none--Ci-yes' $r 'WAIT' 40 $cif @('CI is recorded as yes (-Ci)')

# C4: anything short of a proven `none` waits, and says why.
Remove-Item -LiteralPath $cixLedger -Force
$r = Invoke-Ci
Assert-Verdict 'C4a-no-ledger' $r 'WAIT' 40 $cif @('CI is not recorded as none: no ledger')
Set-BaseLedger $cixLedger $ciHead @('| some-other-repo | abc1234 | none | none | 10:00 |')
$r = Invoke-Ci
Assert-Verdict 'C4b-only-another-repo-says-none' $r 'WAIT' 40 $cif @('0 Baseline rows name this repo')
Set-BaseLedger $cixLedger $ciHead @('| C:\Elsewhere\other-repo | abc1234 | none | none | 10:00 |')
$r = Invoke-Ci
Assert-Verdict 'C4c-another-repo-full-path' $r 'WAIT' 40 $cif @('0 Baseline rows name this repo')
Set-BaseLedger $cixLedger "| Repo | origin/main | Open PRs | Verified at |`n|------|-------------|----------|-------------|" @("| $cixLeaf | abc1234 | none | 10:00 |")
$r = Invoke-Ci
Assert-Verdict 'C4d-no-CI-column' $r 'WAIT' 40 $cif @('the Baseline table has no CI column')
Set-BaseLedger $cixLedger $ciHead @("| $cixLeaf | abc1234 | none | none | 10:00 |", "| $($cix.Launch) | def5678 | none | none | 11:00 |")
$r = Invoke-Ci
Assert-Verdict 'C4e-two-rows-for-the-repo' $r 'WAIT' 40 $cif @('2 Baseline rows name this repo')
Set-BaseLedger $cixLedger $ciHead @("| $cixLeaf | abc1234 | none | none | 10:00 |", '| some-repo (old) | def5678 | none | none | 11:00 |')
$r = Invoke-Ci
Assert-Verdict 'C4f-a-doubtful-Repo-cell-elsewhere' $r 'WAIT' 40 $cif @('doubtful')
Set-BaseLedger $cixLedger $ciHead @("| $cixLeaf | abc1234 | none | maybe | 10:00 |")
$r = Invoke-Ci
Assert-Verdict 'C4g-a-cell-that-is-neither' $r 'WAIT' 40 $cif @("the Baseline CI cell is 'maybe'")
Set-BaseLedger $cixLedger $ciHead @("| $cixLeaf | abc1234 | none |  | 10:00 |")
$r = Invoke-Ci
Assert-Verdict 'C4h-an-empty-cell' $r 'WAIT' 40 $cif @("the Baseline CI cell is ''")
Set-BaseLedger $cixLedger $ciHead @("| $cixLeaf | abc1234 | none | none |")
$r = Invoke-Ci
Assert-Verdict 'C4i-a-ragged-row' $r 'WAIT' 40 $cif @('one cell per column')
[System.IO.File]::WriteAllText($cixLedger, "# Coordination ledger - $today`n`n## Log`n", $coordUtf8)
$r = Invoke-Ci
Assert-Verdict 'C4j-no-Baseline-section' $r 'WAIT' 40 $cif @('no Baseline table')
# A repeated column name, in any case, would let the first column win: unknown.
Set-BaseLedger $cixLedger "| Repo | Ci | CI | Verified at |`n|------|----|----|-------------|" @("| $cixLeaf | none | yes | 10:00 |")
$r = Invoke-Ci
Assert-Verdict 'C4l-repeated-column-name-in-another-case' $r 'WAIT' 40 $cif @('repeats a column name')
Set-BaseLedger $cixLedger "| Repo | CI | CI | Verified at |`n|------|----|----|-------------|" @("| $cixLeaf | none | none | 10:00 |")
$r = Invoke-Ci
Assert-Verdict 'C4l-repeated-column-name' $r 'WAIT' 40 $cif @('repeats a column name')
# A Tracks table that cannot be read takes away the evidence a shared folder
# name is told apart by: unknown, never none.
Set-BaseLedger $cixLedger $ciHead @("| $cixLeaf | abc1234 | none | none | 10:00 |") "`n## Tracks`n`n| Track | Repo | Session | Model | Cwd | Branch | Scope | PR | Status |`n|---|---|---|---|---|---|---|---|---|`n| T1 | $($cix.Launch) | s |`n"
$r = Invoke-Ci
Assert-Verdict 'C4m-a-ragged-Tracks-row' $r 'WAIT' 40 $cif @('the Tracks table could not be read')
# A leaf-named Baseline row, with a Tracks row beside it that lists the repo by
# full path: the leaf row is still this repo's.
Set-BaseLedger $cixLedger $ciHead @("| $cixLeaf | abc1234 | none | none | 10:00 |") "`n## Tracks`n`n| Track | Repo | Session | Model | Cwd | Branch | Scope | PR | Status |`n|---|---|---|---|---|---|---|---|---|`n| T1 | $($cix.Launch) | s | | | cif | docs/** | | working |`n"
$r = Invoke-Ci
Assert-Verdict 'C4k-leaf-row-with-a-tracks-table-beside-it' $r 'READY' 40 $cif

# C5: CI none switches off the empty-rollup wait and nothing else.
Set-BaseLedger $cixLedger $ciHead @("| $cixLeaf | abc1234 | none | none | 10:00 |")
$r = Invoke-Ci -Json (New-CoordPrJson -Number 40 -Head $cif -HeadRef 'cif' -Checks @((New-CoordCheckRun 'build'), (New-CoordCheckRun 'tests' 'COMPLETED' 'FAILURE')))
Assert-Verdict 'C5a-failing-check' $r 'HOLD' 40 $cif @('tests')
$r = Invoke-Ci -Json (New-CoordPrJson -Number 40 -Head $cif -HeadRef 'cif' -Checks @((New-CoordCheckRun 'slow' 'IN_PROGRESS' '')))
Assert-Verdict 'C5b-pending-check' $r 'WAIT' 40 $cif @('slow')
$r = Invoke-Ci -Scope '"src/**"'
Assert-Verdict 'C5c-out-of-scope-file' $r 'HOLD' 40 $cif @('docs/c.md')
$r = Invoke-Ci -Json (New-CoordPrJson -Number 40 -Head $cif -HeadRef 'cif' -Checks @((New-CoordCheckRun 'build')))
Assert-Verdict 'C5d-passing-check' $r 'READY' 40 $cif @('1 check(s) passed') @('CI: none')
$r = Invoke-Ci -Json (New-CoordPrJson -Number 40 -Head $cif -HeadRef 'cif' -Draft $true)
Assert-Verdict 'C5e-draft' $r 'HOLD' 40 $cif @('draft')
$r = Invoke-Ci -Json (New-CoordPrJson -Number 40 -Head $cif -HeadRef 'cif' -MergeState 'BLOCKED')
Assert-Verdict 'C5f-BLOCKED' $r 'HOLD' 40 $cif @('branch protection blocks the merge')

# C6: -Ci takes yes or none.
foreach ($bad in 'maybe', 'no') {
    $r = Invoke-Ci -Extra "-Ci $bad"
    Assert-CouldNotCheck "C6--Ci-$bad" $r 'it takes yes or none'
}

# C7: the verdict lines are the ones the skill names, byte for byte up to the
# reasons.
$skillText = [System.IO.File]::ReadAllText((Join-Path (Split-Path -Parent $coordScriptsDir) 'skills/coordinate/SKILL.md'), $coordUtf8)
$vm = [regex]::Match($skillText, '(?m)^\s*(SLOT-CHECK #<n> @<full sha>: READY\|WAIT\|HOLD - <reasons>)\s*$')
Assert-Coord 'C7 the skill names the verdict line' $vm.Success
$cm = [regex]::Match($skillText, '(?m)^\s*(SLOT-CHECK #<n>: COULD NOT CHECK - <reason>)\s*$')
Assert-Coord 'C7 the skill names the could-not-check line' $cm.Success
if ($vm.Success) {
    $named = $vm.Groups[1].Value
    $c7 = @(
        @('READY', (Invoke-Ci -Extra '-Ci none')),
        @('WAIT', (Invoke-Ci -Extra '-Ci yes')),
        @('HOLD', (Invoke-Ci -Extra '-Ci none' -Scope '"src/**"'))
    )
    foreach ($case in $c7) {
        $prefix = $named.Substring(0, $named.IndexOf(' - ') + 3).Replace('<n>', '40').Replace('<full sha>', $cif).Replace('READY|WAIT|HOLD', $case[0])
        Assert-Coord "C7 a $($case[0]) line starts with the line the skill names" ($case[1].Last.StartsWith($prefix, [StringComparison]::Ordinal)) "want prefix: $prefix`nlast: $($case[1].Last)"
        Assert-Coord "C7 a $($case[0]) line has reasons after it" ($case[1].Last.Length -gt $prefix.Length) $case[1].Last
    }
}
if ($cm.Success) {
    $r = Invoke-Ci -Extra '-Ci maybe'
    $want = $cm.Groups[1].Value.Replace('<n>', '40').Replace('<reason>', '')
    Assert-Coord 'C7 a could-not-check line starts with the line the skill names' ($r.Last.StartsWith($want, [StringComparison]::Ordinal)) "want prefix: $want`nlast: $($r.Last)"
}

# C8: the ledger in the coordinator's checkout, the PR's repo via -Repo (a), or
# the ledger named by -Ledger from a checkout with none (b); the Baseline Repo
# cell is the PR repo's full path.
$coordFx = New-CoordFixture $root 'cixcoord'
$coordLedgerPath = Join-Path $coordFx.Launch ".claude\coordination\$today.md"
Set-BaseLedger $coordLedgerPath $ciHead @("| $($cix.Launch) | abc1234 | none | none | 10:00 |")
$r = Invoke-CoordScript -Name 'slot-check.ps1' -Cwd $coordFx.Launch -ScriptArgs "-Pr 40 -Scope `"docs/**`" -Repo `"$($cix.Launch)`"" -Rules @((New-CoordRule '^pr view 40\b' $noChecks)) -ScriptPath $ScriptPath
Assert-Verdict 'C8a-the-coordinators-ledger-by-default' $r 'READY' 40 $cif @('no checks reported (CI: none)')
Remove-Item -LiteralPath $cixLedger -Force
$r = Invoke-CoordScript -Name 'slot-check.ps1' -Cwd $cix.Launch -ScriptArgs "-Pr 40 -Scope `"docs/**`" -Ledger `"$coordLedgerPath`"" -Rules @((New-CoordRule '^pr view 40\b' $noChecks)) -ScriptPath $ScriptPath
Assert-Verdict 'C8b--Ledger-names-it' $r 'READY' 40 $cif @('no checks reported (CI: none)')

Write-Host "(F5) git below 2.38 is refused at the start"
$gitOldDir = Join-Path $root 'gitstub-floor-old'
[void][IO.Directory]::CreateDirectory($gitOldDir)
[System.IO.File]::WriteAllText((Join-Path $gitOldDir 'git.cmd'), "@echo off`r`necho git version 2.37.9.windows.1`r`nexit /b 0`r`n", [System.Text.Encoding]::ASCII)
$gitOldEnv = @{ PATH = $gitOldDir + [System.IO.Path]::PathSeparator + $env:PATH }
$x = Invoke-CoordScript -Name 'slot-check.ps1' -Cwd $root -ScriptArgs '-Pr 7' -ExtraEnv $gitOldEnv -ScriptPath $ScriptPath
$xOut = ([string]$x.Out).Trim()
Assert-Coord 'F5 slot-check: a git that answers 2.37.9 is refused with exit 2, one line starting "SLOT-CHECK #7: COULD NOT CHECK - " that names git 2.37.9 and the 2.38 floor' ($x.Code -eq 2 -and $xOut.StartsWith('SLOT-CHECK #7: COULD NOT CHECK - ', [System.StringComparison]::Ordinal) -and $xOut -notmatch '[\r\n]' -and $xOut.Contains('git 2.37.9 ') -and $xOut.Contains('2.38')) "code=$($x.Code) out=$($x.Out) err=$($x.Err)"

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "Passed: $script:coordPass  Failed: $script:coordFail"
if ($script:coordFail -gt 0) { exit 1 }
exit 0
