# Ported from the private coordinate toolkit (repo-snapshot.ps1), 2026-10-28.
#
# repo-snapshot.ps1 - the coordinator's start-of-window read, one screen per repo.
#
# Prints, per repo: origin/main head, local branch + dirty count, open PRs with their
# non-passing checks, remote branches, worktrees, the newest handover, and the latest
# CI run on main with the zero-step red run (an Actions billing or runner block) called out, so a red run
# is not misread as code. It edits no branch and no working-tree file: its git writes
# are `git fetch --prune` (remote-tracking refs, FETCH_HEAD, followed tags), the index
# stat cache that `git status` may refresh, and the tree and blob objects
# `git merge-tree --write-tree` stores for the conflict preview (git 2.38+; with an
# older git the preview reads "preview failed").
# -Base (default origin/main) is the remote-tracking branch every head is compared
# with: the heads shown, ahead/behind, files, conflict preview, stale-branch test.
#
# Beyond the plain per-repo read it prints:
#   - `-- tracks`: for each row of the coordination ledger's Tracks table that
#     belongs to this repo and names a Branch: the branch head, its PR (head sha,
#     state, checks), its files against the row's Scope globs, and a
#     `git merge-tree` conflict preview against -Base. Open PRs whose branch
#     is in no row are marked "not in ledger" and get the same files/checks/preview
#     lines without a scope, read at the PR's headRefOid.
#   - `-- stale merged local branches`: local branches whose PR is MERGED (squash
#     merges included) AND whose tip is that PR's head or already on origin/main;
#     a reused name with other commits is shown, not flagged. Marked when a
#     worktree holds them.
#   - A failed `git fetch` is printed and flagged: every head below may be stale.
#   - Every comparison uses refs/remotes/<-Base> (refs/remotes/origin/main by
#     default), never a bare origin/<b>, which a local branch or tag of that
#     name would shadow.
#   - `-- worktrees` with lock state; a lock reason carrying "(pid N)" (Claude Code
#     writes "claude session <name> (pid N)") is checked for a live process.
#   - ONE last line: SNAPSHOT: <n> repo(s); attention: <items | none>.
# A failed gh call or invalid gh output prints "unknown (...)", and a failed preview
# "preview failed": never "(none)" or "no conflicts".
#
# A -Repos path that is not a git repo is skipped but named in attention
# ("<repo> not a git repo"). A finished (MERGED or DONE) Tracks row whose branch is
# gone is noted ("branch gone (row is finished)"), not an attention item.
#
# Ledger: -Ledger <path>, default today's ledger at the canonical location
# (<main checkout of the current directory's repo>/.claude/coordination/<date>.md),
# when it exists. An explicit -Ledger naming a file that does not exist is an
# error ("ledger unreadable: ..."), named in attention, not "no ledger". A Tracks row's Repo is a full path, or a folder name that exactly
# one of -Repos has; a folder name shared by several is an "ambiguous ledger row".
#
# Usage: powershell.exe -ExecutionPolicy Bypass -File repo-snapshot.ps1 -Repos <repo>,<repo> [-Ledger <path>] [-Base origin/main]
#        (default: the current directory). `gh` is optional; PR/CI sections say so when it is absent.
# Sessions are NOT listed here: ask the harness (Claude Code: ListAgents) for that half.

param(
    [string[]]$Repos = @((Get-Location).Path),
    [string]$Ledger = '',
    [string]$Base = 'origin/main'
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'coord-common.ps1')
Initialize-CoordConsole

# git below 2.38 (or none) is refused before any section is printed: a one-line error, exit 2.
$gitFloor = Test-CoordGitFloor
if (-not $gitFloor.Ok) { Write-Output "REPO-SNAPSHOT: NOT RUN - $($gitFloor.Error)"; exit 2 }
$gh = Get-Command gh -ErrorAction SilentlyContinue

# `powershell.exe -File` hands a comma list over as ONE string, so split it here.
$Repos = @($Repos | ForEach-Object { $_ -split '[,;]' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$repoFull = @($Repos | ForEach-Object { $rp = $_; try { ConvertTo-CoordFullPath $rp } catch { $rp } })

$attention = New-Object System.Collections.Generic.List[string]
$baseRef = "refs/remotes/$Base"   # not $base: PowerShell variable names are case-insensitive

# ---- ledger ---------------------------------------------------------------
$ledgerPath = $Ledger
if (-not $ledgerPath) { $ledgerPath = Get-CoordLedgerPath (Get-Location).Path }
$ledgerRows = $null
$ledgerError = $null
if ($ledgerPath -and (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) {
    try { $ledgerRows = @(Read-CoordLedgerTracks $ledgerPath) }
    catch { $ledgerError = "$_"; $attention.Add('ledger unreadable') }
}
elseif ($Ledger) { $ledgerError = "ledger file not found: $Ledger"; $attention.Add('ledger not found') }
$rowsByRepo = @{}
$otherRows = 0
if ($null -ne $ledgerRows) {
    foreach ($row in $ledgerRows) {
        if (-not $row.Branch) { continue }
        $res = Resolve-CoordLedgerRepo $row.Repo $repoFull
        if ($res.Ambiguous) { $attention.Add("ambiguous ledger row '$($row.Track)'"); continue }
        if (-not $res.Match) { $otherRows++; continue }
        if (-not $rowsByRepo.ContainsKey($res.Match)) { $rowsByRepo[$res.Match] = New-Object System.Collections.Generic.List[object] }
        $rowsByRepo[$res.Match].Add($row)
    }
}
if ($null -ne $ledgerRows) { Write-Output "-- ledger $ledgerPath : $(@($ledgerRows).Count) track row(s), $otherRows for repos not in -Repos" }

function Get-ShortSha([string]$Sha) { if ($Sha -and $Sha.Length -ge 12) { return $Sha.Substring(0, 12) } return $Sha }

# A gh list call -> { Ok; Items; Why }. The answer must be an array whose every
# item carries each of $Fields (statusCheckRollup as an array, headRefOid as 40
# hex), else "gh output invalid": a missing field never reads as "no checks".
function Get-GhList {
    param([string[]]$GhArgs, [string[]]$Fields)
    $r = Invoke-CoordGhJson $GhArgs
    if (-not $r.Ok) {
        $why = if ($r.Error -match 'invalid JSON|printed nothing') { 'gh output invalid' } else { 'gh failed' }
        return [pscustomobject]@{ Ok = $false; Items = @(); Why = $why }
    }
    $bad = [pscustomobject]@{ Ok = $false; Items = @(); Why = 'gh output invalid' }
    if (-not ($r.Data -is [array])) { return $bad }
    foreach ($i in $r.Data) {
        if ($null -eq $i) { return $bad }
        foreach ($f in $Fields) {
            if (-not $i.PSObject.Properties[$f]) { return $bad }
            if ($f -eq 'statusCheckRollup' -and -not ($i.statusCheckRollup -is [array])) { return $bad }
            if ($f -eq 'headRefOid' -and -not (Test-CoordSha40 ([string]$i.headRefOid))) { return $bad }
        }
    }
    return [pscustomobject]@{ Ok = $true; Items = @($r.Data); Why = $null }
}

function Format-Checks($Rollup) {
    $s = Get-CoordCheckSummary $Rollup
    $line = "checks: $($s.Pass.Count) passed, $($s.Pending.Count) pending, $($s.Fail.Count) failing"
    if ($s.Pending.Count) { $line += "; pending: $($s.Pending -join ', ')" }
    if ($s.Fail.Count) { $line += "; failing: $($s.Fail -join ', ')" }
    return [pscustomobject]@{ Line = $line; Summary = $s }
}

# Files and conflict-preview lines for a head sha: { Lines; Outside; Preview }.
# The caller prints Lines (a function that printed AND returned would hand its
# printed lines to the caller's variable instead of the screen).
function Get-HeadDetail {
    param([string]$Repo, [string]$Head, [string[]]$Globs, [string]$Indent)
    $lines = New-Object System.Collections.Generic.List[string]
    $cf = Get-CoordChangedFiles $Repo $baseRef $Head
    $outside = @()
    if (-not $cf.Ok) { $lines.Add("${Indent}files: unknown ($($cf.Error))") }
    elseif ($null -eq $Globs) { $lines.Add("${Indent}files: $($cf.Files.Count) changed (no scope declared)") }
    else {
        $outside = @($cf.Files | Where-Object { -not (Test-CoordInScope $_ $Globs) })
        $tail = ''
        if ($outside.Count) {
            $tail = ': ' + ((@($outside | Select-Object -First 8)) -join ', ')
            if ($outside.Count -gt 8) { $tail += " (+$($outside.Count - 8) more)" }
        }
        $lines.Add("${Indent}files: $($cf.Files.Count) changed, $($outside.Count) out of scope$tail")
    }
    $pv = Get-CoordConflictPreview $Repo $baseRef $Head
    switch ($pv.State) {
        'clean' { $lines.Add("${Indent}conflict preview: no conflicts") }
        'conflicts' { $lines.Add("${Indent}conflict preview: $($pv.Files.Count) conflicted: $($pv.Files -join ', ')") }
        default { $lines.Add("${Indent}conflict preview: preview failed") }
    }
    return [pscustomobject]@{ Lines = $lines.ToArray(); Outside = $outside; Preview = $pv.State }
}

foreach ($repo in $Repos) {
    if (-not (Test-Path (Join-Path $repo '.git'))) { Write-Output "== $repo : not a git repo (skipped)"; $attention.Add("$repo not a git repo"); continue }
    $repoKey = ConvertTo-CoordFullPath $repo
    $leaf = Split-Path -Leaf $repoKey
    Write-Output "================================================================"
    Write-Output "== $repo  ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))"
    Write-Output "================================================================"
    $fetch = Invoke-CoordGit $repo @('fetch', '--prune', '--quiet')
    if ($fetch.Code -ne 0) {
        Write-Output "-- fetch: FAILED (exit $($fetch.Code)) - every origin ref below may be stale"
        $attention.Add("$leaf fetch failed")
    }
    $originUrl = (Invoke-CoordGit $repo @('remote', 'get-url', 'origin')).Out | Select-Object -First 1

    Write-Output "-- $Base"
    (Invoke-CoordGit $repo @('log', '--oneline', '-3', $baseRef)).Out | ForEach-Object { Write-Output $_ }
    $branch = (Invoke-CoordGit $repo @('branch', '--show-current')).Out | Select-Object -First 1
    $dirty = @((Invoke-CoordGit $repo @('status', '--short')).Out | Where-Object { $_ }).Count
    $ab = (Invoke-CoordGit $repo @('rev-list', '--left-right', '--count', "$baseRef...HEAD")).Out | Select-Object -First 1
    Write-Output "-- local: branch=$branch dirty=$dirty (behind/ahead ${Base}: $ab)"

    # Ledger rows for this repo, by branch.
    # .ToArray(), not @(...): wrapping a generic List in @() inside an if
    # expression throws "Argument types do not match" in Windows PowerShell 5.1.
    $tracks = @()
    if ($rowsByRepo.ContainsKey($repoKey)) { $tracks = $rowsByRepo[$repoKey].ToArray() }
    # Case-sensitive: git branch names are; a PR on `Feat` is not the track `feat`.
    $trackBranches = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($t in $tracks) { [void]$trackBranches.Add([string]$t.Branch) }

    Write-Output "-- open PRs"
    if ($gh) {
        $open = Get-GhList @('pr', 'list', '--repo', $originUrl, '--state', 'open', '--json', 'number,title,headRefName,headRefOid,isDraft,statusCheckRollup') @('number', 'headRefName', 'headRefOid', 'isDraft', 'statusCheckRollup')
        if (-not $open.Ok) { Write-Output "   unknown ($($open.Why))"; $attention.Add("$leaf open PRs unknown") }
        elseif ($open.Items.Count -eq 0) { Write-Output "   (none)" }
        foreach ($p in $open.Items) {
            $flag = if ($p.isDraft) { ' [DRAFT]' } else { '' }
            $inLedger = $trackBranches.Contains([string]$p.headRefName)
            $mark = if ($inLedger) { '' } else { ' [not in ledger]' }
            Write-Output "   #$($p.number)$flag $($p.headRefName) :: $($p.title)$mark"
            if (-not $inLedger) {
                $pn = "PR #$($p.number)"
                if ($null -ne $ledgerRows) { $attention.Add("$leaf $pn not in ledger") }
                $fc = Format-Checks $p.statusCheckRollup
                Write-Output "      $($fc.Line)"
                if ($fc.Summary.Fail.Count) { $attention.Add("$leaf $pn failing") }
                # The PR's own head (headRefOid), never a same-named origin branch:
                # a fork PR's branch may not be on origin at all.
                $known = Invoke-CoordGit $repo @('cat-file', '-e', "$($p.headRefOid)^{commit}")
                if ($known.Code -eq 0) {
                    $d = Get-HeadDetail $repo ([string]$p.headRefOid) $null '      '
                    $d.Lines | ForEach-Object { Write-Output $_ }
                    if ($d.Preview -eq 'conflicts') { $attention.Add("$leaf $pn conflict") }
                    if ($d.Preview -eq 'failed') { $attention.Add("$leaf $pn preview failed") }
                }
                else {
                    # Typically a fork PR: its head is published only as
                    # refs/pull/<n>/head, which the snapshot does not fetch
                    # (slot-check does). Reported, but the unknown preview is not
                    # an attention item, or it would repeat on every run. A
                    # same-repo head lands here too when the fetch failed (its own
                    # attention item) or went to another remote (a bare fetch
                    # follows the current branch's upstream).
                    Write-Output "      files: unknown (head $(Get-ShortSha ([string]$p.headRefOid)) not fetched here)"
                    Write-Output "      conflict preview: preview failed"
                }
            }
        }
    } else { Write-Output "   (gh not installed: PR state unknown)" }

    Write-Output "-- tracks$(if ($null -ne $ledgerRows) { " (ledger $ledgerPath)" } elseif ($ledgerError) { " (ledger $ledgerPath)" } else { ': no ledger' })"
    if ($ledgerError) { Write-Output "   ledger unreadable: $ledgerError" }
    elseif ($null -ne $ledgerRows -and $tracks.Count -eq 0) { Write-Output "   (no ledger rows for this repo)" }
    foreach ($t in $tracks) {
        $name = if ($t.Track) { $t.Track } else { $t.Branch }
        $hr = Invoke-CoordGit $repo @('rev-parse', '--verify', '--quiet', "refs/remotes/origin/$($t.Branch)^{commit}")
        $where = 'origin'
        if ($hr.Code -ne 0 -or -not $hr.Out.Count) {
            $hr = Invoke-CoordGit $repo @('rev-parse', '--verify', '--quiet', "refs/heads/$($t.Branch)^{commit}")
            $where = 'local only'
        }
        if ($hr.Code -ne 0 -or -not $hr.Out.Count) {
            if (Test-CoordRowTerminal $t.Status) { Write-Output "   [$name] $($t.Branch): branch gone (row is finished)" }
            else {
                Write-Output "   [$name] $($t.Branch): branch not found on origin or locally"
                $attention.Add("$name branch not found")
            }
            continue
        }
        $head = $hr.Out[0].Trim()
        Write-Output "   [$name] $($t.Branch) @ $(Get-ShortSha $head) ($where)"
        $failing = $false
        if ($gh) {
            $pl = Get-GhList @('pr', 'list', '--repo', $originUrl, '--head', $t.Branch, '--state', 'all', '--json', 'number,state,headRefName,headRefOid,isDraft,statusCheckRollup') @('number', 'state', 'headRefName', 'headRefOid', 'isDraft', 'statusCheckRollup')
            if (-not $pl.Ok) { Write-Output "      PR: unknown ($($pl.Why))"; $attention.Add("$name PR unknown") }
            elseif ($pl.Items.Count -eq 0) { Write-Output "      PR: no PR yet" }
            else {
                $pick = @($pl.Items | Where-Object { $_.state -eq 'OPEN' } | Select-Object -First 1)
                if (-not $pick.Count) { $pick = @($pl.Items | Select-Object -First 1) }
                $p = $pick[0]
                $flag = if ($p.isDraft) { ' [DRAFT]' } else { '' }
                $moved = if ([string]$p.headRefOid -and [string]$p.headRefOid -cne $head) { " (differs from the branch head $(Get-ShortSha $head))" } else { '' }
                Write-Output "      PR: #$($p.number) $($p.state)$flag @ $(Get-ShortSha ([string]$p.headRefOid))$moved"
                $fc = Format-Checks $p.statusCheckRollup
                Write-Output "      $($fc.Line)"
                if ($fc.Summary.Fail.Count) { $failing = $true }
            }
        } else { Write-Output "      PR: unknown (gh not installed)" }
        $globs = if ($t.Scope) { Split-CoordScope @($t.Scope) } else { $null }
        $d = Get-HeadDetail $repo $head $globs '      '
        $d.Lines | ForEach-Object { Write-Output $_ }
        if ($d.Outside.Count) { $attention.Add("$name out of scope") }
        if ($d.Preview -eq 'conflicts') { $attention.Add("$name conflict") }
        if ($d.Preview -eq 'failed') { $attention.Add("$name preview failed") }
        if ($failing) { $attention.Add("$name failing") }
    }

    Write-Output "-- remote branches"
    (Invoke-CoordGit $repo @('branch', '-r')).Out | Where-Object { $_ -notmatch 'HEAD' } | ForEach-Object { Write-Output "   $($_.Trim())" }

    # Worktrees from the porcelain list: path, branch, lock (+ pid check), prunable.
    Write-Output "-- worktrees"
    $wtList = New-Object System.Collections.Generic.List[object]
    $cur = $null
    foreach ($line in (Invoke-CoordGit $repo @('worktree', 'list', '--porcelain')).Out) {
        if ($line -match '^worktree (.+)$') { $cur = [ordered]@{ Path = $Matches[1]; Branch = '(detached)'; Locked = $null; Prunable = $false }; $wtList.Add($cur) }
        elseif ($null -eq $cur) { continue }
        elseif ($line -match '^branch refs/heads/(.+)$') { $cur.Branch = $Matches[1] }
        elseif ($line -match '^bare$') { $cur.Branch = '(bare)' }
        elseif ($line -match '^locked ?(.*)$') { $cur.Locked = $Matches[1] }
        elseif ($line -match '^prunable') { $cur.Prunable = $true }
    }
    $heldBy = New-Object System.Collections.Hashtable ([System.StringComparer]::Ordinal)
    foreach ($w in $wtList) {
        $heldBy[$w.Branch] = $w.Path
        $lock = 'unlocked'
        if ($null -ne $w.Locked) {
            $lock = "locked: $($w.Locked)"
            if ($w.Locked -match '\(pid (\d+)\)') {
                $procId = [int]$Matches[1]
                if (Get-Process -Id $procId -ErrorAction SilentlyContinue) { $lock += ' - pid alive' }
                else { $lock += " - pid $procId not running (stale lock?)"; $attention.Add("stale lock $(Split-Path -Leaf $w.Path)") }
            }
        }
        $pr = if ($w.Prunable) { ' [prunable]' } else { '' }
        Write-Output "   $($w.Path) [$($w.Branch)] $lock$pr"
    }

    Write-Output "-- stale merged local branches"
    if ($gh) {
        $merged = Get-GhList @('pr', 'list', '--repo', $originUrl, '--state', 'merged', '--limit', '100', '--json', 'number,headRefName,headRefOid') @('number', 'headRefName', 'headRefOid')
        if (-not $merged.Ok) { Write-Output "   unknown ($($merged.Why))" }
        else {
            # Every merged PR per head branch name (a name can be reused).
            $byRef = New-Object System.Collections.Hashtable ([System.StringComparer]::Ordinal)
            foreach ($m in $merged.Items) {
                $k = [string]$m.headRefName
                if (-not $byRef.ContainsKey($k)) { $byRef[$k] = New-Object System.Collections.Generic.List[object] }
                $byRef[$k].Add($m)
            }
            $locals = @((Invoke-CoordGit $repo @('for-each-ref', '--format=%(refname:short) %(objectname)', 'refs/heads')).Out | Where-Object { $_ })
            $found = 0
            foreach ($entry in $locals) {
                $sp = $entry.LastIndexOf(' ')
                $b = $entry.Substring(0, $sp)
                $tip = $entry.Substring($sp + 1)
                if ($b -ceq 'main' -or $b -ceq 'master' -or $b -ceq $branch) { continue }
                if (-not $byRef.ContainsKey($b)) { continue }
                $prs = $byRef[$b].ToArray()
                $nums = ($prs | ForEach-Object { "#$($_.number)" }) -join ', '
                # Stale only when its work is merged: the tip IS a merged PR's
                # head, or is already contained in origin/main.
                $same = @($prs | Where-Object { [string]$_.headRefOid -ceq $tip }).Count -gt 0
                $onMain = (Invoke-CoordGit $repo @('merge-base', '--is-ancestor', $tip, $baseRef)).Code -eq 0
                $held = if ($heldBy.ContainsKey($b)) { ", held by worktree $($heldBy[$b])" } else { '' }
                if ($same -or $onMain) {
                    $found++
                    Write-Output "   $b (PR $nums merged)$held"
                    $attention.Add("stale merged branch $b")
                }
                else { Write-Output "   $b - name matches merged PR $nums, but the tip $(Get-ShortSha $tip) differs (new work? not flagged)$held" }
            }
            if ($found -eq 0) { Write-Output "   (none)" }
        }
    } else { Write-Output "   (gh not installed)" }

    Write-Output "-- newest handover"
    $ho = Join-Path (Join-Path $repo '.claude') 'handovers'
    if (Test-Path $ho) {
        $f = Get-ChildItem $ho -File -Filter '*.md' | Where-Object { $_.Name -ne 'README.md' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($f) { Write-Output "   $($f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')) $($f.Name)" } else { Write-Output "   (none)" }
    } else { Write-Output "   (no .claude/handovers)" }

    Write-Output "-- latest CI run on main"
    if ($gh) {
        $runs = Invoke-CoordGhJson @('run', 'list', '--repo', $originUrl, '--branch', 'main', '--limit', '1', '--json', 'databaseId,status,conclusion,createdAt')
        if (-not $runs.Ok) { Write-Output "   unknown (gh failed)" }
        else {
            $run = @($runs.Data) | Select-Object -First 1
            if ($run) {
                $line = "   $($run.createdAt) $($run.status)/$($run.conclusion)"
                if ($run.conclusion -eq 'failure') {
                    $view = Invoke-CoordGhJson @('run', 'view', "$($run.databaseId)", '--repo', $originUrl, '--json', 'jobs')
                    if ($view.Ok) {
                        $jobs = @($view.Data.jobs)
                        $zeroStep = @($jobs | Where-Object { $_.conclusion -eq 'failure' -and (@($_.steps).Count -eq 0) }).Count
                        if ($zeroStep -gt 0 -and $zeroStep -eq @($jobs | Where-Object { $_.conclusion -eq 'failure' }).Count) {
                            $line += "  <- every failed job has ZERO steps: Actions billing/runner block, not code"
                        }
                    }
                }
                Write-Output $line
            } else { Write-Output "   (no runs found)" }
        }
    } else { Write-Output "   (gh not installed)" }
    Write-Output ""
}

$items = @($attention | Select-Object -Unique)
$att = if ($items.Count) { $items -join ', ' } else { 'none' }
Write-Output "SNAPSHOT: $($Repos.Count) repo(s); attention: $att"
