# Ported from the private coordinate toolkit (merge-verify.ps1), 2026-10-28.
#
# merge-verify.ps1 - after a merge: is it really on origin, and tidy up. One
# call, one verdict.
#
#   1. `gh pr view`: the PR must be MERGED (else NOT MERGED, nothing touched).
#   2. `git fetch --prune origin`; the merge commit must be an ancestor of
#      refs/remotes/origin/<base>. Full refs everywhere: a local branch or tag
#      named origin/<base> would otherwise win the name lookup.
#   3. The remote head branch. Its tip is read by its exact ref (`git ls-remote
#      origin refs/heads/<b>`; `--heads <b>` would also match x/<b>), with or
#      without -DeleteBranch. Absent -> "already gone". Tip moved -> kept (new
#      work). Tip == the merged head -> the branch is deleted ONLY when
#      -DeleteBranch is given, with
#      `git push --force-with-lease=refs/heads/<b>:<head> origin :refs/heads/<b>`
#      (a push that lands in between makes the delete fail, not vanish), then
#      re-read: "deleted" only when the re-read shows it gone. Without the flag
#      the script never runs a push; where the delete would have happened it
#      prints the command it would have run (the branch part reads "kept:
#      -DeleteBranch not given; would run: ..."), unless the branch name holds
#      a character a shell would act on, when it prints no command. Never deleted, flag or not: a
#      fork PR (gh must state isCrossRepository), the base branch, origin's
#      default branch (read from origin with `ls-remote --symref`; unreadable
#      or naming no branch -> not deleted), main, master, a branch an open PR
#      still uses as its base or head, a merge not verified on origin, or an
#      origin with more than one push URL or one that differs from its fetch URL
#      (the delete would go somewhere the checks never read).
#   4. The launch checkout (-Repo, default: the current directory) is
#      fast-forwarded to origin/<base> only when it is the MAIN worktree, on
#      <base>, has no tracked change (untracked files do not count; git itself
#      refuses to overwrite one) and no local commit missing from origin.
#      Otherwise skipped, with the reason. -NoFastForward skips it.
#   5. git-config sanity on the shared config: core.bare=true, a local
#      core.autocrlf, any local diff.*, an empty effective user.name, and - when
#      a .githooks folder exists - a core.hooksPath other than `.githooks` or
#      `<main checkout>/.githooks` (the absolute form Claude Code writes).
#   6. After an OK verdict only: one paste-ready line per OTHER live row of this repo
#      in the coordination ledger (-Ledger, default: today's at the canonical location of
#      the current directory's repo; a full-path Repo cell, not led by MERGED/DONE, not the
#      merged track's own row = the one on the PR's head branch):
#        NOTIFY <track> (<session>): #<n> merged <HH:mm> as <sha12>; <repo> <base> is now <sha12>; fetch + merge origin/<base> before your next push
#      <session> is the row's Session cell as written (a name or an id), or "no session id"
#      when it is empty; merge sha = gh's mergeCommit.oid; time = gh's mergedAt in local time
#      (not the clock); <base> = gh's baseRefName; base tip = refs/remotes/origin/<base> after
#      the fetch (a base that moved on prints its newer tip); <repo> = the main checkout's
#      folder name. A rerun prints the same lines. Nothing is sent: the coordinator pastes each
#      line to its track. No ledger: nothing printed. A ledger that exists
#      but cannot be read or parsed, a mergedAt that is not a time, or a tip that is not a
#      commit (checked only when a live row waits): one NOTIFY: none printed - <reason> line. A
#      live row whose Repo cell cannot be read as a path is skipped with its own such line, so it
#      never silences the others. The default ledger is the current directory's repo's, so for a
#      repo whose ledger lives elsewhere pass -Ledger. The verdict and the exit code never change
#      because of it.
#
# Last line (the NOTIFY lines come before it):
#   MERGE-VERIFY #<n>: OK|PROBLEM|NOT MERGED - merge <sha12> on origin/<base>; branch <...>; checkout <...>; config <ok|WARN: ...>
#   MERGE-VERIFY #<n>: COULD NOT CHECK - <reason>
# PROBLEM: the merge commit is not on origin; a branch read, delete or re-read
# failed, or the delete's exit code disagrees with the re-read; origin's
# default branch could not be read; the open-PR check (gh) failed; origin's
# push URLs are not exactly its fetch URL; the checkout could not be read (git
# dirs, status or rev-list failed); an attempted fast-forward failed; or a
# config WARN. A deliberate skip is information and stays OK.
# Exit: 0 OK, 1 PROBLEM or NOT MERGED, 2 could not check (-Repo is not a git
# working tree or reads as bare: core.bare=true; it has no origin remote; the
# first gh pr view or the fetch failed; or invalid gh output).
#
# Usage: powershell.exe -ExecutionPolicy Bypass -File merge-verify.ps1 -Pr 12 [-Repo <repo>] [-DeleteBranch] [-NoFastForward] [-Ledger <path>]
# Run it only after the user's merge OK. By default it changes only the launch checkout (a
# fast-forward) and the fetched refs; -DeleteBranch is the one switch that lets it delete a
# remote branch.

param(
    [Parameter(Mandatory = $true)][int]$Pr,
    [string]$Repo = (Get-Location).Path,
    [switch]$DeleteBranch,
    [switch]$NoFastForward,
    [string]$Ledger = ''
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'coord-common.ps1')
Initialize-CoordConsole

function Exit-CouldNotCheck([string]$Reason) {
    Write-Output "MERGE-VERIFY #${Pr}: COULD NOT CHECK - $Reason"
    exit 2
}
function Get-Short([string]$Sha) { if ($Sha.Length -ge 12) { return $Sha.Substring(0, 12) } return $Sha }

$top = Invoke-CoordGit $Repo @('rev-parse', '--show-toplevel')
if ($top.Code -ne 0 -or -not $top.Out[0]) {
    $bare = Invoke-CoordGit $Repo @('config', '--bool', 'core.bare')
    if ($bare.Code -eq 0 -and $bare.Out[0] -eq 'true') { Exit-CouldNotCheck "config WARN: core.bare=true in $Repo, so it reads as a bare repository" }
    Exit-CouldNotCheck "$Repo is not a git working tree"
}
$repoRoot = [System.IO.Path]::GetFullPath($top.Out[0].Trim())
$url = Invoke-CoordGit $repoRoot @('remote', 'get-url', 'origin')
if ($url.Code -ne 0 -or -not $url.Out[0]) { Exit-CouldNotCheck "no origin remote in $repoRoot" }
$originUrl = $url.Out[0].Trim()

$gh = Invoke-CoordGhJson @('pr', 'view', "$Pr", '--repo', $originUrl, '--json', 'state,mergeCommit,mergedAt,headRefName,headRefOid,baseRefName,isCrossRepository')
if (-not $gh.Ok) { Exit-CouldNotCheck $gh.Error }
$pv = $gh.Data
$why = Test-CoordPrView $pv -MergeCommit -Fork
if ($why) { Exit-CouldNotCheck $why }
$head = [string]$pv.headRefOid
$headRef = [string]$pv.headRefName
$base = [string]$pv.baseRefName
if ([string]$pv.state -ne 'MERGED') {
    Write-Output "PR #$Pr $($pv.state) head=$headRef @ $head base=$base"
    Write-Output "MERGE-VERIFY #${Pr}: NOT MERGED - PR is $($pv.state); nothing changed"
    exit 1
}
$mc = [string]$pv.mergeCommit.oid
$cross = ($pv.isCrossRepository -eq $true)
$baseRef = "refs/remotes/origin/$base"

$f = Invoke-CoordGit $repoRoot @('fetch', '--quiet', '--prune', 'origin')
if ($f.Code -ne 0) { Exit-CouldNotCheck "git fetch origin failed (exit $($f.Code))" }

$problems = New-Object System.Collections.Generic.List[string]

# 2. Merge commit on origin/<base>.
$anc = Invoke-CoordGit $repoRoot @('merge-base', '--is-ancestor', $mc, $baseRef)
$mergeOk = ($anc.Code -eq 0)
$mergePart = if ($mergeOk) { "merge $(Get-Short $mc) on origin/$base" } else { "merge $(Get-Short $mc) not on origin/$base" }
if (-not $mergeOk) { $problems.Add('merge commit not on origin') }

# 3. Remote branch.
function Read-RemoteTip([string]$Name) {
    $ls = Invoke-CoordGit $repoRoot @('ls-remote', 'origin', "refs/heads/$Name")
    if ($ls.Code -ne 0) { return [pscustomobject]@{ Ok = $false; Tip = $null } }
    foreach ($line in $ls.Out) {
        $parts = $line -split "`t"
        if ($parts.Count -eq 2 -and $parts[1] -ceq "refs/heads/$Name") { return [pscustomobject]@{ Ok = $true; Tip = $parts[0].Trim() } }
    }
    return [pscustomobject]@{ Ok = $true; Tip = $null }
}
# origin's default branch, asked from origin itself (`ls-remote --symref`): a
# local refs/remotes/origin/HEAD is set by clone but never by fetch, so it can
# be missing or stale. Unreadable -> no delete (an unknown is never a yes), and
# so is an answer with no `ref:` line (origin's HEAD detached or unborn, or a
# server that does not report the symref): a successful exit alone names no
# branch.
$defaultBranch = ''
$sym = Invoke-CoordGit $repoRoot @('ls-remote', '--symref', 'origin', 'HEAD')
if ($sym.Code -eq 0) {
    foreach ($line in $sym.Out) { if ($line -match '^ref: refs/heads/(\S+)\s+HEAD$') { $defaultBranch = $Matches[1] } }
}
$defaultKnown = [bool]$defaultBranch
# Every push URL (--all): `git push origin` pushes to all of them, so a delete
# is allowed only when there is exactly one and it is the fetch URL.
$pushUrl = Invoke-CoordGit $repoRoot @('remote', 'get-url', '--push', '--all', 'origin')
$pushUrls = @($pushUrl.Out | Where-Object { $_.Trim() })
$pushSame = ($pushUrl.Code -eq 0 -and $pushUrls.Count -eq 1 -and $pushUrls[0].Trim() -ceq $originUrl)

# Open PRs that still use the branch as their base (a stacked PR) or head.
function Get-OpenPrsOnBranch([string]$Name) {
    $byBase = Invoke-CoordGhJson @('pr', 'list', '--repo', $originUrl, '--state', 'open', '--base', $Name, '--json', 'number')
    $byHead = Invoke-CoordGhJson @('pr', 'list', '--repo', $originUrl, '--state', 'open', '--head', $Name, '--json', 'number')
    # A wrapper object: an empty array returned bare would unroll to $null.
    if (-not $byBase.Ok -or -not $byHead.Ok -or -not ($byBase.Data -is [array]) -or -not ($byHead.Data -is [array])) { return [pscustomobject]@{ Ok = $false; List = @() } }
    return [pscustomobject]@{ Ok = $true; List = [string[]]@(@($byBase.Data) + @($byHead.Data) | ForEach-Object { "#$($_.number)" }) }
}

# The push that deletes the branch. It is built here so that the "would run"
# text and the real call share one argument list, and it is run in exactly one
# place below, under -DeleteBranch.
$deleteArgs = @('push', '--quiet', "--force-with-lease=refs/heads/${headRef}:$head", 'origin', ":refs/heads/$headRef")

if (-not $mergeOk) { $branchPart = 'kept: merge not verified on origin' }
elseif ($cross) { $branchPart = 'kept: fork PR (its branch is not on this origin)' }
elseif ($headRef -ceq $base) { $branchPart = "kept: '$headRef' is the base branch" }
elseif (-not $defaultKnown -and $sym.Code -ne 0) { $branchPart = "unknown: origin's default branch could not be read (git ls-remote --symref failed)"; $problems.Add('default branch unknown') }
elseif (-not $defaultKnown) { $branchPart = "unknown: origin's default branch could not be read (git ls-remote --symref named no branch)"; $problems.Add('default branch unknown') }
elseif ($headRef -ceq $defaultBranch) { $branchPart = "kept: '$headRef' is origin's default branch" }
elseif (@('main', 'master') -contains $headRef) { $branchPart = "kept: '$headRef' is a protected name (main/master)" }
elseif (-not $pushSame) { $branchPart = "kept: origin pushes to $($pushUrls.Count) URL(s), not exactly its fetch URL"; $problems.Add('push URL differs') }
else {
    $tip = Read-RemoteTip $headRef
    if (-not $tip.Ok) { $branchPart = 'unknown: git ls-remote failed'; $problems.Add('branch read failed') }
    elseif (-not $tip.Tip) { $branchPart = 'already gone' }
    elseif ($tip.Tip -cne $head) { $branchPart = "kept: tip moved to $(Get-Short $tip.Tip) after the merged head $(Get-Short $head)" }
    else {
        $onBranch = Get-OpenPrsOnBranch $headRef
        if (-not $onBranch.Ok) { $branchPart = 'unknown: could not list open PRs on the branch (gh failed)'; $problems.Add('open-PR check failed') }
        elseif ($onBranch.List.Count) { $branchPart = "kept: open PR(s) $($onBranch.List -join ', ') still use '$headRef'" }
        elseif (-not $DeleteBranch) {
            # Every guard passed and the delete is deliberate, not default: say what -DeleteBranch would run.
            # The line is meant to be pasted into a shell, and git accepts ref names with $ ; & ( ) in them,
            # which a shell would run. Only a name of plain characters is printed as a command.
            if ($headRef -cmatch '\A[A-Za-z0-9._/-]+\z') { $branchPart = "kept: -DeleteBranch not given; would run: git $(ConvertTo-CoordArgLine $deleteArgs)" }
            else { $branchPart = "kept: -DeleteBranch not given; the branch name has characters a shell would act on, so no command is printed (pass -DeleteBranch to delete it)" }
        }
        else {
            $del = Invoke-CoordGit $repoRoot $deleteArgs
            $again = Read-RemoteTip $headRef
            if (-not $again.Ok) { $branchPart = "unknown: delete exit $($del.Code), re-read failed"; $problems.Add('branch re-read failed') }
            elseif ($again.Tip) { $branchPart = "kept: delete failed (exit $($del.Code)), still on origin at $(Get-Short $again.Tip)"; $problems.Add('branch delete failed') }
            elseif ($del.Code -ne 0) { $branchPart = "unknown: gone on re-read, but the delete exited $($del.Code)"; $problems.Add('branch delete exit code') }
            else { $branchPart = 'deleted' }
        }
    }
}

# 4. Launch checkout fast-forward.
function Get-CheckoutPart {
    if (-not $mergeOk) { return 'skipped: merge not verified on origin' }
    if ($NoFastForward) { return 'skipped: -NoFastForward' }
    $gd = Invoke-CoordGit $repoRoot @('rev-parse', '--path-format=absolute', '--git-dir')
    $cd = Invoke-CoordGit $repoRoot @('rev-parse', '--path-format=absolute', '--git-common-dir')
    if ($gd.Code -ne 0 -or $cd.Code -ne 0) { $problems.Add('checkout read failed'); return 'failed: could not read the git dirs' }
    if (-not [string]::Equals((ConvertTo-CoordFullPath $gd.Out[0]), (ConvertTo-CoordFullPath $cd.Out[0]), (Get-CoordPathComparison))) {
        return 'skipped: a linked worktree, not the main checkout'
    }
    $br = Invoke-CoordGit $repoRoot @('branch', '--show-current')
    $cur = if ($br.Out.Count) { $br.Out[0].Trim() } else { '' }
    if ($cur -cne $base) { return "skipped: on '$cur', not on $base" }
    $st = Invoke-CoordGit $repoRoot @('status', '--porcelain', '--untracked-files=no')
    if ($st.Code -ne 0) { $problems.Add('checkout status failed'); return 'failed: git status failed' }
    if (@($st.Out | Where-Object { $_ }).Count) { return 'skipped: tracked change(s) in the checkout' }
    $ahead = Invoke-CoordGit $repoRoot @('rev-list', '--count', "$baseRef..HEAD")
    if ($ahead.Code -ne 0) { $problems.Add('checkout read failed'); return 'failed: git rev-list failed' }
    if ([int]$ahead.Out[0] -gt 0) { return "skipped: diverged ($($ahead.Out[0]) local commit(s) not on origin/$base)" }
    $before = (Invoke-CoordGit $repoRoot @('rev-parse', 'HEAD')).Out[0]
    $target = (Invoke-CoordGit $repoRoot @('rev-parse', $baseRef)).Out[0]
    if ($before -ceq $target) { return 'current' }
    $ff = Invoke-CoordGit $repoRoot @('merge', '--ff-only', '--quiet', $baseRef)
    if ($ff.Code -ne 0) { $problems.Add('fast-forward failed'); return "failed: git refused the fast-forward (exit $($ff.Code))" }
    $after = (Invoke-CoordGit $repoRoot @('rev-parse', 'HEAD')).Out[0]
    return "ff $(Get-Short $before)..$(Get-Short $after)"
}
$checkoutPart = Get-CheckoutPart

# 5. Config sanity.
$warns = New-Object System.Collections.Generic.List[string]
$b = Invoke-CoordGit $repoRoot @('config', '--local', '--bool', 'core.bare')
if ($b.Code -eq 0 -and $b.Out[0] -eq 'true') { $warns.Add('core.bare=true') }
$a = Invoke-CoordGit $repoRoot @('config', '--local', '--get', 'core.autocrlf')
if ($a.Code -eq 0) { $warns.Add("core.autocrlf=$($a.Out[0]) (local)") }
$d = Invoke-CoordGit $repoRoot @('config', '--local', '--name-only', '--get-regexp', '^diff\.')
foreach ($k in @($d.Out | Where-Object { $_ })) { $warns.Add("$k (local)") }
$u = Invoke-CoordGit $repoRoot @('config', 'user.name')
if ($u.Code -ne 0 -or -not ($u.Out -join '').Trim()) { $warns.Add('user.name is empty') }
$mainRoot = Get-CoordMainRoot $repoRoot
if ($mainRoot -and (Test-Path -LiteralPath (Join-Path $mainRoot '.githooks') -PathType Container)) {
    $hp = Invoke-CoordGit $repoRoot @('config', 'core.hooksPath')
    $hv = if ($hp.Code -eq 0) { ($hp.Out -join '').Trim() } else { '' }
    $okHooks = ($hv -ceq '.githooks') -or ($hv -and [string]::Equals((ConvertTo-CoordFullPath $hv), (ConvertTo-CoordFullPath (Join-Path $mainRoot '.githooks')), (Get-CoordPathComparison)))
    if (-not $okHooks) { $warns.Add($(if ($hv) { "core.hooksPath=$hv" } else { 'core.hooksPath unset (.githooks not active)' })) }
}
$configPart = if ($warns.Count) { "WARN: $($warns -join ', ')" } else { 'ok' }

# 6. NOTIFY lines (after an OK verdict only): one paste-ready line per OTHER live
# ledger row of this repo. Nothing is sent; a ledger that is absent prints
# nothing; one that exists but cannot be read or parsed, a mergedAt that is not
# a time, or a base tip that is not a commit prints the one `NOTIFY: none
# printed - <reason>` line. None of it can change the verdict or the exit code.
function Get-NotifyOutput {
    $path = if ($Ledger) { $Ledger } else { Get-CoordLedgerPath (Get-Location).Path }
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return @() }
    try { $rows = @(Read-CoordLedgerTracks $path) }
    catch { return @("NOTIFY: none printed - ledger not read: $(([string]$_.Exception.Message) -replace '\s+', ' ')") }
    $repoMain = if ($mainRoot) { $mainRoot } else { $repoRoot }
    # Same row test as slot-check.ps1: a full-path Repo cell; the merged track's own row is the one on its head
    # branch. Live = not led by MERGED or DONE (Test-CoordRowTerminal).
    # A Repo cell that cannot be read as a path (GetFullPath throws on it in Windows PowerShell 5.1) skips that
    # row only, with a line of its own, so one odd row never silences the others.
    $extra = New-Object System.Collections.Generic.List[string]
    $others = @(foreach ($cand in $rows) {
            if ($cand.Branch -ceq $headRef -or (Test-CoordRowTerminal $cand.Status) -or $cand.Repo -notmatch '[\\/:]') { continue }
            try { if ((Resolve-CoordLedgerRepo $cand.Repo @($repoMain)).Match) { $cand } }
            catch { $extra.Add("NOTIFY: none printed - row '$(if ($cand.Track) { $cand.Track } else { $cand.Branch })': its Repo cell is not a usable path") }
        })
    if (-not $others.Count) { return $extra.ToArray() }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $stamp = [DateTimeOffset]::MinValue
    $mAt = $pv.PSObject.Properties['mergedAt']
    $okTime = $false
    if ($mAt -and $mAt.Value -is [datetime]) { $stamp = [DateTimeOffset]$mAt.Value; $okTime = $true }
    elseif ($mAt -and $mAt.Value -is [string] -and $mAt.Value -match '^\d{4}-\d{2}-\d{2}T') {
        $okTime = [DateTimeOffset]::TryParse($mAt.Value, $inv, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$stamp)
    }
    if (-not $okTime) { return @('NOTIFY: none printed - gh gave no valid mergedAt time') + $extra.ToArray() }
    # The full ref, like every comparison above: a local branch or tag named origin/<base> cannot shadow it.
    $tip = Invoke-CoordGit $repoRoot @('rev-parse', '--verify', '--quiet', "$baseRef^{commit}")
    $tipSha = if ($tip.Code -eq 0 -and $tip.Out.Count) { ([string]$tip.Out[0]).Trim() } else { '' }
    if (-not (Test-CoordSha40 $tipSha)) { return @("NOTIFY: none printed - could not read the $baseRef tip as a commit") + $extra.ToArray() }
    $time = $stamp.ToLocalTime().ToString('HH:mm', $inv)
    $repoName = Split-Path -Leaf $repoMain
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($row in $others) {
        $name = if ($row.Track) { $row.Track } else { $row.Branch }
        $sess = if ($row.Session) { $row.Session } else { 'no session id' }
        $out.Add("NOTIFY $name ($sess): #$Pr merged $time as $(Get-Short $mc); $repoName $base is now $(Get-Short $tipSha); fetch + merge origin/$base before your next push")
    }
    return $out.ToArray() + $extra.ToArray()
}

Write-Output "PR #$Pr MERGED head=$headRef @ $head base=$base merge=$mc"
Write-Output "merge commit: $mergePart"
Write-Output "branch: $branchPart"
Write-Output "checkout: $checkoutPart"
Write-Output "config: $configPart"
$verdict = if ($problems.Count -or $warns.Count) { 'PROBLEM' } else { 'OK' }
if ($verdict -eq 'OK') {
    try { $notify = @(Get-NotifyOutput) } catch { $notify = @("NOTIFY: none printed - $(([string]$_.Exception.Message) -replace '\s+', ' ')") }
    foreach ($line in $notify) { Write-Output $line }
}
Write-Output "MERGE-VERIFY #${Pr}: $verdict - $mergePart; branch $branchPart; checkout $checkoutPart; config $configPart"
if ($verdict -eq 'OK') { exit 0 }
exit 1
