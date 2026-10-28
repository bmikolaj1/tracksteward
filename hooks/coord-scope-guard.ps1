# coord-scope-guard.ps1 - the coordinator's track scope guard, a tracksteward
# plugin hook. Ported from the private coordinate toolkit's hook of the same
# name on 2026-10-28. hooks/hooks.json starts this one script for two events:
# PreToolUse on Edit|Write|MultiEdit|NotebookEdit (guard mode) and SessionStart
# (anchor mode). It does nothing until a coordinator has registered a ledger
# (coord-log.ps1 -Register): with no index file for today or yesterday it reads
# no ledger and writes, refreshes and prunes no anchor, and allows silently,
# apart from the warnings about its own input and setup (an event it cannot
# read, a coord-common.ps1 that is missing or fails to load, a SessionStart
# event with no full cwd, an internal error).
# TRACKSTEWARD_GUARD=off in the environment turns it off without uninstalling
# the plugin: the hook exits at once, reads nothing and writes nothing. That is
# a convenience, not a lock: anything that can set the hook's environment (a
# settings env block, a shell export) or write Claude's settings can turn the
# guard off, and COORD_INDEX_DIR and COORD_TODAY (the test suite's index folder
# and clock) are honored the same way. hooks/hooks.json starts the script through
# a -Command launcher; when the launcher fails before the script runs
# (CLAUDE_PLUGIN_ROOT unset, the script missing, a policy overriding the
# execution policy) the hook exits 1. A probe (2026-10-28, plugin root unset, so
# the script path was empty) showed the edit goes ahead and the session sees no
# hook text: for that call the guard is silently off.
#
# WHAT IT GUARDS: the acting session, not the file's owner. A session bound to a
# live Tracks row of a coordinator's ledger may write in its own worktree only
# inside that row's Scope, and a path outside every git working tree (and the
# memory and plans folders, LIMITS) is allowed. A write into any other working
# tree (the main checkout, a sibling's worktree, another repo) passes only
# through a second live row with the same Session token naming that tree's
# repo and branch, and only inside that row's Scope. A token is an id-shaped
# Session cell (local_ plus 8 or more hex digits, local_ plus a UUID, or a bare
# UUID; Get-CoordSessionToken). A cell that holds only a name (the template's
# track name, "none", "TBD") has no token and never binds across repos, so two
# tracks that share a name in two repos stay apart. The refusal says so. A
# write may also go into a
# subagent worktree (LIMITS) inside the bound row's Scope. The refusal names the
# row whose Scope applied, else the first bound row. .claude/handovers/** and
# .claude/coordination/** are always in scope, but only in a worktree bound to
# the acting track (its own, a same-token row's, or a subagent worktree's); in
# the main checkout or any other unbound tree they get
# the rule above, so a track does not write the coordinator's live ledger
# (tests/hooks/coord-scope-guard.test.ps1 G3-25 to G3-30).
# While a row is bound, a target path that crosses a junction or symlink is
# refused (no portable link resolver in PowerShell 5.1).
#
# LEDGERS: today's index `<index dir>\<date>.ledgers` (Get-CoordIndexDir:
# COORD_INDEX_DIR, else ~/.claude/coordination), read by Get-CoordIndexedLedgers.
# An entry is used only when it is the day's canonical ledger
# (Test-CoordLedgerCanonical), passes the trust rules (Test-CoordLedgerTrusted)
# and its Tracks table reads whole (Read-CoordLedgerTracksBounded). The date is
# COORD_TODAY when it is a valid yyyy-MM-dd (the test suite's clock), else
# Get-CoordToday. No index today and none yesterday: allow with zero git calls.
#
# ORDER (git only where a row could bind): 1. The index and the anchor file are
# read, and each anchor's repo, branch and worktree root come from its nearest
# .git (folder, or file holding gitdir <main>\.git\worktrees\<name>) and HEAD;
# an unusual layout asks git instead, never allows. When no anchor is in a repo
# the call allows, with the git-failed warning when an unusual anchor's git
# lookup failed. 2. A coordinator-checkout session (LIMITS) allows here, before
# any ledger is checked, so it sees no refused, unreadable or malformed ledger
# warning. 3. Each listed ledger's Tracks rows are read from files; a ledger
# whose path does not look canonical from file reads alone (not
# <X>\.claude\coordination\<date>.md with <X>\.git a folder, a reparse point on
# the way, a UNC or non-fixed drive), or whose read fails, gets the git checks
# at once, so a refused, unreadable or malformed ledger warns. 4. When no live
# row could bind any anchor, the call allows (after the same lazy check of
# yesterday's index) with no git call beyond step 3's. 5. Otherwise only the
# ledgers holding such a row get the canonical and trust checks, every anchor is
# confirmed with git, and binding uses the rows of usable ledgers only; a ledger
# holding a cross-repo or carried-forward row is checked when that row is
# needed. Every git result is reused within the run.
#
# BINDING: the anchors are, in order, the lines of the session anchor file
# `<index dir>\sessions\<session_id>.anchor`, the event `cwd`, and
# CLAUDE_PROJECT_DIR. The SessionStart run writes the anchor file once, holding
# the event cwd (a resume or compact keeps it), and only when today's or
# yesterday's index exists: a day with no registered coordinator leaves no
# anchor. A write also prunes anchor files not written for 7 days (by their last
# write time) from the same folder; a SessionStart event (start, resume, compact,
# clear) for a session that already has an anchor refreshes its write time and
# changes nothing else, but a session with no SessionStart event for 7 days
# loses its anchor to the next session's write and binds by cwd. A track that
# started before its coordinator registered the ledger has no anchor and binds
# by cwd; so does the coordinator's own session when it started on a day with no
# index (it is then not recognized as the coordinator, see LIMITS, Coordinator:
# the skill keeps that session in the main checkout). A PreToolUse call that finds the
# file holding one line, which binds nothing, while the cwd or
# CLAUDE_PROJECT_DIR binds a row, appends that worktree root as its second line
# (two parallel calls may both append; harmless), except in a
# coordinator-checkout session (LIMITS). An anchor whose git lookup
# fails is dropped. An anchor binds the live row whose Repo is the anchor's main root
# and whose Branch is its branch; a linked worktree whose branch binds no live row
# binds the live row whose Cwd is its root, with a warning. Two live rows for one
# anchor, or bound rows that do not all hold one valid token, are ambiguity and
# block.
#
# FAILURE POLICY: absence (no index, no trusted ledger, no bound live row, not in
# a repo) allows silently, with two exceptions: the coordinator-checkout
# warning (LIMITS, Coordinator), and the midnight rollover: when no
# row is bound today and yesterday's index exists, a live row of yesterday's
# trusted ledgers that the anchors bind and that has no row of the same Track and
# Repo in today's trusted ledgers allows with a warning; yesterday's scope is
# never enforced. A malformed or unreadable ledger, a git failure while checking
# a ledger or finding the target's tree, a dropped anchor that could have bound
# a row when no other anchor binds one, a timeout, the budget running out, an
# event that cannot be read or parsed, and an unexpected error each allow with a
# warning. When another anchor binds, a dropped anchor that could have bound a
# different row (one not holding the bound row's token), or whose layout is
# unusual, warns and the bound row's scope judges the call. Empty stdin,
# another event or another tool exits silently.
# Ambiguity blocks.
#
# OUTPUT PROTOCOL (Claude Code hooks reference, exit codes): block = exit 2, the
# refusal on stderr, nothing on stdout; warning = exit 0 and exactly one JSON
# object on stdout, {"systemMessage":"coord-scope-guard: <w1>; <w2>"}; silent
# allow = exit 0, no output. Plain stdout text is never used.
#
# BUDGET: one stopwatch, started on the first line; 3000 ms of processing (the
# powershell.exe start-up before the script is not counted). Every git call goes
# through Invoke-CoordGitBounded with min(2000, time left - 500) ms and is not
# started when that is not positive; each step checks the time left before it
# starts. The index and Tracks reads get the time left (-TimeoutMs) and a
# timeout there gives the deadline warning; the anchor file read waits at most
# the time left; the anchor append is
# skipped, with a warning, under 200 ms left. Anchor mode has its own 1 s budget
# and exits silently for an unusable session id, with no index, for a session that
# already has its anchor, and when it loses the create race to another run; any
# other failure writes no anchor and warns (a prune failure after the anchor is
# written is ignored).
#
# LIMITS: Bash and PowerShell writes (sed -i, Set-Content) are not covered, only
# the four edit tools. A session opened on a main checkout that holds a listed
# ledger is the coordinator's and is never bound (Coordinator, below); an edit
# whose target lies in a track's worktree warns that this edit is NOT guarded
# (not one inside a worktree-agent-* worktree nested under it: that tree has its
# own root and branch, which no row names, so that edit is a silent allow).
# A session opened on any other main checkout (then EnterWorktree) is
# guarded only from its first edit inside the worktree; a cd away before that
# edit leaves it unbound. A stalled local
# file open or write cannot be bounded from the script: only the hooks.json
# `timeout` covers it, and then the hook's output is lost; no fixture can stall a
# local NTFS open, so that path has no test. A main checkout reached through a
# junction or subst path can miss the file-read pre-binding, and the call is
# then allowed silently. Reparse-point components (OneDrive placeholders, Dev
# Drive) and paths that GetFullPath rejects block for a bound track
# (fail-closed). A row with a blank Cwd whose worktree changes branch is
# unbound, with no warning. An anchor that is both unusual by file reads and
# failing in git (a cwd inside a .git folder, a worktree folder left on disk with a
# dangling .git file after a prune, an unreadable HEAD) warns on every edit
# while an index exists for today or yesterday. The coordinator-checkout warning
# reads the target's folders by file with no network-drive or link check first,
# so a target on a disconnected mapped drive can stall it until the hook
# timeout (the edit is allowed, the warning lost; never a block).
# Memory and plans: a bound track may write below
# <home>\.claude\projects\<any>\memory\ and <home>\.claude\plans\ (home =
# USERPROFILE, else HOME), checked after the link check like a path outside
# every tree, because the home folder may itself be a git working tree; nothing
# else under <home>\.claude is exempt.
# Coordinator: when the anchor file's first line lies in a main checkout (not a
# linked worktree) whose canonical ledger for today or yesterday is listed in
# that day's index, the session binds no row by any anchor and its anchor file
# gets no second line, so a coordinator that cd's into a track worktree stays
# unbound. When the edit's target lies in a linked worktree (read by file) that
# a live row binds by file reads (today's index, else yesterday's), the call
# allows with the warning that this edit in that track's worktree is NOT
# guarded; any other target (the coordinator's own ledger, a path outside every
# tree) allows silently, before any ledger is read. The warning needs the
# ledger to read canonical by file (Test-CsgPureCanonical) and the target's
# tree to read by file; otherwise that edit allows silently. A
# coordinator running in a linked worktree, or with no anchor file, is not
# recognized as the coordinator and can be bound by a cd into a track worktree
# (the skill keeps the coordinator in the main checkout).
# Subagent worktrees: a target in a linked worktree of a bound row's repo whose
# branch starts with worktree-agent- is checked against that row's Scope,
# relative to that worktree's root. This covers any worktree-agent-* worktree
# of that repo, a sibling track's subagent's included: the location cannot
# tell whose subagent it is.
#
# Windows PowerShell 5.1; this file stays ASCII. Windows only: the path rules
# (drive letters, UNC and mapped drives, junctions, case-insensitive compare)
# are Windows rules, and nothing here has been run on another platform. The
# hook does not clear GIT_DIR or GIT_WORK_TREE: run from a git-spawned shell
# that exports them, its git lookups follow those variables (a stated limit).

$csgSw = [System.Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'SilentlyContinue'

# The off switch: first, before stdin, the index or any file is touched.
if (([string]$env:TRACKSTEWARD_GUARD).Trim() -ieq 'off') { exit 0 }

$csgBudgetMs = 3000
$csgAnchorBudgetMs = 1000
$csgWarnings = New-Object System.Collections.Generic.List[string]
$csgSavedEncoding = $null
$csgNotGuarded = 'this edit is NOT guarded'
$csgIdRx = '^[A-Za-z0-9_-]{1,128}\z'
$csgGitCache = New-Object 'System.Collections.Generic.Dictionary[string,object]'
$csgInfoCache = New-Object 'System.Collections.Generic.Dictionary[string,object]'
$csgTimeout = $null
$csgTimeoutMs = 0
$csgGitFail = $null
$csgAnchorFile = $null
$csgAnchorText = ''
$csgAnchorLineCount = 0
$csgYdayEntries = $null

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
function Exit-Csg([int]$Code) {
    if ($null -ne $script:csgSavedEncoding) { try { [Console]::OutputEncoding = $script:csgSavedEncoding } catch { } }
    exit $Code
}

# JSON string body, ASCII only: quote, backslash, control and non-ASCII
# characters escaped.
function ConvertTo-CsgJsonText([string]$Text) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        $c = [int]$ch
        if ($c -eq 34) { [void]$sb.Append('\"') }
        elseif ($c -eq 92) { [void]$sb.Append('\\') }
        elseif ($c -lt 32 -or $c -gt 126) { [void]$sb.Append(('\u{0:x4}' -f $c)) }
        else { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}

function Add-CsgWarning([string]$Text) { $script:csgWarnings.Add($Text) }

# Exit 0: silent, or the warnings (deduplicated, in order) as ONE JSON object.
function Exit-CsgAllow {
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($w in $script:csgWarnings) { if ($seen.Add($w)) { $parts.Add($w) } }
    if ($parts.Count -gt 0) {
        $text = 'coord-scope-guard: ' + ($parts -join '; ')
        [Console]::Out.WriteLine('{"systemMessage":"' + (ConvertTo-CsgJsonText $text) + '"}')
        [Console]::Out.Flush()
    }
    Exit-Csg 0
}

# Exit 2 with the refusal on stderr; warnings are dropped (stdout stays empty).
function Exit-CsgBlock([string]$Message) {
    [Console]::Error.WriteLine('coord-scope-guard: ' + $Message)
    [Console]::Error.Flush()
    Exit-Csg 2
}

function Exit-CsgGitFailed([string]$What) {
    Add-CsgWarning ('git failed (' + $What + '); ' + $script:csgNotGuarded)
    Exit-CsgAllow
}

# ---------------------------------------------------------------------------
# Budget and bounded git
# ---------------------------------------------------------------------------
function Get-CsgLeft { return ($script:csgBudgetMs - $script:csgSw.ElapsedMilliseconds) }

function Stop-CsgOnTimeout {
    if ($null -ne $script:csgTimeout) {
        Add-CsgWarning ('timed out after ' + $script:csgTimeoutMs + ' ms (' + $script:csgTimeout + '); ' + $script:csgNotGuarded)
        Exit-CsgAllow
    }
}

# A bounded read (Get-CoordIndexedLedgers, Read-CoordLedgerTracksBounded) that
# returned TimedOut ends the run with the deadline warning.
function Stop-CsgOnReadTimeout($Result, [long]$Ms, [string]$Step) {
    if ($null -ne $Result -and $Result.PSObject.Properties['TimedOut'] -and $Result.TimedOut) {
        $script:csgTimeout = $Step
        $script:csgTimeoutMs = $Ms
        Stop-CsgOnTimeout
    }
}

function Assert-CsgTime([string]$Step) {
    if ((Get-CsgLeft) -le 0) {
        $script:csgTimeout = 'the budget ran out before ' + $Step
        $script:csgTimeoutMs = $script:csgSw.ElapsedMilliseconds
        Stop-CsgOnTimeout
    }
}

# "git <subcommand> in <repo>" for messages.
function Get-CsgGitWhat([string]$Repo, [string[]]$GitArgs) {
    $words = New-Object System.Collections.Generic.List[string]
    foreach ($a in $GitArgs) {
        if ([string]$a -like '-*') { if ($words.Count -gt 0) { break } else { continue } }
        $words.Add([string]$a)
        if ($words.Count -ge 2 -or $a -ne 'worktree') { break }
    }
    return ('git ' + ($words -join ' ') + ' in ' + $Repo)
}

# The git invoker handed to the shared helpers (`& $Git $Repo $GitArgs`, returns
# { Code; Out }). Bounded by the budget; a timeout is recorded and every later
# call fails at once without starting git. The first non-zero exit since the
# caller reset $csgGitFail is recorded. Results are cached per directory and
# arguments for this one run, so the helpers' repeated `worktree list` calls on
# one folder start git once.
function Invoke-CsgGit([string]$Repo, [string[]]$GitArgs) {
    $key = $Repo + [char]0 + ($GitArgs -join [string][char]0)
    $what = Get-CsgGitWhat $Repo $GitArgs
    if ($script:csgGitCache.ContainsKey($key)) {
        $hit = $script:csgGitCache[$key]
        if ($hit.Code -ne 0 -and $null -eq $script:csgGitFail) { $script:csgGitFail = $what + ' exited ' + $hit.Code }
        return $hit
    }
    $fail = [pscustomobject]@{ Code = -1; Out = [string[]]@() }
    if ($null -ne $script:csgTimeout) { return $fail }
    $wait = [Math]::Min([long]2000, (Get-CsgLeft) - 500)
    if ($wait -le 0) {
        $script:csgTimeout = 'the budget ran out before ' + $what
        $script:csgTimeoutMs = $script:csgSw.ElapsedMilliseconds
        return $fail
    }
    $r = Invoke-CoordGitBounded -Repo $Repo -GitArgs $GitArgs -TimeoutMs ([int]$wait)
    if ($null -eq $r) {
        if ($null -eq $script:csgGitFail) { $script:csgGitFail = $what + ' could not be run' }
        return $fail
    }
    if ($r.TimedOut) {
        $script:csgTimeout = $what
        $script:csgTimeoutMs = $wait
        return $fail
    }
    $out = [string[]]@()
    if ($null -ne $r.Out) { $out = [string[]]@($r.Out | ForEach-Object { [string]$_ }) }
    $res = [pscustomobject]@{ Code = $r.Code; Out = $out }
    if ($res.Code -ne 0 -and $null -eq $script:csgGitFail) { $script:csgGitFail = $what + ' exited ' + $res.Code }
    $script:csgGitCache[$key] = $res
    return $res
}
$csgGit = { param($Repo, $GitArgs) Invoke-CsgGit -Repo $Repo -GitArgs $GitArgs }

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
function Get-CsgProp($Obj, [string]$Name) {
    if ($null -eq $Obj) { return '' }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return '' }
    return [string]$p.Value
}

function Test-CsgDrivePath([string]$Path) { return ([string]$Path -match '^[A-Za-z]:[\\/]') }

# Full path, '/' turned into '\', trailing separators trimmed (a drive root kept).
function ConvertTo-CsgFull([string]$Path) {
    $f = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($f)
    if ($f.Length -gt $root.Length) { $f = $f.TrimEnd('\', '/') }
    return $f
}

# A ledger Repo or Cwd cell as a full path; $null for a blank, relative or UNC cell.
function ConvertTo-CsgCellPath($Cell) {
    $c = ([string]$Cell).Trim()
    if (-not (Test-CsgDrivePath $c)) { return $null }
    try { return (ConvertTo-CsgFull $c) } catch { return $null }
}

function Test-CsgSame([string]$A, [string]$B) {
    if (-not $A -or -not $B) { return $false }
    return [string]::Equals($A, $B, [System.StringComparison]::OrdinalIgnoreCase)
}

# True when $Dir or a folder above it holds a .git entry (folder or file), so
# a folder outside every repo costs no git call.
function Test-CsgUnderGit([string]$Dir) {
    $d = $Dir
    while ($d) {
        $g = [System.IO.Path]::Combine($d, '.git')
        if ([System.IO.Directory]::Exists($g) -or [System.IO.File]::Exists($g)) { return $true }
        $p = [System.IO.Path]::GetDirectoryName($d)
        if (-not $p -or $p -eq $d) { break }
        $d = $p
    }
    return $false
}

# The first existing component of $Full, below the drive root down to $Full
# itself, that is a junction or symlink (a reparse point); $null when none.
function Find-CsgLink([string]$Full) {
    $root = [System.IO.Path]::GetPathRoot($Full)
    $cur = $root.TrimEnd('\')
    foreach ($part in $Full.Substring($root.Length).Split('\')) {
        if (-not $part) { continue }
        $cur = $cur + '\' + $part
        $attr = $null
        try { $attr = [System.IO.File]::GetAttributes($cur) } catch { break }
        if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $cur }
    }
    return $null
}

# The user's home folder: USERPROFILE, else HOME; $null when neither is a full path.
function Get-CsgHome {
    foreach ($h in @($env:USERPROFILE, $HOME)) {
        if (Test-CsgDrivePath $h) { try { return (ConvertTo-CsgFull $h) } catch { } }
    }
    return $null
}

# True for a path below <home>\.claude\projects\<any>\memory\ or
# <home>\.claude\plans\ (full paths, OrdinalIgnoreCase). Nothing else under
# <home>\.claude is exempt.
function Test-CsgMemoryOrPlans([string]$Full) {
    $h = Get-CsgHome
    if (-not $h) { return $false }
    $plans = $h.TrimEnd('\') + '\.claude\plans\'
    if ($Full.Length -gt $plans.Length -and $Full.StartsWith($plans, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    $projects = $h.TrimEnd('\') + '\.claude\projects\'
    if ($Full.Length -gt $projects.Length -and $Full.StartsWith($projects, [System.StringComparison]::OrdinalIgnoreCase)) {
        $parts = $Full.Substring($projects.Length).Split('\')
        if ($parts.Length -ge 3 -and $parts[0] -and $parts[1] -ieq 'memory' -and $parts[2]) { return $true }
    }
    return $false
}

# The nearest existing folder at or above the target's parent; a folder inside
# a .git folder is replaced by the folder holding that .git, so the target is
# judged in that working tree. $null when no ancestor exists.
function Get-CsgNearestDir([string]$Full) {
    $d = [System.IO.Path]::GetDirectoryName($Full)
    if (-not $d) { $d = $Full }
    while (-not [System.IO.Directory]::Exists($d)) {
        $p = [System.IO.Path]::GetDirectoryName($d)
        if (-not $p -or $p -eq $d) { return $null }
        $d = $p
    }
    $parts = $d.Split('\')
    for ($k = $parts.Length - 1; $k -ge 1; $k--) {
        if ($parts[$k] -ieq '.git') {
            $d = ($parts[0..($k - 1)] -join '\')
            if ($d.EndsWith(':')) { $d = $d + '\' }
            break
        }
    }
    return $d
}

# ---------------------------------------------------------------------------
# Working tree of a folder: { State = none | unresolved | failed | ok; Root;
# Main; Branch ('' = detached); Linked; Prefix (the folder below Root,
# '/'-separated, ending in '/', or ''); Why (the git failure, for 'failed') }.
# A timeout ends the run with its warning; a git failure is returned as
# 'failed' and the caller decides. Cached per folder.
# ---------------------------------------------------------------------------
function Get-CsgTreeInfo([string]$Dir) {
    $key = $Dir.ToLowerInvariant()
    if ($script:csgInfoCache.ContainsKey($key)) { return $script:csgInfoCache[$key] }
    $info = [pscustomobject]@{ State = 'none'; Root = $null; Main = $null; Branch = ''; Linked = $false; Prefix = ''; Why = $null }
    $script:csgInfoCache[$key] = $info
    if (-not (Test-CsgUnderGit $Dir)) { return $info }
    $script:csgGitFail = $null
    $main = $null
    try { $main = Get-CoordMainRoot -Dir $Dir -Git $script:csgGit }
    catch { $main = $null; if ($null -eq $script:csgGitFail) { $script:csgGitFail = 'finding the main worktree of ' + $Dir + ': ' + $_.Exception.Message } }
    Stop-CsgOnTimeout
    if (-not $main) {
        if ($script:csgGitFail) { $info.State = 'failed'; $info.Why = $script:csgGitFail; return $info }
        $info.State = 'unresolved'
        return $info
    }
    $r = & $script:csgGit $Dir @('rev-parse', '--show-toplevel', '--show-prefix')
    Stop-CsgOnTimeout
    if ($r.Code -ne 0 -or $r.Out.Count -lt 1 -or -not $r.Out[0].Trim()) {
        $info.State = 'failed'
        $info.Why = $script:csgGitFail
        if (-not $info.Why) { $info.Why = (Get-CsgGitWhat $Dir @('rev-parse')) + ' printed no top level' }
        return $info
    }
    $root = ConvertTo-CsgFull $r.Out[0].Trim()
    $prefix = ''
    if ($r.Out.Count -ge 2) { $prefix = $r.Out[1].TrimEnd("`r").Replace('\', '/') }
    # The branch: from the porcelain list Get-CoordMainRoot already read (a cache
    # hit), else `git branch --show-current`.
    $branch = ''
    $found = $false
    $wl = & $script:csgGit $Dir @('worktree', 'list', '--porcelain')
    if ($wl.Code -eq 0) {
        $cur = $null
        foreach ($line in $wl.Out) {
            if ($line.StartsWith('worktree ')) {
                $cur = $null
                try { $cur = ConvertTo-CsgFull $line.Substring(9).Trim() } catch { $cur = $null }
                continue
            }
            if (-not $found -and (Test-CsgSame $cur $root)) {
                if ($line.StartsWith('branch ')) {
                    $branch = $line.Substring(7).Trim()
                    if ($branch.StartsWith('refs/heads/')) { $branch = $branch.Substring(11) }
                    $found = $true
                }
                elseif ($line.Trim() -eq 'detached') { $branch = ''; $found = $true }
            }
        }
    }
    if (-not $found) {
        $script:csgGitFail = $null
        $bc = & $script:csgGit $Dir @('branch', '--show-current')
        Stop-CsgOnTimeout
        if ($bc.Code -ne 0) {
            $info.State = 'failed'
            $info.Why = $script:csgGitFail
            if (-not $info.Why) { $info.Why = Get-CsgGitWhat $Dir @('branch') }
            return $info
        }
        $branch = ''
        if ($bc.Out.Count -gt 0) { $branch = $bc.Out[0].Trim() }
    }
    $info.Main = ConvertTo-CsgFull $main
    $info.Root = $root
    $info.Branch = $branch
    $info.Linked = -not (Test-CsgSame $root $info.Main)
    $info.Prefix = $prefix
    $info.State = 'ok'
    return $info
}

# ---------------------------------------------------------------------------
# Index, ledgers, rows
# ---------------------------------------------------------------------------
function Read-CsgIndex([string]$Path) {
    Assert-CsgTime ('reading the ledger index ' + $Path)
    $r = $null
    $left = [int](Get-CsgLeft)
    try { $r = Get-CoordIndexedLedgers -Path $Path -TimeoutMs $left } catch { $r = [pscustomobject]@{ Ok = $false; Error = $_.Exception.Message } }
    Stop-CsgOnReadTimeout $r $left ('reading the ledger index ' + $Path)
    if ($null -eq $r -or -not $r.Ok) {
        $why = 'it could not be read'
        if ($r -and $r.Error) { $why = [string]$r.Error }
        Add-CsgWarning ('ledger index ' + $Path + ' skipped: ' + $why)
        return
    }
    if ($r.Overflow) { Add-CsgWarning ('ledger index ' + $Path + ' holds more than 8 ledgers or 64 KiB; only the first 8 are read') }
    foreach ($e in @($r.Entries)) { if ($e) { [string]$e } }
}

function New-CsgRow($Row, $Rec, [string]$Id) {
    $token = Get-CoordSessionToken ([string]$Row.Session)
    return [pscustomobject]@{
        Id       = $Id
        Rec      = $Rec
        Ledger   = $Rec.Path
        Track    = ([string]$Row.Track).Trim()
        RepoCell = ([string]$Row.Repo).Trim()
        Repo     = (ConvertTo-CsgCellPath $Row.Repo)
        Branch   = ([string]$Row.Branch).Trim()
        Cwd      = (ConvertTo-CsgCellPath $Row.Cwd)
        Scope    = [string]$Row.Scope
        Token    = $token
        Live     = (-not (Test-CoordRowTerminal ([string]$Row.Status)))
    }
}

# A ledger record: { Path; Date; No; Rows; Read; ReadOk; ReadError; Checked;
# Usable }. Rows are parsed before any git check, but a row binds or grants
# only when Test-CsgLedgerUsable passes its ledger (canonical, trusted, read
# whole).

# True when $Path looks canonical with file reads only: a local fixed drive,
# <X>\.claude\coordination\<Date>.md, <X>\.git a folder (X is a main
# checkout), and no reparse point at .git, .claude, coordination or the file.
# Anything else, a missing file included, is checked by the git helpers at once.
function Test-CsgPureCanonical([string]$Path, [string]$Date) {
    try {
        if (-not (Test-CsgDrivePath $Path)) { return $false }
        $full = ConvertTo-CsgFull $Path
        if ((New-Object System.IO.DriveInfo([System.IO.Path]::GetPathRoot($full))).DriveType -ne [System.IO.DriveType]::Fixed) { return $false }
        if ([System.IO.Path]::GetFileName($full) -ine ($Date + '.md')) { return $false }
        $coord = [System.IO.Path]::GetDirectoryName($full)
        if ([System.IO.Path]::GetFileName($coord) -ine 'coordination') { return $false }
        $claude = [System.IO.Path]::GetDirectoryName($coord)
        if ([System.IO.Path]::GetFileName($claude) -ine '.claude') { return $false }
        $x = [System.IO.Path]::GetDirectoryName($claude)
        if (-not $x) { return $false }
        $g = [System.IO.Path]::Combine($x, '.git')
        if (-not [System.IO.Directory]::Exists($g)) { return $false }
        foreach ($p in @($g, $claude, $coord, $full)) {
            if (([System.IO.File]::GetAttributes($p) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        }
        return $true
    }
    catch { return $false }
}

# Reads a ledger's Tracks rows into its record (file reads only).
function Read-CsgLedgerFile($Rec) {
    $Rec.Read = $true
    Assert-CsgTime ('reading ledger ' + $Rec.Path)
    $rd = $null
    $left = [int](Get-CsgLeft)
    try { $rd = Read-CoordLedgerTracksBounded -Path $Rec.Path -TimeoutMs $left } catch { $rd = [pscustomobject]@{ Ok = $false; Error = $_.Exception.Message } }
    Stop-CsgOnReadTimeout $rd $left ('reading ledger ' + $Rec.Path)
    if ($null -eq $rd -or -not $rd.Ok) {
        $why = 'its Tracks table could not be read'
        if ($rd -and $rd.Error) { $why = [string]$rd.Error }
        $Rec.ReadError = $why
        return
    }
    $list = New-Object System.Collections.Generic.List[object]
    $ri = 0
    foreach ($row in @($rd.Rows)) {
        if ($null -eq $row) { continue }
        $ri++
        $list.Add((New-CsgRow $row $Rec ($Rec.Date + ':' + $Rec.No + '.' + $ri)))
    }
    $Rec.Rows = $list.ToArray()
    $Rec.ReadOk = $true
}

# The index entries as records. A ledger that passes Test-CsgPureCanonical is
# read with no git call; any other entry, and one whose read fails, is checked
# at once by Test-CsgLedgerUsable, so its warning is the same as when every
# ledger was checked.
function Read-CsgLedgers([string[]]$Entries, [string]$Date) {
    $recs = New-Object System.Collections.Generic.List[object]
    $li = 0
    foreach ($e in $Entries) {
        $li++
        $rec = [pscustomobject]@{ Path = $e; Date = $Date; No = $li; Rows = @(); Read = $false; ReadOk = $false; ReadError = $null; Checked = $false; Usable = $false }
        $recs.Add($rec)
        if (Test-CsgPureCanonical $e $Date) {
            Read-CsgLedgerFile $rec
            if ($rec.ReadOk) { continue }
        }
        [void](Test-CsgLedgerUsable $rec)
    }
    return $recs.ToArray()
}

function Get-CsgRows($Recs) {
    foreach ($r in @($Recs)) { foreach ($x in @($r.Rows)) { if ($null -ne $x) { $x } } }
}

# The git checks of one ledger, run once: canonical for its date, trusted, then
# read whole. A refused or malformed ledger is skipped with a warning; an
# untrusted one silently, unless a git call failed while checking it.
function Test-CsgLedgerUsable($Rec) {
    if ($Rec.Checked) { return $Rec.Usable }
    $Rec.Checked = $true
    $e = $Rec.Path
    Assert-CsgTime ('checking ledger ' + $e)
    $c = $null
    try { $c = Test-CoordLedgerCanonical -Path $e -Date $Rec.Date -Git $script:csgGit } catch { $c = [pscustomobject]@{ Ok = $false; Error = $_.Exception.Message } }
    Stop-CsgOnTimeout
    if ($null -eq $c -or -not $c.Ok) {
        $why = 'it is not the canonical ledger'
        if ($c -and $c.Error) { $why = [string]$c.Error }
        Add-CsgWarning ('ledger ' + $e + ' skipped: ' + $why)
        return $false
    }
    $script:csgGitFail = $null
    $t = $null
    try { $t = Test-CoordLedgerTrusted -Path $e -Git $script:csgGit } catch { $t = $null; if ($null -eq $script:csgGitFail) { $script:csgGitFail = 'the trust check failed: ' + $_.Exception.Message } }
    Stop-CsgOnTimeout
    if ($null -eq $t -or -not $t.Ok) {
        if ($script:csgGitFail) { Add-CsgWarning ('git failed (' + $script:csgGitFail + ', checking ledger ' + $e + '); ' + $script:csgNotGuarded) }
        return $false
    }
    if (-not $Rec.Read) { Read-CsgLedgerFile $Rec }
    if (-not $Rec.ReadOk) {
        Add-CsgWarning ('ledger ' + $e + ' skipped: ' + $Rec.ReadError)
        return $false
    }
    $Rec.Usable = $true
    return $true
}

# True when a live row could be bound by a tree view: repo and branch, or a
# linked worktree's Cwd.
function Test-CsgRowMatches($Row, $Info) {
    if (-not $Row.Live -or $null -eq $Info -or $Info.State -ne 'ok') { return $false }
    if ((Test-CsgSame $Row.Repo $Info.Main) -and $Info.Branch -and $Row.Branch -ceq $Info.Branch) { return $true }
    return ($Info.Linked -and (Test-CsgSame $Row.Cwd $Info.Root))
}

# Live rows of $Rows (skipping ledgers already found unusable) that $Info could bind.
function Get-CsgRowHits($Rows, $Info) {
    foreach ($row in @($Rows)) {
        if ($row.Rec.Checked -and -not $row.Rec.Usable) { continue }
        if (Test-CsgRowMatches $row $Info) { $row }
    }
}

# Ledger records holding a live row that one of $Infos could bind (repo and
# branch, or a linked worktree's Cwd), skipping ledgers already found unusable.
function Get-CsgCandidateRecs($Rows, $Infos) {
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($row in @($Rows)) {
        if (-not $row.Live) { continue }
        if ($row.Rec.Checked -and -not $row.Rec.Usable) { continue }
        foreach ($i in @($Infos)) {
            if ($null -eq $i -or $i.State -ne 'ok') { continue }
            if (Test-CsgRowMatches $row $i) {
                if ($seen.Add($row.Rec.Date + ':' + $row.Rec.No)) { $row.Rec }
                break
            }
        }
    }
}

# Checks the candidate ledgers, confirms every anchor with git, then checks
# any ledger the git view adds. Returns the rows of usable ledgers.
function Confirm-CsgCandidates($Anchors, $Recs, $Infos) {
    $all = @(Get-CsgRows $Recs)
    foreach ($r in @(Get-CsgCandidateRecs $all $Infos)) { [void](Test-CsgLedgerUsable $r) }
    Confirm-CsgAnchors $Anchors
    foreach ($r in @(Get-CsgCandidateRecs $all @(Get-CsgBestInfos $Anchors))) { [void](Test-CsgLedgerUsable $r) }
    foreach ($x in $all) { if ($x.Rec.Checked -and $x.Rec.Usable) { $x } }
}

# ---------------------------------------------------------------------------
# Anchors
# ---------------------------------------------------------------------------
# The anchor file, read with a bounded wait: { Present; Lines; Text }. Over
# 4 KiB, or unreadable: absent, with a warning.
function Read-CsgAnchorFile([string]$Path) {
    $res = [pscustomobject]@{ Present = $false; Lines = @(); Text = '' }
    if (-not [System.IO.File]::Exists($Path)) { return $res }
    Assert-CsgTime ('reading the session anchor ' + $Path)
    $fs = $null
    try {
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        if ($fs.Length -gt 4096) {
            Add-CsgWarning ('session anchor ' + $Path + ' is over 4 KiB; it is treated as absent')
            return $res
        }
        $buf = New-Object byte[] ([int]$fs.Length)
        $got = 0
        while ($got -lt $buf.Length) {
            $left = Get-CsgLeft
            if ($left -le 0) { Assert-CsgTime ('reading the session anchor ' + $Path) }
            $task = $fs.ReadAsync($buf, $got, $buf.Length - $got)
            if (-not $task.Wait([int]$left)) {
                $script:csgTimeout = 'reading the session anchor ' + $Path
                $script:csgTimeoutMs = $left
                Stop-CsgOnTimeout
            }
            $n = $task.Result
            if ($n -le 0) { break }
            $got += $n
        }
        $text = (New-Object System.Text.UTF8Encoding($false)).GetString($buf, 0, $got).TrimStart([char]0xFEFF)
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($l in ($text -split "`n")) {
            $l = $l.TrimEnd("`r")
            if ($l.Trim()) { $lines.Add($l.Trim()) }
        }
        $res.Present = $true
        $res.Text = $text
        $res.Lines = $lines.ToArray()
    }
    catch {
        Add-CsgWarning ('session anchor ' + $Path + ' could not be read (' + $_.Exception.Message + '); it is treated as absent')
        $res.Present = $false
    }
    finally { if ($fs) { $fs.Dispose() } }
    return $res
}

# A folder's working tree from file reads only: { State = none | ok | unusual;
# Root; Main; Branch ('' = detached); Linked }. The nearest .git above the
# folder: a .git folder makes that folder a main checkout; a .git file must hold
# `gitdir: <main>\.git\worktrees\<name>` with commondir `../..` (main = the
# folder holding that .git folder, root = the folder holding the .git file).
# The branch is HEAD's `ref: refs/heads/<b>`, a bare object id is detached.
# Anything else (a .git that is a reparse point, no gitdir line, a relative
# gitdir, another layout, no HEAD, a folder inside .git) is 'unusual', and the
# caller asks git instead.
function Get-CsgPureInfo([string]$Dir) {
    $unusual = [pscustomobject]@{ State = 'unusual'; Root = $null; Main = $null; Branch = ''; Linked = $false }
    if ($Dir -match '(^|\\)\.git(\\|$)') { return $unusual }
    $d = $Dir
    while ($d) {
        $g = [System.IO.Path]::Combine($d, '.git')
        $isDir = [System.IO.Directory]::Exists($g)
        if ($isDir -or [System.IO.File]::Exists($g)) {
            try {
                if (([System.IO.File]::GetAttributes($g) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $unusual }
                $main = $d
                $head = [System.IO.Path]::Combine($g, 'HEAD')
                $linked = $false
                if (-not $isDir) {
                    if ((New-Object System.IO.FileInfo($g)).Length -gt 4096) { return $unusual }
                    $line = ([System.IO.File]::ReadAllText($g) -split "`n")[0].Trim()
                    if (-not $line.StartsWith('gitdir: ')) { return $unusual }
                    $gd = $line.Substring(8).Trim()
                    if (-not (Test-CsgDrivePath $gd)) { return $unusual }
                    $gd = ConvertTo-CsgFull $gd
                    $wts = [System.IO.Path]::GetDirectoryName($gd)
                    if (-not $wts -or [System.IO.Path]::GetFileName($wts) -ine 'worktrees') { return $unusual }
                    $cg = [System.IO.Path]::GetDirectoryName($wts)
                    if (-not $cg -or [System.IO.Path]::GetFileName($cg) -ine '.git') { return $unusual }
                    $main = [System.IO.Path]::GetDirectoryName($cg)
                    if (-not $main) { return $unusual }
                    $cdf = [System.IO.Path]::Combine($gd, 'commondir')
                    if (-not [System.IO.File]::Exists($cdf)) { return $unusual }
                    if ([System.IO.File]::ReadAllText($cdf).Trim().Replace('\', '/') -ne '../..') { return $unusual }
                    $head = [System.IO.Path]::Combine($gd, 'HEAD')
                    $linked = $true
                }
                if (-not [System.IO.File]::Exists($head)) { return $unusual }
                $h = [System.IO.File]::ReadAllText($head).Trim()
                $branch = ''
                if ($h.StartsWith('ref: refs/heads/')) { $branch = $h.Substring(16).Trim() }
                elseif ($h -notmatch '^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$') { return $unusual }
                return [pscustomobject]@{ State = 'ok'; Root = (ConvertTo-CsgFull $d); Main = (ConvertTo-CsgFull $main); Branch = $branch; Linked = $linked }
            }
            catch { return $unusual }
        }
        $p = [System.IO.Path]::GetDirectoryName($d)
        if (-not $p -or $p -eq $d) { break }
        $d = $p
    }
    return [pscustomobject]@{ State = 'none'; Root = $null; Main = $null; Branch = ''; Linked = $false }
}

# An anchor: { Source; Line; Dir; Pure (file-read view, $null when the folder
# is missing); Info (git view, set by Confirm-CsgAnchors; at once when the
# file-read view is unusual) }.
function New-CsgAnchor([string]$Dir, [string]$Source, [int]$Line) {
    $full = $null
    if (Test-CsgDrivePath $Dir) { try { $full = ConvertTo-CsgFull $Dir } catch { $full = $null } }
    $pure = $null
    $info = $null
    if ($full -and [System.IO.Directory]::Exists($full)) {
        $pure = Get-CsgPureInfo $full
        if ($pure.State -eq 'unusual') { $info = Get-CsgTreeInfo $full }
    }
    return [pscustomobject]@{ Source = $Source; Line = $Line; Dir = $full; Pure = $pure; Info = $info }
}

# The git view for every anchor whose folder exists (Get-CsgTreeInfo, cached).
function Confirm-CsgAnchors($Anchors) {
    foreach ($a in @($Anchors)) { if ($a.Pure -and $null -eq $a.Info) { $a.Info = Get-CsgTreeInfo $a.Dir } }
}

# Per anchor, the git view when there is one, else the file-read view.
function Get-CsgBestInfos($Anchors) {
    foreach ($a in @($Anchors)) {
        if ($a.Info) { $a.Info } elseif ($a.Pure) { $a.Pure }
    }
}

# Anchor file lines (Source 'anchor', Line 1..n), then the event cwd, then
# CLAUDE_PROJECT_DIR.
function Get-CsgAnchors {
    $list = New-Object System.Collections.Generic.List[object]
    $sid = Get-CsgProp $script:csgEvt 'session_id'
    if ($sid -cmatch $script:csgIdRx) {
        $af = [System.IO.Path]::Combine([System.IO.Path]::Combine((Get-CoordIndexDir), 'sessions'), $sid + '.anchor')
        $a = Read-CsgAnchorFile $af
        if ($a.Present) {
            $script:csgAnchorFile = $af
            $script:csgAnchorText = $a.Text
            $script:csgAnchorLineCount = @($a.Lines).Count
            $n = 0
            foreach ($l in @($a.Lines)) { $n++; $list.Add((New-CsgAnchor $l 'anchor' $n)) }
        }
    }
    $cwd = Get-CsgProp $script:csgEvt 'cwd'
    if ($cwd) { $list.Add((New-CsgAnchor $cwd 'cwd' 0)) }
    if ($env:CLAUDE_PROJECT_DIR) { $list.Add((New-CsgAnchor $env:CLAUDE_PROJECT_DIR 'project' 0)) }
    return $list.ToArray()
}

# Live rows an anchor's tree binds: by repo and branch; failing that, for a
# linked worktree, by Cwd. Returns { Rows; ByCwd }.
function Find-CsgRowsFor($Info, $Rows) {
    $byBranch = @($Rows | Where-Object { $_.Live -and (Test-CsgSame $_.Repo $Info.Main) -and $Info.Branch -and $_.Branch -ceq $Info.Branch })
    if ($byBranch.Count -gt 0) { return [pscustomobject]@{ Rows = $byBranch; ByCwd = $false } }
    if ($Info.Linked) {
        $byCwd = @($Rows | Where-Object { $_.Live -and (Test-CsgSame $_.Cwd $Info.Root) })
        return [pscustomobject]@{ Rows = $byCwd; ByCwd = $true }
    }
    return [pscustomobject]@{ Rows = @(); ByCwd = $false }
}

# { Bound (entries { Row; Anchors }, in anchor order); Ambiguous ($null or two
# rows); Notes (Cwd-fallback warnings) }.
function Find-CsgBinding($Anchors, $Rows) {
    $bound = New-Object System.Collections.Generic.List[object]
    $notes = New-Object System.Collections.Generic.List[string]
    foreach ($a in $Anchors) {
        $i = $a.Info
        if ($null -eq $i -or $i.State -ne 'ok') { continue }
        $f = Find-CsgRowsFor $i $Rows
        $hits = @($f.Rows)
        if ($hits.Count -ge 2) { return [pscustomobject]@{ Bound = @(); Ambiguous = @($hits[0], $hits[1]); Notes = @() } }
        if ($hits.Count -eq 0) { continue }
        $hit = $hits[0]
        if ($f.ByCwd) {
            $on = 'detached HEAD'
            if ($i.Branch) { $on = $i.Branch }
            $notes.Add($i.Root + ' is on ' + $on + ", not track " + $hit.Track + "'s branch " + $hit.Branch + '; guarding by its Cwd')
        }
        $entry = $null
        foreach ($b in $bound) { if ($b.Row.Id -eq $hit.Id) { $entry = $b; break } }
        if ($null -eq $entry) {
            $entry = [pscustomobject]@{ Row = $hit; Anchors = (New-Object System.Collections.Generic.List[object]) }
            $bound.Add($entry)
        }
        $entry.Anchors.Add($a)
    }
    return [pscustomobject]@{ Bound = $bound.ToArray(); Ambiguous = $null; Notes = $notes.ToArray() }
}

function Format-CsgAmbiguity($R1, $R2) {
    return ('ambiguous ledger rows bind this session: ' + $R1.Track + ' (' + $R1.Ledger + ') and ' + $R2.Track + ' (' + $R2.Ledger + '); the coordinator must fix the ledger')
}

# The started-outside warning: the anchor file's first line is not inside a
# linked worktree and a later line binds a row.
function Add-CsgStartedOutside($Anchors, $Bound) {
    if ($script:csgAnchorLineCount -lt 2) { return }
    $first = @($Anchors | Where-Object { $_.Source -eq 'anchor' -and $_.Line -eq 1 })
    if ($first.Count -gt 0) {
        # The git view, else (dropped on a git failure) the file-read view.
        $fi = $first[0].Info
        if ($null -eq $fi -or $fi.State -ne 'ok') { $fi = $first[0].Pure }
        if ($fi -and $fi.State -eq 'ok' -and $fi.Linked) { return }
    }
    foreach ($e in $Bound) {
        foreach ($a in $e.Anchors) {
            if ($a.Source -eq 'anchor' -and $a.Line -ge 2) {
                Add-CsgWarning ('this session started outside track ' + $e.Row.Track + "'s worktree; it is guarded only from its first edit there; start the track in its worktree")
                break
            }
        }
    }
}

# On a call that finds the anchor file holding one line that binds nothing, the
# worktree root of the anchor that bound the first row is appended as its
# second line (two parallel calls may both append; harmless, later calls read
# two or more lines and append nothing).
function Update-CsgAnchorFile($Bound) {
    if (-not $script:csgAnchorFile -or $script:csgAnchorLineCount -ne 1) { return }
    foreach ($e in $Bound) { foreach ($a in $e.Anchors) { if ($a.Source -eq 'anchor') { return } } }
    $root = $null
    foreach ($e in $Bound) {
        foreach ($a in $e.Anchors) { if (-not $root -and $a.Info -and $a.Info.Root) { $root = $a.Info.Root } }
    }
    if (-not $root) { return }
    if ((Get-CsgLeft) -lt 200) {
        Add-CsgWarning ('session anchor ' + $script:csgAnchorFile + ' not updated (under 200 ms of the budget left)')
        return
    }
    $text = $root + "`n"
    if ($script:csgAnchorText -and -not $script:csgAnchorText.EndsWith("`n")) { $text = "`n" + $text }
    $fs = $null
    try {
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($text)
        $fs = New-Object System.IO.FileStream($script:csgAnchorFile, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        $fs.Write($bytes, 0, $bytes.Length)
    }
    catch { Add-CsgWarning ('session anchor ' + $script:csgAnchorFile + ' not updated (' + $_.Exception.Message + ')') }
    finally { if ($fs) { $fs.Dispose() } }
}

# ---------------------------------------------------------------------------
# Midnight rollover: no row bound today, yesterday's index present.
# ---------------------------------------------------------------------------
# $TodayRows are the rows of every today record read; a today row counts as
# carried forward only when its ledger is usable (checked here, lazily).
function Add-CsgRollover($Anchors, $TodayRows) {
    $entries = @(Read-CsgIndex $script:csgYdayIdx)
    if ($entries.Count -eq 0) { return }
    $yRecs = @(Read-CsgLedgers $entries $script:csgYday)
    if (@(Get-CsgCandidateRecs @(Get-CsgRows $yRecs) @(Get-CsgBestInfos $Anchors)).Count -eq 0) {
        # A dropped anchor that would bind a row of yesterday still warns.
        $why = Get-CsgDroppedWhy $Anchors @(Get-CsgRows $yRecs)
        if ($why) { Add-CsgWarning ('git failed (' + $why + '); ' + $script:csgNotGuarded) }
        return
    }
    $yRows = @(Confirm-CsgCandidates $Anchors $yRecs @(Get-CsgBestInfos $Anchors))
    $bindsAny = $false
    foreach ($a in $Anchors) {
        if ($a.Info -and $a.Info.State -eq 'ok' -and @((Find-CsgRowsFor $a.Info $yRows).Rows).Count -gt 0) { $bindsAny = $true; break }
    }
    if (-not $bindsAny) {
        $why = Get-CsgDroppedWhy $Anchors @(Get-CsgRows $yRecs)
        if ($why) { Add-CsgWarning ('git failed (' + $why + '); ' + $script:csgNotGuarded) }
        return
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($a in $Anchors) {
        $i = $a.Info
        if ($null -eq $i -or $i.State -ne 'ok') { continue }
        foreach ($y in @((Find-CsgRowsFor $i $yRows).Rows)) {
            if (-not $seen.Add($y.Id)) { continue }
            $carried = $false
            foreach ($tr in @($TodayRows)) {
                if (-not [string]::Equals($tr.Track, $y.Track, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                if (-not ((Test-CsgSame $tr.Repo $y.Repo) -or (-not $tr.Repo -and -not $y.Repo -and [string]::Equals($tr.RepoCell, $y.RepoCell, [System.StringComparison]::OrdinalIgnoreCase)))) { continue }
                if (Test-CsgLedgerUsable $tr.Rec) { $carried = $true; break }
            }
            if (-not $carried) {
                Add-CsgWarning ('track ' + $y.Track + ' was live yesterday (' + $y.Ledger + ") and has no row in today's ledgers; edits are NOT guarded until the coordinator carries the row forward or marks it DONE")
            }
        }
    }
}

# ---------------------------------------------------------------------------
# The target, with an acting track bound.
# ---------------------------------------------------------------------------
function Test-CsgTarget($Bound, $TodayRows, $Token) {
    $raw = $script:csgTargetRaw
    $full = $null
    try {
        $p = $raw
        if (-not (Test-CsgDrivePath $p) -and -not $p.StartsWith('\\') -and -not $p.StartsWith('//')) {
            $base = Get-CsgProp $script:csgEvt 'cwd'
            if (-not $base) { $base = [System.Environment]::CurrentDirectory }
            $p = [System.IO.Path]::Combine($base, $p)
        }
        $full = ConvertTo-CsgFull $p
    }
    catch { Exit-CsgBlock ($raw + ' cannot be resolved to a full path (' + $_.Exception.Message + '); the guard cannot verify where it lands') }
    if ($full.StartsWith('\\')) { Exit-CsgBlock ($full + ' is a network or device path; the guard cannot verify where it lands') }
    $dt = $null
    try { $dt = (New-Object System.IO.DriveInfo([System.IO.Path]::GetPathRoot($full))).DriveType } catch { $dt = $null }
    if ($dt -eq [System.IO.DriveType]::Network) { Exit-CsgBlock ($full + ' is on a network drive; the guard cannot verify where it lands') }

    # Aliases first, before any scope or outside-the-tree exemption.
    $link = Find-CsgLink $full
    if ($link) { Exit-CsgBlock ($full + ' crosses a junction or symlink at ' + $link + '; the guard cannot verify where it lands') }

    # Memory and plan folders under the user's home are allowed like a path
    # outside every tree (the home folder may itself be a git working tree).
    if (Test-CsgMemoryOrPlans $full) { Exit-CsgAllow }

    $dir = Get-CsgNearestDir $full
    if (-not $dir) { Exit-CsgAllow }
    Assert-CsgTime ('finding the working tree of ' + $dir)
    $t = Get-CsgTreeInfo $dir
    if ($t.State -eq 'none') { Exit-CsgAllow }
    if ($t.State -eq 'failed') { Exit-CsgGitFailed $t.Why }
    if ($t.State -ne 'ok') { Exit-CsgGitFailed ('no main worktree found for ' + $dir) }
    $tail = $full.Substring($dir.Length).TrimStart('\')
    $rel = ($t.Prefix + $tail.Replace('\', '/')).TrimStart('/')

    # The session's own worktree: the tree of an anchor that bound a row.
    $own = $null
    foreach ($e in $Bound) {
        foreach ($a in $e.Anchors) { if ($a.Info -and (Test-CsgSame $a.Info.Root $t.Root)) { $own = $e.Row; break } }
        if ($own) { break }
    }
    $rule = $own
    if (-not $rule -and $t.Linked -and $t.Branch -clike 'worktree-agent-*') {
        # A worktree-isolated subagent's worktree of a bound row's repo: that
        # row's Scope, relative to the subagent worktree's root.
        foreach ($e in $Bound) { if (Test-CsgSame $e.Row.Repo $t.Main) { $rule = $e.Row; break } }
    }
    $crossNote = ''
    if (-not $rule) {
        # Another tree: only a second live row with the same token naming its
        # repo and branch, in a usable ledger; two such rows are ambiguity.
        $cands = New-Object System.Collections.Generic.List[object]
        foreach ($x in @($TodayRows)) {
            if ($x.Live -and (Test-CsgSame $x.Repo $t.Main) -and $t.Branch -and $x.Branch -ceq $t.Branch) {
                if (Test-CsgLedgerUsable $x.Rec) { $cands.Add($x) }
            }
        }
        if ($cands.Count -ge 2) { Exit-CsgBlock (Format-CsgAmbiguity $cands[0] $cands[1]) }
        if ($cands.Count -eq 1) {
            if ($Token -and $cands[0].Token -and $cands[0].Token -eq $Token) { $rule = $cands[0] }
            else { $crossNote = ' Track ' + $cands[0].Track + ' names that tree, but this session may write there only if both rows hold the same session id; a Session cell that holds only a name never binds.' }
        }
    }
    if ($rule) {
        # Always in scope, but only in a worktree bound to the acting track.
        if (Test-CoordInScope -Path $rel -Globs @('.claude/handovers/**', '.claude/coordination/**') -IgnoreCase) { Exit-CsgAllow }
        $globs = Split-CoordScope -Scope @($rule.Scope)
        if (@($globs).Count -gt 0 -and (Test-CoordInScope -Path $rel -Globs $globs -IgnoreCase)) { Exit-CsgAllow }
    }
    # The refusal names the row whose scope applied, else the first bound row.
    $named = $rule
    if (-not $named) { $named = $Bound[0].Row }
    $ng = Split-CoordScope -Scope @($named.Scope)
    Exit-CsgBlock ($full + ' is outside track ' + $named.Track + "'s scope (" + (@($ng) -join ', ') + '). Ask the coordinator to widen the ledger row, or message the owning track; do not edit it.' + $crossNote)
}

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------
function Invoke-CsgAnchorMode {
    $sid = Get-CsgProp $script:csgEvt 'session_id'
    if ($sid -cnotmatch $script:csgIdRx) { Exit-Csg 0 }
    $cwd = Get-CsgProp $script:csgEvt 'cwd'
    if (-not (Test-CsgDrivePath $cwd)) { Add-CsgWarning 'session anchor not written (the event has no full cwd)'; Exit-CsgAllow }
    try {
        $full = ConvertTo-CsgFull $cwd
        $dir = [System.IO.Path]::Combine((Get-CoordIndexDir), 'sessions')
        $file = [System.IO.Path]::Combine($dir, $sid + '.anchor')
        # Anchor policy: only a day with a registered coordinator (today's or
        # yesterday's index exists) touches the sessions folder at all; otherwise
        # nothing is written, refreshed or pruned, not even the sessions folder.
        if (-not ([System.IO.File]::Exists((Get-CoordIndexPath -Date $script:csgToday)) -or [System.IO.File]::Exists((Get-CoordIndexPath -Date $script:csgYday)))) { Exit-Csg 0 }
        if ([System.IO.File]::Exists($file)) {
            # A start, resume, compact or clear of a session that already has its
            # anchor keeps the file as it is; only its write time is refreshed, so
            # the 7-day prune below does not take the anchor of a session that
            # started or resumed recently.
            try { [System.IO.File]::SetLastWriteTimeUtc($file, [DateTime]::UtcNow) } catch { }
            Exit-Csg 0
        }
        if ($script:csgSw.ElapsedMilliseconds -ge $script:csgAnchorBudgetMs) {
            Add-CsgWarning ('session anchor not written (the ' + $script:csgAnchorBudgetMs + ' ms budget ran out)')
            Exit-CsgAllow
        }
        [void][System.IO.Directory]::CreateDirectory($dir)
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($full + "`n")
        $fs = $null
        try { $fs = New-Object System.IO.FileStream($file, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None) }
        catch { if ([System.IO.File]::Exists($file)) { Exit-Csg 0 }; throw }
        $ok = $false
        try { $fs.Write($bytes, 0, $bytes.Length); $fs.Flush(); $ok = $true }
        finally {
            $fs.Dispose()
            if (-not $ok) { try { [System.IO.File]::Delete($file) } catch { } }
        }
        # Prune on the write path: anchor files not written for 7 days. Best
        # effort, inside the anchor budget; a file that cannot be removed stays.
        # Its own try: the anchor is already written, so a failure here (the
        # folder cannot be listed) must not turn into a "not written" warning.
        try {
            $cutoff = [DateTime]::UtcNow.AddDays(-7)
            foreach ($old in [System.IO.Directory]::EnumerateFiles($dir, '*.anchor')) {
                if ($script:csgSw.ElapsedMilliseconds -ge $script:csgAnchorBudgetMs) { break }
                if ($old -eq $file) { continue }
                try { if ([System.IO.File]::GetLastWriteTimeUtc($old) -lt $cutoff) { [System.IO.File]::Delete($old) } } catch { }
            }
        }
        catch { }
    }
    catch {
        Add-CsgWarning ('session anchor not written (' + $_.Exception.Message + ')')
        Exit-CsgAllow
    }
    Exit-Csg 0
}

# The main checkout of the anchor file's first line when that line lies in a
# main checkout (not a linked worktree) whose canonical ledger for today, or
# yesterday, is listed in that day's index: the coordinator's own session.
# $null otherwise. Decided from file reads (git only when that line's .git
# layout is unusual). Yesterday's entries are kept in $csgYdayEntries.
function Get-CsgCoordinatorMain($Anchors, $TodayEntries, [bool]$YdayExists) {
    $l1 = $null
    foreach ($a in @($Anchors)) { if ($a.Source -eq 'anchor' -and $a.Line -eq 1) { $l1 = $a; break } }
    if ($null -eq $l1) { return $null }
    $i = $l1.Info
    if ($null -eq $i) { $i = $l1.Pure }
    if ($null -eq $i -or $i.State -ne 'ok' -or $i.Linked) { return $null }
    $mine = $i.Main.TrimEnd('\') + '\.claude\coordination\' + $script:csgToday + '.md'
    foreach ($e in @($TodayEntries)) { if (Test-CsgSame ([string]$e) $mine) { return $i.Main } }
    if (-not $YdayExists) { return $null }
    $entries = @(Read-CsgIndexQuiet $script:csgYdayIdx)
    $script:csgYdayEntries = $entries
    $mineY = $i.Main.TrimEnd('\') + '\.claude\coordination\' + $script:csgYday + '.md'
    foreach ($e in $entries) { if (Test-CsgSame ([string]$e) $mineY) { return $i.Main } }
    return $null
}

# An index's entries with no warning (a timeout still ends the run).
function Read-CsgIndexQuiet([string]$Path) {
    Assert-CsgTime ('reading the ledger index ' + $Path)
    $left = [int](Get-CsgLeft)
    $r = $null
    try { $r = Get-CoordIndexedLedgers -Path $Path -TimeoutMs $left } catch { $r = $null }
    Stop-CsgOnReadTimeout $r $left ('reading the ledger index ' + $Path)
    if ($null -eq $r -or -not $r.Ok) { return }
    foreach ($e in @($r.Entries)) { if ($e) { [string]$e } }
}

# A coordinator-checkout session never binds. When the edit's TARGET lies in a
# linked worktree (its tree read by file, like the pre-binding) that a live row
# binds by file reads (canonical-looking ledgers of today's index, else
# yesterday's; no git check, no ledger warning), it warns that this edit is not
# guarded. A target anywhere else returns before any ledger read.
function Add-CsgCoordinatorWarning($Anchors, [string]$Main, $TodayEntries, [bool]$YdayExists) {
    $ti = $null
    try {
        $p = $script:csgTargetRaw
        if (-not (Test-CsgDrivePath $p)) {
            $base = Get-CsgProp $script:csgEvt 'cwd'
            if (-not (Test-CsgDrivePath $base)) { return }
            $p = [System.IO.Path]::Combine($base, $p)
        }
        $tf = ConvertTo-CsgFull $p
        if (-not (Test-CsgDrivePath $tf)) { return }
        $dir = Get-CsgNearestDir $tf
        if ($dir) { $ti = Get-CsgPureInfo $dir }
    }
    catch { return }
    if ($null -eq $ti -or $ti.State -ne 'ok' -or -not $ti.Linked) { return }
    $infos = @($ti)
    $days = @(@{ Date = $script:csgToday; Entries = @($TodayEntries) })
    if ($YdayExists) {
        if ($null -eq $script:csgYdayEntries) { $script:csgYdayEntries = @(Read-CsgIndexQuiet $script:csgYdayIdx) }
        $days += @{ Date = $script:csgYday; Entries = @($script:csgYdayEntries) }
    }
    foreach ($day in $days) {
        $no = 0
        foreach ($e in @($day.Entries)) {
            $no++
            if (-not (Test-CsgPureCanonical $e $day.Date)) { continue }
            $rec = [pscustomobject]@{ Path = $e; Date = $day.Date; No = $no; Rows = @(); Read = $false; ReadOk = $false; ReadError = $null; Checked = $false; Usable = $false }
            Read-CsgLedgerFile $rec
            foreach ($i in $infos) {
                foreach ($row in @(Get-CsgRowHits $rec.Rows $i)) {
                    Add-CsgWarning ("this session was opened on the coordinator's checkout " + $Main + "; this edit in track " + $row.Track + "'s worktree is NOT guarded; start the track in its worktree")
                    return
                }
            }
        }
    }
}

# The git failure of an anchor that was dropped (its git view 'failed') although
# its file-read view could have bound a live row of $Rows (or was unusual);
# $null when there is none.
function Get-CsgDroppedWhy($Anchors, $Rows) {
    foreach ($a in @($Anchors)) {
        if ($null -eq $a.Info -or $a.Info.State -ne 'failed') { continue }
        if ($null -eq $a.Pure -or $a.Pure.State -eq 'unusual') { return $a.Info.Why }
        if (@(Get-CsgCandidateRecs $Rows @($a.Pure)).Count -gt 0) { return $a.Info.Why }
    }
    return $null
}

function Invoke-CsgGuard {
    $todayEntries = @(Read-CsgIndex (Get-CoordIndexPath -Date $script:csgToday))
    $script:csgYdayIdx = Get-CoordIndexPath -Date $script:csgYday
    $ydayExists = [System.IO.File]::Exists($script:csgYdayIdx)
    if ($todayEntries.Count -eq 0 -and -not $ydayExists) { Exit-CsgAllow }

    # Anchors and ledgers by file reads; git only from here on when a live row
    # could bind (or a ledger needs its warning).
    $anchors = @(Get-CsgAnchors)
    $inRepo = @(Get-CsgBestInfos $anchors | Where-Object { $_.State -eq 'ok' })
    if ($inRepo.Count -eq 0) {
        # An unusual anchor whose git lookup failed leaves the binding undecided.
        $why = Get-CsgDroppedWhy $anchors @()
        if ($why) { Exit-CsgGitFailed $why }
        Exit-CsgAllow
    }
    # A coordinator-checkout session binds nothing (no row, no rollover, no
    # line 2); it warns when the edit's target lies in a live track's worktree.
    $coordMain = Get-CsgCoordinatorMain $anchors $todayEntries $ydayExists
    if ($coordMain) {
        Add-CsgCoordinatorWarning $anchors $coordMain $todayEntries $ydayExists
        Exit-CsgAllow
    }

    $todayRecs = @(Read-CsgLedgers $todayEntries $script:csgToday)
    $todayAll = @(Get-CsgRows $todayRecs)
    $usable = @()
    if (@(Get-CsgCandidateRecs $todayAll @(Get-CsgBestInfos $anchors)).Count -gt 0) {
        $usable = @(Confirm-CsgCandidates $anchors $todayRecs @(Get-CsgBestInfos $anchors))
    }
    $todayRows = @(Get-CsgRows $todayRecs)
    $b = Find-CsgBinding $anchors $usable
    if ($b.Ambiguous) { Exit-CsgBlock (Format-CsgAmbiguity $b.Ambiguous[0] $b.Ambiguous[1]) }
    $bound = @($b.Bound)
    if ($bound.Count -eq 0) {
        # An anchor dropped on a git failure that could have bound a row leaves
        # the binding undecided.
        $why = Get-CsgDroppedWhy $anchors $todayAll
        if ($why) { Exit-CsgGitFailed $why }
        if ($ydayExists) { Add-CsgRollover $anchors $todayRows }
        Exit-CsgAllow
    }
    # One acting track: one row, or rows that all hold one valid token.
    $token = $bound[0].Row.Token
    for ($k = 1; $k -lt $bound.Count; $k++) {
        $o = $bound[$k].Row
        if (-not $token -or -not $o.Token -or $o.Token -ne $token) { Exit-CsgBlock (Format-CsgAmbiguity $bound[0].Row $o) }
    }
    foreach ($n in @($b.Notes)) { Add-CsgWarning $n }
    # A dropped anchor whose file-read view finds a live row that is not bound
    # (and holds another token), or is unusual (no row known): the bound row
    # judges the call, with a warning.
    $boundIds = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($e in $bound) { [void]$boundIds.Add($e.Row.Id) }
    foreach ($a in $anchors) {
        if ($null -eq $a.Info -or $a.Info.State -ne 'failed' -or $null -eq $a.Pure) { continue }
        if ($a.Pure.State -eq 'unusual') {
            Add-CsgWarning ('git failed on anchor ' + $a.Dir + ' (' + $a.Info.Why + '), which might bind another track; judged by track ' + $bound[0].Row.Track + "'s scope")
            continue
        }
        if ($a.Pure.State -ne 'ok') { continue }
        foreach ($row in @(Get-CsgRowHits $todayAll $a.Pure)) {
            if ($boundIds.Contains($row.Id)) { continue }
            if ($token -and $row.Token -and $row.Token -eq $token) { continue }
            Add-CsgWarning ('git failed on anchor ' + $a.Dir + ' (' + $a.Info.Why + '), which could bind track ' + $row.Track + "; judged by track " + $bound[0].Row.Track + "'s scope")
            break
        }
    }
    Add-CsgStartedOutside $anchors $bound
    Update-CsgAnchorFile $bound
    Test-CsgTarget $bound $todayRows $token
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
# A stdin read or JSON parse failure warns (the guard did not run); empty
# stdin is no event and stays silent.
$csgRaw = ''
try {
    $csgReader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), (New-Object System.Text.UTF8Encoding($false)), $true)
    $csgRaw = $csgReader.ReadToEnd()
}
catch {
    Add-CsgWarning ('event could not be read (' + $_.Exception.Message + '); the guard did not run')
    Exit-CsgAllow
}
if ($csgRaw) { $csgRaw = $csgRaw.TrimStart([char]0xFEFF) }
if (-not $csgRaw -or -not $csgRaw.Trim()) { exit 0 }
$csgEvt = $null
try { $csgEvt = ConvertFrom-Json -InputObject $csgRaw -ErrorAction Stop }
catch {
    Add-CsgWarning ('event could not be read (' + $_.Exception.Message + '); the guard did not run')
    Exit-CsgAllow
}
if ($null -eq $csgEvt -or $csgEvt -is [array]) { exit 0 }
$csgMode = Get-CsgProp $csgEvt 'hook_event_name'
if ($csgMode -cne 'SessionStart' -and $csgMode -cne 'PreToolUse') { exit 0 }

$csgTargetRaw = ''
if ($csgMode -ceq 'PreToolUse') {
    if (@('Edit', 'Write', 'MultiEdit', 'NotebookEdit') -cnotcontains (Get-CsgProp $csgEvt 'tool_name')) { exit 0 }
    $csgToolInput = $null
    $csgTi = $csgEvt.PSObject.Properties['tool_input']
    if ($csgTi) { $csgToolInput = $csgTi.Value }
    $csgTargetRaw = Get-CsgProp $csgToolInput 'file_path'
    if (-not $csgTargetRaw) { $csgTargetRaw = Get-CsgProp $csgToolInput 'notebook_path' }
    if (-not $csgTargetRaw) { exit 0 }
}
else { $csgNotGuarded = 'no session anchor was written' }

# UTF-8 for the refusal text on stderr (a path may hold non-ASCII characters).
try {
    $csgSavedEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
}
catch { $csgSavedEncoding = $null }

# coord-common.ps1: the plugin layout, hooks/ beside scripts/. Dot-sourced
# through the wildcard escape, so a '[' in the path cannot wildcard-match a sibling.
$csgCommon = $null
try { $csgCommon = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..\scripts\coord-common.ps1')) } catch { $csgCommon = $null }
if ($csgCommon -and -not [System.IO.File]::Exists($csgCommon)) { $csgCommon = $null }
if (-not $csgCommon) {
    Add-CsgWarning ('coord-common.ps1 was not found beside the hook; ' + $csgNotGuarded)
    Exit-CsgAllow
}
try { . ([WildcardPattern]::Escape($csgCommon.Replace('`', '``'))) }
catch {
    Add-CsgWarning ('coord-common.ps1 could not be loaded (' + $_.Exception.Message + '); ' + $csgNotGuarded)
    Exit-CsgAllow
}

try {
    # Today and yesterday, for both modes: the anchor policy and the guard read
    # the same two index files.
    $csgDate = [DateTime]::MinValue
    $csgToday = [string]$env:COORD_TODAY
    if (-not ($csgToday -match '^\d{4}-\d{2}-\d{2}$' -and [DateTime]::TryParseExact($csgToday, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$csgDate))) {
        $csgToday = Get-CoordToday
        [void][DateTime]::TryParseExact($csgToday, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$csgDate)
    }
    $csgYday = $csgDate.AddDays(-1).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    $csgYdayIdx = $null
    if ($csgMode -ceq 'SessionStart') { Invoke-CsgAnchorMode }
    else { Invoke-CsgGuard }
}
catch {
    Add-CsgWarning ('internal error (' + $_.Exception.Message + '); ' + $csgNotGuarded)
    Exit-CsgAllow
}
Exit-CsgAllow
