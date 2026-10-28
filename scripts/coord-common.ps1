# Ported from the private coordinate toolkit (coord-common.ps1), 2026-10-18.
#
# coord-common.ps1 - helpers shared by the coordinate scripts. Today
# coord-log.ps1, coord-brief.ps1, repo-snapshot.ps1 and slot-check.ps1
# dot-source it, from the same folder:
# `. (Join-Path $PSScriptRoot 'coord-common.ps1')`. merge-verify.ps1 and the
# scope guard hook are to share it too (ported in a later slice).
#
# Runs under Windows PowerShell 5.1 and PowerShell 7. Windows is the verified
# platform; every behaviour that differs elsewhere branches on
# Test-CoordWindows, and each non-Windows branch is marked "Not verified off
# Windows."
#
# Nothing here prints. Failures come back as values ({ Ok = $false; Error = ... })
# so that a caller can never read a failed git or gh call as "nothing found":
# a failure is "could not check", "unknown" or "preview failed", never READY,
# "none" or "no conflicts".

# Native output (git, gh) is decoded with [Console]::OutputEncoding in
# Windows PowerShell 5.1; UTF-8 keeps non-ASCII paths and titles intact.
# The set is inside try/catch: a console that refuses it (redirected, or a
# host without one) leaves the encoding as it was and the script runs on.
function Initialize-CoordConsole {
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
}

# $true on Windows: Windows PowerShell 5.1 (edition Desktop, which has no
# $IsWindows), PowerShell 7 with $IsWindows set, or a Windows PowerShell 5.0
# or older (no PSEdition at all) on a Win32NT platform. Every Windows-only
# behaviour in these scripts branches on it.
function Test-CoordWindows {
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return $true }
    if (Test-Path -LiteralPath 'variable:IsWindows') { return ((Get-Variable -Name IsWindows -ValueOnly) -eq $true) }
    if (-not $PSVersionTable.PSEdition) { return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) }
    return $false
}

# How two paths compare: ignoring case on Windows and macOS (their default
# file systems ignore it), exactly on Linux. Returns a StringComparison for
# [string]::Equals; with -Comparer, the matching StringComparer (for a
# HashSet).
function Get-CoordPathComparison {
    param([switch]$Comparer)
    $ignore = $true
    if (-not (Test-CoordWindows)) {
        # Not verified off Windows.
        $ignore = ((Test-Path -LiteralPath 'variable:IsMacOS') -and ((Get-Variable -Name IsMacOS -ValueOnly) -eq $true))
    }
    if ($Comparer) {
        if ($ignore) { return [System.StringComparer]::OrdinalIgnoreCase }
        return [System.StringComparer]::Ordinal
    }
    if ($ignore) { return [System.StringComparison]::OrdinalIgnoreCase }
    return [System.StringComparison]::Ordinal
}

function Get-CoordToday {
    return [DateTime]::Now.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
}

# The date a ledger's file-name leaf (no extension) stands for: the leaf when
# ALL of it is yyyy-MM-dd, else today. \z, not '$': '$' also matches before a
# final line feed (a name Windows cannot hold, so this is latent there).
function Get-CoordLedgerDate([string]$Leaf) {
    # [0-9], not \d (which also matches other scripts' digits), and a real date.
    $d = [DateTime]::MinValue
    if ($Leaf -match '^[0-9]{4}-[0-9]{2}-[0-9]{2}\z' -and
        [DateTime]::TryParseExact($Leaf, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$d)) { return $Leaf }
    return (Get-CoordToday)
}

function Test-CoordSha40([string]$Value) {
    return ($Value -cmatch '^[0-9a-f]{40}\z')
}

# Runs `git -C $Repo <args>`; returns { Code; Out (string[]) }. stderr dropped.
# @(...) and no `| Select-Object -First`: stopping a native pipeline early
# leaves $LASTEXITCODE at -1.
function Invoke-CoordGit {
    param([string]$Repo, [string[]]$GitArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = @(& git -C $Repo @GitArgs 2>$null)
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $prev }
    return [pscustomobject]@{ Code = $code; Out = [string[]]@($out | ForEach-Object { [string]$_ }) }
}

# A git invoker given as -Git (a scriptblock called as `& $Git <repo> <args>`
# that returns { Code; Out }), or Invoke-CoordGit when none is given.
function Invoke-CoordGitWith {
    param([scriptblock]$Git, [string]$Repo, [string[]]$GitArgs)
    if ($Git) { return (& $Git $Repo $GitArgs) }
    return (Invoke-CoordGit $Repo $GitArgs)
}

# One argument list for ProcessStartInfo.Arguments, quoted by the rules the
# C runtime parses (git.exe): an argument holding a space, a tab or a quote,
# or an empty one, is quoted; backslashes before a quote are doubled.
function ConvertTo-CoordArgLine([string[]]$Items) {
    $parts = foreach ($a in $Items) {
        $s = [string]$a
        if ($s.Length -gt 0 -and $s -notmatch '[\s"]') { $s }
        # \z, not '$': '$' also matches before a final line feed, which would
        # double a backslash that is not in front of the closing quote.
        else { '"' + (($s -replace '(\\*)"', '$1$1\"') -replace '(\\+)\z', '$1$1') + '"' }
    }
    return (@($parts) -join ' ')
}

# Moves every finished read of a bounded git call into its buffer (stdout) or
# drops it (stderr), and starts the next read; a read of 0 bytes, or one that
# failed, is the end of that stream.
function Step-CoordGitReads($S) {
    while (-not $S.OutEof -and $S.OutT.IsCompleted) {
        $n = 0
        if ($S.OutT.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) { $n = $S.OutT.Result }
        if ($n -le 0) { $S.OutEof = $true; break }
        $S.OutMs.Write($S.OutBuf, 0, $n)
        $S.OutT = $S.OutS.ReadAsync($S.OutBuf, 0, $S.OutBuf.Length)
    }
    while (-not $S.ErrEof -and $S.ErrT.IsCompleted) {
        $n = 0
        if ($S.ErrT.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) { $n = $S.ErrT.Result }
        if ($n -le 0) { $S.ErrEof = $true; break }
        $S.ErrT = $S.ErrS.ReadAsync($S.ErrBuf, 0, $S.ErrBuf.Length)
    }
}

# Runs `git -C $Repo <args>` with a time bound, for the scope guard (ported
# in a later slice), whose whole run is to have a 3 s budget. Returns { Code; Out (string[]); TimedOut }.
# git is the first git application on PATH (as `& git` in Invoke-CoordGit
# finds it; a .cmd there runs too). Both streams are read asynchronously into
# buffers, never to their end: stdout is decoded as UTF-8 (whatever the
# console code page), stderr is dropped. The process is waited on only with
# WaitForExit(<ms left>), never the unbounded overload, and the bound counts
# from the call's start. A git still running at the bound is killed with its
# children (on Windows `taskkill /T /F /PID`, waited on for at most 500 ms;
# elsewhere Kill($true) on its process object, the whole tree, then waited on
# for at most 500 ms; never by name) and the call returns TimedOut = $true,
# Code = -1, without waiting for the streams. A git that exits in time gets
# at most 250 ms more for its streams to end (a child that keeps stdout open
# is not waited for; Out holds what arrived). A
# TimeoutMs of 0 or less starts nothing and returns TimedOut = $true. git not
# found, or not startable: Code = -1, TimedOut = $false.
$script:coordGitExe = $null
$script:coordGitExeForPath = $null
function Invoke-CoordGitBounded {
    param([string]$Repo, [string[]]$GitArgs, [int]$TimeoutMs)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $none = [string[]]@()
    if ($TimeoutMs -le 0) { return [pscustomobject]@{ Code = -1; Out = $none; TimedOut = $true } }
    if (-not $script:coordGitExe -or $script:coordGitExeForPath -cne [string]$env:PATH) {
        $script:coordGitExe = $null
        $found = @(Get-Command git -CommandType Application -ErrorAction SilentlyContinue)
        if ($found.Count) { $script:coordGitExe = [string]$found[0].Source }
        $script:coordGitExeForPath = [string]$env:PATH
    }
    if (-not $script:coordGitExe) { return [pscustomobject]@{ Code = -1; Out = $none; TimedOut = $false } }
    if ($TimeoutMs - [int]$sw.ElapsedMilliseconds -le 0) { return [pscustomobject]@{ Code = -1; Out = $none; TimedOut = $true } }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:coordGitExe
    $psi.Arguments = ConvertTo-CoordArgLine (@('-C', $Repo) + @($GitArgs))
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    try { $p = [System.Diagnostics.Process]::Start($psi) }
    catch { return [pscustomobject]@{ Code = -1; Out = $none; TimedOut = $false } }
    try { $p.StandardInput.Close() } catch { }
    $st = @{ OutS = $p.StandardOutput.BaseStream; ErrS = $p.StandardError.BaseStream
        OutBuf = (New-Object byte[] 65536); ErrBuf = (New-Object byte[] 4096)
        OutMs = (New-Object System.IO.MemoryStream); OutEof = $false; ErrEof = $false }
    $st.OutT = $st.OutS.ReadAsync($st.OutBuf, 0, $st.OutBuf.Length)
    $st.ErrT = $st.ErrS.ReadAsync($st.ErrBuf, 0, $st.ErrBuf.Length)

    $exited = $false
    while ($true) {
        Step-CoordGitReads $st
        if ($p.HasExited) { $exited = $true; break }
        $left = $TimeoutMs - [int]$sw.ElapsedMilliseconds
        if ($left -le 0) { break }
        $pending = @()
        if (-not $st.OutEof) { $pending += $st.OutT }
        if (-not $st.ErrEof) { $pending += $st.ErrT }
        if ($pending.Count) { [void][System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]$pending, [int][Math]::Min($left, 50)) }
        else { $exited = $p.WaitForExit($left); break }
    }
    if (-not $exited) {
        if (Test-CoordWindows) {
            try {
                $tk = New-Object System.Diagnostics.ProcessStartInfo
                $tk.FileName = Join-Path $env:SystemRoot 'System32\taskkill.exe'
                if (-not [System.IO.File]::Exists($tk.FileName)) { $tk.FileName = 'taskkill.exe' }
                $tk.Arguments = "/T /F /PID $($p.Id)"
                $tk.UseShellExecute = $false
                $tk.CreateNoWindow = $true
                # Redirected: taskkill's SUCCESS lines must not reach the hook's stdout.
                $tk.RedirectStandardOutput = $true
                $tk.RedirectStandardError = $true
                $kp = [System.Diagnostics.Process]::Start($tk)
                [void]$kp.WaitForExit(500)
            }
            catch { }
        }
        else {
            # Not verified off Windows. Kill($true) ends the started git and
            # its whole process tree through its process object, never by
            # name. That overload exists on .NET Core 3.0 and later only, so
            # in PowerShell 7 only, the PowerShell that runs off Windows.
            try { $p.Kill($true) } catch { }
            try { [void]$p.WaitForExit(500) } catch { }
        }
        return [pscustomobject]@{ Code = -1; Out = $none; TimedOut = $true }
    }
    $graceEnd = $sw.ElapsedMilliseconds + 250
    while ($true) {
        Step-CoordGitReads $st
        if ($st.OutEof -and $st.ErrEof) { break }
        $left = [int]($graceEnd - $sw.ElapsedMilliseconds)
        if ($left -le 0) { break }
        $pending = @()
        if (-not $st.OutEof) { $pending += $st.OutT }
        if (-not $st.ErrEof) { $pending += $st.ErrT }
        [void][System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]$pending, $left)
    }
    $code = $p.ExitCode
    $text = $utf8.GetString($st.OutMs.ToArray())
    if ($text.EndsWith("`n")) {
        $text = $text.Substring(0, $text.Length - 1)
        if ($text.EndsWith("`r")) { $text = $text.Substring(0, $text.Length - 1) }
    }
    $out = $none
    if ($st.OutMs.Length -gt 0) { $out = [string[]]($text -split '\r?\n') }
    if ($st.OutEof -and $st.ErrEof) { $p.Dispose() }
    return [pscustomobject]@{ Code = $code; Out = [string[]]$out; TimedOut = $false }
}

# The repository's main worktree: the first entry of `git worktree list
# --porcelain`. $null outside a repo or for a bare main. A --separate-git-dir
# repo lists its git dir there (git does not record the main checkout): then
# $Dir's own top level when $Dir is in the main checkout, else $null.
# Paths compare as Get-CoordPathComparison says.
# -Git: the git invoker every git call here goes through (see
# Invoke-CoordGitWith; the scope guard, ported in a later slice, is to pass a
# bounded one); default
# Invoke-CoordGit.
function Get-CoordMainRoot {
    param([string]$Dir, [scriptblock]$Git = $null)
    $r = Invoke-CoordGitWith $Git $Dir @('worktree', 'list', '--porcelain')
    if ($null -eq $r -or $r.Code -ne 0 -or $r.Out.Count -eq 0 -or -not ([string]$r.Out[0]).StartsWith('worktree ')) { return $null }
    for ($k = 1; $k -lt [Math]::Min(3, $r.Out.Count); $k++) { if ($r.Out[$k].Trim() -eq 'bare') { return $null } }
    $main = [System.IO.Path]::GetFullPath($r.Out[0].Substring(9).Trim())
    if (Test-Path -LiteralPath (Join-Path $main '.git')) { return $main }
    $gd = Invoke-CoordGitWith $Git $Dir @('rev-parse', '--path-format=absolute', '--absolute-git-dir')
    $top = Invoke-CoordGitWith $Git $Dir @('rev-parse', '--show-toplevel')
    if ($gd.Code -eq 0 -and $top.Code -eq 0 -and $gd.Out.Count -and $top.Out.Count -and
        [string]::Equals((ConvertTo-CoordFullPath $gd.Out[0].Trim()), $main.TrimEnd([System.IO.Path]::DirectorySeparatorChar), (Get-CoordPathComparison))) {
        return [System.IO.Path]::GetFullPath($top.Out[0].Trim())
    }
    return $null
}

# Today's (or $Date's) ledger path at the canonical location of the repo that
# holds $Dir. The file may not exist. $null outside a repo.
function Get-CoordLedgerPath {
    param([string]$Dir, [string]$Date = (Get-CoordToday))
    $main = Get-CoordMainRoot $Dir
    if (-not $main) { return $null }
    $sep = [string][System.IO.Path]::DirectorySeparatorChar
    return (Join-Path $main ('.claude' + $sep + 'coordination' + $sep + $Date + '.md'))
}

function ConvertTo-CoordFullPath([string]$Path) {
    return ([System.IO.Path]::GetFullPath($Path)).TrimEnd('\', '/')
}

# ---- the ledger index
# The scope guard (ported in a later slice) is to find the day's ledgers
# through <index dir>/<date>.ledgers, one full path per line; coord-log.ps1
# writes it. <index dir> is $env:COORD_INDEX_DIR when set (the coord-common
# and coord-log suites point it at a scratch folder), as a full path; else
# $HOME/.claude/coordination.
function Get-CoordIndexDir {
    $d = [string]$env:COORD_INDEX_DIR
    if ($d) { return [System.IO.Path]::GetFullPath($d) }
    $sep = [string][System.IO.Path]::DirectorySeparatorChar
    return ("$HOME" + $sep + '.claude' + $sep + 'coordination')
}

function Get-CoordIndexPath {
    param([string]$Date = (Get-CoordToday))
    return [System.IO.Path]::Combine((Get-CoordIndexDir), $Date + '.ledgers')
}

# The session token of a Tracks Session cell: the cell trimmed, one pair of
# surrounding backticks or double quotes removed, must be exactly ONE session
# id: `local_` and 8 or more hex digits, `local_` and a UUID, or a bare UUID
# (8-4-4-4-12 hex digits). Its token comes back (see below); anything else
# (empty, a name such as 'none', 'TBD' or 'main', two words, an id plus a
# note, two ids) is $null: two rows share a session only through one id each.
# Names are for display; only ids bind, because names repeat across repos and
# an ordinary word would become a shared token.
function Get-CoordSessionToken([string]$Cell) {
    if (-not $Cell) { return $null }
    $t = $Cell.Trim()
    if ($t.Length -ge 2 -and (($t.StartsWith('`') -and $t.EndsWith('`')) -or ($t.StartsWith('"') -and $t.EndsWith('"')))) {
        $t = $t.Substring(1, $t.Length - 2)
    }
    # \A and \z, not ^ and $: $ also matches before a final line feed.
    $uuid = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    # A local_ id binds by its leading hex run, as the private toolkit did: the
    # short form (local_<8 hex>) and the full local_<uuid> of one session are
    # the same token. A bare UUID binds as itself.
    if ($t -cmatch ('\A(?:local_[0-9a-fA-F]{8,}|local_' + $uuid + ')\z')) {
        return ('local_' + [regex]::Match($t.Substring(6), '\A[0-9a-fA-F]+').Value).ToLowerInvariant()
    }
    if ($t -cmatch ('\A' + $uuid + '\z')) { return $t.ToLowerInvariant() }
    return $null
}

# Whether $Path is the canonical ledger of $Date:
# <Get-CoordMainRoot of its folder>/.claude/coordination/<Date>.md, compared
# after GetFullPath, as Get-CoordPathComparison says (ignoring case on
# Windows). Refused before any git call (a network open can stall past any
# deadline): on Windows a UNC path or a drive that is not a local fixed drive;
# elsewhere a path that starts with //. Refused after: no main root (outside
# a repo, or git failed), any other path (a stale copy the app made in a
# linked worktree, another day's ledger). Returns { Ok; Canonical (the canonical path, $null when there is no
# main root); Undecided ($true only when no main root was found: outside a
# repo and a failed git look the same, so the answer is "could not tell");
# Error }.
function Test-CoordLedgerCanonical {
    param([string]$Path, [string]$Date = (Get-CoordToday), [scriptblock]$Git = $null)
    if ($Date -notmatch '^\d{4}-\d{2}-\d{2}\z') { return [pscustomobject]@{ Ok = $false; Canonical = $null; Undecided = $false; Error = "the date '$Date' is not yyyy-MM-dd" } }
    try { $full = [System.IO.Path]::GetFullPath($Path) }
    catch { return [pscustomobject]@{ Ok = $false; Canonical = $null; Undecided = $false; Error = "'$Path' is not a usable path: $($_.Exception.Message)" } }
    if (Test-CoordWindows) {
        if ($full.StartsWith('\\')) { return [pscustomobject]@{ Ok = $false; Canonical = $null; Undecided = $false; Error = "$full is a network (UNC) path; only a ledger on a local fixed drive is used" } }
        $type = 'unknown'
        try { $type = [string]([System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot($full))).DriveType } catch { }
        if ($type -ne 'Fixed') { return [pscustomobject]@{ Ok = $false; Canonical = $null; Undecided = $false; Error = "$full is not on a local fixed drive (drive type $type)" } }
    }
    else {
        # Not verified off Windows. No drive letters here: a path is local
        # unless it starts with // (checked as given too: GetFullPath may
        # collapse the doubled separator).
        if ($Path.StartsWith('//') -or $full.StartsWith('//')) { return [pscustomobject]@{ Ok = $false; Canonical = $null; Undecided = $false; Error = "$full is a network path (it starts with //); only a ledger on a local drive is used" } }
    }
    $main = Get-CoordMainRoot ([System.IO.Path]::GetDirectoryName($full)) -Git $Git
    if (-not $main) { return [pscustomobject]@{ Ok = $false; Canonical = $null; Undecided = $true; Error = "$full is not in a git repository with a main checkout (or git failed)" } }
    $sep = [string][System.IO.Path]::DirectorySeparatorChar
    $canon = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($main, '.claude' + $sep + 'coordination' + $sep + $Date + '.md'))
    if (-not [string]::Equals($full, $canon, (Get-CoordPathComparison))) {
        return [pscustomobject]@{ Ok = $false; Canonical = $canon; Undecided = $false; Error = "$full is not the canonical ledger; the coordinator's ledger is $canon" }
    }
    return [pscustomobject]@{ Ok = $true; Canonical = $canon; Undecided = $false; Error = $null }
}

# The file open for the two bounded readers below. With -TimeoutMs given to
# them the file is opened for asynchronous I/O. The open itself is not bounded
# (.NET Framework has no timeout on a local open); Test-CoordLedgerCanonical
# keeps network paths out.
function Open-CoordReadStream([string]$Path, [bool]$Bounded) {
    if ($Bounded) {
        return [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite, 4096, [System.IO.FileOptions]::Asynchronous)
    }
    return [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
}

# The chunk read both bounded readers below use: up to $MaxBytes from
# $Stream, until that many are in or the stream ends. Without -TimeoutMs:
# synchronous reads, no bound. With it: each read is one ReadAsync waited on
# for the time left from this call's start; a read still pending when the time
# runs out is abandoned (the caller disposes the stream), and a TimeoutMs of 0
# or less reads nothing. Returns { Ok; Bytes (what was read); TimedOut; Error }:
# timed out is Ok = $false, TimedOut = $true, Error 'read timed out after
# <ms> ms'; a failed read is Ok = $false with the failure in Error.
function Read-CoordStreamBounded {
    param([System.IO.Stream]$Stream, [int]$MaxBytes, [int]$TimeoutMs = 0)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $bounded = $PSBoundParameters.ContainsKey('TimeoutMs')
    $timedOut = [pscustomobject]@{ Ok = $false; Bytes = [byte[]]@(); TimedOut = $true; Error = "read timed out after $TimeoutMs ms" }
    if ($bounded -and $TimeoutMs -le 0) { return $timedOut }
    $buf = New-Object byte[] ([Math]::Max(0, $MaxBytes))
    $count = 0
    try {
        while ($count -lt $buf.Length) {
            if ($bounded) {
                $left = $TimeoutMs - [int]$sw.ElapsedMilliseconds
                if ($left -le 0) { return $timedOut }
                $t = $Stream.ReadAsync($buf, $count, $buf.Length - $count)
                if (-not $t.Wait($left)) { return $timedOut }
                $n = $t.Result
            }
            else { $n = $Stream.Read($buf, $count, $buf.Length - $count) }
            if ($n -le 0) { break }
            $count += $n
        }
    }
    catch {
        $e = $_.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        return [pscustomobject]@{ Ok = $false; Bytes = [byte[]]@(); TimedOut = $false; Error = $e.Message }
    }
    $out = $buf
    if ($count -lt $buf.Length) {
        $out = New-Object byte[] $count
        [Array]::Copy($buf, 0, $out, 0, $count)
    }
    return [pscustomobject]@{ Ok = $true; Bytes = $out; TimedOut = $false; Error = $null }
}

# The bounded discovery read of an index, for the scope guard and
# coord-brief.ps1 -Check (both ported in a later slice). From -Path (a file;
# at most its first 65536 bytes are read, through a handle that lets a writer keep it open) or -Bytes (the same
# rules over bytes in hand; Register-CoordLedger checks its proposed index this
# way). Lines end in LF (one CR before it is dropped); a last line with no LF
# inside the bytes read (a torn write, or a line cut by the 64 KiB bound) is
# dropped; blank lines are skipped. Each entry is GetFullPath'd with trailing
# separators trimmed; a line GetFullPath rejects is skipped; a repeat (compared
# as Get-CoordPathComparison says: ignoring case on Windows) counts once, as
# first spelled. Returns { Ok; Entries (the first 8
# distinct, in file order); Overflow (a 9th distinct entry, or more than 65536
# bytes); Missing (no file: Ok, no entries); TimedOut; Error }. A file that
# cannot be read (a folder, a refused open) is Ok = $false.
# -TimeoutMs (with -Path; default: no bound): the read is waited on for at
# most that long from the call's start (Read-CoordStreamBounded); when the time
# runs out, or TimeoutMs is 0 or less (then nothing is read), the result is
# Ok = $false, TimedOut = $true, Error 'read timed out after <ms> ms'.
function Get-CoordIndexedLedgers {
    param([string]$Path = '', [byte[]]$Bytes = $null, [int]$TimeoutMs = 0)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $cap = 65536
    $bounded = $PSBoundParameters.ContainsKey('TimeoutMs')
    $timedOut = [pscustomobject]@{ Ok = $false; Entries = [string[]]@(); Overflow = $false; Missing = $false; TimedOut = $true; Error = "read timed out after $TimeoutMs ms" }
    if ($PSBoundParameters.ContainsKey('Bytes')) {
        # Not `$data = if ...`: a statement's output is unrolled, and the bytes
        # would come back as object[].
        $data = $Bytes
        if ($null -eq $data) { $data = [byte[]]@() }
        $total = $data.Length
        $count = [Math]::Min($total, $cap)
    }
    else {
        if ($bounded -and $TimeoutMs -le 0) { return $timedOut }
        if (-not [System.IO.File]::Exists($Path) -and -not [System.IO.Directory]::Exists($Path)) {
            return [pscustomobject]@{ Ok = $true; Entries = [string[]]@(); Overflow = $false; Missing = $true; TimedOut = $false; Error = $null }
        }
        try {
            $fs = Open-CoordReadStream $Path $bounded
            try {
                $total = $fs.Length
                $readArgs = @{ Stream = $fs; MaxBytes = [int][Math]::Min($total, [long]$cap) }
                if ($bounded) { $readArgs['TimeoutMs'] = $TimeoutMs - [int]$sw.ElapsedMilliseconds }
                $rd = Read-CoordStreamBounded @readArgs
            }
            finally { $fs.Dispose() }
        }
        catch { return [pscustomobject]@{ Ok = $false; Entries = [string[]]@(); Overflow = $false; Missing = $false; TimedOut = $false; Error = "cannot read the ledger index ${Path}: $($_.Exception.Message)" } }
        if ($rd.TimedOut) { return $timedOut }
        if (-not $rd.Ok) { return [pscustomobject]@{ Ok = $false; Entries = [string[]]@(); Overflow = $false; Missing = $false; TimedOut = $false; Error = "cannot read the ledger index ${Path}: $($rd.Error)" } }
        $data = $rd.Bytes
        $count = $data.Length
    }
    $overflow = ($total -gt $cap)
    $entries = New-Object System.Collections.Generic.List[string]
    $pathComparer = Get-CoordPathComparison -Comparer
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ($pathComparer)
    $rawSeen = New-Object 'System.Collections.Generic.HashSet[string]' ($pathComparer)
    $lastLf = if ($count -gt 0) { [Array]::LastIndexOf($data, [byte]10, $count - 1) } else { -1 }
    if ($lastLf -ge 0) {
        $start = 0
        if ($count -ge 3 -and $data[0] -eq 0xEF -and $data[1] -eq 0xBB -and $data[2] -eq 0xBF) { $start = 3 }
        $lines = (New-Object System.Text.UTF8Encoding($false)).GetString($data, $start, [Math]::Max(0, $lastLf + 1 - $start)).Split([char]10)
        # The element after the last LF is the dropped (empty or torn) one.
        for ($i = 0; $i -lt $lines.Length - 1; $i++) {
            $l = $lines[$i]
            if ($l.EndsWith("`r")) { $l = $l.Substring(0, $l.Length - 1) }
            if (-not $l.Trim()) { continue }
            if (-not $rawSeen.Add($l)) { continue }
            try { $e = ConvertTo-CoordFullPath $l } catch { continue }
            if ($seen.Contains($e)) { continue }
            if ($entries.Count -ge 8) { $overflow = $true; break }
            [void]$seen.Add($e)
            $entries.Add($e)
        }
    }
    return [pscustomobject]@{ Ok = $true; Entries = [string[]]$entries.ToArray(); Overflow = $overflow; Missing = $false; TimedOut = $false; Error = $null }
}

# Adds the canonical ledger $Ledger (Test-CoordLedgerCanonical for $Date) to
# the index of $Date, once. Under <index>.lock (opened with no sharing, deleted
# on close, retried every 100 ms for 5 s: coord-log.ps1's lock, because two
# coordinators' ledger locks do not cover one shared index) it builds the
# proposed index (the current bytes, an LF first when they end without one,
# then the entry and an LF) and appends, in one write, only when
# Get-CoordIndexedLedgers over the proposed bytes returns the entry; so a
# ledger that registers is one the guard reads. Refused, the index unchanged:
# not canonical (nothing is created), 8 distinct ledgers already, the 64 KiB
# bound passed, the lock not taken. Returns { Ok; Added; Index; Error }.
function Register-CoordLedger {
    param([string]$Ledger, [string]$Date = (Get-CoordToday))
    $index = Get-CoordIndexPath -Date $Date
    $c = Test-CoordLedgerCanonical -Path $Ledger -Date $Date
    if (-not $c.Ok) { return [pscustomobject]@{ Ok = $false; Added = $false; Index = $index; Error = $c.Error } }
    $entry = $c.Canonical
    try { [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($index)) }
    catch { return [pscustomobject]@{ Ok = $false; Added = $false; Index = $index; Error = "cannot create the index folder of ${index}: $($_.Exception.Message)" } }
    $lockPath = $index + '.lock'
    $lock = $null
    for ($try = 1; ; $try++) {
        try {
            $lock = [System.IO.FileStream]::new($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None, 1, [System.IO.FileOptions]::DeleteOnClose)
            break
        }
        catch {
            $e = $_.Exception
            while ($e.InnerException) { $e = $e.InnerException }
            if ($e -is [System.UnauthorizedAccessException] -or $e -is [System.IO.DirectoryNotFoundException]) {
                return [pscustomobject]@{ Ok = $false; Added = $false; Index = $index; Error = "cannot create ${lockPath}: $($e.Message)" }
            }
            if ($try -ge 50) { return [pscustomobject]@{ Ok = $false; Added = $false; Index = $index; Error = "cannot take $lockPath within 5 s: $($e.Message)" } }
            Start-Sleep -Milliseconds 100
        }
    }
    try {
        $cur = [byte[]]@()
        if ([System.IO.File]::Exists($index)) { $cur = [System.IO.File]::ReadAllBytes($index) }
        foreach ($have in @((Get-CoordIndexedLedgers -Bytes $cur).Entries)) {
            if ([string]::Equals($have, $entry, (Get-CoordPathComparison))) {
                return [pscustomobject]@{ Ok = $true; Added = $false; Index = $index; Error = $null }
            }
        }
        $lead = if ($cur.Length -gt 0 -and $cur[$cur.Length - 1] -ne 10) { "`n" } else { '' }
        $delta = (New-Object System.Text.UTF8Encoding($false)).GetBytes($lead + $entry + "`n")
        $proposed = New-Object byte[] ($cur.Length + $delta.Length)
        [Array]::Copy($cur, 0, $proposed, 0, $cur.Length)
        [Array]::Copy($delta, 0, $proposed, $cur.Length, $delta.Length)
        $found = $false
        foreach ($have in @((Get-CoordIndexedLedgers -Bytes $proposed).Entries)) {
            if ([string]::Equals($have, $entry, (Get-CoordPathComparison))) { $found = $true }
        }
        if (-not $found) {
            $why = if ($proposed.Length -gt 65536) { "index $index passed 64 KiB" } else { "index $index is full (8 distinct ledgers)" }
            return [pscustomobject]@{ Ok = $false; Added = $false; Index = $index; Error = $why }
        }
        $fs = [System.IO.FileStream]::new($index, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        try { $fs.Write($delta, 0, $delta.Length); $fs.Flush() }
        finally { $fs.Dispose() }
        return [pscustomobject]@{ Ok = $true; Added = $true; Index = $index; Error = $null }
    }
    catch { return [pscustomobject]@{ Ok = $false; Added = $false; Index = $index; Error = "cannot update ${index}: $($_.Exception.Message)" } }
    finally { $lock.Dispose() }
}

# The trust rules for a ledger, implemented once here for the scope guard and
# coord-brief.ps1 -Check (both ported in a later slice): the ledger sits in
# <main root>/.claude/coordination (main root = Get-CoordMainRoot of its folder); git names that main root as
# its own top level; the ledger is an existing regular file, not a reparse
# point; .claude and .claude/coordination exist and are no junction or
# symlink; and `git --icase-pathspecs ls-files -s` over .claude,
# .claude/coordination, the ledger and (on Windows) the two 8.3-alias globs
# exits 0 and lists none of those three paths (any case) and (on Windows) no
# path with an 8.3-style component (`~` and a digit). Any git failure is "not
# trusted" (fails closed). Paths compare as Get-CoordPathComparison says.
# Returns { Ok; Error }.
function Test-CoordLedgerTrusted {
    param([string]$Path, [scriptblock]$Git = $null)
    try { $full = [System.IO.Path]::GetFullPath($Path) }
    catch { return [pscustomobject]@{ Ok = $false; Error = "'$Path' is not a usable path" } }
    $dir = [System.IO.Path]::GetDirectoryName($full)
    $main = Get-CoordMainRoot $dir -Git $Git
    if (-not $main) { return [pscustomobject]@{ Ok = $false; Error = 'not in a git repository with a main checkout (or git failed)' } }
    $win = Test-CoordWindows
    $sepChar = [System.IO.Path]::DirectorySeparatorChar
    $dotClaude = [System.IO.Path]::Combine($main, '.claude')
    $coordDir = [System.IO.Path]::Combine($main, '.claude' + [string]$sepChar + 'coordination')
    if (-not [string]::Equals($dir.TrimEnd($sepChar), $coordDir.TrimEnd($sepChar), (Get-CoordPathComparison))) {
        return [pscustomobject]@{ Ok = $false; Error = "not in the main checkout's coordination folder $coordDir" }
    }
    $top = Invoke-CoordGitWith $Git $main @('rev-parse', '--show-toplevel')
    $topOk = $false
    if ($null -ne $top -and $top.Code -eq 0 -and $top.Out.Count) {
        try { $topOk = [string]::Equals((ConvertTo-CoordFullPath (([string]$top.Out[0]).Trim())), $main.TrimEnd($sepChar), (Get-CoordPathComparison)) } catch { }
    }
    if (-not $topOk) { return [pscustomobject]@{ Ok = $false; Error = "git does not name $main as the top level of its checkout (or git failed)" } }
    # FileAttributes.ReparsePoint marks a junction or symlink on Windows and a
    # symlink on .NET Core elsewhere. Not verified off Windows.
    $reparse = [System.IO.FileAttributes]::ReparsePoint
    $fi = [System.IO.FileInfo]::new($full)
    if (-not $fi.Exists) { return [pscustomobject]@{ Ok = $false; Error = 'no ledger file there (missing, or a folder)' } }
    if ($fi.Attributes -band $reparse) { return [pscustomobject]@{ Ok = $false; Error = 'the ledger is a symbolic link or another reparse point' } }
    foreach ($d in @($dotClaude, $coordDir)) {
        $di = [System.IO.DirectoryInfo]::new($d)
        if (-not $di.Exists) { return [pscustomobject]@{ Ok = $false; Error = "$d is not a folder" } }
        if ($di.Attributes -band $reparse) { return [pscustomobject]@{ Ok = $false; Error = "$d is a junction or symbolic link" } }
    }
    $rel = '.claude/coordination/' + [System.IO.Path]::GetFileName($full)
    $lsArgs = @('--icase-pathspecs', 'ls-files', '-s', '--', '.claude', '.claude/coordination', $rel)
    # 8.3 short names exist on Windows only; elsewhere neither the two globs
    # nor the component check below run. Not verified off Windows.
    if ($win) { $lsArgs += @(':(glob)**/*~[0-9]*', ':(glob)**/*~[0-9]*/**') }
    $ls = Invoke-CoordGitWith $Git $main $lsArgs
    if ($null -eq $ls -or $ls.Code -ne 0) { return [pscustomobject]@{ Ok = $false; Error = "git ls-files failed in $main (exit $(if ($ls) { $ls.Code }))" } }
    foreach ($en in @($ls.Out)) {
        $enPath = ([string]$en -split "`t", 2)[-1]
        if ($enPath -ieq '.claude' -or $enPath -ieq '.claude/coordination' -or $enPath -ieq $rel) {
            return [pscustomobject]@{ Ok = $false; Error = "git tracks $enPath (a ledger shipped in a repo is not used)" }
        }
        # A path with an 8.3-style component (CLAUDE~1, COORDI~1) may open as
        # .claude\coordination on NTFS: fail closed.
        if ($win -and $enPath -match '(^|/)[^/]*~[0-9]') { return [pscustomobject]@{ Ok = $false; Error = "git tracks $enPath, an 8.3-style name that may open as .claude\coordination" } }
    }
    return [pscustomobject]@{ Ok = $true; Error = $null }
}

# Splits one markdown table row into cells: outer pipes removed, split on '|'
# not preceded by a backslash, '\|' unescaped, backticks removed, trimmed.
function Split-CoordTableRow([string]$Row) {
    $t = $Row.Trim()
    if ($t.StartsWith('|')) { $t = $t.Substring(1) }
    if ($t.EndsWith('|') -and -not $t.EndsWith('\|')) { $t = $t.Substring(0, $t.Length - 1) }
    $parts = [regex]::Split($t, '(?<!\\)\|')
    return , ([string[]]@($parts | ForEach-Object { ($_.Replace('\|', '|') -replace '`', '').Trim() }))
}

# The ledger's `## Tracks` table as objects with the properties Track, Repo,
# Session, Model, Cwd, Branch, Scope, PR, Status (missing optional columns are
# '').
# Columns are found by header name, any order. Throws (naming the ledger) on a
# missing Repo, Branch or Scope column or a row whose cell count differs from
# the header. No `## Tracks` section, or a table with no data rows: no output.
# Rows are written to the pipeline one by one: wrap the call in @(...).
function Read-CoordLedgerTracks {
    param([string]$Path)
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $lines = $text -split '\r\n|\r|\n'
    $inSection = $false
    $rows = New-Object System.Collections.Generic.List[string]
    foreach ($l in $lines) {
        if (-not $inSection) {
            if ($l -match '^##\s+Tracks\s*$') { $inSection = $true }
            continue
        }
        if ($l -match '^#{1,2}\s') { break }
        if ($l.TrimStart().StartsWith('|')) { $rows.Add($l) }
        elseif ($rows.Count -gt 0) { break }
    }
    if ($rows.Count -eq 0) { return }
    return (ConvertFrom-CoordTracksRows $rows $Path)
}

# The row parser Read-CoordLedgerTracks and Read-CoordLedgerTracksBounded
# share: $Rows are the Tracks table's lines, the header first. Throws as
# Read-CoordLedgerTracks documents; writes the rows to the pipeline.
function ConvertFrom-CoordTracksRows {
    param($Rows, [string]$Path)
    $head = Split-CoordTableRow $Rows[0]
    $idx = @{}
    for ($k = 0; $k -lt $head.Length; $k++) {
        $name = $head[$k]
        if ($name -and -not $idx.ContainsKey($name)) { $idx[$name] = $k }
    }
    foreach ($req in 'Repo', 'Branch', 'Scope') {
        if (-not $idx.ContainsKey($req)) { throw "ledger ${Path}: the Tracks table has no '$req' column" }
    }
    $result = New-Object System.Collections.Generic.List[object]
    for ($j = 1; $j -lt $rows.Count; $j++) {
        $raw = $rows[$j]
        if ($raw -match '^[\s|:-]+$' -and $raw.Contains('-')) { continue }
        $cells = Split-CoordTableRow $raw
        if ($cells.Length -ne $head.Length) {
            throw "ledger ${Path}: Tracks row $j has $($cells.Length) cells, the header has $($head.Length)"
        }
        $o = [ordered]@{}
        foreach ($col in 'Track', 'Repo', 'Session', 'Model', 'Cwd', 'Branch', 'Scope', 'PR', 'Status') {
            $o[$col] = if ($idx.ContainsKey($col)) { $cells[$idx[$col]] } else { '' }
        }
        $result.Add([pscustomobject]$o)
    }
    return $result.ToArray()
}

# One line of the bounded Tracks read: the section scan of
# Read-CoordLedgerTracks, step by step. $S: Heading, Ended, Rows.
function Add-CoordTracksLine($S, [string]$Line) {
    if (-not $S.Heading) {
        if ($Line -match '^##\s+Tracks\s*$') { $S.Heading = $true }
        return
    }
    if ($Line -match '^#{1,2}\s') { $S.Ended = $true; return }
    if ($Line.TrimStart().StartsWith('|')) { $S.Rows.Add($Line) }
    elseif ($S.Rows.Count -gt 0) { $S.Ended = $true }
}

# The ledger's Tracks table as the scope guard (ported in a later slice) is
# to read it: lines from the top,
# through a handle that lets a writer keep the file open, within the first
# 1 MiB (1048576 bytes), stopping at the line that ends the table (the first
# non-table line after its rows, as Read-CoordLedgerTracks ends it). The rest
# of the file is not read, so the read stays small as the Log grows.
# Malformed (Ok = $false, Error says why; never used in part): no `## Tracks`
# heading in what was read, no table in the section, a table not ended within
# the 1 MiB or before the end of the file (the newline that ends the file's
# last line is no line of its own), and what Read-CoordLedgerTracks throws on
# (a missing Repo, Branch or Scope column, a ragged row). A table with a
# header row and no data rows is Ok with no rows. Returns { Ok; Rows (the
# objects Read-CoordLedgerTracks returns); TimedOut; Error }.
# -TimeoutMs (default: no bound): each chunk read is waited on for the time
# left from the call's start (Read-CoordStreamBounded; the line handling between
# reads is not interrupted); when the time runs out, or TimeoutMs is 0 or less
# (then nothing is read), the result is Ok = $false, TimedOut = $true, Error
# 'read timed out after <ms> ms'.
function Read-CoordLedgerTracksBounded {
    param([string]$Path, [int]$TimeoutMs = 0)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $cap = 1048576
    $bounded = $PSBoundParameters.ContainsKey('TimeoutMs')
    $timedOut = [pscustomobject]@{ Ok = $false; Rows = @(); TimedOut = $true; Error = "read timed out after $TimeoutMs ms" }
    if ($bounded -and $TimeoutMs -le 0) { return $timedOut }
    try { $fs = Open-CoordReadStream $Path $bounded }
    catch { return [pscustomobject]@{ Ok = $false; Rows = @(); TimedOut = $false; Error = "cannot open ${Path}: $($_.Exception.Message)" } }
    $late = $false
    $st = @{ Heading = $false; Ended = $false; Rows = (New-Object System.Collections.Generic.List[string]) }
    try {
        $total = $fs.Length
        $limit = [int][Math]::Min($total, [long]$cap)
        $buf = New-Object byte[] $limit
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $have = 0
        $pos = 0
        $eof = $false
        while (-not $st.Ended) {
            if ($have -lt $limit) {
                $readArgs = @{ Stream = $fs; MaxBytes = [int][Math]::Min(65536, $limit - $have) }
                if ($bounded) { $readArgs['TimeoutMs'] = $TimeoutMs - [int]$sw.ElapsedMilliseconds }
                $rd = Read-CoordStreamBounded @readArgs
                if ($rd.TimedOut) { $late = $true; break }
                if (-not $rd.Ok) { throw $rd.Error }
                $n = $rd.Bytes.Length
                if ($n -eq 0) { $eof = $true }
                else {
                    [Array]::Copy($rd.Bytes, 0, $buf, $have, $n)
                    if ($have -eq 0 -and $n -ge 3 -and $buf[0] -eq 0xEF -and $buf[1] -eq 0xBB -and $buf[2] -eq 0xBF) { $pos = 3 }
                    $have += $n
                }
            }
            # Every complete (LF-ended) line read so far; a CR before the LF is
            # part of the line end, a CR elsewhere ends a line too.
            while (-not $st.Ended -and $pos -lt $have) {
                $lf = [Array]::IndexOf($buf, [byte]10, $pos, $have - $pos)
                if ($lf -lt 0) { break }
                $line = $utf8.GetString($buf, $pos, $lf - $pos)
                $pos = $lf + 1
                if ($line.EndsWith("`r")) { $line = $line.Substring(0, $line.Length - 1) }
                foreach ($part in $line.Split([char]13)) { Add-CoordTracksLine $st $part; if ($st.Ended) { break } }
            }
            if ($st.Ended -or $eof -or $have -ge $limit) { break }
        }
        # The whole file is in hand: its last line, when it has no LF, is a line.
        if (-not $late -and -not $st.Ended -and $total -le $cap -and $pos -lt $have) {
            foreach ($part in $utf8.GetString($buf, $pos, $have - $pos).Split([char]13)) { Add-CoordTracksLine $st $part; if ($st.Ended) { break } }
        }
    }
    catch { return [pscustomobject]@{ Ok = $false; Rows = @(); TimedOut = $false; Error = "cannot read ${Path}: $($_.Exception.Message)" } }
    finally { $fs.Dispose() }
    if ($late) { return $timedOut }
    $where = if ($total -gt $cap) { 'within the first 1 MiB of' } else { 'in' }
    if (-not $st.Heading) { return [pscustomobject]@{ Ok = $false; Rows = @(); TimedOut = $false; Error = "no '## Tracks' heading $where $Path" } }
    if (-not $st.Ended) {
        $why = if ($total -gt $cap) { "the ## Tracks table of $Path does not end within the first 1 MiB" } else { "the ## Tracks table of $Path runs to the end of the file with no line after it" }
        return [pscustomobject]@{ Ok = $false; Rows = @(); TimedOut = $false; Error = $why }
    }
    if ($st.Rows.Count -eq 0) { return [pscustomobject]@{ Ok = $false; Rows = @(); TimedOut = $false; Error = "the ## Tracks section of $Path holds no table" } }
    try { $parsed = @(ConvertFrom-CoordTracksRows $st.Rows $Path) }
    catch { return [pscustomobject]@{ Ok = $false; Rows = @(); TimedOut = $false; Error = $_.Exception.Message } }
    return [pscustomobject]@{ Ok = $true; Rows = [object[]]$parsed; TimedOut = $false; Error = $null }
}

# A Tracks row is finished (terminal) when the FIRST word of its Status cell is
# MERGED or DONE, upper case and a whole word; anything else is live. A
# substring test would read "NOT MERGED" as finished and switch off a live
# "running; round 1 DONE". The one test every coordinate script uses.
function Test-CoordRowTerminal([string]$Status) {
    return ([string]$Status -cmatch '^\s*(MERGED|DONE)(?=$|[\s.,;:()])')
}

# Which of $Repos a ledger Repo cell names. A cell with a path separator or a
# drive colon is a full path (compared after GetFullPath, trailing separators
# trimmed, as Get-CoordPathComparison says: ignoring case on Windows). A bare
# folder name (compared the same way) matches only when exactly one
# repo has that leaf; several -> Ambiguous. Returns { Match; Ambiguous }.
function Resolve-CoordLedgerRepo {
    param([string]$Cell, [string[]]$Repos)
    $cell = $Cell.Trim()
    if (-not $cell) { return [pscustomobject]@{ Match = $null; Ambiguous = $false } }
    $cmp = Get-CoordPathComparison
    if ($cell -match '[\\/:]') {
        $want = ConvertTo-CoordFullPath $cell
        foreach ($r in $Repos) {
            if ([string]::Equals((ConvertTo-CoordFullPath $r), $want, $cmp)) {
                return [pscustomobject]@{ Match = $r; Ambiguous = $false }
            }
        }
        return [pscustomobject]@{ Match = $null; Ambiguous = $false }
    }
    $hits = @($Repos | Where-Object { [string]::Equals((Split-Path -Leaf (ConvertTo-CoordFullPath $_)), $cell, $cmp) })
    if ($hits.Count -eq 1) { return [pscustomobject]@{ Match = $hits[0]; Ambiguous = $false } }
    return [pscustomobject]@{ Match = $null; Ambiguous = ($hits.Count -gt 1) }
}

# A ledger Repo cell as one rooted full path, or $null. Windows: a drive letter
# with a separator, or a UNC share. Elsewhere (not verified): a path that starts
# with one '/' (a leading '//' is a network path). Either way no list separator
# (, ;) and no annotation in parentheses. Anything else is $null and is never
# resolved against the process directory (`Fx\x`, `C:x` or `/c/x` would each
# name some folder, and the row would silently drop out of LIVE TRACKS and
# NOT yours).
function ConvertTo-CoordRootedPath([string]$Path) {
    $p = ([string]$Path).Trim()
    if (Test-CoordWindows) {
        if ($p -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+)') { return $null }
    }
    elseif ($p -notmatch '^/(?!/)') { return $null }
    if ($p -match '[,;()]') { return $null }
    # \\?\ and \\.\ (device paths) look like a UNC share to the test above but
    # name no share; and a drive root alone would lose its separator below
    # (C:\ -> C:, which is drive-relative).
    if ($p -match '^\\\\[?.][\\/]') { return $null }
    try { $full = ConvertTo-CoordFullPath $p } catch { return $null }
    if ($full -match '^[A-Za-z]:\z' -or $full -match '^\\\\[?.][\\/]') { return $null }
    return $full
}

# Whether a full path is on a local fixed disk, as { Ok; Type } (the guard binds
# a row by its Repo path, so a network or removable one cannot be bound).
# Windows: not UNC and a DriveInfo type of Fixed. Elsewhere (not verified): any
# path that does not start with '//'.
function Test-CoordLocalFixedPath([string]$FullPath) {
    if (Test-CoordWindows) {
        if ($FullPath.StartsWith('\\')) { return [pscustomobject]@{ Ok = $false; Type = 'Network' } }
        $type = 'unknown'
        try { $type = [string]([System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot($FullPath))).DriveType } catch { }
        return [pscustomobject]@{ Ok = ($type -eq 'Fixed'); Type = $type }
    }
    if ($FullPath.StartsWith('//')) { return [pscustomobject]@{ Ok = $false; Type = 'Network' } }
    return [pscustomobject]@{ Ok = $true; Type = 'Local' }
}

# Scope cell or -Scope argument -> globs. Separators: comma, semicolon,
# whitespace. Backticks removed; backslashes become '/'; a leading './' or '/'
# is dropped; a trailing '/' means everything below ('dir/' = 'dir/**').
function Split-CoordScope {
    param([string[]]$Scope)
    $globs = New-Object System.Collections.Generic.List[string]
    foreach ($s in $Scope) {
        foreach ($g in ([string]$s -replace '`', '') -split '[,;\s]+') {
            if (-not $g) { continue }
            $neg = $g.StartsWith('!')
            if ($neg) { $g = $g.Substring(1) }
            # Not verified off Windows. There a '\' may be a literal character
            # of a file name; it is folded to '/' here all the same.
            $g = $g.Replace('\', '/')
            while ($g.StartsWith('./')) { $g = $g.Substring(2) }
            $g = $g.TrimStart('/')
            if ($g.EndsWith('/')) { $g = $g + '**' }
            if (-not $g) { continue }
            $globs.Add($(if ($neg) { '!' + $g } else { $g }))
        }
    }
    return , $globs.ToArray()
}

# One glob -> an anchored regex over a '/'-separated path (no case option of
# its own: Test-CoordInScope matches it case-sensitively unless -IgnoreCase).
# `**/` = zero or more directories, `**` elsewhere = anything (including '/'),
# `*` = anything but '/', `?` = one character but '/'.
function ConvertTo-CoordGlobRegex([string]$Glob) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('^')
    $i = 0
    while ($i -lt $Glob.Length) {
        $c = $Glob[$i]
        if ($c -eq '*' -and $i + 1 -lt $Glob.Length -and $Glob[$i + 1] -eq '*') {
            if ($i + 2 -lt $Glob.Length -and $Glob[$i + 2] -eq '/') { [void]$sb.Append('(?:.*/)?'); $i += 3 }
            else { [void]$sb.Append('.*'); $i += 2 }
            continue
        }
        if ($c -eq '*') { [void]$sb.Append('[^/]*') }
        elseif ($c -eq '?') { [void]$sb.Append('[^/]') }
        else { [void]$sb.Append([regex]::Escape([string]$c)) }
        $i++
    }
    [void]$sb.Append('\z')   # not '$': that also matches before a final LF
    return $sb.ToString()
}

# True when $Path matches at least one positive glob and no '!' glob.
# Case-sensitive; with -IgnoreCase (for the scope guard, ported in a later
# slice: NTFS paths ignore case)
# positive and '!' globs alike are matched ignoring case.
function Test-CoordInScope {
    param([string]$Path, [string[]]$Globs, [switch]$IgnoreCase)
    $opt = [System.Text.RegularExpressions.RegexOptions]::None
    if ($IgnoreCase) { $opt = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant }
    # Not verified off Windows. There a '\' may be a literal character of a
    # file name; it is folded to '/' here all the same.
    $p = $Path.Replace('\', '/')
    # A path holding a control character (LF, CR, ...) is never in scope. '*' and '?' compile to [^/]* and
    # [^/], which match an LF, while '.' in '.*' and a literal name do not: a positive '*' glob could match
    # such a path that a '!' exclusion then misses, so an exclusion would fail open.
    if ($p -match '[\x00-\x1f]') { return $false }
    $in = $false
    foreach ($g in $Globs) {
        if ($g.StartsWith('!')) { continue }
        if ([regex]::IsMatch($p, (ConvertTo-CoordGlobRegex $g), $opt)) { $in = $true; break }
    }
    if (-not $in) { return $false }
    foreach ($g in $Globs) {
        if (-not $g.StartsWith('!')) { continue }
        if ([regex]::IsMatch($p, (ConvertTo-CoordGlobRegex $g.Substring(1)), $opt)) { return $false }
    }
    return $true
}

# gh's statusCheckRollup -> { Pass; Pending; Fail } (check names). CheckRun:
# status other than COMPLETED is pending; conclusion SUCCESS, NEUTRAL or
# SKIPPED passes; anything else fails. StatusContext: SUCCESS passes, PENDING
# or EXPECTED is pending, anything else fails. An item of neither shape fails,
# and so does a null item: dropping it could leave zero checks, which reads as
# "nothing to wait for".
function Get-CoordCheckSummary {
    param($Rollup)
    $pass = New-Object System.Collections.Generic.List[string]
    $pending = New-Object System.Collections.Generic.List[string]
    $fail = New-Object System.Collections.Generic.List[string]
    foreach ($c in @($Rollup)) {
        if ($null -eq $c) { $fail.Add('<null check entry>'); continue }
        $props = $c.PSObject.Properties
        $name = if ($props['name'] -and $c.name) { [string]$c.name } elseif ($props['context'] -and $c.context) { [string]$c.context } else { '<unnamed check>' }
        if ($props['status'] -and $c.status) {
            if ([string]$c.status -ne 'COMPLETED') { $pending.Add($name) }
            elseif (@('SUCCESS', 'NEUTRAL', 'SKIPPED') -contains [string]$c.conclusion) { $pass.Add($name) }
            else { $fail.Add("$name=$($c.conclusion)") }
        }
        elseif ($props['state'] -and $c.state) {
            $st = [string]$c.state
            if ($st -eq 'SUCCESS') { $pass.Add($name) }
            elseif ($st -eq 'PENDING' -or $st -eq 'EXPECTED') { $pending.Add($name) }
            else { $fail.Add("$name=$st") }
        }
        else { $fail.Add("$name=<unknown check shape>") }
    }
    return [pscustomobject]@{ Pass = $pass.ToArray(); Pending = $pending.ToArray(); Fail = $fail.ToArray() }
}

# Whether the repo $Repo (its main checkout) has CI, from the CI cell of the
# ledger's `## Baseline` row. Returns { Ci = none | yes | unknown; Why }.
# 'none' is the one answer that lets a PR with no checks be READY, so it must
# be proven: exactly one Baseline row names this repo, no Baseline row has a
# Repo cell that is doubtful (neither a clean folder name nor one rooted path,
# or a folder name two known repos share, as coord-brief reads the Baseline),
# the table has a CI column, and the cell is `none`, in any case. `yes` is the
# same cell reading `yes`; every other outcome (no ledger, no row, two rows,
# a doubtful row, an odd cell) is 'unknown', with the reason in Why, and
# callers treat 'unknown' as 'yes'. A Repo cell is a folder name or a full
# path; the known repos are $Repo and the rooted Repo cells of the Tracks
# table (a Tracks table that cannot be read is 'unknown': it is the evidence
# a shared folder name is told apart by). A header that repeats a column name,
# in any case (blank names aside), is 'unknown'. Known limit: only a path in the
# Tracks table tells two checkouts of one folder name apart, so with a Baseline
# row written as a bare folder name, a second checkout of that name that has no
# Tracks row cannot be seen. Write the Baseline Repo cell as a full path when
# two checkouts share a folder name. Never throws.
function Get-CoordBaselineCi {
    param([string]$LedgerPath, [string]$Repo)
    try {
        if (-not $LedgerPath -or -not (Test-Path -LiteralPath $LedgerPath -PathType Leaf)) { return [pscustomobject]@{ Ci = 'unknown'; Why = 'no ledger' } }
        $cmp = Get-CoordPathComparison
        $known = New-Object System.Collections.Generic.List[string]
        $known.Add((ConvertTo-CoordFullPath $Repo))
        try {
            foreach ($t in @(Read-CoordLedgerTracks $LedgerPath)) {
                $p = ConvertTo-CoordRootedPath $t.Repo
                if (-not $p) { continue }
                $dup = $false
                foreach ($k in $known) { if ([string]::Equals($k, $p, $cmp)) { $dup = $true; break } }
                if (-not $dup) { $known.Add($p) }
            }
        }
        catch { return [pscustomobject]@{ Ci = 'unknown'; Why = "the Tracks table could not be read: $($_.Exception.Message)" } }
        $lines = [System.IO.File]::ReadAllText($LedgerPath, [System.Text.Encoding]::UTF8) -split '\r\n|\r|\n'
        $inBase = $false
        $head = $null
        $mine = New-Object System.Collections.Generic.List[object]
        $doubt = $null
        foreach ($l in $lines) {
            if (-not $inBase) { if ($l -match '^##\s+Baseline\s*$') { $inBase = $true }; continue }
            if ($l -match '^#{1,2}\s') { break }
            if (-not $l.TrimStart().StartsWith('|')) { if ($head) { break } else { continue } }
            $cells = Split-CoordTableRow $l
            if (-not $head) {
                $head = $cells
                $names = @($head | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
                if (@($names | Select-Object -Unique).Count -ne $names.Count) { $doubt = 'the Baseline table repeats a column name' }
                continue
            }
            if ($l -match '^[\s|:-]+$' -and $l.Contains('-')) { continue }
            if ($cells.Length -ne $head.Length) { $doubt = 'a Baseline row does not have one cell per column'; continue }
            $o = @{}
            for ($k = 0; $k -lt $head.Length; $k++) { if (-not $o.ContainsKey($head[$k])) { $o[$head[$k]] = $cells[$k] } }
            $cell = ([string]$o['Repo']).Trim()
            if ($cell -notmatch '^[A-Za-z0-9._-]+$' -and -not (ConvertTo-CoordRootedPath $cell)) { $doubt = "a Baseline Repo cell is doubtful ('$cell')"; continue }
            $res = Resolve-CoordLedgerRepo $cell $known.ToArray()
            if ($res.Ambiguous) { $doubt = "the Baseline Repo cell '$cell' fits several repos"; continue }
            if ($res.Match -and [string]::Equals((ConvertTo-CoordFullPath $res.Match), $known[0], $cmp)) { $mine.Add($o) }
        }
        if (-not $head) { return [pscustomobject]@{ Ci = 'unknown'; Why = 'no Baseline table' } }
        if ($head -cnotcontains 'CI') { return [pscustomobject]@{ Ci = 'unknown'; Why = 'the Baseline table has no CI column' } }
        if ($doubt) { return [pscustomobject]@{ Ci = 'unknown'; Why = $doubt } }
        if ($mine.Count -ne 1) { return [pscustomobject]@{ Ci = 'unknown'; Why = "$($mine.Count) Baseline rows name this repo (one is needed)" } }
        $v = ([string]$mine[0]['CI']).Trim()
        if ($v -ieq 'none') { return [pscustomobject]@{ Ci = 'none'; Why = $null } }
        if ($v -ieq 'yes') { return [pscustomobject]@{ Ci = 'yes'; Why = $null } }
        return [pscustomobject]@{ Ci = 'unknown'; Why = "the Baseline CI cell is '$v', neither yes nor none" }
    }
    catch { return [pscustomobject]@{ Ci = 'unknown'; Why = "the Baseline could not be read: $($_.Exception.Message)" } }
}

# Files changed on $Head since its merge base with $Base. --no-renames lists a
# rename as a deletion plus an addition, so a move out of a foreign path
# cannot hide behind its new name. Local git, so gh's 100-file cap on `files`
# does not apply. Returns { Ok; Files; Error }.
# -z: names come NUL-separated and unquoted, so a path holding a quote or a
# control character is read as itself. Pass $Base as a full ref
# (refs/remotes/origin/<b>): a local branch or tag named origin/<b> would
# otherwise win the name lookup.
function Get-CoordChangedFiles {
    param([string]$Repo, [string]$Base, [string]$Head)
    $r = Invoke-CoordGit $Repo @('diff', '--name-only', '--no-renames', '-z', "$Base...$Head")
    if ($r.Code -ne 0) { return [pscustomobject]@{ Ok = $false; Files = @(); Error = "git diff $Base...$Head failed (exit $($r.Code))" } }
    $files = @(($r.Out -join "`n") -split [string][char]0 | Where-Object { $_ })
    return [pscustomobject]@{ Ok = $true; Files = [string[]]$files; Error = $null }
}

# `git merge-tree --write-tree` (git 2.38+): what merging $Head into $Base
# would conflict on. It changes no ref, index or working tree, but it does
# write tree and blob objects into .git/objects. Pass $Base as a full ref.
# Returns { State = clean | conflicts | failed; Files }.
function Get-CoordConflictPreview {
    param([string]$Repo, [string]$Base, [string]$Head)
    $r = Invoke-CoordGit $Repo @('-c', 'core.quotepath=off', 'merge-tree', '--write-tree', '--name-only', '--no-messages', $Base, $Head)
    if ($r.Code -eq 0) { return [pscustomobject]@{ State = 'clean'; Files = @() } }
    if ($r.Code -eq 1 -and $r.Out.Count -ge 1 -and (Test-CoordSha40 $r.Out[0].Trim())) {
        $files = @($r.Out | Select-Object -Skip 1 | Where-Object { $_ } | Sort-Object -Unique)
        return [pscustomobject]@{ State = 'conflicts'; Files = [string[]]$files }
    }
    return [pscustomobject]@{ State = 'failed'; Files = @() }
}

# Runs gh and parses its JSON. Returns { Ok; Data; Error }. A non-zero exit,
# empty output or unparseable JSON is Ok = $false, never empty data.
function Invoke-CoordGhJson {
    param([string[]]$GhArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = @(& gh @GhArgs 2>$null)
        $code = $LASTEXITCODE
    }
    catch { return [pscustomobject]@{ Ok = $false; Data = $null; Error = "gh could not be run: $_" } }
    finally { $ErrorActionPreference = $prev }
    if ($code -ne 0) { return [pscustomobject]@{ Ok = $false; Data = $null; Error = "gh $($GhArgs[0]) $($GhArgs[1]) failed (exit $code)" } }
    $json = ($out -join "`n").Trim()
    if (-not $json) { return [pscustomobject]@{ Ok = $false; Data = $null; Error = "gh $($GhArgs[0]) $($GhArgs[1]) printed nothing" } }
    try { $data = ConvertFrom-Json -InputObject $json -ErrorAction Stop }
    catch { return [pscustomobject]@{ Ok = $false; Data = $null; Error = "gh $($GhArgs[0]) $($GhArgs[1]) printed invalid JSON" } }
    return [pscustomobject]@{ Ok = $true; Data = $data; Error = $null }
}

# Validates a `gh pr view` object. Returns $null when valid, else a reason.
# Required: state (OPEN, CLOSED, MERGED), 40-hex headRefOid, non-empty
# headRefName and baseRefName, and (with -Checks) a statusCheckRollup array
# (it may be empty); a MERGED PR needs a 40-hex mergeCommit.oid when
# -MergeCommit is given.
# -Fork: isCrossRepository must be present and a boolean (a missing field must
# never read as "not a fork" before a branch delete).
# -Draft: isDraft must be present and a boolean (a missing field must never
# read as "not a draft" before a READY).
function Test-CoordPrView {
    param($Pr, [switch]$Checks, [switch]$MergeCommit, [switch]$Fork, [switch]$Draft)
    if ($null -eq $Pr -or $Pr -is [array]) { return 'gh output is not one PR object' }
    $p = $Pr.PSObject.Properties
    if (-not $p['state'] -or @('OPEN', 'CLOSED', 'MERGED') -notcontains [string]$Pr.state) { return 'gh output has no valid state' }
    if (-not $p['headRefOid'] -or -not (Test-CoordSha40 ([string]$Pr.headRefOid))) { return 'gh output has no 40-hex headRefOid' }
    if (-not $p['headRefName'] -or -not [string]$Pr.headRefName) { return 'gh output has no headRefName' }
    if (-not $p['baseRefName'] -or -not [string]$Pr.baseRefName) { return 'gh output has no baseRefName' }
    if ($Checks) {
        if (-not $p['statusCheckRollup']) { return 'gh output has no statusCheckRollup' }
        if (-not ($Pr.statusCheckRollup -is [array])) { return 'gh output statusCheckRollup is not a list' }
    }
    if ($Fork -and (-not $p['isCrossRepository'] -or -not ($Pr.isCrossRepository -is [bool]))) { return 'gh output has no boolean isCrossRepository' }
    if ($Draft -and (-not $p['isDraft'] -or -not ($Pr.isDraft -is [bool]))) { return 'gh output has no boolean isDraft' }
    if ($MergeCommit -and [string]$Pr.state -eq 'MERGED') {
        if (-not $p['mergeCommit'] -or $null -eq $Pr.mergeCommit -or -not (Test-CoordSha40 ([string]$Pr.mergeCommit.oid))) { return 'gh output has no 40-hex mergeCommit.oid for a MERGED PR' }
    }
    return $null
}

# ---- writing the ledger
# The lock, read, section search and swap coord-log.ps1 appends with, as
# helpers so that every script that writes the ledger does it the same way.
# None of them exits or prints: each returns { Ok; Error; ... } and the caller
# words its refusal. The caller keeps the lock in a try/finally that disposes
# it, so a run that dies in process still releases it.

# Takes <Path>.coord-log.lock: a lock file next to the ledger, opened with no
# sharing and deleted on close, so two writers never both read the old ledger
# and the later swap never drops the earlier change. A lock held elsewhere is
# retried every 100 ms, 50 tries (about 5 s); a lock that cannot be created at
# all (access refused, no folder) fails at once. Returns { Ok; Lock (the open
# FileStream; dispose it to release); LockPath; Error }.
function Enter-CoordLedgerLock {
    param([string]$Path)
    $lockPath = $Path + '.coord-log.lock'
    for ($try = 1; ; $try++) {
        try {
            # ::new, not New-Object: a failed constructor call throws whatever
            # the caller's ErrorActionPreference, so the catch below sees it.
            $lock = [System.IO.FileStream]::new($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None, 1, [System.IO.FileOptions]::DeleteOnClose)
            return [pscustomobject]@{ Ok = $true; Lock = $lock; LockPath = $lockPath; Error = $null }
        }
        catch {
            $e = $_.Exception
            while ($e.InnerException) { $e = $e.InnerException }
            if ($e -is [System.UnauthorizedAccessException] -or $e -is [System.IO.DirectoryNotFoundException]) {
                return [pscustomobject]@{ Ok = $false; Lock = $null; LockPath = $lockPath; Error = "cannot create ${lockPath}: $($e.Message)" }
            }
            if ($try -ge 50) { return [pscustomobject]@{ Ok = $false; Lock = $null; LockPath = $lockPath; Error = "cannot take $lockPath within 5 s: $($e.Message)" } }
            Start-Sleep -Milliseconds 100
        }
    }
}

# Reads the ledger once and decodes it: UTF-8, with a BOM kept as found
# (Bom), anything that is not valid UTF-8 refused; the line end is CRLF when
# the text holds any CRLF, else LF (Newline). Returns { Ok; Bytes (the file
# as read: the swap compares the ledger with them); Bom; Newline; Lines (a
# List[string], split on CRLF or LF); Error }.
function Read-CoordLedgerFile {
    param([string]$Path)
    $fail = { param($Why) [pscustomobject]@{ Ok = $false; Bytes = $null; Bom = $false; Newline = $null; Lines = $null; Error = $Why } }
    try { $bytes = [System.IO.File]::ReadAllBytes($Path) } catch { return (& $fail "cannot read ${Path}: $($_.Exception.Message)") }
    $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $strict = New-Object System.Text.UTF8Encoding($bom, $true)
    try {
        $start = if ($bom) { 3 } else { 0 }
        $content = $strict.GetString($bytes, $start, $bytes.Length - $start)
    }
    catch { return (& $fail "$Path is not valid UTF-8") }
    $nl = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [System.Collections.Generic.List[string]]::new([string[]]($content -split "`r?`n"))
    return [pscustomobject]@{ Ok = $true; Bytes = $bytes; Bom = $bom; Newline = $nl; Lines = $lines; Error = $null }
}

# The `## <Name>` section of $Lines: its header must appear exactly once
# (`##`, one or more spaces, the name; case-insensitive, trailing spaces
# ignored); the section runs to the next `#` or `##` header or the end. $Path
# only names the ledger in the error. Returns { Ok; Header (its line index);
# End (the index of the line that ends the section, or Lines.Count); Insert
# (the index after the section's last non-blank line, the header's when the
# section is blank: where an appended line goes); Error }.
function Find-CoordSectionEnd {
    param($Lines, [string]$Name, [string]$Path)
    $headers = @()
    for ($k = 0; $k -lt $Lines.Count; $k++) {
        if ($Lines[$k] -match '^##\s+(.+?)\s*$' -and [string]::Equals($Matches[1], $Name, [System.StringComparison]::OrdinalIgnoreCase)) { $headers += $k }
    }
    if ($headers.Count -ne 1) { return [pscustomobject]@{ Ok = $false; Header = -1; End = -1; Insert = -1; Error = "found $($headers.Count) '## $Name' headers in $Path, need exactly one" } }
    $h = $headers[0]
    $end = $Lines.Count
    for ($k = $h + 1; $k -lt $Lines.Count; $k++) { if ($Lines[$k] -match '^#{1,2}\s') { $end = $k; break } }
    $last = $h
    for ($k = $end - 1; $k -gt $h; $k--) { if ($Lines[$k].Trim()) { $last = $k; break } }
    return [pscustomobject]@{ Ok = $true; Header = $h; End = $end; Insert = $last + 1; Error = $null }
}

# Swaps $Text in as the ledger: written (UTF-8, with a BOM when -Bom) to
# <Path>.coord-log-<8 hex>.tmp next to it, then File.Replace, up to 10 tries
# 100 ms apart (a scanner or indexer briefly holding the ledger made one
# Replace in 300 fail). The lock keeps out other writers, not an editor:
# before EVERY try the ledger is compared with $Expected (the bytes read), and
# a change is refused rather than swapped away (the handle that fails a try is
# often an editor's write). The comparison and the swap are not one step: a
# write landing between them is still lost. A ledger gone when the swap fails
# (moved away, or ReplaceFile failed half-way without a backup) is never
# recreated: the temp file, the only copy of the ledger as read plus the
# change, is kept and named. In every other failure the temp file is removed.
# -Added names what the temp file holds besides the ledger as read, for that
# message. Returns { Ok; Status (written, changed, gone, failed); Temp (the
# kept temp file when gone, else $null); Error }. On changed, Error is a
# default; the caller words its own refusal.
function Write-CoordLedgerSwap {
    param([string]$Path, [byte[]]$Expected, [string]$Text, [bool]$Bom, [string]$Added = 'the new line')
    $out = New-Object System.Text.UTF8Encoding($Bom)
    $tmp = $Path + '.coord-log-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp'
    $base64 = [Convert]::ToBase64String($Expected)
    try {
        [System.IO.File]::WriteAllText($tmp, $Text, $out)
        for ($try = 1; ; $try++) {
            if ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Path)) -cne $base64) {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                return [pscustomobject]@{ Ok = $false; Status = 'changed'; Temp = $null; Error = "$Path changed since it was read" }
            }
            try { [System.IO.File]::Replace($tmp, $Path, [NullString]::Value); break }
            catch { if ($try -ge 10) { throw }; Start-Sleep -Milliseconds 100 }
        }
    }
    catch {
        $why = $_.Exception.Message
        if (-not (Test-Path -LiteralPath $Path) -and (Test-Path -LiteralPath $tmp)) {
            return [pscustomobject]@{ Ok = $false; Status = 'gone'; Temp = $tmp; Error = "$Path is gone (moved away, or a failed swap); the ledger as read plus $Added is in $tmp ($why)" }
        }
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{ Ok = $false; Status = 'failed'; Temp = $null; Error = "cannot write ${Path}: $why" }
    }
    return [pscustomobject]@{ Ok = $true; Status = 'written'; Temp = $null; Error = $null }
}
