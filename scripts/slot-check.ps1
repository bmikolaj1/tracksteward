# Ported from the private coordinate toolkit (slot-check.ps1), 2026-10-28.
#
# slot-check.ps1 - is this PR ready for its merge slot? One call, one verdict.
#
# Reads the PR with `gh pr view`, fetches its head from origin
# (refs/pull/<n>/head) and its base branch, and prints:
#   - the PR's state, base, head branch and FULL head sha (what
#     `gh pr merge --match-head-commit` needs);
#   - the files it changes (local `git diff --no-renames base...head`: a rename
#     lists its old path too, and there is no 100-file cap) and every file
#     outside the expected scope;
#   - its checks: passed, pending, failing;
#   - and ONE last line:
#       SLOT-CHECK #<n> @<sha40>: READY|WAIT|HOLD - <reasons>
#     HOLD  not open, draft, CONFLICTING, a failing check, a file out of scope,
#           a base other than -Base (default main), or GitHub's mergeStateStatus
#           DIRTY, DRAFT or BLOCKED (branch protection; but see WAIT for a
#           BLOCKED with a check pending and none failing)
#     WAIT  a pending check, mergeability UNKNOWN, origin's head differs from
#           gh's, the head does not contain origin/<base> (behind), or
#           mergeStateStatus BLOCKED while a check is pending and none is
#           failing (most likely a required check still running), BEHIND,
#           UNKNOWN, missing or not recognized, or no checks reported while the
#           repo is not recorded as having no CI (see Checks)
#     READY otherwise ("no checks reported" when there are none and CI is
#           `none`; mergeStateStatus CLEAN, HAS_HOOKS and UNSTABLE pass)
#   or, when it could not check at all (gh or git failure, invalid gh output
#   including a missing or non-boolean isDraft, no scope, a -Ci that is neither
#   yes nor none):
#                SLOT-CHECK #<n>: COULD NOT CHECK - <reason>
#
# Exit: 0 READY, 1 WAIT or HOLD, 2 could not check. Informational only: it is
# not a merge gate and nothing calls it as one.
#
# Scope: -Scope takes globs (comma, semicolon or space separated; `**` crosses
# folders, `*` and `?` do not, case-sensitive, `!glob` excludes). Without it,
# the scope comes from today's coordination ledger - the one at the canonical
# location of the CURRENT directory's repo (the coordinator's checkout, where
# the ledger lives), or -Ledger: the Tracks row whose Repo cell is the full
# path of this repository's main checkout AND whose Branch is the PR's head
# branch. A folder-name-only Repo cell is not used here (one repo is in play,
# so a name could never be shown ambiguous). Rows whose Status cell is led by
# MERGED or DONE are finished and skipped (Test-CoordRowTerminal), since
# sequential tracks can share one branch. No live such row, or more than one,
# is "could not check".
#
# Checks: a PR that reports no checks is READY only when the repo has no CI.
# That is the CI column of the ledger's Baseline row for this repo
# (Get-CoordBaselineCi: read from -Ledger, else today's ledger at the canonical
# location), or -Ci none / -Ci yes, which wins over the ledger. Anything that
# is not provably `none` (no ledger, no Baseline row, two rows, a doubtful
# cell, `yes`) reads WAIT: the runs may not have registered yet, or none of
# them runs on this PR (path filters, push-only or scheduled triggers), and the
# script cannot tell which, so a WAIT that persists is the coordinator's to
# check by hand; the reason says so. With `none`, a PR that does report checks
# is judged on them like any other. A null check entry counts as failing.
#
# Usage: powershell.exe -ExecutionPolicy Bypass -File slot-check.ps1 -Pr 12 [-Scope "docs/**,src/**"] [-Base main] [-Repo <repo>] [-Ledger <path>] [-Ci yes|none]
# Writes only origin/<base> and the fetched objects (git fetch) and a private ref
# refs/tracksteward/slot-check/<guid> that it deletes again at once; changes no
# branch, index or working tree.

param(
    [Parameter(Mandatory = $true)][int]$Pr,
    [string[]]$Scope = @(),
    [string]$Base = 'main',
    [string]$Repo = (Get-Location).Path,
    [string]$Ledger = '',
    [string]$Ci = ''
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'coord-common.ps1')
Initialize-CoordConsole

function Exit-CouldNotCheck([string]$Reason) {
    Write-Output "SLOT-CHECK #${Pr}: COULD NOT CHECK - $Reason"
    exit 2
}

$ciArg = $Ci.Trim().ToLowerInvariant()
if ($ciArg -and $ciArg -ne 'yes' -and $ciArg -ne 'none') { Exit-CouldNotCheck "-Ci is '$Ci'; it takes yes or none" }

$top = Invoke-CoordGit $Repo @('rev-parse', '--show-toplevel')
if ($top.Code -ne 0 -or -not $top.Out[0]) { Exit-CouldNotCheck "$Repo is not a git repository" }
$repoRoot = [System.IO.Path]::GetFullPath($top.Out[0].Trim())
$url = Invoke-CoordGit $repoRoot @('remote', 'get-url', 'origin')
if ($url.Code -ne 0 -or -not $url.Out[0]) { Exit-CouldNotCheck "no origin remote in $repoRoot" }
$originUrl = $url.Out[0].Trim()

$gh = Invoke-CoordGhJson @('pr', 'view', "$Pr", '--repo', $originUrl, '--json', 'number,state,isDraft,mergeable,mergeStateStatus,headRefName,headRefOid,baseRefName,statusCheckRollup')
if (-not $gh.Ok) { Exit-CouldNotCheck $gh.Error }
$pv = $gh.Data
$why = Test-CoordPrView $pv -Checks -Draft
if ($why) { Exit-CouldNotCheck $why }
$head = [string]$pv.headRefOid
$headRef = [string]$pv.headRefName
$expectedBase = $Base   # PowerShell variables are case-insensitive: $base below would overwrite -Base
$base = [string]$pv.baseRefName
$repoMain = Get-CoordMainRoot $repoRoot
if (-not $repoMain) { $repoMain = $repoRoot }
$ledgerPath = if ($Ledger) { $Ledger } else { Get-CoordLedgerPath (Get-Location).Path }

# Scope: -Scope, else the ledger row for this repo and this head branch.
$scopeFrom = '-Scope'
if (@($Scope | Where-Object { $_ }).Count -gt 0) { $globs = Split-CoordScope $Scope }
else {
    if (-not $ledgerPath -or -not (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) {
        Exit-CouldNotCheck "no -Scope given and no ledger at $ledgerPath"
    }
    try { $rows = @(Read-CoordLedgerTracks $ledgerPath) } catch { Exit-CouldNotCheck "$_" }
    $mine = @($rows | Where-Object { $_.Branch -ceq $headRef -and $_.Repo -match '[\\/:]' -and (Resolve-CoordLedgerRepo $_.Repo @($repoMain)).Match })
    # Finished rows (Status led by MERGED or DONE) never own the branch:
    # sequential tracks share one.
    $hits = @($mine | Where-Object { -not (Test-CoordRowTerminal $_.Status) })
    $done = $mine.Count - $hits.Count
    if ($mine.Count -eq 0) { Exit-CouldNotCheck "no ledger row for repo $repoMain (full path) and branch $headRef in $ledgerPath" }
    if ($hits.Count -eq 0) { Exit-CouldNotCheck "no live ledger row for repo $repoMain (full path) and branch $headRef in $ledgerPath ($done finished: $(($mine | ForEach-Object { $_.Track }) -join ', '))" }
    if ($hits.Count -gt 1) { Exit-CouldNotCheck "$($hits.Count) live ledger rows for repo $repoMain and branch $headRef in $ledgerPath (tracks: $(($hits | ForEach-Object { $_.Track }) -join ', '))" }
    $globs = Split-CoordScope @($hits[0].Scope)
    $scopeFrom = "ledger row '$($hits[0].Track)'"
}
if (@($globs | Where-Object { -not $_.StartsWith('!') }).Count -eq 0) { Exit-CouldNotCheck "the scope ($scopeFrom) has no positive glob" }

# Base and PR head from origin.
$f = Invoke-CoordGit $repoRoot @('fetch', '--quiet', '--no-tags', '--no-write-fetch-head', 'origin', "+refs/heads/${base}:refs/remotes/origin/$base")
if ($f.Code -ne 0) { Exit-CouldNotCheck "git fetch of origin/$base failed (exit $($f.Code))" }
# The PR head goes into a private ref, not the shared FETCH_HEAD (another fetch
# in this checkout would leave the wrong sha there). It is pinned to a sha at once and deleted again at once; the objects stay.
$prRef = 'refs/tracksteward/slot-check/' + [guid]::NewGuid().ToString('N')
$f = Invoke-CoordGit $repoRoot @('fetch', '--quiet', '--no-tags', '--no-write-fetch-head', 'origin', "+refs/pull/${Pr}/head:$prRef")
$fetchCode = $f.Code
$fh = if ($fetchCode -eq 0) { Invoke-CoordGit $repoRoot @('rev-parse', '--verify', '--quiet', "$prRef^{commit}") } else { $null }
$del = Invoke-CoordGit $repoRoot @('update-ref', '-d', $prRef)
if ($del.Code -ne 0) { [Console]::Error.WriteLine("slot-check: warning: could not delete the private ref $prRef (exit $($del.Code))") }
if ($fetchCode -ne 0) { Exit-CouldNotCheck "git fetch of refs/pull/$Pr/head failed (exit $fetchCode)" }
if ($fh.Code -ne 0 -or -not (Test-CoordSha40 $fh.Out[0])) { Exit-CouldNotCheck "could not read the fetched head of refs/pull/$Pr/head" }
$fetched = $fh.Out[0].Trim()

$cf = Get-CoordChangedFiles $repoRoot "refs/remotes/origin/$base" $fetched
if (-not $cf.Ok) { Exit-CouldNotCheck $cf.Error }
# Freshness: GitHub merges the PR into the CURRENT base, so checks that went green
# on a head that lacks the base tip never ran against the merged tree. Exit 1 is the
# only "not an ancestor" answer; any other non-zero exit is a git failure.
$anc = Invoke-CoordGit $repoRoot @('merge-base', '--is-ancestor', "refs/remotes/origin/$base", $fetched)
if ($anc.Code -ne 0 -and $anc.Code -ne 1) { Exit-CouldNotCheck "git merge-base --is-ancestor origin/$base failed (exit $($anc.Code))" }
$baseTip = Invoke-CoordGit $repoRoot @('rev-parse', '--verify', '--quiet', "refs/remotes/origin/$base^{commit}")
if ($baseTip.Code -ne 0 -or -not (Test-CoordSha40 $baseTip.Out[0])) { Exit-CouldNotCheck "could not read origin/$base" }
$files = @($cf.Files)
$outside = @($files | Where-Object { -not (Test-CoordInScope $_ $globs) })
$checks = Get-CoordCheckSummary $pv.statusCheckRollup

$hold = New-Object System.Collections.Generic.List[string]
$wait = New-Object System.Collections.Generic.List[string]
if ([string]$pv.state -ne 'OPEN') { $hold.Add("PR is $($pv.state)") }
if ($base -cne $expectedBase) { $hold.Add("base is $base, not $expectedBase") }
$isDraft = $pv.PSObject.Properties['isDraft'] -and $pv.isDraft -eq $true
if ($isDraft) { $hold.Add('PR is a draft') }
$mergeable = if ($pv.PSObject.Properties['mergeable'] -and $pv.mergeable) { [string]$pv.mergeable } else { 'UNKNOWN' }
if ($mergeable -eq 'CONFLICTING') { $hold.Add('mergeable CONFLICTING') }
elseif ($mergeable -ne 'MERGEABLE') { $wait.Add("mergeable $mergeable (not computed yet)") }
# GitHub's own merge verdict, which also covers branch protection (required checks
# and reviews). Only the values below pass; a missing, null or new value waits.
$mergeState = if ($pv.PSObject.Properties['mergeStateStatus'] -and $pv.mergeStateStatus -is [string] -and $pv.mergeStateStatus) { [string]$pv.mergeStateStatus } else { '' }
switch -CaseSensitive ($mergeState) {
    { @('CLEAN', 'HAS_HOOKS', 'UNSTABLE') -ccontains $_ } { }
    # BLOCKED while a check is pending and none is failing is most likely that
    # required check, and clears when it passes; otherwise it is a failing
    # check, a missing review or another rule.
    'BLOCKED' {
        if ($checks.Pending.Count -and -not $checks.Fail.Count) { $wait.Add('mergeStateStatus BLOCKED while checks are pending (most likely a required check still running; if it stays BLOCKED after they pass, a review or another rule blocks the merge)') }
        else { $hold.Add('branch protection blocks the merge (mergeStateStatus BLOCKED, and not only by a pending check: a failing required check, a review missing, or another rule)') }
    }
    'DIRTY' { if ($mergeable -ne 'CONFLICTING') { $hold.Add('mergeStateStatus DIRTY (merge conflicts)') } }
    'DRAFT' { if (-not $isDraft) { $hold.Add('mergeStateStatus DRAFT (PR is a draft)') } }
    'BEHIND' { $wait.Add('mergeStateStatus BEHIND (the head is behind its base; update the branch and re-run CI)') }
    'UNKNOWN' { $wait.Add('mergeStateStatus UNKNOWN (not computed yet)') }
    '' { $wait.Add('mergeStateStatus missing from gh output (not computed yet)') }
    default { $wait.Add("mergeStateStatus $mergeState not recognized") }
}
if ($anc.Code -eq 1) { $wait.Add("head does not contain origin/$base $($baseTip.Out[0].Trim()) (behind; update the branch and re-run CI)") }
if ($checks.Fail.Count) { $hold.Add("failing: $($checks.Fail -join ', ')") }
if ($outside.Count) {
    $shown = @($outside | Select-Object -First 5)
    $more = if ($outside.Count -gt 5) { " (+$($outside.Count - 5) more)" } else { '' }
    $hold.Add("$($outside.Count) file(s) out of scope: $($shown -join ', ')$more")
}
if ($checks.Pending.Count) { $wait.Add("pending: $($checks.Pending -join ', ')") }
if ($fetched -ne $head) { $wait.Add("head moved: gh says $head, origin refs/pull/$Pr/head is $fetched") }
$total = $checks.Pass.Count + $checks.Pending.Count + $checks.Fail.Count
$ciState = $null
if ($total -eq 0) {
    # The repo has no CI only when that is proven: -Ci, else the ledger Baseline.
    if ($ciArg) { $ciState = [pscustomobject]@{ Ci = $ciArg; Why = $null; From = '-Ci' } }
    else {
        $b = Get-CoordBaselineCi $ledgerPath $repoMain
        $ciState = [pscustomobject]@{ Ci = $b.Ci; Why = $b.Why; From = 'the ledger Baseline' }
    }
    if ($ciState.Ci -ne 'none') {
        $basis = if ($ciState.Ci -eq 'yes') { "CI is recorded as yes ($($ciState.From))" } elseif ($ciState.Why) { "CI is not recorded as none: $($ciState.Why)" } else { 'CI is not recorded as none' }
        $wait.Add("no checks reported, and ${basis}: the runs may not have registered yet, or none of them runs on this PR (path filters, push-only or scheduled triggers) - if it stays like this, check the PR's checks by hand; a repo with no CI records CI: none in the ledger Baseline (or pass -Ci none)")
    }
}

$draftTag = if ($pv.PSObject.Properties['isDraft'] -and $pv.isDraft -eq $true) { ' [DRAFT]' } else { '' }
Write-Output "PR #$Pr $($pv.state)$draftTag base=$base head=$headRef @ $head (origin: $fetched)"
Write-Output "scope ($scopeFrom): $($globs -join ', ')"
Write-Output "files: $($files.Count) changed, $($outside.Count) out of scope"
foreach ($o in $outside) { Write-Output "  OUT: $o" }
$checkLine = "checks: $($checks.Pass.Count) passed, $($checks.Pending.Count) pending, $($checks.Fail.Count) failing"
if ($checks.Pending.Count) { $checkLine += "; pending: $($checks.Pending -join ', ')" }
if ($checks.Fail.Count) { $checkLine += "; failing: $($checks.Fail -join ', ')" }
Write-Output $checkLine
Write-Output "mergeable: $mergeable; mergeStateStatus: $(if ($mergeState) { $mergeState } else { '<missing>' })"

if ($hold.Count) { Write-Output "SLOT-CHECK #$Pr @${head}: HOLD - $(@($hold) + @($wait) -join '; ')"; exit 1 }
if ($wait.Count) { Write-Output "SLOT-CHECK #$Pr @${head}: WAIT - $($wait -join '; ')"; exit 1 }
$okWhy = if ($total -eq 0) { "$($files.Count) file(s) in scope; no checks reported (CI: none)" } else { "$($files.Count) file(s) in scope; $($checks.Pass.Count) check(s) passed" }
Write-Output "SLOT-CHECK #$Pr @${head}: READY - $okWhy"
exit 0
