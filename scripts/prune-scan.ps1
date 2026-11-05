# Ported from the private coordinate toolkit (prune-scan.ps1), 2026-11-05.
#
# prune-scan.ps1 - which worktrees and branches can go? One verdict per item.
#
# For each repo: one line per worktree, local branch and origin branch, SAFE or
# KEEP <reason>, then ONE last line:
#   PRUNE-SCAN: <n> SAFE, <m> KEEP[; applied <a>, failed <f>][; COULD NOT CHECK: <repo> (<reason>), ...]
# A `ledger:` line first names every ledger read, or says why none was.
# Every rule that cannot be evaluated is KEEP: an unknown is never a yes.
#
# Branch (refs/heads/<b>, and refs/remotes/origin/<b> after `git fetch --prune`), SAFE only when:
#   - it is not main, master or HEAD (any case) or origin's default branch (read from
#     origin with `ls-remote --symref`, as merge-verify.ps1 does; unknown -> every branch KEEP);
#   - no live ledger row (Status not led by MERGED/DONE) names it as its Branch (any case),
#     unless the row's Repo cell resolves to another existing repo's main checkout or is the
#     folder name of another repo scanned in this run (an unresolved cell protects);
#   - a merged PR that is not cross-repository has headRefOid == the branch tip
#     (`gh pr list --state merged --head <b>`), and that PR merged into origin's default
#     branch, or the tip is contained in it (a PR merged into a stacked base that never
#     reached main is KEEP). A tip that moved past the merged head holds commits nobody
#     merged: KEEP. Being contained in origin/main alone is NOT enough: a fresh track
#     branch cut from main has no commits yet and is contained too;
#   - no open PR uses it as head or base;
#   - local: not a symbolic ref (deleting one through it deletes its target); no other
#     local branch has its name in another case (on Windows deleting one
#     removed both); no worktree that holds it (any case) is KEEP: the main checkout
#     included, and a worktree mid-rebase or mid-bisect (listed as detached; the branches are
#     read from its git dir's rebase-merge/head-name, rebase-apply/head-name, BISECT_START
#     and rebase-merge/update-refs); a git dir that cannot be read, or a prunable detached
#     worktree, makes every local and origin branch KEEP;
#   - remote: origin has exactly one push URL and it is the fetch URL, and no KEEP worktree
#     holds a local branch of the same name (any case) or one that tracks it (a live session's stays).
# Worktree (`git worktree list --porcelain`), SAFE only when: not the main checkout,
#   not bare, prunable, locked (a dead-pid lock too) or detached; no session cwd
#   (-SessionCwds, plus the current directory) and no live ledger row's Cwd (any repo's
#   row) is the worktree or inside it; a session or ledger cwd with a junction or symlink
#   on its path cannot be placed, so it makes every worktree KEEP; no junction or symlink on the
#   worktree's path or inside its tree; `git status --porcelain --untracked-files=all`
#   empty; no file flagged assume-unchanged or skip-worktree (`git ls-files -v`; a sparse
#   checkout is KEEP too); every ignored path (`--ignored=matching`) disposable (a build cache: a segment
#   .dart_tool, build, node_modules, .gradle, Pods, .cxx or ephemeral, or
#   .flutter-plugins*; or, by whole path, one of the two files Flutter regenerates:
#   android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java, or android/local.properties while every line in it is
#   `key=value` for sdk.dir, flutter.sdk, flutter.buildMode, flutter.versionName or flutter.versionCode
#   (Flutter's own keys; values are not checked; a comment or blank line is fine, any other line
#   makes it KEEP, a .worktreeinclude copy of it included); or a plain .worktreeinclude entry byte-identical to the main
#   checkout's copy); and its branch SAFE by the branch rules. Anything else ignored
#   (_inbox/, CODE-REVIEW.md, PLAN.md, settings.local.json, golden failure PNGs, anything
#   unknown) is KEEP.
#
# -Apply acts on SAFE items only, one destructive git call per item (reads before and after it), never chained, in order:
#   1. the worktree's status and ignored files are read again (a file written since the
#      scan makes it FAILED, untouched), then `git worktree remove <path>` (no --force:
#      git refuses a dirty or locked one; it does NOT look at ignored files, hence the re-read).
#      A non-zero exit still counts as removed when the worktree list, read again, no longer shows
#      it and its folder is missing or empty (a session cwd holds it: git removes the files and
#      the entry, cannot delete the folder, exits 255); the line says so. A folder that still holds
#      a file, or a worktree still listed, is FAILED;
#   2. `git update-ref --no-deref -d refs/heads/<b> <tip>`: deletes only while the tip is the merged
#      head; skipped when a worktree holding it was not removed, or when the worktree list,
#      read again right before, shows one on it now (rebase holders are not re-read;
#      branch.<b>.* config stays);
#   3. `git push --force-with-lease=refs/heads/<b>:<tip> origin :refs/heads/<b>`, then an
#      `ls-remote` re-read: "deleted" only when the re-read shows it gone; skipped when a
#      local branch of that name (any case) or tracking it stays: its worktree was not
#      removed, a worktree is on it now, or its delete failed; and when the local branches
#      and worktrees, read again right before, show a worktree on such a local (KEEP or new).
#
# Ledger: -Ledger <path> reads that file only (it must exist). Without it: today's and
# yesterday's ledger at the canonical location of the current directory's repo, and every
# ledger the index of those two days lists (coord-log.ps1 -Register), those that exist.
# COULD NOT CHECK for every repo: an index that cannot be read or lists more than it can
# hold (over 8 ledgers or 64 KiB), a listed path that is a folder, a ledger the scope
# guard's reader refuses (Read-CoordLedgerTracksBounded: no `## Tracks` heading, no table,
# a table that runs to the end of the file, a ragged row), and a Tracks table split by a
# non-table line (the reader would drop the rows below it). Not refused: a file cut between
# the CR and the LF of a table row reads as Ok with fewer rows (the reader's, in coord-common;
# the coord writers swap the file whole, so only a writer that is not atomic can tear it).
# A live row of yesterday's ledger protects only until today's ledger has a row with the same Track
# and Repo (trimmed, any case) that is MERGED or DONE (the carry rule: the track ended). A live
# yesterday row that today's ledger does not end keeps protecting, even beside a live row of the
# same Track today. Ledgers of one day, and one -Ledger file, are equals. A row with no Track cell
# is never dropped. A MERGED/DONE row protects nothing, in any ledger.
# A listed ledger that Test-Path cannot see (it does not exist, or access is denied) is skipped.
# A repo that is not a git checkout, has no origin, whose fetch failed, whose local or
# remote branch list or worktree list failed, or with gh missing is COULD NOT CHECK: no
# item lines, never applied.
#
# Exit: 0 scan done (and every apply succeeded), 1 an apply failed, 2 could not check.
# Usage: powershell.exe -ExecutionPolicy Bypass -File prune-scan.ps1 -Repos <repoA>,<repoB> [-SessionCwds <dir>,<dir>] [-Ledger <path>] [-Apply]
# Lists are split on commas only (a semicolon is legal in a folder name).
# Without -Apply its only writes are `git fetch --prune` (remote-tracking refs).
# Not seen: a cwd on a subst or mapped drive that reaches a worktree (it is compared as given);
# a session that enters a worktree between the scan and its removal; under an ignore line like
# `notes/*`, git prints `notes/build/` alone, which reads as a build cache; GIT_DIR or
# GIT_INDEX_FILE inherited from a hook overrides `git -C <worktree>`; a stale fsmonitor or
# untracked cache can hide an edit from `git status` (and from `git worktree remove`).
# Run -Apply only after the user's OK: it removes worktrees and deletes branches.

param(
    [string[]]$Repos = @((Get-Location).Path),
    [string[]]$SessionCwds = @(),
    [string]$Ledger = '',
    [switch]$Apply
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'coord-common.ps1')
Initialize-CoordConsole

# Verified on Windows PowerShell 5.1 only. -Apply deletes branches and removes worktrees, and the
# checks it leans on (junctions, 8.3 names, a held folder) were measured on Windows: off Windows it
# refuses. The scan alone runs elsewhere, not verified there.
if ($Apply -and -not (Test-CoordWindows)) {
    Write-Output "PRUNE-SCAN: 0 SAFE, 0 KEEP; COULD NOT CHECK: -Apply (not verified off Windows; nothing changed)"
    exit 2
}

# `powershell.exe -File` hands a comma list over as ONE string, so split it here.
function Split-List([string[]]$Items) { return @($Items | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
$Repos = Split-List $Repos
$SessionCwds = Split-List $SessionCwds

function Get-Short([string]$Sha) { if ($Sha -and $Sha.Length -ge 12) { return $Sha.Substring(0, 12) } return $Sha }
function New-OrdinalTable { return (New-Object System.Collections.Hashtable ([System.StringComparer]::Ordinal)) }

# A full path with every 8.3 component (USERNA~1) expanded to its long name: the
# directory search matches short names and returns the long one. A path that does
# not exist keeps the components it cannot find as given.
function Get-LongPath([string]$Path) {
    try { $full = ConvertTo-CoordFullPath $Path } catch { return $Path }
    if (-not (Test-CoordWindows) -or $full -notmatch '~' -or $full.StartsWith('\\')) { return $full }
    $parts = $full.Split('\')
    $cur = $parts[0] + '\'
    for ($i = 1; $i -lt $parts.Count; $i++) {
        if (-not $parts[$i]) { continue }
        $hits = @()
        try { $hits = @([System.IO.Directory]::GetFileSystemEntries($cur, $parts[$i])) } catch { }
        $cur = if ($hits.Count -eq 1) { $hits[0] } else { Join-Path $cur $parts[$i] }
    }
    return $cur.TrimEnd('\')
}

# $Child is $Parent or below it (full long paths, case-insensitive).
function Test-UnderPath([string]$Child, [string]$Parent) {
    if ([string]::Equals($Child, $Parent, (Get-CoordPathComparison))) { return $true }
    return $Child.StartsWith($Parent.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar, (Get-CoordPathComparison))
}

$reparse = [System.IO.FileAttributes]::ReparsePoint
# The first existing component of $Path, itself or an ancestor, that is a junction or symlink; '' when none.
function Find-ReparseOnPath([string]$Path) {
    $cur = $Path
    while ($cur) {
        try { if ((Test-Path -LiteralPath $cur) -and (([System.IO.File]::GetAttributes($cur) -band $reparse) -ne 0)) { return $cur } } catch { return $cur }
        $parent = Split-Path -Parent $cur
        if (-not $parent -or $parent -eq $cur) { break }
        $cur = $parent
    }
    return ''
}
# The first junction or symlink inside $Dir (not descending into one), relative; '' when none; '?' when unreadable.
function Find-ReparseInside([string]$Dir) {
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Dir)
    while ($stack.Count) {
        $d = $stack.Pop()
        try { $entries = @((New-Object System.IO.DirectoryInfo $d).GetFileSystemInfos()) } catch { return '?' }
        foreach ($e in $entries) {
            if (($e.Attributes -band $reparse) -ne 0) { return $e.FullName.Substring($Dir.Length).TrimStart('\') }
            if ($e -is [System.IO.DirectoryInfo]) { $stack.Push($e.FullName) }
        }
    }
    return ''
}

# A gh pr list call -> { Ok; Items; Why }. Every item needs a number; -Merged also a
# 40-hex headRefOid, a boolean isCrossRepository (a missing field is never "not a fork")
# and a non-empty baseRefName.
function Get-GhPrList([string]$Url, [string[]]$Filter, [switch]$Merged) {
    $fields = if ($Merged) { 'number,headRefOid,isCrossRepository,baseRefName' } else { 'number' }
    $r = Invoke-CoordGhJson (@('pr', 'list', '--repo', $Url) + $Filter + @('--json', $fields))
    $bad = [pscustomobject]@{ Ok = $false; Items = @(); Why = 'gh output invalid' }
    if (-not $r.Ok) {
        $why = if ($r.Error -match 'invalid JSON|printed nothing') { 'gh output invalid' } else { 'gh failed' }
        return [pscustomobject]@{ Ok = $false; Items = @(); Why = $why }
    }
    if (-not ($r.Data -is [array])) { return $bad }
    foreach ($i in $r.Data) {
        if ($null -eq $i -or -not $i.PSObject.Properties['number']) { return $bad }
        if ($Merged) {
            if (-not $i.PSObject.Properties['headRefOid'] -or -not (Test-CoordSha40 ([string]$i.headRefOid))) { return $bad }
            if (-not $i.PSObject.Properties['isCrossRepository'] -or -not ($i.isCrossRepository -is [bool])) { return $bad }
            if (-not $i.PSObject.Properties['baseRefName'] -or -not [string]$i.baseRefName) { return $bad }
        }
    }
    return [pscustomobject]@{ Ok = $true; Items = @($r.Data); Why = $null }
}

$disposableDirs = @('.dart_tool', 'build', 'node_modules', '.gradle', 'Pods', '.cxx', 'ephemeral')
$disposableFiles = @('.flutter-plugins', '.flutter-plugins-dependencies')
# Files Flutter and `pub get` regenerate, by their whole repo-relative path (case-sensitive; a file of
# the same name elsewhere is not one of them).
$disposablePaths = @('android/local.properties', 'android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java')

# '' when the ## Tracks section holds one unbroken table; else why not. A table line after
# the line that ended the table (up to the next # or ## heading, as the reader reads it).
function Find-TracksSplit([string]$Path) {
    try { $lines = [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8) } catch { return "ledger unreadable: $(([string]$_.Exception.Message) -replace '\s+', ' ')" }
    $in = $false; $seenRow = $false; $ended = $false
    foreach ($ln in $lines) {
        if (-not $in) { if ($ln -match '^##\s+Tracks\s*$') { $in = $true }; continue }
        if ($ln -match '^#{1,2}\s') { break }
        if ($ln.TrimStart().StartsWith('|')) {
            if ($ended) { return "ledger $Path has a ## Tracks table split by a non-table line (rows below it would be dropped)" }
            $seenRow = $true
        }
        elseif ($seenRow) { $ended = $true }
    }
    return ''
}

# ---- ledgers ----------------------------------------------------------------
$ledgerPaths = New-Object System.Collections.Generic.List[string]
# The age of each ledger read: 0 = today's (or the one -Ledger file), 1 = yesterday's. A file the
# index lists for both days keeps the newer age.
$ledgerAge = New-Object System.Collections.Hashtable ((Get-CoordPathComparison -Comparer))
$ledgerError = ''
$ledgerWhy = ''
if ($Ledger) {
    if (Test-Path -LiteralPath $Ledger -PathType Leaf) { $full = ConvertTo-CoordFullPath $Ledger; $ledgerPaths.Add($full); $ledgerAge[$full] = 0 } else { $ledgerError = "ledger $Ledger not found" }
}
else {
    $seenL = New-Object 'System.Collections.Generic.HashSet[string]' ((Get-CoordPathComparison -Comparer))
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $now = [DateTime]::Now
    $dayAge = 0
    foreach ($day in @($now, $now.AddDays(-1))) {
        $thisAge = $dayAge
        $dayAge++
        $date = $day.ToString('yyyy-MM-dd', $inv)
        $cands = @()
        $own = Get-CoordLedgerPath (Get-Location).Path $date
        if ($own) { $cands += $own }
        $idx = Get-CoordIndexedLedgers -Path (Get-CoordIndexPath $date)
        if (-not $idx.Ok) { $ledgerError = $idx.Error; break }
        if ($idx.Overflow) { $ledgerError = "the ledger index of $date lists more than can be read (over 8 ledgers or 64 KiB)"; break }
        $cands += @($idx.Entries)
        foreach ($c in $cands) {
            if (-not (Test-Path -LiteralPath $c)) { continue }
            if (-not (Test-Path -LiteralPath $c -PathType Leaf)) { $ledgerError = "ledger $c is not a file"; break }
            $full = ConvertTo-CoordFullPath $c
            if ($seenL.Add($full)) { $ledgerPaths.Add($full); $ledgerAge[$full] = $thisAge }
        }
        if ($ledgerError) { break }
    }
    if (-not $ledgerError -and -not $ledgerPaths.Count) { $ledgerWhy = "no ledger for today or yesterday at this repo's canonical location or in the index" }
}
$ledgerRows = New-Object System.Collections.Generic.List[object]
if (-not $ledgerError) {
    foreach ($lp in $ledgerPaths) {
        # The scope guard's reader, one read: no Tracks heading, no table, or a table that
        # runs to the end of the file is refused (a cut between a row's CR and LF is not).
        $rd = Read-CoordLedgerTracksBounded $lp
        if (-not $rd.Ok) { $ledgerError = "ledger unreadable: $(([string]$rd.Error) -replace '\s+', ' ')"; break }
        # The reader ends the table at its first non-table line, so a blank line inside the
        # table would drop every row below it and still read as Ok: refuse a split table.
        $split = Find-TracksSplit $lp
        if ($split) { $ledgerError = $split; break }
        foreach ($row in @($rd.Rows)) { $row | Add-Member -NotePropertyName Age -NotePropertyValue ([int]$ledgerAge[$lp]) -Force; $ledgerRows.Add($row) }
    }
}
if ($ledgerError) { Write-Output "ledger: could not be read ($ledgerError)" }
elseif ($ledgerPaths.Count) { Write-Output "ledger: $($ledgerPaths -join ', ') ($($ledgerRows.Count) track row(s))" }
else { Write-Output "ledger: none ($ledgerWhy); only -SessionCwds protect live work" }
# A row is live when its Status is not MERGED/DONE, unless a NEWER ledger (lower Age) has a row with the
# same Track and Repo (trimmed, any case) whose Status IS MERGED/DONE: the carry rule says the newer row
# speaks for the track, and it says the track ended. A newer row that is live drops nothing: the older
# row keeps protecting its own Branch and Cwd (a reused Track name must not unprotect the old job).
# A row with no Track cell is never dropped, and a track with no row in the newer ledger stays as its
# older row says (never carried: unknown, so it protects).
function Get-RowKey($Row) { return ("$(([string]$Row.Track).Trim())`t$(([string]$Row.Repo).Trim())").ToLowerInvariant() }
$endedAge = New-OrdinalTable
foreach ($row in $ledgerRows) {
    if (-not ([string]$row.Track).Trim() -or -not (Test-CoordRowTerminal $row.Status)) { continue }
    $k = Get-RowKey $row
    if (-not $endedAge.ContainsKey($k) -or $row.Age -lt $endedAge[$k]) { $endedAge[$k] = $row.Age }
}
$liveRows = @($ledgerRows | Where-Object {
    -not (Test-CoordRowTerminal $_.Status) -and
    -not (([string]$_.Track).Trim() -and $endedAge.ContainsKey((Get-RowKey $_)) -and $endedAge[(Get-RowKey $_)] -lt $_.Age)
})

# ---- session cwds ------------------------------------------------------------
$cwds = New-Object System.Collections.Generic.List[string]
$cwdJunction = ''
foreach ($c in @($SessionCwds) + @((Get-Location).Path)) {
    $lp = Get-LongPath $c
    $cwds.Add($lp)
    $j = Find-ReparseOnPath $lp
    if ($j -and -not $cwdJunction) { $cwdJunction = "session cwd $c goes through a junction or symlink ($j), so the worktree it reaches is unknown" }
}
# Every live row's Cwd protects, whatever its Repo cell says (it can only match a worktree path).
$liveCwds = New-Object System.Collections.Generic.List[object]
foreach ($row in $liveRows) {
    $tn = if ($row.Track) { $row.Track } else { $row.Branch }
    if ($row.Cwd -and $row.Cwd -match '[\\/:]') {
        $lp = Get-LongPath ([string]$row.Cwd)
        $liveCwds.Add([pscustomobject]@{ Path = $lp; Track = $tn })
        $j = Find-ReparseOnPath $lp
        if ($j -and -not $cwdJunction) { $cwdJunction = "live ledger row '$tn' cwd goes through a junction or symlink ($j), so the worktree it reaches is unknown" }
    }
}

$couldNot = New-Object System.Collections.Generic.List[string]
$script:safeN = 0
$script:keepN = 0
$script:applied = 0
$script:failed = 0

function Write-Item([string]$Line, $V) {
    if ($V.Safe) { $script:safeN++; Write-Output "${Line}: SAFE ($($V.Why))" }
    else { $script:keepN++; Write-Output "${Line}: KEEP $($V.Why)" }
}
function New-Verdict([bool]$Safe, [string]$Why) { return [pscustomobject]@{ Safe = $Safe; Why = $Why } }

# Folder names of the scanned repos' main checkouts, for bare-name ledger Repo cells.
$repoLeaves = @{}
foreach ($rp in $Repos) { $mr = $null; try { $mr = Get-CoordMainRoot $rp } catch { }; $repoLeaves[$rp] = Split-Path -Leaf $(if ($mr) { $mr } else { ConvertTo-CoordFullPath $rp }) }

foreach ($repo in $Repos) {
    $otherLeaves = @($Repos | Where-Object { $_ -ne $repo } | ForEach-Object { $repoLeaves[$_] })
    if ($ledgerError) { $couldNot.Add("$repo ($ledgerError)"); continue }
    $top = Invoke-CoordGit $repo @('rev-parse', '--show-toplevel')
    if ($top.Code -ne 0 -or -not $top.Out.Count) { $couldNot.Add("$repo (not a git checkout)"); continue }
    $main = Get-CoordMainRoot $repo
    if (-not $main) { $couldNot.Add("$repo (no main checkout found)"); continue }
    $main = Get-LongPath $main
    $u = Invoke-CoordGit $main @('remote', 'get-url', 'origin')
    if ($u.Code -ne 0 -or -not $u.Out.Count) { $couldNot.Add("$main (no origin remote)"); continue }
    $originUrl = $u.Out[0].Trim()
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { $couldNot.Add("$main (gh not installed)"); continue }
    $f = Invoke-CoordGit $main @('fetch', '--quiet', '--prune', 'origin')
    if ($f.Code -ne 0) { $couldNot.Add("$main (git fetch failed, exit $($f.Code))"); continue }
    Write-Output "== $main"

    $defaultBranch = ''
    $sym = Invoke-CoordGit $main @('ls-remote', '--symref', 'origin', 'HEAD')
    if ($sym.Code -eq 0) { foreach ($line in $sym.Out) { if ($line -match '^ref: refs/heads/(\S+)\s+HEAD$') { $defaultBranch = $Matches[1] } } }
    $pushUrl = Invoke-CoordGit $main @('remote', 'get-url', '--push', '--all', 'origin')
    $pushUrls = @($pushUrl.Out | Where-Object { $_.Trim() })
    $pushSame = ($pushUrl.Code -eq 0 -and $pushUrls.Count -eq 1 -and $pushUrls[0].Trim() -ceq $originUrl)

    # Live rows whose Branch protects here: every row, except one whose Repo cell resolves to
    # another existing repo's main checkout or is the folder name of another repo scanned in
    # this run (an unknown is never "another repo").
    # Case-insensitive: a protection table, unlike the gh caches (over-protecting is the safe side).
    $liveBranch = New-Object System.Collections.Hashtable ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($row in $liveRows) {
        if (-not $row.Branch) { continue }
        $cell = ([string]$row.Repo).Trim()
        $applies = $true
        if ($cell -match '[\\/:]') {
            $rowMain = $null
            try { if (Test-Path -LiteralPath $cell -PathType Container) { $rowMain = Get-CoordMainRoot $cell } } catch { $rowMain = $null }
            if ($rowMain -and -not [string]::Equals((Get-LongPath $rowMain), $main, (Get-CoordPathComparison))) { $applies = $false }
        }
        elseif ($cell -and -not [string]::Equals($cell, (Split-Path -Leaf $main), [System.StringComparison]::OrdinalIgnoreCase)) {
            # A bare name is another repo only when it is the folder name of another repo scanned here.
            if (@($otherLeaves | Where-Object { [string]::Equals($_, $cell, [System.StringComparison]::OrdinalIgnoreCase) }).Count) { $applies = $false }
        }
        if ($applies) { $liveBranch[[string]$row.Branch] = $(if ($row.Track) { $row.Track } else { $row.Branch }) }
    }

    # gh answers per branch name (case-sensitive), fetched once (a local and a remote branch share them).
    $mergedCache = New-OrdinalTable
    $openCache = New-OrdinalTable
    function Get-BranchVerdict([string]$Name, [string]$Tip) {
        if (@('main', 'master', 'HEAD') -contains $Name) { return (New-Verdict $false 'protected name (main/master)') }
        if (-not $defaultBranch) { return (New-Verdict $false "origin's default branch unknown (ls-remote --symref named none)") }
        if ([string]::Equals($Name, $defaultBranch, [System.StringComparison]::OrdinalIgnoreCase)) { return (New-Verdict $false "origin's default branch") }
        if ($liveBranch.ContainsKey($Name)) { return (New-Verdict $false "live ledger row '$($liveBranch[$Name])' branch") }
        if (-not $mergedCache.ContainsKey($Name)) { $mergedCache[$Name] = Get-GhPrList $originUrl @('--state', 'merged', '--head', $Name) -Merged }
        $m = $mergedCache[$Name]
        if (-not $m.Ok) { return (New-Verdict $false "unknown ($($m.Why) on the merged-PR list)") }
        $same = @($m.Items | Where-Object { -not $_.isCrossRepository })
        $hit = @($same | Where-Object { [string]$_.headRefOid -ceq $Tip } | Select-Object -First 1)
        if (-not $hit.Count) {
            if ($same.Count) {
                $p = $same[0]
                $anc = Invoke-CoordGit $main @('merge-base', '--is-ancestor', [string]$p.headRefOid, $Tip)
                $how = if ($anc.Code -eq 0) { 'moved past' } else { 'differs from' }
                return (New-Verdict $false "tip $(Get-Short $Tip) $how merged PR #$($p.number) head $(Get-Short ([string]$p.headRefOid))")
            }
            if (@($m.Items).Count) { return (New-Verdict $false "only cross-repository merged PR(s): $((@($m.Items) | ForEach-Object { "#$($_.number)" }) -join ', ')") }
            return (New-Verdict $false 'no merged PR at this tip')
        }
        $pr = $hit[0]
        if ([string]$pr.baseRefName -cne $defaultBranch) {
            $inDefault = (Invoke-CoordGit $main @('merge-base', '--is-ancestor', $Tip, "refs/remotes/origin/$defaultBranch")).Code -eq 0
            if (-not $inDefault) { return (New-Verdict $false "merged PR #$($pr.number) went into '$($pr.baseRefName)', and the tip is not on origin/$defaultBranch") }
        }
        if (-not $openCache.ContainsKey($Name)) {
            $h = Get-GhPrList $originUrl @('--state', 'open', '--head', $Name)
            $b = if ($h.Ok) { Get-GhPrList $originUrl @('--state', 'open', '--base', $Name) } else { $h }
            $openCache[$Name] = if (-not $h.Ok) { $h } elseif (-not $b.Ok) { $b } else { [pscustomobject]@{ Ok = $true; Items = @(@($h.Items) + @($b.Items)); Why = $null } }
        }
        $o = $openCache[$Name]
        if (-not $o.Ok) { return (New-Verdict $false "unknown ($($o.Why) on the open-PR list)") }
        if (@($o.Items).Count) { return (New-Verdict $false "open PR $((@($o.Items) | ForEach-Object { "#$($_.number)" }) -join ', ') still uses it (head or base)") }
        return (New-Verdict $true "merged as PR #$($pr.number) at this tip")
    }

    # Local branches: base verdict first; a worktree's verdict needs it.
    # Each with its upstream: a remote branch a KEEP worktree's local branch tracks stays too.
    $locals = New-Object System.Collections.Generic.List[object]
    $fe = Invoke-CoordGit $main @('for-each-ref', '--format=%(objectname)%09%(upstream)%09%(refname:lstrip=2)%09%(symref)', 'refs/heads')
    $wl = Invoke-CoordGit $main @('worktree', 'list', '--porcelain')
    $rr = Invoke-CoordGit $main @('for-each-ref', '--format=%(objectname) %(refname:lstrip=3)', 'refs/remotes/origin')
    if ($fe.Code -ne 0 -or $wl.Code -ne 0 -or -not $wl.Out.Count -or $rr.Code -ne 0) { $couldNot.Add("$main (git for-each-ref or worktree list failed)"); continue }
    $feEntries = @($fe.Out | Where-Object { $_ })
    # Two local branches whose names differ only in case: on Windows `update-ref -d` of one
    # (packed) also removed the other (loose) - measured. Neither is SAFE.
    $nameCount = New-Object System.Collections.Hashtable ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $feEntries) { $nm = $entry.Split("`t")[2]; $nameCount[$nm] = 1 + [int]$nameCount[$nm] }
    foreach ($entry in $feEntries) {
        $parts = $entry.Split("`t")
        # A symbolic branch ref: deleting it through the ref would delete its target (main, say).
        $v = if ($parts.Count -gt 3 -and $parts[3]) { New-Verdict $false "a symbolic ref to $($parts[3])" }
        elseif ($nameCount[$parts[2]] -gt 1) { New-Verdict $false 'another local branch has the same name in another case (deleting one can delete both)' }
        else { Get-BranchVerdict $parts[2] $parts[0] }
        $locals.Add([pscustomobject]@{ Name = $parts[2]; Tip = $parts[0]; Upstream = $parts[1]; V = $v })
    }
    $localByName = New-OrdinalTable
    foreach ($l in $locals) { $localByName[$l.Name] = $l }

    # Worktrees.
    $wts = New-Object System.Collections.Generic.List[object]
    $cur = $null
    foreach ($line in $wl.Out) {
        if ($line -match '^worktree (.+)$') { $cur = [pscustomobject]@{ Path = (Get-LongPath $Matches[1]); Branch = ''; Holds = @(); Detached = $false; Bare = $false; Locked = $null; Prunable = $false; IsMain = ($wts.Count -eq 0); V = $null }; $wts.Add($cur) }
        elseif ($null -eq $cur) { continue }
        elseif ($line -match '^branch refs/heads/(.+)$') { $cur.Branch = $Matches[1] }
        elseif ($line -match '^detached$') { $cur.Detached = $true }
        elseif ($line -match '^bare$') { $cur.Bare = $true }
        elseif ($line -match '^locked ?(.*)$') { $cur.Locked = $Matches[1] }
        elseif ($line -match '^prunable') { $cur.Prunable = $true }
    }
    # A rebase or bisect in progress shows its worktree as detached, with no branch line, while
    # the branch it is rewriting is named in the worktree's git dir; `update-ref -d` does not check.
    # `rebase --update-refs` also holds every branch its rebase-merge/update-refs names.
    $holdUnknown = ''
    foreach ($w in $wts) {
        if ($w.Bare) { continue }
        if ($w.Prunable) {
            # Its folder is gone, so its git dir is not read: detached, it may be mid-rebase.
            if (-not $w.Branch -and -not $holdUnknown) { $holdUnknown = "worktree $($w.Path) is prunable and detached (a rebase there would hold a branch; git worktree prune by hand)" }
            continue
        }
        $gd = Invoke-CoordGit $w.Path @('rev-parse', '--absolute-git-dir')
        if ($gd.Code -ne 0 -or -not $gd.Out.Count) { if (-not $holdUnknown) { $holdUnknown = "the git dir of worktree $($w.Path) could not be read (a rebase or bisect there would hold a branch)" }; continue }
        $dir = $gd.Out[0].Trim()
        $names = @()
        foreach ($rel in 'rebase-merge/head-name', 'rebase-apply/head-name', 'BISECT_START', 'rebase-merge/update-refs') {
            $fp = Join-Path $dir $rel
            if (-not (Test-Path -LiteralPath $fp -PathType Leaf)) { continue }
            $lines = @()
            try { $lines = @([System.IO.File]::ReadAllLines($fp) | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } catch { if (-not $holdUnknown) { $holdUnknown = "$fp could not be read" } }
            foreach ($ln in $lines) {
                if ($ln -match '^refs/heads/(.+)$') { $names += $Matches[1] }
                elseif ($rel -ne 'rebase-merge/update-refs') { $names += $ln }   # update-refs: the other lines are object ids
            }
        }
        $w.Holds = @($names | Where-Object { $_ -and $_ -cne $w.Branch })
    }
    # Every worktree on each branch (git worktree add -f puts two on one branch; a rebase holds one too).
    # Case-insensitive, like the refs on a Windows disk: a worktree on Feat holds feat too.
    $heldBy = New-Object System.Collections.Hashtable ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($w in $wts) {
        foreach ($b in @(@($w.Branch) + @($w.Holds) | Where-Object { $_ })) {
            if (-not $heldBy.ContainsKey($b)) { $heldBy[$b] = New-Object System.Collections.Generic.List[object] }
            $heldBy[$b].Add($w)
        }
    }
    # The .worktreeinclude entries: plain paths only (a glob line protects nothing).
    $includes = @()
    $wi = Join-Path $main '.worktreeinclude'
    if (Test-Path -LiteralPath $wi -PathType Leaf) {
        $includes = @(Get-Content -LiteralPath $wi -Encoding UTF8 | ForEach-Object { $_.Trim().Replace('\', '/').TrimStart('/') } | Where-Object { $_ -and -not $_.StartsWith('#') -and $_ -notmatch '[*?\[!]' })
    }
    function Test-Disposable([string]$Wt, [string]$Rel) {
        $p = $Rel.Trim('"').TrimEnd('/')
        $segs = $p.Split('/')
        foreach ($s in $segs) { if ($disposableDirs -ccontains $s) { return $true } }
        if ($disposableFiles -ccontains $segs[-1]) { return $true }
        if (-not $Rel.Trim('"').EndsWith('/') -and $disposablePaths -ccontains $p) {
            if ($p -cne 'android/local.properties') { return $true }
            # local.properties can carry hand-written lines (an API key, a signing path): disposable
            # only while every non-comment line is `key=value` for one of Flutter's own keys (the value is
            # not checked). This rule alone judges it: a .worktreeinclude copy identical to main's
            # is KEEP too when it holds another key.
            try { $lines = @([System.IO.File]::ReadAllLines((Join-Path $Wt $p)) | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }) } catch { return $false }
            return (@($lines | Where-Object { $_ -notmatch '^(sdk\.dir|flutter\.sdk|flutter\.buildMode|flutter\.versionName|flutter\.versionCode)\s*=' }).Count -eq 0)
        }
        if ($includes -ccontains $p) {
            $mine = Join-Path $Wt $p
            $theirs = Join-Path $main $p
            if ((Test-Path -LiteralPath $mine -PathType Leaf) -and (Test-Path -LiteralPath $theirs -PathType Leaf)) {
                $h1 = $null; $h2 = $null
                try { $h1 = (Get-FileHash -LiteralPath $mine -Algorithm SHA256 -ErrorAction Stop).Hash; $h2 = (Get-FileHash -LiteralPath $theirs -Algorithm SHA256 -ErrorAction Stop).Hash } catch { return $false }
                return ($h1 -and $h2 -and $h1 -eq $h2)
            }
        }
        return $false
    }
    # What the worktree's folder holds: $null when nothing but disposable files, else a KEEP reason.
    # Run at scan time and again right before `git worktree remove`.
    function Get-ContentKeep([string]$Path) {
        $st = Invoke-CoordGit $Path @('status', '--porcelain', '--untracked-files=all')
        if ($st.Code -ne 0) { return 'unknown (git status failed)' }
        $dirty = @($st.Out | Where-Object { $_ })
        if ($dirty.Count) { return "$($dirty.Count) uncommitted or untracked: $((@($dirty | Select-Object -First 5 | ForEach-Object { $_.Substring(3) })) -join ', ')" }
        # An edit to a file flagged assume-unchanged (tag in lower case) or skip-worktree (S) is
        # invisible to git status, and `git worktree remove` would drop it.
        $lv = Invoke-CoordGit $Path @('ls-files', '-v')
        if ($lv.Code -ne 0) { return 'unknown (git ls-files -v failed)' }
        $flagged = @($lv.Out | Where-Object { $_ -and $_.Length -gt 2 -and ([string]$_[0]) -cmatch '^[a-zS]$' })
        if ($flagged.Count) { return "$($flagged.Count) file(s) flagged assume-unchanged or skip-worktree (an edit there is invisible to git status): $((@($flagged | Select-Object -First 5 | ForEach-Object { $_.Substring(2) })) -join ', ')" }
        $ig = Invoke-CoordGit $Path @('status', '--porcelain', '--ignored=matching', '--untracked-files=all')
        if ($ig.Code -ne 0) { return 'unknown (git status --ignored failed)' }
        $notable = @($ig.Out | Where-Object { $_ -like '!! *' } | ForEach-Object { $_.Substring(3) } | Where-Object { -not (Test-Disposable $Path $_) })
        if ($notable.Count) { return "ignored file(s) not disposable: $((@($notable | Select-Object -First 5)) -join ', ')" }
        $inside = Find-ReparseInside $Path
        if ($inside -eq '?') { return 'unknown (its tree could not be read)' }
        if ($inside) { return "holds a junction or symlink: $inside" }
        return $null
    }
    # After a failed `git worktree remove`: 'missing' or 'empty' when git's list, read again, no longer
    # shows the worktree and its folder is gone or holds nothing (git removed the files and the entry
    # but could not delete the folder, say because a process has it as its cwd); else $null.
    function Get-RemoveRemnant([string]$Path) {
        $now = Invoke-CoordGit $main @('worktree', 'list', '--porcelain')
        if ($now.Code -ne 0 -or -not $now.Out.Count) { return $null }
        foreach ($line in $now.Out) { if ($line -match '^worktree (.+)$' -and [string]::Equals((Get-LongPath $Matches[1]), $Path, (Get-CoordPathComparison))) { return $null } }
        if (-not (Test-Path -LiteralPath $Path)) { return 'missing' }
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $null }
        try { if (@([System.IO.Directory]::GetFileSystemEntries($Path)).Count -eq 0) { return 'empty' } } catch { }
        return $null
    }
    function Get-WorktreeVerdict($W) {
        if ($W.IsMain) { return (New-Verdict $false 'main checkout') }
        if ($W.Bare) { return (New-Verdict $false 'bare') }
        if ($W.Prunable) { return (New-Verdict $false 'prunable: its folder is missing (git worktree prune is by hand)') }
        if ($null -ne $W.Locked) {
            $why = "locked: $($W.Locked)"
            if ($W.Locked -match '\(pid (\d+)\)') {
                $procId = [int]$Matches[1]
                if (Get-Process -Id $procId -ErrorAction SilentlyContinue) { $why += ' - pid alive' } else { $why += " - pid $procId not running (unlock by hand once its session is gone)" }
            }
            return (New-Verdict $false $why)
        }
        if ($W.Detached -or -not $W.Branch) { return (New-Verdict $false 'detached HEAD') }
        foreach ($c in $cwds) { if (Test-UnderPath $c $W.Path) { return (New-Verdict $false "live session cwd $c") } }
        foreach ($c in $liveCwds) { if (Test-UnderPath $c.Path $W.Path) { return (New-Verdict $false "live ledger row '$($c.Track)' cwd") } }
        if ($cwdJunction) { return (New-Verdict $false $cwdJunction) }
        $j = Find-ReparseOnPath $W.Path
        if ($j) { return (New-Verdict $false "path through a junction or symlink: $j") }
        $k = Get-ContentKeep $W.Path
        if ($k) { return (New-Verdict $false $k) }
        $lb = $localByName[$W.Branch]
        if (-not $lb) { return (New-Verdict $false "branch $($W.Branch) not found") }
        if (-not $lb.V.Safe) { return (New-Verdict $false "branch $($W.Branch) is KEEP ($($lb.V.Why))") }
        return (New-Verdict $true "clean, branch $($W.Branch) $($lb.V.Why)")
    }
    if ($holdUnknown) { foreach ($l in $locals) { if ($l.V.Safe) { $l.V = New-Verdict $false "unknown ($holdUnknown)" } } }
    foreach ($w in $wts) { $w.V = Get-WorktreeVerdict $w }
    # A branch is KEEP when any worktree holding it is; then every SAFE worktree on it is
    # KEEP too (its branch stays, so the worktree is someone's).
    foreach ($l in $locals) {
        if (-not $l.V.Safe -or -not $heldBy.ContainsKey($l.Name)) { continue }
        $keeper = @($heldBy[$l.Name] | Where-Object { -not $_.V.Safe } | Select-Object -First 1)
        if ($keeper.Count) {
            $why = if ($keeper[0].IsMain) { 'checked out in the main checkout' } else { "held by worktree $($keeper[0].Path) (KEEP)" }
            $l.V = New-Verdict $false $why
            foreach ($w in $heldBy[$l.Name]) { if ($w.V.Safe) { $w.V = New-Verdict $false "branch $($l.Name) is KEEP ($why)" } }
        }
    }
    foreach ($w in $wts) {
        $label = if ($w.Branch) { $w.Branch } elseif ($w.Bare) { '(bare)' } else { '(detached)' }
        Write-Item "worktree $($w.Path) [$label]" $w.V
    }
    foreach ($l in $locals) { Write-Item "branch $($l.Name) @$(Get-Short $l.Tip)" $l.V }

    # Remote branches (origin only).
    $remotes = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($rr.Out | Where-Object { $_ })) {
        $sp = $entry.IndexOf(' ')
        $name = $entry.Substring($sp + 1)
        if ($name -ceq 'HEAD') { continue }
        $tipSha = $entry.Substring(0, $sp)
        # The local branches that are this remote branch: the same name (any case), or tracking it.
        $tracking = @($locals | Where-Object { $_.Name -eq $name -or $_.Upstream -eq "refs/remotes/origin/$name" } | ForEach-Object { $_.Name })
        $keeper = $null
        $kb = ''
        foreach ($tn in $tracking) {
            if ($keeper -or -not $heldBy.ContainsKey($tn)) { continue }
            $k = @($heldBy[$tn] | Where-Object { -not $_.V.Safe } | Select-Object -First 1)
            if ($k.Count) { $keeper = $k[0]; $kb = $tn }
        }
        $v = if (-not $pushSame) { New-Verdict $false "origin pushes to $($pushUrls.Count) URL(s), not exactly its fetch URL" } else { Get-BranchVerdict $name $tipSha }
        # A worktree whose git dir could not be read may be rebasing a local branch of this one.
        if ($v.Safe -and $holdUnknown) { $v = New-Verdict $false "unknown ($holdUnknown)" }
        if ($v.Safe -and $keeper) { $v = New-Verdict $false "worktree $($keeper.Path) on the local $kb is KEEP" }
        $remotes.Add([pscustomobject]@{ Name = $name; Tip = $tipSha; V = $v; Tracking = $tracking })
        Write-Item "remote origin/$name @$(Get-Short $tipSha)" $v
    }

    if (-not $Apply) { continue }
    # ---- -Apply: SAFE items only, one destructive git call each --------------
    # Local branches that stay, with why: the origin branch of one (same name or tracked) stays too.
    $localStays = New-Object System.Collections.Hashtable ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($w in $wts) {
        if (-not $w.V.Safe) { continue }
        $k = Get-ContentKeep $w.Path
        if ($k) { $localStays[$w.Branch] = 'its worktree was not removed'; $script:failed++; Write-Output "APPLY worktree $($w.Path): FAILED (changed since the scan: $k; untouched)"; continue }
        $rm = Invoke-CoordGit $main @('worktree', 'remove', $w.Path)
        $left = if ($rm.Code -ne 0) { Get-RemoveRemnant $w.Path } else { $null }
        if ($rm.Code -eq 0 -and -not (Test-Path -LiteralPath $w.Path)) { $script:applied++; Write-Output "APPLY worktree $($w.Path): removed" }
        elseif ($left) {
            $script:applied++
            $note = if ($left -eq 'empty') { 'empty folder left, probably in use' } else { 'folder gone' }
            Write-Output "APPLY worktree $($w.Path): removed (git exit $($rm.Code); $note)"
        }
        else { $localStays[$w.Branch] = 'its worktree was not removed'; $script:failed++; Write-Output "APPLY worktree $($w.Path): FAILED (git worktree remove exit $($rm.Code))" }
    }
    foreach ($l in $locals) {
        if (-not $l.V.Safe) { continue }
        if ($localStays.ContainsKey($l.Name)) { $script:failed++; Write-Output "APPLY branch $($l.Name): FAILED (skipped: $($localStays[$l.Name]))"; continue }
        # `update-ref -d` does not look at worktrees: one added on it since the scan would lose
        # its branch. Read the list again (rebase holders are not re-read).
        $wlNow = Invoke-CoordGit $main @('worktree', 'list', '--porcelain')
        $onIt = @($wlNow.Out | Where-Object { $_ -match '^branch refs/heads/(.+)$' -and [string]::Equals($Matches[1], $l.Name, [System.StringComparison]::OrdinalIgnoreCase) })
        if ($wlNow.Code -ne 0 -or $onIt.Count) {
            $localStays[$l.Name] = if ($wlNow.Code -ne 0) { 'the worktree list could not be read again' } else { 'a worktree is on it now' }
            $script:failed++; Write-Output "APPLY branch $($l.Name): FAILED (skipped: $($localStays[$l.Name]))"; continue
        }
        $del = Invoke-CoordGit $main @('update-ref', '--no-deref', '-d', "refs/heads/$($l.Name)", $l.Tip)
        $still = Invoke-CoordGit $main @('rev-parse', '--verify', '--quiet', "refs/heads/$($l.Name)")
        if ($del.Code -eq 0 -and $still.Code -ne 0) { $script:applied++; Write-Output "APPLY branch $($l.Name): deleted" }
        else { $localStays[$l.Name] = 'its delete failed'; $script:failed++; Write-Output "APPLY branch $($l.Name): FAILED (update-ref exit $($del.Code))" }
    }
    foreach ($rb in $remotes) {
        if (-not $rb.V.Safe) { continue }
        $stuck = @($rb.Tracking | Where-Object { $localStays.ContainsKey($_) })
        if ($stuck.Count) { $script:failed++; Write-Output "APPLY remote origin/$($rb.Name): FAILED (skipped: the local $($stuck[0]) stays: $($localStays[$stuck[0]]))"; continue }
        # Read the local branches and worktrees again right before: a worktree that took a
        # local of this name or tracking it since the scan (a KEEP local too, or one created
        # since) keeps it on origin. Rebase holders are not re-read.
        $feNow = Invoke-CoordGit $main @('for-each-ref', '--format=%(upstream)%09%(refname:lstrip=2)', 'refs/heads')
        $wlNow = Invoke-CoordGit $main @('worktree', 'list', '--porcelain')
        if ($feNow.Code -ne 0 -or $wlNow.Code -ne 0) { $script:failed++; Write-Output "APPLY remote origin/$($rb.Name): FAILED (skipped: the local branches or worktrees could not be read again)"; continue }
        $tracksNow = @($feNow.Out | Where-Object { $_ } | ForEach-Object { $pp = $_.Split("`t"); if ($pp[1] -eq $rb.Name -or $pp[0] -eq "refs/remotes/origin/$($rb.Name)") { $pp[1] } })
        $heldNow = @($wlNow.Out | Where-Object { $_ -match '^branch refs/heads/(.+)$' } | ForEach-Object { $_.Substring(18) } | Where-Object { $tracksNow -contains $_ })
        if ($heldNow.Count) { $script:failed++; Write-Output "APPLY remote origin/$($rb.Name): FAILED (skipped: a worktree is on the local $($heldNow[0]) now)"; continue }
        $push = Invoke-CoordGit $main @('push', '--quiet', "--force-with-lease=refs/heads/$($rb.Name):$($rb.Tip)", 'origin', ":refs/heads/$($rb.Name)")
        $ls = Invoke-CoordGit $main @('ls-remote', 'origin', "refs/heads/$($rb.Name)")
        $gone = ($ls.Code -eq 0 -and -not @($ls.Out | Where-Object { ($_ -split "`t")[-1] -ceq "refs/heads/$($rb.Name)" }).Count)
        if ($push.Code -eq 0 -and $gone) { $script:applied++; Write-Output "APPLY remote origin/$($rb.Name): deleted" }
        elseif ($ls.Code -ne 0) { $script:failed++; Write-Output "APPLY remote origin/$($rb.Name): FAILED (push exit $($push.Code), re-read failed)" }
        elseif (-not $gone) { $script:failed++; Write-Output "APPLY remote origin/$($rb.Name): FAILED (push exit $($push.Code), still on origin)" }
        else { $script:failed++; Write-Output "APPLY remote origin/$($rb.Name): FAILED (gone on re-read, but the push exited $($push.Code))" }
    }
}

$last = "PRUNE-SCAN: $script:safeN SAFE, $script:keepN KEEP"
if ($Apply) { $last += "; applied $script:applied, failed $script:failed" }
if ($couldNot.Count) { $last += "; COULD NOT CHECK: $($couldNot -join ', ')" }
Write-Output $last
if ($couldNot.Count) { exit 2 }
if ($script:failed) { exit 1 }
exit 0
