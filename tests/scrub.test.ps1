# Scrub suite: nothing private ships. Scans the next commit: the files git would
# ship from the work tree plus the index (tracked files plus untracked files that
# are not ignored: git ls-files -z --cached --others --exclude-standard,
# NUL-separated so no name is lost to git's quoting). With -History <range> (or
# $env:TRACKSTEWARD_SCRUB_HISTORY, which tests\run.ps1's child processes inherit)
# it also scans the history of a range of commits (group SG6, the S7 release gate:
# origin/main..HEAD, run right after a git fetch: a stale origin/main, left behind
# by a remote rewound since, would hide the commits the remote no longer has);
# without one the SG6 history row is reported UNCHECKED. The suite fails on:
#   - an absolute user or project path: a drive letter, then \Users\ or
#     \Projects\ (either slash, also JSON-escaped as C:\\Users\\), or the
#     Git-Bash / WSL spellings /c/Users/, /c/Projects/, /mnt/c/Users/ (any
#     case)
#   - /Users/<word> or /home/<word>, except /home/me
#   - the prefix of a desktop session id followed by 8 or more hex digits
#   - a 40-hex commit sha in a .md file
#   - an internal follow-up number (FU- and digits)
#   - every whole-word, case-insensitive entry of the denylist file named by
#     $env:TRACKSTEWARD_SCRUB_DENYLIST (one entry per line, # comments and blank
#     lines ignored), matched over the whole text after NFKC normalisation with
#     zero-width characters and soft hyphens removed: the words of a
#     multi-word entry may be parted by any run of white space (a line break
#     too), comment markers (# > * / ;) and the joiners - . _ , (not by nothing:
#     CamelCase is not matched). The denylist is private and lives outside this
#     repo.
#     If the variable is unset, the file is missing, or the file holds no
#     entry, the denylist is absent. The denylist rows then FAIL when the
#     variable is set (to anything: a broken setup, not a skip) and in a
#     -History run (the release gate and the .githooks/pre-push gate never pass
#     unscanned); otherwise (a clone without the private file, a GitHub Actions
#     run, a shell without the variable) they are skipped with a loud UNCHECKED
#     "NOT CHECKED: denylist absent" line (not passed). -Strict makes that a
#     FAIL as well.
#   - a token of 7 to 40 hex digits that is a commit of any repo listed in
#     $env:TRACKSTEWARD_SCRUB_REPOS (paths separated by ';'), checked with
#     git -C <repo> cat-file -e <hex>^{commit}. The repo paths are never
#     printed. A listed path counts only when it is the top level of a git repo
#     (git -C <path> rev-parse --show-toplevel names the same full path, compared
#     as the platform compares paths); every other entry (a mistyped path, a
#     plain folder inside a repo) is reported UNCHECKED by its position in the
#     list, so -Strict fails on it. Unset (or no listed path is a repo top level):
#     the row is UNCHECKED, not an error.
# This file is scanned too, but for the denylist and the commit-sha rule only:
# the pattern rules are skipped for it, because it holds their patterns.
# Each hit prints file:line and the rule; for a pattern rule also the matched
# text cut to 80 characters, for a denylist entry only its number (the word
# itself is never printed), for a commit sha only the rule.
#
# What the scan reads: the work-tree version of each listed entry that is a leaf
# file, as bytes. A UTF-32 or UTF-16 file with a BOM is decoded and scanned (the
# UTF-32 BOMs, FF FE 00 00 and 00 00 FE FF, are tested first: FF FE 00 00 also
# starts with the UTF-16 LE BOM, so it is UTF-32 only when it decodes cleanly
# as whole 4-byte units). A file with NUL bytes and no BOM cannot be
# scanned: it is reported UNCHECKED by name (a FAIL in a -History run's history
# rows). Bytes that are not valid UTF-8 are read as Windows-1252 as well. File
# names are scanned as text, each hit named by the entry's position (by its
# blob in the history), never by the name. For a tracked file with unstaged
# changes (git diff --name-only -z) the version in the index
# (git cat-file blob :<path>) is scanned too, because that is what a commit
# would ship.
#
# Every listed entry is accounted for: work-tree versions scanned + NUL files +
# unreadable files + skipped entries == entries listed (SG4 and SG5 assert it).
# Reported UNCHECKED by name: a listed entry that is not a leaf file (a dangling
# symlink, a submodule, a path absent from the work tree such as a
# skip-worktree one), a file the file system will not let the suite read, and an
# index version git cat-file could not read.
#
# Discovery that fails (git missing, not a work tree) or lists no file is a
# FAIL, never UNCHECKED. A check that cannot run (no denylist in CI, no repos, a NUL
# file, a skipped entry, a file name the file system refuses) is UNCHECKED; with
# -Strict (or $env:TRACKSTEWARD_SCRUB_STRICT = 1) every UNCHECKED is a FAIL
# instead.
#
# SG1  each pattern rule against synthetic lines: it hits where it should and
#      stays quiet where it should (the rule itself can fail); hex tokens
# SG2  the denylist reader and matcher: comments and blanks skipped, whole word,
#      case-insensitive; an unset variable, a missing file and an empty file
#      have no denylist; an absent denylist fails when the variable is set or in
#      a history run, and is skipped (UNCHECKED) otherwise
# SG3  strict mode and the repo list (an unset variable gives an empty array)
# SG4  the scanner on synthetic repos: discovery failures, git-quoted names,
#      untracked and ignored files, UTF-16 and UTF-32, NUL files, the index
#      version and a failed index read, skipped entries (submodule, skip-worktree,
#      symlinks), an unreadable file, the accounting, the skipped self file, the
#      commit-sha rule with good, mistyped, blank and unset repo entries
# SG5  the shipped files: the scan covers them, one row per rule: no hit
# SG6  the history scan on synthetic repos (a blob added and removed, modified, a
#      type change, a merge's message and a blob only a merge brings in, bad, empty
#      and dash-leading ranges, a range of several revisions, -AllowEmpty, file
#      names, author and committer lines with and without an allowed identity,
#      annotated tags, tags on a blob, pushed ref names), then on the real range
#      when one is given. In that real run a blob it could not read (NUL bytes
#      and no BOM, or git failed) is a FAIL: the release gate and the pre-push
#      gate allow none. Allowed identities: the file named by
#      $env:TRACKSTEWARD_SCRUB_ALLOW_IDENT, one exact "Name <email>" per line; an
#      author, committer or tagger line that is one of them is let through, every
#      other one is scanned (unset: all are; set to a missing or empty file: a
#      FAIL). Commits and tags are read as stored (git cat-file, every git call
#      with --no-replace-objects): the message as a file is read, every header
#      but tree, parent and the signature. Not read: notes, grafts
#      (.git/info/grafts), a lightweight tag's name unless it is pushed
#      (-PushRefs), and file names in bytes that are not valid UTF-8
#
# This file's pattern rules are skipped by the scan, so the rule patterns and the
# examples below may appear in it. Examples are still built from pieces where that
# is easy, and no private word is written in it.
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\scrub.test.ps1 [-Strict] [-History <range>]
#       [-PushRefs "<ref> <ref>"] [-AllowEmptyRange]
# <range> is one or more revisions parted by spaces ("a..b", or "<tip> ^<sha>").
# -PushRefs names the ref names a push writes (scanned as text); -AllowEmptyRange
# lets a range with no commit pass discovery (the pre-push gate passes both).
# Exit: 0 = all passed, 1 = a case failed.
param([switch]$Strict, [string]$History = '', [string]$PushRefs = '', [switch]$AllowEmptyRange)
if (-not $History) { $History = [string]$env:TRACKSTEWARD_SCRUB_HISTORY }

$testsDir = $PSScriptRoot
$repoRoot = Split-Path -Parent $testsDir
$fixturesDir = Join-Path $testsDir 'fixtures'
try { . (Join-Path $fixturesDir 'hook-test-fixture.ps1') } catch { Write-Error "could not load hook-test-fixture.ps1: $_"; exit 1 }
Clear-HookRunnerGitEnv
. (Join-Path $fixturesDir 'coord-test-fixture.ps1')
$ErrorActionPreference = 'Stop'
$selfName = 'tests/scrub.test.ps1'

# ---- strict mode ---------------------------------------------------------------
function Get-ScrubStrictMode([bool]$SwitchOn, [string]$EnvValue) {
    return [bool]($SwitchOn -or ($EnvValue -eq '1'))
}
# What a check that could not run counts as.
function Get-ScrubUncheckedVerdict([bool]$StrictMode) {
    if ($StrictMode) { return 'FAIL' }
    return 'UNCHECKED'
}
$script:scrubStrict = Get-ScrubStrictMode ([bool]$Strict) ([string]$env:TRACKSTEWARD_SCRUB_STRICT)
function Write-ScrubUnchecked([string]$Label, [string]$Reason) {
    if ((Get-ScrubUncheckedVerdict $script:scrubStrict) -eq 'FAIL') {
        Assert-Coord "$Label (could not run; strict mode counts that as a failure)" $false $Reason
    }
    else { Write-CoordUnchecked $Label $Reason }
}

# ---- the rules ---------------------------------------------------------------
$idPrefix = 'local' + '_'
$scrubRules = @(
    [pscustomobject]@{ Name = 'absolute user or project path'; Pattern = '(?i)(?:[A-Za-z]:[\\/]{1,4}|(?<![A-Za-z0-9_.-])/(?:mnt/)?[A-Za-z]/)(?:Users|Projects)[\\/]'; MdOnly = $false },
    [pscustomobject]@{ Name = 'user home path (/Users/<word>, /home/<word>)'; Pattern = '/(Users|home)/([A-Za-z0-9._-]+)'; MdOnly = $false },
    [pscustomobject]@{ Name = 'desktop session id'; Pattern = ($idPrefix + '[0-9A-Fa-f]{8,}'); MdOnly = $false },
    [pscustomobject]@{ Name = '40-hex commit sha in a .md file'; Pattern = '(?i)(?<![0-9a-f])[0-9a-f]{40}(?![0-9a-f])'; MdOnly = $true },
    [pscustomobject]@{ Name = 'internal follow-up number'; Pattern = ('\bFU' + '-\d+'); MdOnly = $false }
)
$hexTokenPattern = '(?i)(?<![0-9A-Za-z_])[0-9a-f]{7,40}(?![0-9A-Za-z_])'
$hexRuleName = 'commit sha of a listed repo'

# The denylist entries of a file, or $null when there is none to use (path
# empty, file missing, no entry).
function Read-ScrubDenylist([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $entries = @([System.IO.File]::ReadAllLines($Path) | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    if ($entries.Count -eq 0) { return $null }
    return , ([string[]]$entries)
}
# What an absent denylist counts as. FAIL when TRACKSTEWARD_SCRUB_DENYLIST is
# set (to anything, a space included: whoever set it has a denylist, so a
# missing or empty file is a broken setup, not a skip) and in a history run
# (-History, the release gate, which must never pass unscanned). Otherwise SKIP,
# reported as a loud UNCHECKED line (a clone without the private file, a GitHub
# Actions run); -Strict turns that into a FAIL too.
function Get-ScrubDenylistAbsentVerdict([string]$DenylistVar, [bool]$HistoryRun) {
    if ($DenylistVar -or $HistoryRun) { return 'FAIL' }
    return 'SKIP'
}
function Write-ScrubDenylistAbsent([string]$Label) {
    $var = [string]$env:TRACKSTEWARD_SCRUB_DENYLIST
    if ((Get-ScrubDenylistAbsentVerdict $var ([bool]$History)) -ceq 'SKIP') {
        $where = if ([string]$env:GITHUB_ACTIONS -ceq 'true') { 'GitHub Actions run: the private denylist is not on the runner' } else { 'TRACKSTEWARD_SCRUB_DENYLIST is unset' }
        Write-ScrubUnchecked "$Label NOT CHECKED: denylist absent ($where); the private-name scrub did not run, so this run does not show that no private name ships" 'set TRACKSTEWARD_SCRUB_DENYLIST to the private denylist file to run it; a run with the variable set, and every -History run, fails without it'
    }
    elseif ($var) {
        Assert-Coord "${Label}: denylist absent (TRACKSTEWARD_SCRUB_DENYLIST is set, but the file is missing or holds no entry)" $false 'fix the path or the file'
    }
    else {
        Assert-Coord "${Label}: denylist absent (a -History run is the release gate and needs it: set TRACKSTEWARD_SCRUB_DENYLIST to the private denylist file)" $false 'TRACKSTEWARD_SCRUB_DENYLIST is unset'
    }
}
# Text as the denylist sees it: NFKC (fullwidth letters fold to ASCII, a
# letter with a combining mark to its one-code-point form), with the invisible
# characters that can sit inside a word removed (zero-width space, joiner and
# non-joiner, word joiner, BOM, soft hyphen). Line breaks are kept where they
# are. The characters are built from their code points here.
$scrubInvisible = [regex]::new('[' + [string][char]0x200B + '-' + [string][char]0x200D + [string][char]0x2060 + [string][char]0xFEFF + [string][char]0x00AD + ']')
function Get-ScrubDenyText([string]$Text) {
    return $scrubInvisible.Replace($Text.Normalize([System.Text.NormalizationForm]::FormKC), '')
}
# The matcher of one entry: whole word, case-insensitive, on the text of
# Get-ScrubDenyText. The words of a multi-word entry may be parted by any run
# of white space (a line break included), comment markers (# > * / ;) and the
# joiners - . _ , (a hard-wrapped name, in a comment or not, an email local
# part, a snake_case name, a "Surname, Given" list). Not matched: words run
# together (CamelCase).
function Get-ScrubDenyRegex([string]$Entry) {
    $words = @((Get-ScrubDenyText $Entry) -split '\s+' | Where-Object { $_ } | ForEach-Object { [regex]::Escape($_) })
    return [regex]::new('(?i)(?<![A-Za-z0-9_])' + ($words -join '[\s#>*/;,._-]+') + '(?![A-Za-z0-9_])')
}
# The allowed identities of a file (one "Name <email>" per line, # comments
# and blank lines ignored), or $null when there is none (path empty, file
# missing, no entry).
function Read-ScrubIdentAllow([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $entries = @([System.IO.File]::ReadAllLines($Path) | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    if ($entries.Count -eq 0) { return $null }
    return , ([string[]]$entries)
}

# Hits in $Lines of the file named $Path (its extension picks the .md rule).
# Returns objects { Line; Rule; Text } where Text is the matched text cut to 80
# characters, or '' for a denylist hit. -SkipPatterns leaves the pattern rules
# out (the denylist still applies). The pattern rules run line by line; the
# denylist runs over the whole text (Get-ScrubDenyText), so a multi-word entry
# wrapped across lines hits (on the line it starts on), at most once per line
# and entry.
function Find-ScrubHits {
    param([string]$Path, [string[]]$Lines, [string[]]$Denylist = $null, [switch]$SkipPatterns)
    $isMd = $Path.EndsWith('.md', [System.StringComparison]::OrdinalIgnoreCase)
    $deny = @()
    if ($Denylist) { $deny = @($Denylist | ForEach-Object { Get-ScrubDenyRegex $_ }) }
    $hits = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if (-not $line) { continue }
        if (-not $SkipPatterns) {
            foreach ($rule in $scrubRules) {
                if ($rule.MdOnly -and -not $isMd) { continue }
                foreach ($m in [regex]::Matches($line, $rule.Pattern)) {
                    if ($rule.Name -like 'user home path*' -and $m.Groups[1].Value -ceq 'home' -and $m.Groups[2].Value -ceq 'me') { continue }
                    $txt = $m.Value
                    if ($txt.Length -gt 80) { $txt = $txt.Substring(0, 80) }
                    $hits.Add([pscustomobject]@{ Line = $i + 1; Rule = $rule.Name; Text = $txt })
                }
            }
        }
    }
    if ($deny.Count -gt 0) {
        # Normalising leaves the line breaks where they are, so a match's line is
        # the count of breaks before it.
        $all = Get-ScrubDenyText ($Lines -join "`n")
        for ($d = 0; $d -lt $deny.Count; $d++) {
            $lastLine = 0
            foreach ($m in $deny[$d].Matches($all)) {
                $ln = 1 + ([regex]::Matches($all.Substring(0, $m.Index), "`n")).Count
                if ($ln -eq $lastLine) { continue }
                $lastLine = $ln
                $hits.Add([pscustomobject]@{ Line = $ln; Rule = "denylist entry $($d + 1)"; Text = '' })
            }
        }
    }
    return $hits.ToArray()
}

# The tokens of 7 to 40 hex digits in $Lines, bounded by non-word characters,
# lower-cased. Returns objects { Line; Token }.
function Get-ScrubHexTokens([string[]]$Lines) {
    $out = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if (-not $Lines[$i]) { continue }
        foreach ($m in [regex]::Matches($Lines[$i], $hexTokenPattern)) {
            $out.Add([pscustomobject]@{ Line = $i + 1; Token = $m.Value.ToLowerInvariant() })
        }
    }
    return $out.ToArray()
}

# The paths of $Raw, split on ';', trimmed, empty ones dropped. Always an array
# object, also when empty: `return @()` would hand an empty list to the caller as
# $null in Windows PowerShell 5.1, and a $null path then reaches Test-Path.
function Get-ScrubRepoList([string]$Raw) {
    if (-not $Raw) { return , @() }
    return , @($Raw -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# How the platform compares paths: ignoring case on Windows, exactly elsewhere.
function Get-ScrubPathComparison {
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { return [System.StringComparison]::OrdinalIgnoreCase }
    return [System.StringComparison]::Ordinal
}
# Whether two spellings name the same full path (separators and a trailing
# separator do not count).
function Test-ScrubSamePath([string]$A, [string]$B) {
    try {
        $seps = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        $fa = [System.IO.Path]::GetFullPath($A).TrimEnd($seps)
        $fb = [System.IO.Path]::GetFullPath($B).TrimEnd($seps)
    }
    catch { return $false }
    return [string]::Equals($fa, $fb, (Get-ScrubPathComparison))
}
# Whether $Path is the top level of a git repo: a folder for which
# git rev-parse --show-toplevel names that same folder. A blank path, a missing
# folder, a folder that is no repo and a plain folder inside a repo are not.
function Test-ScrubUsableRepo([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    # Invoke-ScrubGit starts git as a process: under the suite's
    # ErrorActionPreference Stop, a native git's stderr would end the suite.
    $g = Invoke-ScrubGit $Path @('rev-parse', '--show-toplevel')
    if (-not $g.Ok -or $g.Code -ne 0) { return $false }
    $top = $coordUtf8.GetString($g.Bytes).Trim()
    if (-not $top) { return $false }
    return (Test-ScrubSamePath $top $Path)
}

# ---- git, as bytes -------------------------------------------------------------
# Stops a process this suite started, by its process id. Windows: taskkill /T /F
# /PID. Elsewhere (not verified off Windows): Kill($true) on PowerShell 7, else
# Kill() for the process alone.
function Stop-ScrubProcess([System.Diagnostics.Process]$P) {
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { & taskkill.exe /T /F /PID $P.Id 2>$null | Out-Null }
    else {
        try { $P.Kill($true) }
        catch { try { $P.Kill() } catch { } }
    }
}

# Runs `git -C $Repo <args>` and returns { Ok; Code; Bytes; Error }: Bytes is the
# raw stdout (no console decoding, NUL bytes kept). Ok is $false when git is
# missing, did not start or did not exit in time; a non-zero Code is still Ok.
function Invoke-ScrubGit {
    param([string]$Repo, [string[]]$GitArgs, [int]$Seconds = 120)
    $gitCmd = @(Get-Command git -CommandType Application -ErrorAction SilentlyContinue)
    if ($gitCmd.Count -eq 0) { return [pscustomobject]@{ Ok = $false; Code = $null; Bytes = [byte[]]@(); Error = 'git was not found on PATH' } }
    # --no-replace-objects: a replace ref (git replace) must not make the scan
    # read other objects than the ones a push sends.
    $argv = @('-C', $Repo, '--no-replace-objects') + $GitArgs
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = [string]$gitCmd[0].Source
    # The quoting rules of ConvertTo-CoordArgLine: backslashes before a quote and
    # at the end are doubled, or "C:\x\" would escape its own closing quote.
    $psi.Arguments = (($argv | ForEach-Object { '"' + ((([string]$_) -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    try { $p = [System.Diagnostics.Process]::Start($psi) }
    catch { return [pscustomobject]@{ Ok = $false; Code = $null; Bytes = [byte[]]@(); Error = "git did not start: $_" } }
    $p.StandardInput.Close()
    $ms = New-Object System.IO.MemoryStream
    $copy = $p.StandardOutput.BaseStream.CopyToAsync($ms)
    $errRead = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($Seconds * 1000)) {
        Stop-ScrubProcess $p
        return [pscustomobject]@{ Ok = $false; Code = $null; Bytes = [byte[]]@(); Error = "git did not exit within $Seconds s" }
    }
    $p.WaitForExit()
    # A copy still running (a child of git holding stdout open) would hand back
    # a short listing that reads as complete: not Ok instead.
    if (-not $copy.Wait(10000)) {
        return [pscustomobject]@{ Ok = $false; Code = $p.ExitCode; Bytes = [byte[]]@(); Error = 'git output was not complete within 10 s of its exit' }
    }
    $errText = if ($errRead.Wait(10000)) { ([string]$errRead.Result).Trim() } else { '' }
    return [pscustomobject]@{ Ok = $true; Code = $p.ExitCode; Bytes = $ms.ToArray(); Error = $errText }
}

# The NUL-separated names of a git -z listing.
function Get-ScrubNames([byte[]]$Bytes) {
    $text = $coordUtf8.GetString($Bytes)
    return @($text.Split([char]0) | Where-Object { $_ })
}

# The files git would ship from $Repo: { Ok; Files; Reason }. Not Ok when git
# fails or lists no file.
function Get-ScrubShippedFiles([string]$Repo) {
    $r = Invoke-ScrubGit $Repo @('ls-files', '-z', '--cached', '--others', '--exclude-standard')
    if (-not $r.Ok -or $r.Code -ne 0) {
        return [pscustomobject]@{ Ok = $false; Files = @(); Reason = "git ls-files failed (exit $($r.Code)): $($r.Error)" }
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $files = New-Object System.Collections.Generic.List[string]
    foreach ($n in (Get-ScrubNames $r.Bytes)) { if ($seen.Add($n)) { $files.Add($n) } }
    if ($files.Count -eq 0) { return [pscustomobject]@{ Ok = $false; Files = @(); Reason = 'git ls-files listed no files' } }
    $files.Sort([System.StringComparer]::Ordinal)
    return [pscustomobject]@{ Ok = $true; Files = $files.ToArray(); Reason = '' }
}

# The tracked files whose work-tree version differs from the index.
function Get-ScrubUnstagedNames([string]$Repo) {
    $r = Invoke-ScrubGit $Repo @('diff', '--name-only', '-z')
    if (-not $r.Ok -or $r.Code -ne 0) {
        return [pscustomobject]@{ Ok = $false; Names = @(); Reason = "git diff --name-only failed (exit $($r.Code)): $($r.Error)" }
    }
    return [pscustomobject]@{ Ok = $true; Names = @(Get-ScrubNames $r.Bytes); Reason = '' }
}

# ---- the scanner ---------------------------------------------------------------
# Decodes and scans $Bytes. Returns 'nul' when the bytes cannot be scanned (NUL
# bytes and no BOM), else 'scanned'.
function Add-ScrubContent {
    param($Res, [string]$Rel, [string]$Label, [byte[]]$Bytes, [bool]$SkipPatterns, [string[]]$Denylist)
    $text = $null
    $alt = $null
    # The UTF-32 BOMs come before the UTF-16 ones: FF FE 00 00 starts with the
    # UTF-16 LE BOM. FF FE 00 00 counts as UTF-32 LE only when the rest is whole
    # 4-byte units that decode without a replacement character; otherwise it is
    # a UTF-16 LE file whose first character is U+0000.
    $u32le = $null
    if ($Bytes.Length -ge 4 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE -and $Bytes[2] -eq 0 -and $Bytes[3] -eq 0 -and (($Bytes.Length - 4) % 4) -eq 0) {
        $u32le = (New-Object System.Text.UTF32Encoding($false, $false)).GetString($Bytes, 4, $Bytes.Length - 4)
        if ($u32le.IndexOf([char]0xFFFD) -ge 0) { $u32le = $null }
    }
    if ($null -ne $u32le) {
        $text = $u32le
        $Res.Utf32.Add($Label)
    }
    elseif ($Bytes.Length -ge 4 -and $Bytes[0] -eq 0 -and $Bytes[1] -eq 0 -and $Bytes[2] -eq 0xFE -and $Bytes[3] -eq 0xFF) {
        $text = (New-Object System.Text.UTF32Encoding($true, $false)).GetString($Bytes, 4, $Bytes.Length - 4)
        $Res.Utf32.Add($Label)
    }
    elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        $text = [System.Text.Encoding]::Unicode.GetString($Bytes, 2, $Bytes.Length - 2)
        $Res.Utf16.Add($Label)
    }
    elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
        $text = [System.Text.Encoding]::BigEndianUnicode.GetString($Bytes, 2, $Bytes.Length - 2)
        $Res.Utf16.Add($Label)
    }
    elseif ([Array]::IndexOf($Bytes, [byte]0) -ge 0) {
        $Res.NulFiles.Add($Label)
        return 'nul'
    }
    else {
        $text = $coordUtf8.GetString($Bytes).TrimStart([char]0xFEFF)
        # Bytes that are not valid UTF-8 (an ANSI file: a Windows-1252 accented
        # letter decodes to U+FFFD) are read as Windows-1252 as well.
        try { [void](New-Object System.Text.UTF8Encoding($false, $true)).GetString($Bytes) }
        catch {
            $alt = [System.Text.Encoding]::GetEncoding(1252).GetString($Bytes)
            $Res.NonUtf8.Add($Label)
        }
    }
    $lines = $text -split "`r?`n"
    $Res.Scanned.Add($Label)
    if ($SkipPatterns) { $Res.PatternSkipped.Add($Label) }
    $found = @(Find-ScrubHits -Path $Rel -Lines $lines -Denylist $Denylist -SkipPatterns:$SkipPatterns)
    if ($null -ne $alt) { $found += @(Find-ScrubHits -Path $Rel -Lines ($alt -split "`r?`n") -Denylist $Denylist -SkipPatterns:$SkipPatterns) }
    $seenHit = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($h in $found) {
        if (-not $seenHit.Add("$($h.Line)`t$($h.Rule)`t$($h.Text)")) { continue }
        $Res.Hits.Add([pscustomobject]@{ File = $Label; Line = $h.Line; Rule = $h.Rule; Text = $h.Text })
    }
    foreach ($t in @(Get-ScrubHexTokens $lines)) {
        if (-not $Res.HexTokens.ContainsKey($t.Token)) { $Res.HexTokens[$t.Token] = New-Object System.Collections.Generic.List[object] }
        $Res.HexTokens[$t.Token].Add([pscustomobject]@{ File = $Label; Line = $t.Line })
    }
    return 'scanned'
}

# Hits in a short text that is not a file version (a file name, a ref name, an
# identity), added under $Label. Not counted as a scanned version, and no hex
# tokens taken from it.
function Add-ScrubTextHits {
    param($Res, [string]$Label, [string]$Text, [string[]]$Denylist)
    foreach ($h in @(Find-ScrubHits -Path '' -Lines @($Text -split "`r?`n") -Denylist $Denylist)) {
        $Res.Hits.Add([pscustomobject]@{ File = $Label; Line = $h.Line; Rule = $h.Rule; Text = $h.Text })
    }
}
# An author, committer or tagger header value ("Name <email> <time> <zone>"):
# its identity, everything before the trailing time and zone ("Name <email>",
# or the whole value when it does not end in a time and zone), is let through
# when it is exactly one of $AllowIdent (ordinal), and is scanned as text
# otherwise. -NoCount: a second reading of the same line, not counted again.
function Add-ScrubIdent {
    param($Res, [string]$Label, [string]$Value, [string[]]$Denylist, [string[]]$AllowIdent, [switch]$NoCount)
    $ident = $Value.TrimEnd()
    $m = [regex]::Match($ident, '^(.*) \d+ [+-]\d{4}$')
    if ($m.Success) { $ident = $m.Groups[1].Value }
    if (-not $NoCount) { $Res.Idents++ }
    if ($AllowIdent -and ($AllowIdent -ccontains $ident)) { if (-not $NoCount) { $Res.IdentAllowed++ }; return }
    Add-ScrubTextHits $Res $Label $ident $Denylist
}
# The readings of raw object bytes: UTF-8, and Windows-1252 as well when the
# bytes are not valid UTF-8 (as Add-ScrubContent reads a file).
function Get-ScrubReadings([byte[]]$Bytes) {
    $utf8 = $coordUtf8.GetString($Bytes)
    try { [void](New-Object System.Text.UTF8Encoding($false, $true)).GetString($Bytes); return , @($utf8) }
    catch { return , @($utf8, [System.Text.Encoding]::GetEncoding(1252).GetString($Bytes)) }
}
# Splits raw commit or tag bytes at the first empty line: { Head (bytes);
# Body (bytes, empty when there is none) }.
function Split-ScrubObject([byte[]]$Bytes) {
    for ($i = 0; $i -lt $Bytes.Length - 1; $i++) {
        if ($Bytes[$i] -eq 10 -and $Bytes[$i + 1] -eq 10) {
            $body = [byte[]]@()
            if ($i + 2 -lt $Bytes.Length) { $body = [byte[]]$Bytes[($i + 2)..($Bytes.Length - 1)] }
            return [pscustomobject]@{ Head = [byte[]]$Bytes[0..$i]; Body = $body }
        }
    }
    return [pscustomobject]@{ Head = $Bytes; Body = [byte[]]@() }
}
# The header lines of a commit or tag object as { Key; Value } (a continuation
# line, which starts with a space, is added to the header before it).
function Get-ScrubHeaders([string]$Head) {
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($ln in ($Head -split "`n")) {
        if (-not $ln) { continue }
        if ($ln.StartsWith(' ') -and $out.Count -gt 0) { $out[$out.Count - 1].Value += "`n" + $ln.Substring(1); continue }
        $sp = $ln.IndexOf(' ')
        if ($sp -lt 0) { $out.Add([pscustomobject]@{ Key = $ln; Value = '' }) }
        else { $out.Add([pscustomobject]@{ Key = $ln.Substring(0, $sp); Value = $ln.Substring($sp + 1) }) }
    }
    return , $out.ToArray()
}

# The listed entries the scan accounted for: work-tree versions scanned, NUL
# files, unreadable files and skipped entries. Equals $Res.Listed when no entry
# was lost.
function Get-ScrubAccounted($Res) {
    return [int]($Res.WorkTreeScanned + $Res.WorkTreeNul + $Res.Unreadable.Count + $Res.Skipped.Count)
}

# Scans the files git would ship from $Repo. $SelfRel names the one file whose
# pattern rules are skipped. Returns { DiscoveryOk; Reason; Listed (entries
# listed); WorkTreeScanned, WorkTreeNul (counts of the work-tree versions);
# Scanned (labels, index versions included); PatternSkipped; IndexScanned;
# Utf16; Utf32; NulFiles; Unreadable (names the file system would not let the
# suite read); Skipped (names of listed entries that are not a leaf file);
# IndexFailed (names whose index version git cat-file could not read);
# RepoUnchecked (positions, see Add-ScrubRepoShaHits); Hits (File; Line; Rule;
# Text); HexTokens }.
function Invoke-ScrubScan {
    param([string]$Repo, [string]$SelfRel = '', [string[]]$Denylist = $null)
    $res = [pscustomobject]@{
        DiscoveryOk = $false; Reason = ''
        Listed = 0; WorkTreeScanned = 0; WorkTreeNul = 0
        Scanned = (New-Object System.Collections.Generic.List[string])
        PatternSkipped = (New-Object System.Collections.Generic.List[string])
        IndexScanned = (New-Object System.Collections.Generic.List[string])
        Utf16 = (New-Object System.Collections.Generic.List[string])
        Utf32 = (New-Object System.Collections.Generic.List[string])
        NonUtf8 = (New-Object System.Collections.Generic.List[string])
        NulFiles = (New-Object System.Collections.Generic.List[string])
        Unreadable = (New-Object System.Collections.Generic.List[string])
        Skipped = (New-Object System.Collections.Generic.List[string])
        IndexFailed = (New-Object System.Collections.Generic.List[string])
        RepoUnchecked = (New-Object System.Collections.Generic.List[int])
        Hits = (New-Object System.Collections.Generic.List[object])
        HexTokens = @{}
    }
    $d = Get-ScrubShippedFiles $Repo
    if (-not $d.Ok) { $res.Reason = $d.Reason; return $res }
    $u = Get-ScrubUnstagedNames $Repo
    if (-not $u.Ok) { $res.Reason = $u.Reason; return $res }
    $res.DiscoveryOk = $true
    $res.Listed = $d.Files.Count
    $unstaged = [System.Collections.Generic.HashSet[string]]::new([string[]]$u.Names, [System.StringComparer]::Ordinal)
    $pos = 0
    foreach ($rel in $d.Files) {
        # The name itself, named by its position: a name that holds a denylist
        # entry is never printed.
        $pos++
        Add-ScrubTextHits $res "file name of listed entry $pos" $rel $Denylist
        $skip = [bool]($SelfRel -and ($rel -ceq $SelfRel))
        $full = Join-Path $Repo $rel
        $isLeaf = $false
        try { $isLeaf = [bool](Test-Path -LiteralPath $full -PathType Leaf) } catch { $isLeaf = $false }
        if (-not $isLeaf) { $res.Skipped.Add($rel) }
        else {
            $bytes = $null
            try { $bytes = [System.IO.File]::ReadAllBytes($full) } catch { $bytes = $null }
            if ($null -eq $bytes) { $res.Unreadable.Add($rel) }
            else {
                $kind = @(Add-ScrubContent $res $rel $rel $bytes $skip $Denylist)[-1]
                if ($kind -ceq 'nul') { $res.WorkTreeNul = $res.WorkTreeNul + 1 }
                else { $res.WorkTreeScanned = $res.WorkTreeScanned + 1 }
            }
        }
        if ($unstaged.Contains($rel)) {
            # cat-file blob, not show: the stored bytes, nothing else.
            $g = Invoke-ScrubGit $Repo @('cat-file', 'blob', (':' + $rel))
            if ($g.Ok -and $g.Code -eq 0) {
                $res.IndexScanned.Add($rel)
                [void](Add-ScrubContent $res $rel "$rel (index)" $g.Bytes $skip $Denylist)
            }
            else { $res.IndexFailed.Add($rel) }
        }
    }
    return $res
}

# Adds a hit for every token of $Res.HexTokens that is a commit of one of the
# listed repos that is usable (the top level of a git repo, see
# Test-ScrubUsableRepo). Returns how many of the paths are usable; 0 means the
# rule could not run. Sets $Res.RepoUnchecked to the 1-based positions of the
# entries that are not usable (a mistyped path, a blank or $null entry): the
# caller reports those UNCHECKED by position, never by path. $RepoPaths $null or
# empty is 0 usable, with no error.
function Add-ScrubRepoShaHits {
    param($Res, [string[]]$RepoPaths)
    $Res.RepoUnchecked.Clear()
    $paths = @()
    if ($null -ne $RepoPaths) { $paths = $RepoPaths }
    $usable = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $paths.Count; $i++) {
        if (Test-ScrubUsableRepo $paths[$i]) { $usable.Add([string]$paths[$i]) }
        else { $Res.RepoUnchecked.Add($i + 1) }
    }
    if ($usable.Count -eq 0) { return 0 }
    foreach ($tok in @($Res.HexTokens.Keys | Sort-Object)) {
        $found = $false
        foreach ($r in $usable) {
            # Through Invoke-ScrubGit, whose quoting doubles a trailing
            # backslash: a native `& git -C "<path with a space>\"` in Windows
            # PowerShell 5.1 hands git a broken -C, which read as "no commit".
            # A git that cannot run at all ends the suite (no silent miss).
            $g = Invoke-ScrubGit $r @('cat-file', '-e', ($tok + '^{commit}')) 30
            if (-not $g.Ok) { throw "git cat-file could not run in a listed repo: $($g.Error)" }
            if ($g.Code -eq 0) { $found = $true; break }
        }
        if (-not $found) { continue }
        foreach ($loc in $Res.HexTokens[$tok]) {
            $Res.Hits.Add([pscustomobject]@{ File = $loc.File; Line = $loc.Line; Rule = $hexRuleName; Text = '' })
        }
    }
    return $usable.Count
}

# The commit-sha rule for the repo variable value $Raw (as SG5 runs it): the
# entries are listed, the rule is run, and the result says what happened.
# Returns { Listed (entries); Usable; Unchecked (positions of the entries that
# are not a repo top level); Verdict ('RAN', or 'UNCHECKED' when no entry is
# usable: unset, blank, or every entry mistyped) }.
function Invoke-ScrubRepoRule {
    param($Res, [string]$Raw)
    $list = Get-ScrubRepoList $Raw
    $n = Add-ScrubRepoShaHits $Res $list
    $verdict = 'UNCHECKED'
    if ($n -gt 0) { $verdict = 'RAN' }
    $listed = 0
    if ($null -ne $list) { $listed = @($list).Count }
    return [pscustomobject]@{ Listed = $listed; Usable = [int]$n; Unchecked = @($Res.RepoUnchecked); Verdict = $verdict }
}

# Scans the history of a range of commits ($Range: one or more git revisions
# parted by spaces, such as origin/main..HEAD or "<tip> ^<sha>"): every blob that
# a commit of the range adds or changes, at its path, every such path as a name
# (once per path), every commit as stored (git cat-file commit): its message,
# its author and committer lines (an exact $AllowIdent identity is let through,
# see Add-ScrubIdent) and every other header but tree, parent and the
# signature; every annotated tag a positive revision names (its headers, tagger
# and message, along a tag chain), and the $RefNames given. A blob seen under the same path twice is
# scanned once. A merge commit is read too: its message, and the blobs it differs
# by from each parent (a merge with a parent outside the range also reads what
# that parent brings in: it errs on the side of reading more). Not read: a gitlink
# (a submodule's commit; reported unreadable), notes, grafts (replace refs are
# ignored: Invoke-ScrubGit passes --no-replace-objects), and, in a
# shallow clone, anything before its boundary (the range is not checked for
# that). $SelfRel names the one path whose pattern rules are skipped, as in
# Invoke-ScrubScan. Returns { DiscoveryOk; Reason; Commits; Tags; Idents;
# IdentAllowed; the same lists as Invoke-ScrubScan (Scanned, PatternSkipped,
# Utf16, Utf32, NonUtf8, NulFiles, Unreadable, RepoUnchecked, Hits, HexTokens);
# Blobs }. Not DiscoveryOk when git cannot resolve the range, a positive
# revision does not end on a commit (a tag on a blob), or the range holds no
# commit (unless -AllowEmpty).
function Invoke-ScrubHistory {
    param([string]$Repo, [string]$Range, [string]$SelfRel = '', [string[]]$Denylist = $null,
        [string[]]$AllowIdent = $null, [string[]]$RefNames = @(), [switch]$AllowEmpty)
    $res = [pscustomobject]@{
        DiscoveryOk = $false; Reason = ''; Commits = 0; Blobs = 0; Tags = 0; Idents = 0; IdentAllowed = 0
        Scanned = (New-Object System.Collections.Generic.List[string])
        PatternSkipped = (New-Object System.Collections.Generic.List[string])
        Utf16 = (New-Object System.Collections.Generic.List[string])
        Utf32 = (New-Object System.Collections.Generic.List[string])
        NonUtf8 = (New-Object System.Collections.Generic.List[string])
        NulFiles = (New-Object System.Collections.Generic.List[string])
        Unreadable = (New-Object System.Collections.Generic.List[string])
        RepoUnchecked = (New-Object System.Collections.Generic.List[int])
        Hits = (New-Object System.Collections.Generic.List[object])
        HexTokens = @{}
    }
    # The range is one or more revisions parted by spaces (no ref name holds a
    # space): "a..b", or "<tip> <tip> ^<sha> ^<sha>" as the pre-push gate passes it.
    $revs = @($Range -split '\s+' | Where-Object { $_ })
    if ($revs.Count -eq 0) { $res.Reason = 'no range was given'; return $res }
    # --end-of-options: a revision that starts with '-' is never read as an option.
    $c = Invoke-ScrubGit $Repo (@('rev-list', '--end-of-options') + $revs)
    if (-not $c.Ok -or $c.Code -ne 0) { $res.Reason = "git rev-list failed for the range '$Range' (exit $($c.Code)): $($c.Error)"; return $res }
    $shas = @($coordUtf8.GetString($c.Bytes) -split "`r?`n" | Where-Object { $_ })
    # Each positive revision: an annotated tag (a chain of them) is read, its
    # name, message and tagger; what it ends on must be a commit.
    $seenTag = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($rv in $revs) {
        if ($rv.StartsWith('^') -or $rv.Contains('..')) { continue }
        $o = Invoke-ScrubGit $Repo @('rev-parse', '--verify', '-q', '--end-of-options', $rv)
        if (-not $o.Ok -or $o.Code -ne 0) { $res.Reason = "git rev-parse could not resolve '$rv' (exit $($o.Code)): $($o.Error)"; return $res }
        $cur = $coordUtf8.GetString($o.Bytes).Trim()
        $type = ''
        for ($depth = 0; $depth -lt 20; $depth++) {
            $t = Invoke-ScrubGit $Repo @('cat-file', '-t', $cur)
            if (-not $t.Ok -or $t.Code -ne 0) { $res.Reason = "git cat-file could not read the object '$cur' of '$rv' (exit $($t.Code)): $($t.Error)"; return $res }
            $type = $coordUtf8.GetString($t.Bytes).Trim()
            if ($type -cne 'tag') { break }
            $g = Invoke-ScrubGit $Repo @('cat-file', 'tag', $cur)
            if (-not $g.Ok -or $g.Code -ne 0) { $res.Reason = "git cat-file could not read the tag '$cur' (exit $($g.Code)): $($g.Error)"; return $res }
            $parts = Split-ScrubObject $g.Bytes
            $next = ''
            if ($seenTag.Add($cur)) {
                $res.Tags++
                $short = $cur.Substring(0, 7)
                $readings = Get-ScrubReadings $parts.Head
                for ($rd = 0; $rd -lt $readings.Count; $rd++) {
                    foreach ($h in (Get-ScrubHeaders $readings[$rd])) {
                        if ($h.Key -ceq 'object') { if ($rd -eq 0) { $next = $h.Value.Trim() } }
                        elseif ($h.Key -ceq 'type') { }
                        elseif ($h.Key -ceq 'tagger') { Add-ScrubIdent $res ('tagger of tag ' + $short) $h.Value $Denylist $AllowIdent -NoCount:($rd -gt 0) }
                        # The name and any other header (not the signature).
                        elseif ($h.Key -cne 'gpgsig' -and $h.Key -cne 'gpgsig-sha256') { Add-ScrubTextHits $res ('tag ' + $short + ' header ' + $h.Key) $h.Value $Denylist }
                    }
                }
                # The message, as stored (Add-ScrubContent reads it as UTF-8 and,
                # when it is not valid UTF-8, as Windows-1252 too).
                $label = 'tag ' + $short
                [void](Add-ScrubContent $res $label $label $parts.Body $false $Denylist)
            }
            else {
                foreach ($h in (Get-ScrubHeaders $coordUtf8.GetString($parts.Head))) { if ($h.Key -ceq 'object') { $next = $h.Value.Trim() } }
            }
            if (-not $next) { $res.Reason = "the tag '$cur' of '$rv' names no object"; return $res }
            $cur = $next
        }
        if ($type -cne 'commit') { $res.Reason = "the revision '$rv' names a $type, not a commit"; return $res }
    }
    if ($shas.Count -eq 0 -and -not $AllowEmpty) { $res.Reason = "the range '$Range' holds no commit"; return $res }
    $res.DiscoveryOk = $true
    $res.Commits = $shas.Count
    # The ref names a push writes, named by their position.
    for ($k = 0; $k -lt $RefNames.Count; $k++) { Add-ScrubTextHits $res "pushed ref name $($k + 1)" $RefNames[$k] $Denylist }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $seenName = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($sha in $shas) {
        $short = $sha.Substring(0, 7)
        # The commit object as stored (git cat-file commit, not git show: show
        # stops a message at a NUL byte and re-encodes it by its encoding
        # header). The message is read as a file is; every header but tree,
        # parent and the signature is read too: author and committer as
        # identities, any other (encoding, mergetag, an unknown one) as text.
        $co = Invoke-ScrubGit $Repo @('cat-file', 'commit', $sha)
        if ($co.Ok -and $co.Code -eq 0) {
            $parts = Split-ScrubObject $co.Bytes
            $label = 'commit message ' + $short
            [void](Add-ScrubContent $res $label $label $parts.Body $false $Denylist)
            $readings = Get-ScrubReadings $parts.Head
            for ($rd = 0; $rd -lt $readings.Count; $rd++) {
                foreach ($h in (Get-ScrubHeaders $readings[$rd])) {
                    if ($h.Key -ceq 'author') { Add-ScrubIdent $res ('author of commit ' + $short) $h.Value $Denylist $AllowIdent -NoCount:($rd -gt 0) }
                    elseif ($h.Key -ceq 'committer') { Add-ScrubIdent $res ('committer of commit ' + $short) $h.Value $Denylist $AllowIdent -NoCount:($rd -gt 0) }
                    elseif ($h.Key -cin @('tree', 'parent', 'gpgsig', 'gpgsig-sha256')) { }
                    else { Add-ScrubTextHits $res ('commit headers of ' + $short) ($h.Key + ' ' + $h.Value) $Denylist }
                }
            }
        }
        else { $res.Unreadable.Add('commit ' + $short) }
        # The blobs this commit adds or modifies (a type change included; a rename or copy counts as an add), against each parent
        # (-m: a merge is compared with every parent, so what only the merge itself brings in is seen; the empty tree for a root commit).
        $t = Invoke-ScrubGit $Repo @('diff-tree', '-r', '-z', '-m', '--root', '--no-renames', '--diff-filter=AMT', '--no-abbrev', $sha)
        if (-not $t.Ok -or $t.Code -ne 0) { $res.Unreadable.Add('tree of ' + $sha.Substring(0, 7)); continue }
        # -z raw output: ":<mode> <mode> <old> <new> <status>" NUL "<path>" NUL ... (each commit's output starts with its own sha, skipped here).
        $parts = @($coordUtf8.GetString($t.Bytes).Split([char]0) | Where-Object { $_ })
        $i = 0
        while ($i -lt $parts.Count) {
            if (-not $parts[$i].StartsWith(':')) { $i++; continue }
            $f = $parts[$i].Substring(1).Split(' ')
            $newSha = $f[3]
            $path = $parts[$i + 1]
            $i += 2
            if ($newSha -match '^0+$') { continue }
            # The path itself, once per path, named by its blob: a name that
            # holds a denylist entry is never printed.
            if ($seenName.Add($path)) { Add-ScrubTextHits $res ('file name of blob ' + $newSha.Substring(0, 7)) $path $Denylist }
            if (-not $seen.Add($path + [char]0 + $newSha)) { continue }
            $res.Blobs++
            $g = Invoke-ScrubGit $Repo @('cat-file', 'blob', $newSha)
            if (-not $g.Ok -or $g.Code -ne 0) { $res.Unreadable.Add($path + ' (blob ' + $newSha.Substring(0, 7) + ')'); continue }
            $skip = [bool]($SelfRel -and ($path -ceq $SelfRel))
            [void](Add-ScrubContent $res $path ($path + ' (blob ' + $newSha.Substring(0, 7) + ')') $g.Bytes $skip $Denylist)
        }
    }
    return $res
}

function Format-ScrubHit($H) {
    $s = "$($H.File):$($H.Line): $($H.Rule)"
    if ($H.Text) { $s += ": $($H.Text)" }
    return $s
}

# ---- SG1: each rule against synthetic lines -----------------------------------
Write-Host "(SG1) the pattern rules"
$un = 'Us' + 'ers'
$pj = 'Proj' + 'ects'
$sha40 = ('0123456789abcdef' * 3).Substring(0, 40)
$pathRule = 'absolute user or project path'
$homeRule = 'user home path (/Users/<word>, /home/<word>)'
$rows = @(
    @($pathRule, 'a.md', ('see C:\' + $un + '\x\f.txt'), $true),
    @($pathRule, 'a.md', ('see C:\' + $pj + '\app'), $true),
    @($pathRule, 'a.md', ('see c:/' + $un.ToLowerInvariant() + '/x'), $true),
    @($pathRule, 'a.md', ('json "C:\\' + $un + '\\x\\f.txt"'), $true),
    @($pathRule, 'a.md', ('json "C:\\' + $pj + '\\app"'), $true),
    @($pathRule, 'a.md', ('json "C:\\' + $un.ToUpperInvariant() + '\\x"'), $true),
    @($pathRule, 'a.md', ('cd /c/' + $un + '/x'), $true),
    @($pathRule, 'a.md', ('cd /c/' + $pj + '/app'), $true),
    @($pathRule, 'a.md', ('cd /C/' + $pj.ToUpperInvariant() + '/app'), $true),
    @($pathRule, 'a.md', ('cd /mnt/c/' + $un + '/x'), $true),
    @($pathRule, 'a.md', ('cd /mnt/d/' + $pj.ToLowerInvariant() + '/x'), $true),
    @($pathRule, 'a.md', 'see C:\src\app and D:\Other\app', $false),
    @($pathRule, 'a.md', 'json "C:\\src\\app"', $false),
    @($pathRule, 'a.md', 'see /c/other/x and /mnt/c/other/x', $false),
    @($pathRule, 'a.md', ('see src/c/' + $un + '/x'), $false),
    @($homeRule, 'a.md', ('at /' + $un + '/jane/x'), $true),
    @($homeRule, 'a.md', 'at /home/jane/x', $true),
    @($homeRule, 'a.md', 'at /home/mel/x', $true),
    @($homeRule, 'a.md', 'at /home/me/app', $false),
    @($homeRule, 'a.md', 'at /home/<you>/app', $false),
    @('desktop session id', 'a.md', ('id ' + $idPrefix + '0123abcd'), $true),
    @('desktop session id', 'a.md', ('id ' + $idPrefix + '0123abc'), $false),
    @('desktop session id', 'a.md', ('id ' + $idPrefix + '<uuid>'), $false),
    @('40-hex commit sha in a .md file', 'a.md', "commit $sha40 here", $true),
    @('40-hex commit sha in a .md file', 'a.ps1', "commit $sha40 here", $false),
    @('40-hex commit sha in a .md file', 'a.md', ('commit ' + $sha40.Substring(0, 39) + ' here'), $false),
    @('40-hex commit sha in a .md file', 'a.md', ('commit ' + $sha40 + '0 here'), $false),
    @('internal follow-up number', 'a.md', ('see FU' + '-12'), $true),
    @('internal follow-up number', 'a.md', ('see FU' + '-x'), $false),
    @('internal follow-up number', 'a.md', ('see XFU' + '-12'), $false)
)
foreach ($r in $rows) {
    $h = @(Find-ScrubHits -Path $r[1] -Lines @($r[2]) | Where-Object { $_.Rule -ceq $r[0] })
    Assert-Coord "SG1 '$($r[0])' on a $($r[1]) line $(if ($r[3]) { 'hits' } else { 'does not hit' }): $($r[2])" (($h.Count -gt 0) -eq $r[3]) "hits=$($h.Count)"
}
$h = @(Find-ScrubHits -Path 'a.md' -Lines @('ok', ('x C:\' + $pj + '\y'), '', ('z FU' + '-3')))
Assert-Coord 'SG1 a hit names its line number and rule' ($h.Count -eq 2 -and $h[0].Line -eq 2 -and $h[0].Rule -ceq $pathRule -and $h[1].Line -eq 4 -and $h[1].Rule -ceq 'internal follow-up number') (($h | ForEach-Object { "$($_.Line) $($_.Rule)" }) -join '; ')
$h = @(Find-ScrubHits -Path 'a.md' -Lines @('at /home/' + ('a' * 100)))
Assert-Coord 'SG1 the matched text of a hit is cut to 80 characters' ($h.Count -eq 1 -and $h[0].Text.Length -eq 80) "hits=$($h.Count) length=$(if ($h.Count) { $h[0].Text.Length })"
$h = @(Find-ScrubHits -Path 'a.md' -Lines @(('see C:\' + $pj + '\y zzalpha')) -Denylist @('zzalpha') -SkipPatterns)
Assert-Coord 'SG1 -SkipPatterns leaves the pattern rules out and keeps the denylist' ($h.Count -eq 1 -and $h[0].Rule -ceq 'denylist entry 1') (($h | ForEach-Object { $_.Rule }) -join ';')
$ht = @(Get-ScrubHexTokens @('ref 0123abc; abc123; x0123abd; 0123abe_ ; ABCDEF12 .', '', ('long ' + ('a' * 41))))
Assert-Coord 'SG1 hex tokens: 7 to 40 digits between non-word characters, lower-cased; 6 digits, a letter before, an underscore after and 41 digits are not tokens' ($ht.Count -eq 2 -and $ht[0].Token -ceq '0123abc' -and $ht[0].Line -eq 1 -and $ht[1].Token -ceq 'abcdef12') (($ht | ForEach-Object { "$($_.Line) $($_.Token)" }) -join '; ')

# ---- SG2: the denylist --------------------------------------------------------
Write-Host "(SG2) the denylist"
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('scrub-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory($tmp)
$dlFile = Join-Path $tmp 'deny.txt'
[System.IO.File]::WriteAllText($dlFile, "# a comment`n`nzzalpha`n  zz beta  `n# zzgamma`n", $coordUtf8)
$dl = Read-ScrubDenylist $dlFile
Assert-Coord 'SG2 the reader keeps the two entries, trimmed, and skips the comments and the blank line' ($dl -and $dl.Count -eq 2 -and $dl[0] -ceq 'zzalpha' -and $dl[1] -ceq 'zz beta') "$($dl -join '|')"
$h = @(Find-ScrubHits -Path 'a.txt' -Lines @('talk of ZZAlpha today') -Denylist $dl)
Assert-Coord 'SG2 an entry hits in another letter case, and the hit names the entry by number, not by word' ($h.Count -eq 1 -and $h[0].Rule -ceq 'denylist entry 1' -and $h[0].Text -ceq '') (($h | ForEach-Object { $_.Rule }) -join ';')
$h = @(Find-ScrubHits -Path 'a.txt' -Lines @('zzalphas and xzzalpha and zzalpha_1') -Denylist $dl)
Assert-Coord 'SG2 an entry is a whole word: it does not hit inside a longer word' ($h.Count -eq 0) (($h | ForEach-Object { $_.Rule }) -join ';')
$h = @(Find-ScrubHits -Path 'a.txt' -Lines @('a zz beta b', 'and zzgamma') -Denylist $dl)
Assert-Coord 'SG2 an entry with a space hits, a commented-out entry does not' ($h.Count -eq 1 -and $h[0].Rule -ceq 'denylist entry 2' -and $h[0].Line -eq 1) (($h | ForEach-Object { "$($_.Line) $($_.Rule)" }) -join ';')
$h = @(Find-ScrubHits -Path 'a.txt' -Lines @('zzalpha') -Denylist $null)
Assert-Coord 'SG2 no denylist: no denylist hit' ($h.Count -eq 0)
Assert-Coord 'SG2 an unset variable (empty path) has no denylist' ($null -eq (Read-ScrubDenylist ''))
Assert-Coord 'SG2 a missing file has no denylist' ($null -eq (Read-ScrubDenylist (Join-Path $tmp 'nope.txt')))
$emptyFile = Join-Path $tmp 'empty.txt'
[System.IO.File]::WriteAllText($emptyFile, "# only a comment`n`n", $coordUtf8)
Assert-Coord 'SG2 a file with no entry has no denylist' ($null -eq (Read-ScrubDenylist $emptyFile))
Assert-Coord 'SG2 an absent denylist with the variable unset and no history range is skipped (read UNCHECKED)' ((Get-ScrubDenylistAbsentVerdict '' $false) -ceq 'SKIP')
$setVars = @((Join-Path $tmp 'nope.txt'), $emptyFile, ' ')
Assert-Coord 'SG2 an absent denylist fails when the variable is set (a missing file, a file with no entry, only a space)' (@($setVars | Where-Object { (Get-ScrubDenylistAbsentVerdict $_ $false) -cne 'FAIL' }).Count -eq 0)
Assert-Coord 'SG2 an absent denylist fails in a history run (the release gate), the variable unset' ((Get-ScrubDenylistAbsentVerdict '' $true) -ceq 'FAIL')
# A multi-word entry is matched over the whole text, not line by line: a name
# hard-wrapped onto the next line, a comment marker in front of the second word.
$h = @(Find-ScrubHits -Path 'a.md' -Lines @('a zz', 'beta b') -Denylist $dl)
Assert-Coord 'SG2 a multi-word entry hard-wrapped across two lines hits once, on the line it starts on' ($h.Count -eq 1 -and $h[0].Rule -ceq 'denylist entry 2' -and $h[0].Line -eq 1) (($h | ForEach-Object { "$($_.Line) $($_.Rule)" }) -join ';')
$h = @(Find-ScrubHits -Path 'a.ps1' -Lines @('# a zz', '# beta b', '//  zz', '//   beta') -Denylist $dl)
Assert-Coord 'SG2 a multi-word entry wrapped inside # and // comments hits (the comment marker sits between the words)' ($h.Count -eq 2 -and $h[0].Line -eq 1 -and $h[1].Line -eq 3) (($h | ForEach-Object { "$($_.Line) $($_.Rule)" }) -join ';')
$h = @(Find-ScrubHits -Path 'a.txt' -Lines @('zz    beta', 'zzbeta') -Denylist $dl)
Assert-Coord 'SG2 a multi-word entry with several spaces between the words hits; the words run together do not' ($h.Count -eq 1 -and $h[0].Line -eq 1) (($h | ForEach-Object { "$($_.Line) $($_.Rule)" }) -join ';')
$h = @(Find-ScrubHits -Path 'a.txt' -Lines @('zzalpha zzalpha', 'zzalpha') -Denylist $dl)
Assert-Coord 'SG2 an entry twice on one line is one hit for that line' ($h.Count -eq 2 -and $h[0].Line -eq 1 -and $h[1].Line -eq 2) (($h | ForEach-Object { "$($_.Line) $($_.Rule)" }) -join ';')
# NFC and NFD: an accented letter written as one code point or as a letter plus
# a combining mark is the same text (the code points are built at run time).
$nfc = 'zzcaf' + [string][char]0x00E9
$nfd = 'zzcafe' + [string][char]0x0301
$h = @(Find-ScrubHits -Path 'a.txt' -Lines @("x $nfd y") -Denylist @($nfc))
Assert-Coord 'SG2 an NFC entry hits the NFD spelling of the same word' ($h.Count -eq 1) "hits=$($h.Count)"
$h = @(Find-ScrubHits -Path 'a.txt' -Lines @("x $nfc y") -Denylist @($nfd))
Assert-Coord 'SG2 an NFD entry hits the NFC spelling of the same word' ($h.Count -eq 1) "hits=$($h.Count)"
# The words of a multi-word entry joined by a dot, an underscore or a comma (an
# email local part, a snake_case name, a "Surname, Given" list) still hit.
$h = @(Find-ScrubHits -Path 'a.txt' -Lines @('mail zz.beta@example.invalid', 'id zz_beta', 'list zz, beta') -Denylist $dl)
Assert-Coord 'SG2 a multi-word entry joined by . _ or , hits on each line' ($h.Count -eq 3 -and $h[0].Line -eq 1 -and $h[1].Line -eq 2 -and $h[2].Line -eq 3) (($h | ForEach-Object { "$($_.Line) $($_.Rule)" }) -join ';')
# Compatibility forms: fullwidth letters fold to ASCII (NFKC), and invisible
# characters inside a word (zero-width space, soft hyphen) do not hide it.
$fw = -join ('zzalpha'.ToCharArray() | ForEach-Object { [char]([int]$_ + 0xFEE0) })
$zw = 'zz' + [string][char]0x200B + 'al' + [string][char]0x00AD + 'pha'
$h = @(Find-ScrubHits -Path 'a.txt' -Lines @("x $fw y", "x $zw y") -Denylist $dl)
Assert-Coord 'SG2 an entry in fullwidth letters, and one with a zero-width space and a soft hyphen inside, both hit' ($h.Count -eq 2 -and $h[0].Line -eq 1 -and $h[1].Line -eq 2) (($h | ForEach-Object { "$($_.Line) $($_.Rule)" }) -join ';')

# ---- SG3: strict mode and the repo list ---------------------------------------
Write-Host "(SG3) strict mode and the repo list"
Assert-Coord 'SG3 neither the switch nor the variable: not strict' ((Get-ScrubStrictMode $false '') -eq $false)
Assert-Coord 'SG3 the -Strict switch: strict' ((Get-ScrubStrictMode $true '') -eq $true)
Assert-Coord 'SG3 the variable set to 1: strict' ((Get-ScrubStrictMode $false '1') -eq $true)
Assert-Coord 'SG3 the variable set to 0: not strict' ((Get-ScrubStrictMode $false '0') -eq $false)
Assert-Coord 'SG3 an unchecked row is UNCHECKED when not strict' ((Get-ScrubUncheckedVerdict $false) -ceq 'UNCHECKED')
Assert-Coord 'SG3 an unchecked row is a FAIL when strict' ((Get-ScrubUncheckedVerdict $true) -ceq 'FAIL')
$rl = Get-ScrubRepoList ' first ;second;; third '
Assert-Coord 'SG3 the repo list splits on ;, trims and drops empty entries' ($rl.Count -eq 3 -and $rl[0] -ceq 'first' -and $rl[1] -ceq 'second' -and $rl[2] -ceq 'third') ($rl -join '|')
$rl = Get-ScrubRepoList 'only'
Assert-Coord 'SG3 a list of one entry is an array of one' ($rl -is [array] -and $rl.Count -eq 1 -and $rl[0] -ceq 'only') "type=$(if ($null -ne $rl) { $rl.GetType().Name })"
foreach ($raw in @('', ';', ' ; ;; ')) {
    # The value itself, not @(value): @($null) holds one $null element, and it
    # is a $null that reached Test-Path in Windows PowerShell 5.1.
    $rl = Get-ScrubRepoList $raw
    Assert-Coord "SG3 the repo variable '$raw' lists no repo, as an empty array and not `$null" ($null -ne $rl -and $rl -is [array] -and $rl.Count -eq 0) "type=$(if ($null -ne $rl) { $rl.GetType().Name } else { 'null' })"
}
$cmpBase = Join-Path ([System.IO.Path]::GetTempPath()) 'AbC'
Assert-Coord 'SG3 two spellings of one path (separators, a trailing separator) are the same path' (Test-ScrubSamePath $cmpBase ($cmpBase.Replace('\', '/') + '/'))
Assert-Coord 'SG3 two different folders are not the same path' (-not (Test-ScrubSamePath $cmpBase ($cmpBase + 'x')))
Assert-Coord 'SG3 a path and its upper-case twin are the same path on Windows, a different one elsewhere' ((Test-ScrubSamePath $cmpBase $cmpBase.ToUpperInvariant()) -eq ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT))
Assert-Coord 'SG3 a blank path matches no path' (-not (Test-ScrubSamePath '' $cmpBase))

# ---- SG4: the scanner on synthetic repos ---------------------------------------
Write-Host "(SG4) the scanner on synthetic repos"
$hitLine = 'see C:\' + $pj + '\x'
function New-ScrubTestRepo([string]$Name, [hashtable]$Files = @{}) {
    $r = Join-Path $tmp $Name
    New-HookTestRepo $r
    foreach ($k in $Files.Keys) { Set-CoordFile $r $k $Files[$k] }
    return $r
}
# The top level of the repo at $Repo as git spells it, with the platform's
# separators.
function Get-ScrubGitSpelling([string]$Repo) {
    return [System.IO.Path]::GetFullPath((Get-CoordGitOut $Repo @('rev-parse', '--show-toplevel')))
}
function Get-ScrubHitsOf($Res, [string]$File, [string]$Rule = '') {
    # Callers wrap the call in @(): unrolled, one hit is a bare [pscustomobject],
    # which has no .Count in Windows PowerShell 5.1.
    return @($Res.Hits | Where-Object { $_.File -ceq $File -and ((-not $Rule) -or $_.Rule -ceq $Rule) })
}

# Discovery that fails or finds nothing is a FAIL of the real run (SG5), and an
# unusable result here.
$res = Invoke-ScrubScan -Repo (Join-Path $tmp 'no-such-folder')
Assert-Coord 'SG4 a folder that is not a work tree: discovery fails, with a reason, and nothing is scanned' (-not $res.DiscoveryOk -and $res.Reason -match 'git ls-files failed' -and $res.Scanned.Count -eq 0) "ok=$($res.DiscoveryOk) reason=$($res.Reason)"
$emptyRepo = New-ScrubTestRepo 'empty-repo'
$res = Invoke-ScrubScan -Repo $emptyRepo
Assert-Coord 'SG4 a work tree with no file to ship: discovery fails (zero files), not a pass' (-not $res.DiscoveryOk -and $res.Reason -match 'no files') "ok=$($res.DiscoveryOk) reason=$($res.Reason)"

# Names git quotes without -z: a non-ASCII name always; a name with a double
# quote or a tab where the file system allows one.
$accent = 'caf' + [string][char]0x00E9 + '.txt'
$quoteName = 'q' + [string][char]0x22 + 'b.txt'
$tabName = 'q' + [string][char]9 + 't.txt'
$qFiles = @{}
$qFiles[$accent] = $hitLine + "`n"
$qMade = New-Object System.Collections.Generic.List[string]
foreach ($qn in @($quoteName, $tabName)) {
    try { Set-CoordFile (Join-Path $tmp 'probe-names') $qn "x`n"; $qMade.Add($qn) } catch { }
}
foreach ($qn in $qMade) { $qFiles[$qn] = $hitLine + "`n" }
$qRepo = New-ScrubTestRepo 'quoted-names' $qFiles
$res = Invoke-ScrubScan -Repo $qRepo
Assert-Coord 'SG4 a file whose name git would quote (non-ASCII) is listed and scanned: its hit is reported under its real name' ($res.DiscoveryOk -and $res.Scanned.Contains($accent) -and @(Get-ScrubHitsOf $res $accent $pathRule).Count -eq 1) "ok=$($res.DiscoveryOk) scanned=$($res.Scanned -join '|') hits=$(($res.Hits | ForEach-Object { Format-ScrubHit $_ }) -join ';')"
foreach ($qn in @($quoteName, $tabName)) {
    $shown = $qn.Replace([string][char]0x22, '<dq>').Replace([string][char]9, '<tab>')
    if ($qMade.Contains($qn)) {
        Assert-Coord "SG4 a file named $shown is listed and scanned" ($res.Scanned.Contains($qn) -and @(Get-ScrubHitsOf $res $qn $pathRule).Count -eq 1) "scanned=$($res.Scanned -join '|')"
    }
    else { Write-ScrubUnchecked "SG4 a file named $shown is listed and scanned" 'this file system refuses that file name' }
}

# Untracked files are scanned, ignored ones are not, tracked ones are.
$uRepo = New-ScrubTestRepo 'untracked' @{
    '.gitignore'    = "ignored.txt`n"
    'tracked.txt'   = $hitLine + "`n"
    'untracked.txt' = $hitLine + "`n"
    'ignored.txt'   = $hitLine + "`n"
}
Invoke-HookTestGit $uRepo @('-c', 'core.autocrlf=false', 'add', '--', '.gitignore', 'tracked.txt')
$res = Invoke-ScrubScan -Repo $uRepo
Assert-Coord 'SG4 a tracked and an untracked file are scanned and hit' ($res.Scanned.Contains('tracked.txt') -and $res.Scanned.Contains('untracked.txt') -and @(Get-ScrubHitsOf $res 'tracked.txt' $pathRule).Count -eq 1 -and @(Get-ScrubHitsOf $res 'untracked.txt' $pathRule).Count -eq 1) "scanned=$($res.Scanned -join '|')"
Assert-Coord 'SG4 an ignored file is not scanned and has no hit' (-not $res.Scanned.Contains('ignored.txt') -and @(Get-ScrubHitsOf $res 'ignored.txt').Count -eq 0) "scanned=$($res.Scanned -join '|')"

# Encodings: UTF-32 and UTF-16 with a BOM are decoded and scanned; NUL bytes
# without a BOM cannot be scanned and are counted by name.
$eRepo = New-ScrubTestRepo 'encodings' @{ 'plain.txt' = "nothing here`n" }
$le = [byte[]](@(0xFF, 0xFE) + [System.Text.Encoding]::Unicode.GetBytes($hitLine + "`n"))
$be = [byte[]](@(0xFE, 0xFF) + [System.Text.Encoding]::BigEndianUnicode.GetBytes($hitLine + "`n"))
$le32 = [byte[]](@(0xFF, 0xFE, 0x00, 0x00) + (New-Object System.Text.UTF32Encoding($false, $false)).GetBytes($hitLine + "`n"))
$be32 = [byte[]](@(0x00, 0x00, 0xFE, 0xFF) + (New-Object System.Text.UTF32Encoding($true, $false)).GetBytes($hitLine + "`n"))
[System.IO.File]::WriteAllBytes((Join-Path $eRepo 'u16le.txt'), $le)
[System.IO.File]::WriteAllBytes((Join-Path $eRepo 'u16be.txt'), $be)
[System.IO.File]::WriteAllBytes((Join-Path $eRepo 'u32le.txt'), $le32)
[System.IO.File]::WriteAllBytes((Join-Path $eRepo 'u32be.txt'), $be32)
[System.IO.File]::WriteAllBytes((Join-Path $eRepo 'zerobytes.bin'), [byte[]](0x61, 0x00, 0x62))
# A UTF-16 LE file whose first character is U+0000 starts FF FE 00 00 too. The
# row reaches the U+FFFD check only while (length - 4) % 4 is 0, which holds
# because $hitLine has an odd length; with an even one the length check alone
# would send the file to UTF-16 and the U+FFFD check would go untested.
$le0 = [byte[]](@(0xFF, 0xFE) + [System.Text.Encoding]::Unicode.GetBytes([string][char]0 + $hitLine + "`n"))
[System.IO.File]::WriteAllBytes((Join-Path $eRepo 'u16nul.txt'), $le0)
$res = Invoke-ScrubScan -Repo $eRepo
Assert-Coord 'SG4 a UTF-16 LE file whose first character is U+0000 (FF FE 00 00) is read as UTF-16, not UTF-32, and its hit reported' ($res.Utf16.Contains('u16nul.txt') -and -not $res.Utf32.Contains('u16nul.txt') -and @(Get-ScrubHitsOf $res 'u16nul.txt' $pathRule).Count -eq 1) "utf32=$($res.Utf32 -join '|') utf16=$($res.Utf16 -join '|') hits=$(@(Get-ScrubHitsOf $res 'u16nul.txt').Count)"
Assert-Coord 'SG4 a UTF-16 LE file with a BOM is decoded and its hit reported' ($res.Utf16.Contains('u16le.txt') -and @(Get-ScrubHitsOf $res 'u16le.txt' $pathRule).Count -eq 1) "utf16=$($res.Utf16 -join '|')"
Assert-Coord 'SG4 a UTF-16 BE file with a BOM is decoded and its hit reported' ($res.Utf16.Contains('u16be.txt') -and @(Get-ScrubHitsOf $res 'u16be.txt' $pathRule).Count -eq 1) "utf16=$($res.Utf16 -join '|')"
Assert-Coord 'SG4 a UTF-32 LE file with a BOM (FF FE 00 00) is decoded as UTF-32, not UTF-16, and its hit reported' ($res.Utf32.Contains('u32le.txt') -and -not $res.Utf16.Contains('u32le.txt') -and @(Get-ScrubHitsOf $res 'u32le.txt' $pathRule).Count -eq 1) "utf32=$($res.Utf32 -join '|') utf16=$($res.Utf16 -join '|') hits=$(@(Get-ScrubHitsOf $res 'u32le.txt').Count)"
Assert-Coord 'SG4 a UTF-32 BE file with a BOM (00 00 FE FF) is decoded as UTF-32, not listed as a NUL file, and its hit reported' ($res.Utf32.Contains('u32be.txt') -and -not $res.NulFiles.Contains('u32be.txt') -and @(Get-ScrubHitsOf $res 'u32be.txt' $pathRule).Count -eq 1) "utf32=$($res.Utf32 -join '|') nul=$($res.NulFiles -join '|') hits=$(@(Get-ScrubHitsOf $res 'u32be.txt').Count)"
Assert-Coord 'SG4 a file with NUL bytes and no BOM is not scanned and is listed by name' ($res.NulFiles.Contains('zerobytes.bin') -and -not $res.Scanned.Contains('zerobytes.bin') -and -not $res.NulFiles.Contains('u16le.txt') -and -not $res.NulFiles.Contains('plain.txt')) "nul=$($res.NulFiles -join '|')"
Assert-Coord 'SG4 every listed entry is accounted for (7 listed: 6 scanned, 1 NUL file)' ($res.Listed -eq 7 -and $res.WorkTreeScanned -eq 6 -and $res.WorkTreeNul -eq 1 -and (Get-ScrubAccounted $res) -eq $res.Listed) "listed=$($res.Listed) scanned=$($res.WorkTreeScanned) nul=$($res.WorkTreeNul) accounted=$(Get-ScrubAccounted $res)"
# Text that is not valid UTF-8 (a Windows-1252 byte for the accented letter)
# decodes to U+FFFD as UTF-8, so it is read as Windows-1252 as well; a hit in
# both readings is reported once.
$aRepo = New-ScrubTestRepo 'ansi' @{ 'plain.txt' = "nothing here`n" }
[System.IO.File]::WriteAllBytes((Join-Path $aRepo 'ansi.txt'), [byte[]]([System.Text.Encoding]::ASCII.GetBytes('x zzcaf') + @(0xE9) + [System.Text.Encoding]::ASCII.GetBytes(" zzalpha y`n")))
$res = Invoke-ScrubScan -Repo $aRepo -Denylist @($nfc, 'zzalpha')
Assert-Coord 'SG4 a file that is not valid UTF-8 is read as Windows-1252 too: its accented entry hits, its ASCII entry hits once, and it is listed as not UTF-8' ($res.NonUtf8.Contains('ansi.txt') -and -not $res.NonUtf8.Contains('plain.txt') -and @(Get-ScrubHitsOf $res 'ansi.txt' 'denylist entry 1').Count -eq 1 -and @(Get-ScrubHitsOf $res 'ansi.txt' 'denylist entry 2').Count -eq 1) "nonutf8=$($res.NonUtf8 -join '|') hits=$(($res.Hits | ForEach-Object { Format-ScrubHit $_ }) -join ';')"
# File names are scanned as text (the hit names the entry by position, not by
# its name, which holds the word).
$fRepo = New-ScrubTestRepo 'names' @{ 'a.txt' = "fine`n"; 'notes-zzalpha.md' = "fine`n" }
$res = Invoke-ScrubScan -Repo $fRepo -Denylist @('zzalpha')
Assert-Coord 'SG4 a file name that holds a denylist entry hits, named by its position in the listing' (@(Get-ScrubHitsOf $res 'file name of listed entry 2' 'denylist entry 1').Count -eq 1 -and @($res.Hits | Where-Object { $_.File -like '*zzalpha*' }).Count -eq 0) "hits=$(($res.Hits | ForEach-Object { Format-ScrubHit $_ }) -join ';')"
Assert-Coord 'SG4 file names do not count as scanned file versions (the accounting is unchanged)' ($res.Listed -eq 2 -and $res.Scanned.Count -eq 2 -and (Get-ScrubAccounted $res) -eq 2) "listed=$($res.Listed) scanned=$($res.Scanned.Count)"

# Listed entries the scan cannot read as a file are accounted for and named, not
# dropped: a submodule entry (a gitlink; the commit id is built at run time), a
# skip-worktree path that is absent from the work tree, a dangling symlink
# (where the machine allows symlinks), and a file another process holds open
# without sharing.
$gRepo = New-ScrubTestRepo 'gitlink' @{ 'plain.txt' = "fine`n" }
Invoke-HookTestGit $gRepo @('update-index', '--add', '--cacheinfo', ('160000,' + ('a' * 40) + ',sub'))
$res = Invoke-ScrubScan -Repo $gRepo
Assert-Coord 'SG4 a submodule entry (gitlink) is listed, not read, and reported skipped by name; the entries are all accounted for' ($res.DiscoveryOk -and $res.Skipped.Contains('sub') -and $res.Skipped.Count -eq 1 -and $res.Scanned.Contains('plain.txt') -and $res.Listed -eq 2 -and (Get-ScrubAccounted $res) -eq $res.Listed) "ok=$($res.DiscoveryOk) reason=$($res.Reason) skipped=$($res.Skipped -join '|') listed=$($res.Listed) accounted=$(Get-ScrubAccounted $res)"
$wRepo = New-ScrubTestRepo 'skipworktree' @{ 'keep.txt' = "fine`n"; 'gone.txt' = "fine`n" }
Invoke-HookTestGit $wRepo @('-c', 'core.autocrlf=false', 'add', '--', 'keep.txt', 'gone.txt')
Invoke-HookTestGit $wRepo @('update-index', '--skip-worktree', 'gone.txt')
Remove-Item -LiteralPath (Join-Path $wRepo 'gone.txt') -Force
$res = Invoke-ScrubScan -Repo $wRepo
Assert-Coord 'SG4 a skip-worktree path absent from the work tree is listed, not read, and reported skipped by name; the entries are all accounted for' ($res.DiscoveryOk -and $res.Skipped.Contains('gone.txt') -and $res.Skipped.Count -eq 1 -and $res.Scanned.Contains('keep.txt') -and $res.Listed -eq 2 -and (Get-ScrubAccounted $res) -eq $res.Listed) "ok=$($res.DiscoveryOk) reason=$($res.Reason) skipped=$($res.Skipped -join '|') listed=$($res.Listed) accounted=$(Get-ScrubAccounted $res)"
$lRepo = New-ScrubTestRepo 'symlinks' @{ 'plain.txt' = "fine`n" }
$linkMade = $false
try {
    New-Item -ItemType SymbolicLink -Path (Join-Path $lRepo 'dangling') -Target (Join-Path $lRepo 'no-such-target') -ErrorAction Stop | Out-Null
    $linkMade = $true
}
catch { $linkMade = $false }
if ($linkMade) {
    $res = Invoke-ScrubScan -Repo $lRepo
    Assert-Coord 'SG4 a dangling symlink is listed, not read, and reported skipped by name; the entries are all accounted for' ($res.DiscoveryOk -and $res.Skipped.Contains('dangling') -and $res.Scanned.Contains('plain.txt') -and (Get-ScrubAccounted $res) -eq $res.Listed) "ok=$($res.DiscoveryOk) reason=$($res.Reason) skipped=$($res.Skipped -join '|') listed=$($res.Listed) accounted=$(Get-ScrubAccounted $res)"
}
else { Write-CoordUnchecked 'SG4 a dangling symlink is reported skipped by name' 'this machine refuses to create symbolic links for this user (needs developer mode or elevation on Windows)' }
$kRepo = New-ScrubTestRepo 'locked' @{ 'open.txt' = "fine`n"; 'ok.txt' = "fine`n" }
if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
    $lockStream = [System.IO.File]::Open((Join-Path $kRepo 'open.txt'), [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try { $res = Invoke-ScrubScan -Repo $kRepo }
    finally { $lockStream.Dispose() }
    Assert-Coord 'SG4 a file the suite cannot read (held open without sharing) is reported unreadable by name, the others are scanned, and the entries are all accounted for' ($res.DiscoveryOk -and $res.Unreadable.Contains('open.txt') -and $res.Unreadable.Count -eq 1 -and $res.Scanned.Contains('ok.txt') -and -not $res.Scanned.Contains('open.txt') -and (Get-ScrubAccounted $res) -eq $res.Listed) "ok=$($res.DiscoveryOk) reason=$($res.Reason) unreadable=$($res.Unreadable -join '|') listed=$($res.Listed) accounted=$(Get-ScrubAccounted $res)"
}
else { Write-CoordUnchecked 'SG4 a file the suite cannot read is reported unreadable by name' 'a sharing lock is built with FileShare.None, which only Windows enforces' }

# A tracked file with an unstaged change: the version in the index is scanned too.
$iRepo = New-ScrubTestRepo 'index-version' @{
    'staged-dirty.txt' = $hitLine + "`n"
    'staged-clean.txt' = "fine`n"
    'plain.txt'        = "fine`n"
}
Invoke-HookTestGit $iRepo @('-c', 'core.autocrlf=false', 'add', '--', 'staged-dirty.txt', 'staged-clean.txt', 'plain.txt')
Set-CoordFile $iRepo 'staged-dirty.txt' "now clean after the edit`n"
Set-CoordFile $iRepo 'staged-clean.txt' "still fine, edited`n"
$res = Invoke-ScrubScan -Repo $iRepo
Assert-Coord 'SG4 a hit that is only in the index version (the work tree was cleaned afterwards) is reported, labelled (index)' (@(Get-ScrubHitsOf $res 'staged-dirty.txt (index)' $pathRule).Count -eq 1 -and @(Get-ScrubHitsOf $res 'staged-dirty.txt').Count -eq 0) (($res.Hits | ForEach-Object { Format-ScrubHit $_ }) -join ';')
Assert-Coord 'SG4 only files with unstaged changes get the index scan; a clean index version has no hit' ($res.IndexScanned.Contains('staged-dirty.txt') -and $res.IndexScanned.Contains('staged-clean.txt') -and -not $res.IndexScanned.Contains('plain.txt') -and @(Get-ScrubHitsOf $res 'staged-clean.txt (index)').Count -eq 0) "index=$($res.IndexScanned -join '|')"
Assert-Coord 'SG4 when every index version could be read, none is reported failed and the entries are all accounted for' ($res.IndexFailed.Count -eq 0 -and $res.Listed -eq 3 -and (Get-ScrubAccounted $res) -eq $res.Listed) "failed=$($res.IndexFailed -join '|') listed=$($res.Listed) accounted=$(Get-ScrubAccounted $res)"

# An index version git cannot read (an unmerged path has no stage-0 entry) is
# reported by name, not dropped; its work-tree version is still scanned.
$cRepo = New-ScrubTestRepo 'conflict' @{ 'c.txt' = "base`n" }
$conflictBuilt = $false
try {
    Invoke-HookTestGit $cRepo @('-c', 'core.autocrlf=false', 'add', '--', 'c.txt')
    Invoke-HookTestGit $cRepo @('-c', 'core.autocrlf=false', 'commit', '--quiet', '-m', 'base')
    Invoke-HookTestGit $cRepo @('checkout', '--quiet', '-b', 'side')
    Set-CoordFile $cRepo 'c.txt' "side`n"
    Invoke-HookTestGit $cRepo @('-c', 'core.autocrlf=false', 'commit', '--quiet', '-a', '-m', 'side')
    Invoke-HookTestGit $cRepo @('checkout', '--quiet', 'main')
    Set-CoordFile $cRepo 'c.txt' "main`n"
    Invoke-HookTestGit $cRepo @('-c', 'core.autocrlf=false', 'commit', '--quiet', '-a', '-m', 'main')
    # The merge conflicts on purpose (exit 1), and a native command's stderr is
    # an error record in Windows PowerShell 5.1: Continue for this one call.
    $eapSaved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & git -C $cRepo -c core.autocrlf=false merge --no-edit side 2>&1 | Out-Null } finally { $ErrorActionPreference = $eapSaved }
    $conflictBuilt = ((Get-CoordGitOut $cRepo @('ls-files', '--unmerged')) -ne '')
}
catch { $conflictBuilt = $false }
if ($conflictBuilt) {
    $res = Invoke-ScrubScan -Repo $cRepo
    Assert-Coord 'SG4 an index version git cat-file cannot read (an unmerged path) is reported failed by name, its work-tree version is still scanned, and the entries are all accounted for' ($res.DiscoveryOk -and $res.IndexFailed.Contains('c.txt') -and -not $res.IndexScanned.Contains('c.txt') -and $res.Scanned.Contains('c.txt') -and (Get-ScrubAccounted $res) -eq $res.Listed) "ok=$($res.DiscoveryOk) reason=$($res.Reason) failed=$($res.IndexFailed -join '|') index=$($res.IndexScanned -join '|') scanned=$($res.Scanned -join '|')"
}
else { Write-CoordUnchecked 'SG4 an index version git cannot read is reported failed by name' 'could not build a merge conflict in the fixture repo' }

# This file: pattern rules skipped, the denylist (and the sha rule) still applied.
$sRepo = New-ScrubTestRepo 'self-file' @{
    'tests/scrub.test.ps1' = $hitLine + " zzalpha`n"
    'other.txt'            = $hitLine + " zzalpha`n"
}
$res = Invoke-ScrubScan -Repo $sRepo -SelfRel $selfName -Denylist @('zzalpha')
$selfHits = @(Get-ScrubHitsOf $res $selfName)
Assert-Coord 'SG4 the self file is scanned for the denylist only: no pattern hit, one denylist hit' ($res.Scanned.Contains($selfName) -and $res.PatternSkipped.Contains($selfName) -and $selfHits.Count -eq 1 -and $selfHits[0].Rule -ceq 'denylist entry 1') (($selfHits | ForEach-Object { Format-ScrubHit $_ }) -join ';')
Assert-Coord 'SG4 another file with the same content gets both the pattern hit and the denylist hit' (@(Get-ScrubHitsOf $res 'other.txt' $pathRule).Count -eq 1 -and @(Get-ScrubHitsOf $res 'other.txt' 'denylist entry 1').Count -eq 1)

# The commit-sha rule: a token that is a commit of a listed repo is a hit.
$privRepo = New-CoordCanonRepo $tmp 'listed-repo' -Commit
# The fixture's commits are reproducible, so other-listed-repo below holds the
# same first commit; a second commit only this repo has is the one to find.
[void](Get-CoordGitOut $privRepo @('commit', '--allow-empty', '-q', '-m', 'only in listed-repo'))
$privSha = Get-CoordGitOut $privRepo @('rev-parse', 'HEAD')
$otherRepo = New-CoordCanonRepo $tmp 'other-listed-repo' -Commit
# The listed repos are spelled the way git spells their top level (a %TEMP% in
# 8.3 form would otherwise never equal what git prints).
$privRepo = Get-ScrubGitSpelling $privRepo
$otherRepo = Get-ScrubGitSpelling $otherRepo
$shipRepo = New-ScrubTestRepo 'ship' @{
    'ref.txt'   = "head " + $privSha.Substring(0, 10) + "`nfull " + $privSha + "`nseven " + $privSha.Substring(0, 7) + "`n"
    'other.txt' = "nothing abcdef1 there and abcdef12345 either`n"
    'edge.txt'  = "six " + $privSha.Substring(0, 6) + " wrapped v" + $privSha.Substring(0, 10) + " under " + $privSha.Substring(0, 10) + "_x`n"
}
$res = Invoke-ScrubScan -Repo $shipRepo
$nUsable = Add-ScrubRepoShaHits $res @($privRepo)
$refHits = @(Get-ScrubHitsOf $res 'ref.txt' $hexRuleName | Sort-Object Line)
Assert-Coord 'SG4 a token that is a commit of a listed repo is a hit on every line that holds it (10, 40 and 7 digits)' ($nUsable -eq 1 -and $refHits.Count -eq 3 -and $refHits[0].Line -eq 1 -and $refHits[1].Line -eq 2 -and $refHits[2].Line -eq 3) "usable=$nUsable hits=$(($res.Hits | ForEach-Object { Format-ScrubHit $_ }) -join ';')"
Assert-Coord 'SG4 a hex token that is no commit of a listed repo is no hit' (@(Get-ScrubHitsOf $res 'other.txt').Count -eq 0)
Assert-Coord 'SG4 a 6-digit prefix, a prefix glued to a letter and one followed by an underscore are not tokens, so no hit' (@(Get-ScrubHitsOf $res 'edge.txt').Count -eq 0)
$printed = ($res.Hits | ForEach-Object { Format-ScrubHit $_ }) -join "`n"
Assert-Coord 'SG4 a commit-sha hit prints the file, the line and the rule, and neither the repo path nor the sha' ($printed.Contains('ref.txt:1: ' + $hexRuleName) -and -not $printed.Contains($privRepo) -and -not $printed.Contains($privSha.Substring(0, 7))) $printed
$res = Invoke-ScrubScan -Repo $shipRepo
$nUsable = Add-ScrubRepoShaHits $res @($otherRepo, $privRepo)
Assert-Coord 'SG4 with two listed repos the commit of the second one is found too' ($nUsable -eq 2 -and @(Get-ScrubHitsOf $res 'ref.txt' $hexRuleName).Count -eq 3) "usable=$nUsable"
$res = Invoke-ScrubScan -Repo $shipRepo
$nUsable = Add-ScrubRepoShaHits $res @($otherRepo)
Assert-Coord 'SG4 a listed repo that does not hold the commit gives no hit' ($nUsable -eq 1 -and @(Get-ScrubHitsOf $res 'ref.txt' $hexRuleName).Count -eq 0)
$res = Invoke-ScrubScan -Repo $shipRepo
$nUsable = Add-ScrubRepoShaHits $res @((Join-Path $tmp 'no-such-repo'), $tmp)
Assert-Coord 'SG4 paths that are not git repos are not usable: the rule cannot run (UNCHECKED), no hit' ($nUsable -eq 0 -and @(Get-ScrubHitsOf $res 'ref.txt' $hexRuleName).Count -eq 0) "usable=$nUsable"
$nUsable = Add-ScrubRepoShaHits $res @()
Assert-Coord 'SG4 no listed repo: the rule cannot run (UNCHECKED)' ($nUsable -eq 0)

# An unset variable, or one of only ';' and blanks, must leave the rule UNCHECKED
# and never throw (in Windows PowerShell 5.1 an empty list reached Test-Path as a
# $null path and ended the suite).
foreach ($raw in @('', ';', ' ; ;; ')) {
    $res = Invoke-ScrubScan -Repo $shipRepo
    $thrown = ''
    $rr = $null
    try { $rr = Invoke-ScrubRepoRule $res $raw } catch { $thrown = "$_" }
    Assert-Coord "SG4 the repo variable '$raw' (unset or blank) gives UNCHECKED, not an error: nothing listed, nothing usable, no hit" ($thrown -eq '' -and $null -ne $rr -and $rr.Verdict -ceq 'UNCHECKED' -and $rr.Listed -eq 0 -and $rr.Usable -eq 0 -and @($rr.Unchecked).Count -eq 0 -and @(Get-ScrubHitsOf $res 'ref.txt' $hexRuleName).Count -eq 0) "thrown=$thrown verdict=$(if ($rr) { $rr.Verdict }) listed=$(if ($rr) { $rr.Listed })"
}
$res = Invoke-ScrubScan -Repo $shipRepo
$thrown = ''
$nUsable = -1
try { $nUsable = Add-ScrubRepoShaHits $res (Get-ScrubRepoList '') } catch { $thrown = "$_" }
Assert-Coord 'SG4 Add-ScrubRepoShaHits on the list of an unset variable returns 0 and does not throw' ($thrown -eq '' -and $nUsable -eq 0 -and $res.RepoUnchecked.Count -eq 0) "thrown=$thrown usable=$nUsable"
$res = Invoke-ScrubScan -Repo $shipRepo
$thrown = ''
$nUsable = -1
try { $nUsable = Add-ScrubRepoShaHits $res $null } catch { $thrown = "$_" }
Assert-Coord 'SG4 Add-ScrubRepoShaHits on $null returns 0 and does not throw' ($thrown -eq '' -and $nUsable -eq 0 -and $res.RepoUnchecked.Count -eq 0) "thrown=$thrown usable=$nUsable"
$res = Invoke-ScrubScan -Repo $shipRepo
$thrown = ''
$nUsable = -1
try { $nUsable = Add-ScrubRepoShaHits $res @('', '   ') } catch { $thrown = "$_" }
Assert-Coord 'SG4 a blank repo entry is not usable and does not throw: reported unchecked by position (1 and 2)' ($thrown -eq '' -and $nUsable -eq 0 -and ($res.RepoUnchecked -join ',') -ceq '1,2') "thrown=$thrown usable=$nUsable unchecked=$($res.RepoUnchecked -join ',')"

# Every listed repo entry is accounted for: the usable ones run the rule, the
# others are reported by position, and the path is never printed.
$noRepo = Join-Path $tmp 'no-such-repo'
$res = Invoke-ScrubScan -Repo $shipRepo
$nUsable = Add-ScrubRepoShaHits $res @($privRepo, $noRepo)
Assert-Coord 'SG4 one good and one mistyped repo entry: the good one finds its hits and the mistyped one (position 2) is reported unchecked' ($nUsable -eq 1 -and @(Get-ScrubHitsOf $res 'ref.txt' $hexRuleName).Count -eq 3 -and ($res.RepoUnchecked -join ',') -ceq '2') "usable=$nUsable unchecked=$($res.RepoUnchecked -join ',')"
$res = Invoke-ScrubScan -Repo $shipRepo
$nUsable = Add-ScrubRepoShaHits $res @($noRepo, $privRepo)
Assert-Coord 'SG4 a mistyped first entry is reported unchecked as position 1, and the good second one still finds its hits' ($nUsable -eq 1 -and @(Get-ScrubHitsOf $res 'ref.txt' $hexRuleName).Count -eq 3 -and ($res.RepoUnchecked -join ',') -ceq '1') "usable=$nUsable unchecked=$($res.RepoUnchecked -join ',')"
$plainSub = Join-Path $privRepo 'plain-sub'
[void][IO.Directory]::CreateDirectory($plainSub)
$res = Invoke-ScrubScan -Repo $shipRepo
$nUsable = Add-ScrubRepoShaHits $res @($plainSub)
Assert-Coord 'SG4 a plain folder inside a repo is not the top level of a repo: not usable, reported unchecked, no hit' ($nUsable -eq 0 -and ($res.RepoUnchecked -join ',') -ceq '1' -and @(Get-ScrubHitsOf $res 'ref.txt' $hexRuleName).Count -eq 0) "usable=$nUsable unchecked=$($res.RepoUnchecked -join ',')"
$res = Invoke-ScrubScan -Repo $shipRepo
$nUsable = Add-ScrubRepoShaHits $res @($privRepo + [System.IO.Path]::DirectorySeparatorChar)
Assert-Coord 'SG4 a repo entry written with a trailing separator is still the top level of the repo' ($nUsable -eq 1 -and $res.RepoUnchecked.Count -eq 0 -and @(Get-ScrubHitsOf $res 'ref.txt' $hexRuleName).Count -eq 3) "usable=$nUsable unchecked=$($res.RepoUnchecked -join ',')"
# A path with a space and a trailing separator: the lookup's git -C must still
# get the whole path (a native call quoted it as "...\" and found nothing).
$spaced = Join-Path $tmp 'listed repo copy'
[void](Get-CoordGitOut $tmp @('clone', '-q', $privRepo, $spaced))
$spaced = Get-ScrubGitSpelling $spaced
$res = Invoke-ScrubScan -Repo $shipRepo
$nUsable = Add-ScrubRepoShaHits $res @($spaced + [System.IO.Path]::DirectorySeparatorChar)
Assert-Coord 'SG4 a repo entry with a space and a trailing separator is usable and its commits are found' ($nUsable -eq 1 -and $res.RepoUnchecked.Count -eq 0 -and @(Get-ScrubHitsOf $res 'ref.txt' $hexRuleName).Count -eq 3) "usable=$nUsable unchecked=$($res.RepoUnchecked -join ',') hits=$(@(Get-ScrubHitsOf $res 'ref.txt' $hexRuleName).Count)"
if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
    $res = Invoke-ScrubScan -Repo $shipRepo
    $nUsable = Add-ScrubRepoShaHits $res @($privRepo.ToUpperInvariant())
    Assert-Coord 'SG4 on Windows a repo entry spelled in other letter case is still the top level of the repo' ($nUsable -eq 1 -and $res.RepoUnchecked.Count -eq 0) "usable=$nUsable unchecked=$($res.RepoUnchecked -join ',')"
}
else { Write-CoordUnchecked 'SG4 a repo entry spelled in other letter case is still the top level' 'paths compare exactly off Windows, so the row does not apply' }
$res = Invoke-ScrubScan -Repo $shipRepo
$rr = Invoke-ScrubRepoRule $res ($privRepo + ';' + $noRepo)
Assert-Coord 'SG4 the repo rule with a good and a mistyped entry: RAN, 2 listed, 1 usable, entry 2 unchecked' ($rr.Verdict -ceq 'RAN' -and $rr.Listed -eq 2 -and $rr.Usable -eq 1 -and (@($rr.Unchecked) -join ',') -ceq '2') "verdict=$($rr.Verdict) listed=$($rr.Listed) usable=$($rr.Usable) unchecked=$(@($rr.Unchecked) -join ',')"
$res = Invoke-ScrubScan -Repo $shipRepo
$rr = Invoke-ScrubRepoRule $res $noRepo
Assert-Coord 'SG4 the repo rule with only a mistyped entry: UNCHECKED, 1 listed, 0 usable, entry 1 unchecked' ($rr.Verdict -ceq 'UNCHECKED' -and $rr.Listed -eq 1 -and $rr.Usable -eq 0 -and (@($rr.Unchecked) -join ',') -ceq '1') "verdict=$($rr.Verdict) listed=$($rr.Listed) usable=$($rr.Usable) unchecked=$(@($rr.Unchecked) -join ',')"

# ---- SG5: the shipped files ----------------------------------------------------
Write-Host "(SG5) the files git would ship"
$denyPath = [string]$env:TRACKSTEWARD_SCRUB_DENYLIST
$denylist = Read-ScrubDenylist $denyPath
$res = Invoke-ScrubScan -Repo $repoRoot -SelfRel $selfName -Denylist $denylist
# Never UNCHECKED: a scan that found nothing to scan would pass every rule below.
Assert-Coord 'SG5 discovery: git lists the files that would ship (a failure or an empty list fails this suite)' $res.DiscoveryOk $res.Reason
if ($res.DiscoveryOk) {
    Assert-Coord "SG5 the scan reads files (found $($res.Scanned.Count) versions, $($res.Utf16.Count) UTF-16 and $($res.Utf32.Count) UTF-32 decoded, $($res.IndexScanned.Count) index versions)" ($res.Scanned.Count -gt 0)
    Assert-Coord "SG5 every listed entry is accounted for (listed $($res.Listed): $($res.WorkTreeScanned) scanned + $($res.WorkTreeNul) NUL + $($res.Unreadable.Count) unreadable + $($res.Skipped.Count) skipped)" ((Get-ScrubAccounted $res) -eq $res.Listed) "accounted=$(Get-ScrubAccounted $res)"
    Assert-Coord 'SG5 a test file is scanned, and this file is scanned with its pattern rules skipped' ($res.Scanned.Contains('tests/run.ps1') -and $res.Scanned.Contains($selfName) -and $res.PatternSkipped.Contains($selfName) -and @($res.PatternSkipped | Where-Object { $_ -cne $selfName -and $_ -cne ($selfName + ' (index)') }).Count -eq 0) "skipped=$($res.PatternSkipped -join '|')"
    if ($res.NulFiles.Count -gt 0) {
        Write-ScrubUnchecked 'SG5 files with NUL bytes and no BOM' ("not scanned: " + ($res.NulFiles -join ', '))
    }
    if ($res.Unreadable.Count -gt 0) {
        Write-ScrubUnchecked 'SG5 files the suite could not read' ("not scanned: " + ($res.Unreadable -join ', '))
    }
    if ($res.Skipped.Count -gt 0) {
        Write-ScrubUnchecked 'SG5 listed entries that are not a leaf file (a dangling symlink, a submodule, a path absent from the work tree)' ("not scanned: " + ($res.Skipped -join ', '))
    }
    if ($res.IndexFailed.Count -gt 0) {
        Write-ScrubUnchecked 'SG5 index versions git cat-file could not read' ("not scanned: " + ($res.IndexFailed -join ', '))
    }
    Write-Host "(SG5) no private content in the shipped files"
    foreach ($rule in $scrubRules) {
        $hs = @($res.Hits | Where-Object { $_.Rule -ceq $rule.Name } | ForEach-Object { Format-ScrubHit $_ })
        Assert-Coord "SG5 no '$($rule.Name)' in $($res.Scanned.Count) file versions" ($hs.Count -eq 0) ($hs -join "`n")
    }
    if ($denylist) {
        $hs = @($res.Hits | Where-Object { $_.Rule -like 'denylist entry*' } | ForEach-Object { Format-ScrubHit $_ })
        Assert-Coord "SG5 no denylist entry ($($denylist.Count) entries) in $($res.Scanned.Count) file versions, this file included" ($hs.Count -eq 0) ($hs -join "`n")
    }
    # An unset variable is UNCHECKED here, never an error (SG4 runs this call on
    # unset and blank values). A listed path that is not a repo top level is
    # UNCHECKED too, by its position in the list: the path is never printed.
    $repoRule = Invoke-ScrubRepoRule $res ([string]$env:TRACKSTEWARD_SCRUB_REPOS)
    if ($repoRule.Verdict -ceq 'RAN') {
        $hs = @($res.Hits | Where-Object { $_.Rule -ceq $hexRuleName } | ForEach-Object { Format-ScrubHit $_ })
        Assert-Coord "SG5 no hex token that is a commit of the $($repoRule.Usable) listed repo(s) in $($res.Scanned.Count) file versions" ($hs.Count -eq 0) ($hs -join "`n")
    }
    else {
        Write-ScrubUnchecked 'SG5 commit-sha rows' 'TRACKSTEWARD_SCRUB_REPOS is unset, or none of its entries is the top level of a git repo'
    }
    foreach ($pos in @($repoRule.Unchecked)) {
        Write-ScrubUnchecked "SG5 commit-sha rule, listed repo entry $pos of $($repoRule.Listed)" 'not the top level of a git repo (a mistyped path, a plain folder inside a repo, or not a folder)'
    }
}
if (-not $denylist) {
    Write-ScrubDenylistAbsent 'SG5 denylist rows'
}

Write-Host "(SG6) the history scan: every blob a range of commits adds or changes, and every commit message"
function Add-ScrubTestCommit([string]$Repo, [string]$Message) {
    # no line-ending warning from git: the fixture helper reads stderr as an error
    Invoke-HookTestGit $Repo @('config', 'core.autocrlf', 'false')
    Invoke-HookTestGit $Repo @('add', '-A')
    Invoke-HookTestGit $Repo @('commit', '--quiet', '--allow-empty', '-m', $Message)
}
$hRepo = New-ScrubTestRepo 'hist' @{ 'base.txt' = $hitLine + "`n" }
Add-ScrubTestCommit $hRepo 'base'
$hBase = Get-CoordGitOut $hRepo @('rev-parse', 'HEAD')
# a private line added in one commit and removed in the next: the tip is clean, the history is not
Set-CoordFile $hRepo 'gone.md' ($hitLine + "`nzzbeta in it`n")
Add-ScrubTestCommit $hRepo 'adds a file with private content'
Remove-Item -LiteralPath (Join-Path $hRepo 'gone.md')
Set-CoordFile $hRepo 'clean.txt' "nothing here`n"
Add-ScrubTestCommit $hRepo 'removes it again'
# the scrub suite itself holds the patterns: only its denylist hits count
Set-CoordFile $hRepo 'tests/scrub.test.ps1' ($hitLine + " zzbeta`n")
Add-ScrubTestCommit $hRepo 'a self file'
Set-CoordFile $hRepo 'clean.txt' ("nothing here`n" + $hitLine + "`n")
Add-ScrubTestCommit $hRepo 'modifies a file'
Add-ScrubTestCommit $hRepo ('message with ' + $hitLine)
$res = Invoke-ScrubHistory -Repo $hRepo -Range ($hBase + '..HEAD') -SelfRel $selfName -Denylist @('zzbeta')
Assert-Coord 'SG6 discovery works on a real range' $res.DiscoveryOk $res.Reason
$tipRes = Invoke-ScrubScan -Repo $hRepo -SelfRel $selfName
Assert-Coord 'SG6 control: the tip of that repo has no hit in gone.md (the file is gone), so only a history scan can see it' (@(Get-ScrubHitsOf $tipRes 'gone.md').Count -eq 0)
$goneHits = @($res.Hits | Where-Object { $_.File -like 'gone.md*' })
Assert-Coord 'SG6 a blob added and removed inside the range is scanned: the path rule and the denylist both hit' (@($goneHits | Where-Object { $_.Rule -ceq $pathRule }).Count -eq 1 -and @($goneHits | Where-Object { $_.Rule -like 'denylist entry*' }).Count -eq 1) (($res.Hits | ForEach-Object { Format-ScrubHit $_ }) -join "`n")
Assert-Coord 'SG6 a blob a commit of the range modifies (not only adds) is scanned' (@($res.Hits | Where-Object { $_.File -like 'clean.txt*' -and $_.Rule -ceq $pathRule }).Count -eq 1)
Assert-Coord 'SG6 a file of the base commit is not scanned (outside the range, before any merge from outside it)' (@($res.Hits | Where-Object { $_.File -like 'base.txt*' }).Count -eq 0 -and -not ($res.Scanned | Where-Object { $_ -like 'base.txt*' }))
Assert-Coord 'SG6 the self file is scanned for the denylist only' (@($res.Hits | Where-Object { $_.File -like "$selfName*" -and $_.Rule -ceq $pathRule }).Count -eq 0 -and @($res.Hits | Where-Object { $_.File -like "$selfName*" -and $_.Rule -like 'denylist entry*' }).Count -eq 1)
Assert-Coord 'SG6 a commit message is scanned (named by its commit, not by a file)' (@($res.Hits | Where-Object { $_.File -like 'commit message *' -and $_.Rule -ceq $pathRule }).Count -eq 1)
$badRes = Invoke-ScrubHistory -Repo $hRepo -Range 'no-such-rev..HEAD'
Assert-Coord 'SG6 a range git cannot resolve is not a pass: discovery fails with a reason' ((-not $badRes.DiscoveryOk) -and $badRes.Reason)
$emptyRes = Invoke-ScrubHistory -Repo $hRepo -Range 'HEAD..HEAD'
Assert-Coord 'SG6 an empty range is not a pass either: discovery fails' ((-not $emptyRes.DiscoveryOk) -and $emptyRes.Reason)
# a merge: the commits of a merged branch are in the range
Invoke-HookTestGit $hRepo @('checkout', '--quiet', '-b', 'side', $hBase)
Set-CoordFile $hRepo 'side.md' ($hitLine + "`n")
Add-ScrubTestCommit $hRepo 'side work'
Invoke-HookTestGit $hRepo @('checkout', '--quiet', 'main')
Invoke-HookTestGit $hRepo @('merge', '--quiet', '--no-ff', '-m', 'merge side', 'side')
$mRes = Invoke-ScrubHistory -Repo $hRepo -Range ($hBase + '..HEAD')
Assert-Coord 'SG6 a branch merged inside the range is scanned' (@($mRes.Hits | Where-Object { $_.File -like 'side.md*' }).Count -eq 1)
# a merge commit is read too: its message, and content that only the merge itself brings in
Invoke-HookTestGit $hRepo @('checkout', '--quiet', '-b', 'side2', $hBase)
Set-CoordFile $hRepo 'side2.txt' "side two`n"
Add-ScrubTestCommit $hRepo 'side two work'
Invoke-HookTestGit $hRepo @('checkout', '--quiet', 'main')
# git prints "stopped before committing as requested" on stderr, which the fixture helper would read as a failure
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try { & git -C $hRepo merge --quiet --no-ff --no-commit side2 2>&1 | Out-Null } finally { $ErrorActionPreference = $prevEap }
Assert-Coord 'SG6 control: the merge of side2 started (no error, a merge is in progress)' (($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath (Join-Path $hRepo '.git/MERGE_HEAD'))) ''
Set-CoordFile $hRepo 'only-in-merge.txt' ($hitLine + "`n")
Invoke-HookTestGit $hRepo @('add', '-A')
Invoke-HookTestGit $hRepo @('commit', '--quiet', '-m', ('merge side2 ' + $hitLine))
Assert-Coord 'SG6 control: that commit is a merge (two parents)' (@((Get-CoordGitOut $hRepo @('rev-list', '--parents', '-n', '1', 'HEAD')) -split ' ').Count -eq 3) ''
Remove-Item -LiteralPath (Join-Path $hRepo 'only-in-merge.txt')
Add-ScrubTestCommit $hRepo 'drops the merge-only file again'
$mRes2 = Invoke-ScrubHistory -Repo $hRepo -Range ($hBase + '..HEAD')
Assert-Coord 'SG6 a merge commit message is scanned' (@($mRes2.Hits | Where-Object { $_.File -like 'commit message *' -and $_.Rule -ceq $pathRule }).Count -eq 2) (($mRes2.Hits | ForEach-Object { Format-ScrubHit $_ }) -join "`n")
Assert-Coord 'SG6 a blob that only a merge commit brings in (removed again afterwards) is scanned' (@($mRes2.Hits | Where-Object { $_.File -like 'only-in-merge.txt*' }).Count -eq 1)
# a type change: a symlink replaced by a regular file with a hit (the symlink is made in the index, which needs no privilege)
Invoke-HookTestGit $hRepo @('config', 'core.symlinks', 'true')
$tgtFile = Join-Path $tmp 'link-target.txt'
[System.IO.File]::WriteAllText($tgtFile, 'target.txt', $coordUtf8)
$linkBlob = Get-CoordGitOut $hRepo @('hash-object', '-w', $tgtFile)
Invoke-HookTestGit $hRepo @('update-index', '--add', '--cacheinfo', ('120000,' + $linkBlob + ',tlink'))
Invoke-HookTestGit $hRepo @('commit', '--quiet', '-m', 'adds a symlink')
$typeBase = Get-CoordGitOut $hRepo @('rev-parse', 'HEAD')
Set-CoordFile $hRepo 'tlink' ($hitLine + "`n")
Add-ScrubTestCommit $hRepo 'turns the symlink into a regular file'
Assert-Coord 'SG6 control: that commit is a type change (T)' ((Get-CoordGitOut $hRepo @('diff-tree', '-r', '--no-commit-id', '--name-status', 'HEAD')) -match '^T\s+tlink') ''
$tRes = Invoke-ScrubHistory -Repo $hRepo -Range ($typeBase + '..HEAD')
Assert-Coord 'SG6 the new blob of a type change (symlink to regular file) is scanned' (@($tRes.Hits | Where-Object { $_.File -like 'tlink*' -and $_.Rule -ceq $pathRule }).Count -eq 1) (($tRes.Hits | ForEach-Object { Format-ScrubHit $_ }) -join "`n")
# a range that starts with a dash is a revision, never an option
$dashRes = Invoke-ScrubHistory -Repo $hRepo -Range '--all'
Assert-Coord 'SG6 a range that starts with a dash is refused by git, not run as an option' ((-not $dashRes.DiscoveryOk) -and $dashRes.Reason) ''
# A range of several revisions (what the pre-push gate passes: the pushed tips,
# then ^<sha> for each commit the remote already has).
$tipNow = Get-CoordGitOut $hRepo @('rev-parse', 'HEAD')
$multiRes = Invoke-ScrubHistory -Repo $hRepo -Range ("$tipNow ^$typeBase")
Assert-Coord 'SG6 a range of several revisions split on spaces ("<tip> ^<base>") is the same range as <base>..<tip>' ($multiRes.DiscoveryOk -and $multiRes.Commits -eq $tRes.Commits -and @($multiRes.Hits | Where-Object { $_.File -like 'tlink*' }).Count -eq 1) "ok=$($multiRes.DiscoveryOk) reason=$($multiRes.Reason) commits=$($multiRes.Commits)/$($tRes.Commits)"
$emptyOk = Invoke-ScrubHistory -Repo $hRepo -Range "$tipNow ^$tipNow" -AllowEmpty
Assert-Coord 'SG6 -AllowEmpty: a range with no commit is discovered, with 0 commits (the gate pushes a tag or a ref name alone)' ($emptyOk.DiscoveryOk -and $emptyOk.Commits -eq 0) "ok=$($emptyOk.DiscoveryOk) reason=$($emptyOk.Reason)"
# File names, author and committer lines, and tags (F7).
$idBase = $tipNow
Set-CoordFile $hRepo 'plan-zzbeta.md' "clean`n"
Add-ScrubTestCommit $hRepo 'a clean message'
Remove-Item -LiteralPath (Join-Path $hRepo 'plan-zzbeta.md')
Add-ScrubTestCommit $hRepo 'drops it'
$nameRes = Invoke-ScrubHistory -Repo $hRepo -Range ($idBase + '..HEAD') -Denylist @('zzbeta')
Assert-Coord 'SG6 a file name in the history that holds a denylist entry hits, named by its blob, not by the name' (@($nameRes.Hits | Where-Object { $_.File -like 'file name of blob *' -and $_.Rule -ceq 'denylist entry 1' }).Count -eq 1 -and @($nameRes.Hits | Where-Object { $_.File -like '*zzbeta*' }).Count -eq 0) (($nameRes.Hits | ForEach-Object { Format-ScrubHit $_ }) -join "`n")
$idBase = Get-CoordGitOut $hRepo @('rev-parse', 'HEAD')
$leakIdent = 'Zzbeta Q <q@example.invalid>'
Invoke-HookTestGit $hRepo @('commit', '--quiet', '--allow-empty', '--author', $leakIdent, '-m', 'clean message')
$idRes = Invoke-ScrubHistory -Repo $hRepo -Range ($idBase + '..HEAD') -Denylist @('zzbeta')
Assert-Coord 'SG6 an author line that holds a denylist entry hits (no allowed identity given), the clean committer line does not' (@($idRes.Hits | Where-Object { $_.File -like 'author of commit *' -and $_.Rule -ceq 'denylist entry 1' }).Count -eq 1 -and @($idRes.Hits | Where-Object { $_.File -like 'committer of commit *' }).Count -eq 0) (($idRes.Hits | ForEach-Object { Format-ScrubHit $_ }) -join "`n")
$idRes = Invoke-ScrubHistory -Repo $hRepo -Range ($idBase + '..HEAD') -Denylist @('zzbeta') -AllowIdent @($leakIdent)
Assert-Coord 'SG6 an author line that is exactly an allowed identity is let through' (@($idRes.Hits | Where-Object { $_.File -like 'author of commit *' }).Count -eq 0 -and $idRes.IdentAllowed -eq 1) "allowed=$($idRes.IdentAllowed) $(($idRes.Hits | ForEach-Object { Format-ScrubHit $_ }) -join ';')"
$idRes = Invoke-ScrubHistory -Repo $hRepo -Range ($idBase + '..HEAD') -Denylist @('zzbeta') -AllowIdent @('Zzbeta Q <other@example.invalid>')
Assert-Coord 'SG6 the allowed name with another email is not an allowed identity: it hits' (@($idRes.Hits | Where-Object { $_.File -like 'author of commit *' }).Count -eq 1) (($idRes.Hits | ForEach-Object { Format-ScrubHit $_ }) -join "`n")
$idBase = Get-CoordGitOut $hRepo @('rev-parse', 'HEAD')
Invoke-HookTestGit $hRepo @('-c', 'user.name=Zzbeta C', '-c', 'user.email=c@example.invalid', 'commit', '--quiet', '--allow-empty', '-m', 'clean message')
$idRes = Invoke-ScrubHistory -Repo $hRepo -Range ($idBase + '..HEAD') -Denylist @('zzbeta')
Assert-Coord 'SG6 a committer line that holds a denylist entry hits' (@($idRes.Hits | Where-Object { $_.File -like 'committer of commit *' -and $_.Rule -ceq 'denylist entry 1' }).Count -eq 1) (($idRes.Hits | ForEach-Object { Format-ScrubHit $_ }) -join "`n")
# An annotated tag: its name and message are read, the tagger line as an identity.
Invoke-HookTestGit $hRepo @('tag', '-a', 'rel-zzbeta', '-m', 'a clean tag message', 'HEAD')
Invoke-HookTestGit $hRepo @('tag', '-a', 'rel-msg', '-m', ('release ' + $hitLine), 'HEAD')
$tagHead = Get-CoordGitOut $hRepo @('rev-parse', 'HEAD')
$tagRes = Invoke-ScrubHistory -Repo $hRepo -Range "refs/tags/rel-zzbeta refs/tags/rel-msg ^$tagHead" -Denylist @('zzbeta') -AllowEmpty
Assert-Coord 'SG6 an annotated tag is read with no new commit: its name hits the denylist and its message the path rule' ($tagRes.DiscoveryOk -and $tagRes.Tags -eq 2 -and @($tagRes.Hits | Where-Object { $_.File -like 'tag *' -and $_.Rule -ceq 'denylist entry 1' }).Count -eq 1 -and @($tagRes.Hits | Where-Object { $_.File -like 'tag *' -and $_.Rule -ceq $pathRule }).Count -eq 1) "ok=$($tagRes.DiscoveryOk) reason=$($tagRes.Reason) tags=$($tagRes.Tags) $(($tagRes.Hits | ForEach-Object { Format-ScrubHit $_ }) -join ';')"
$blobSha = Get-CoordGitOut $hRepo @('hash-object', '-w', $tgtFile)
Invoke-HookTestGit $hRepo @('tag', 'on-blob', $blobSha)
Invoke-HookTestGit $hRepo @('tag', '-a', 'on-blob-a', '-m', 'x', $blobSha)
$bRes = Invoke-ScrubHistory -Repo $hRepo -Range 'refs/tags/on-blob' -AllowEmpty
$baRes = Invoke-ScrubHistory -Repo $hRepo -Range 'refs/tags/on-blob-a' -AllowEmpty
Assert-Coord 'SG6 a tag on a blob, plain or annotated, is not a pass: discovery fails, naming what it points at' ((-not $bRes.DiscoveryOk) -and $bRes.Reason -match 'blob' -and (-not $baRes.DiscoveryOk) -and $baRes.Reason -match 'blob') "plain: $($bRes.Reason) | annotated: $($baRes.Reason)"
# Ref names (the gate passes the remote ref names a push writes).
$refRes = Invoke-ScrubHistory -Repo $hRepo -Range "$tagHead ^$tagHead" -AllowEmpty -Denylist @('zzbeta') -RefNames @('refs/heads/fine', 'refs/heads/fix-zzbeta')
Assert-Coord 'SG6 a pushed ref name that holds a denylist entry hits, named by its position' (@($refRes.Hits | Where-Object { $_.File -ceq 'pushed ref name 2' -and $_.Rule -ceq 'denylist entry 1' }).Count -eq 1 -and @($refRes.Hits | Where-Object { $_.File -ceq 'pushed ref name 1' }).Count -eq 0) (($refRes.Hits | ForEach-Object { Format-ScrubHit $_ }) -join "`n")
$tagTwice = Invoke-ScrubHistory -Repo $hRepo -Range "refs/tags/rel-zzbeta refs/tags/rel-zzbeta ^$tagHead" -Denylist @('zzbeta') -AllowEmpty
Assert-Coord 'SG6 a tag named twice is read once: one tag, one tagger line' ($tagTwice.Tags -eq 1 -and $tagTwice.Idents -eq 1) "tags=$($tagTwice.Tags) idents=$($tagTwice.Idents)"
# A commit or tag object written byte for byte (git hash-object --literally), so
# a header, a NUL or an encoding git would not write itself can be tested.
function New-ScrubRawObject([string]$Repo, [string]$Type, [byte[]]$Bytes) {
    $f = Join-Path $tmp ('raw-' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
    [System.IO.File]::WriteAllBytes($f, $Bytes)
    return Get-CoordGitOut $Repo @('hash-object', '-t', $Type, '-w', '--literally', $f)
}
function Get-ScrubAscii([string]$S) { return [byte[]][System.Text.Encoding]::ASCII.GetBytes($S) }
$rawTree = Get-CoordGitOut $hRepo @('rev-parse', 'HEAD^{tree}')
$rawParent = Get-CoordGitOut $hRepo @('rev-parse', 'HEAD')
$rawHead = "tree $rawTree`nparent $rawParent`n"
$rawIdent = "R Q <r@example.invalid> 1700000000 +0000`n"
function Invoke-ScrubRaw([byte[]]$Bytes, [string[]]$Allow = $null) {
    $sha = New-ScrubRawObject $hRepo 'commit' $Bytes
    return Invoke-ScrubHistory -Repo $hRepo -Range "$sha ^$rawParent" -Denylist @('zzbeta', $nfc) -AllowIdent $Allow
}
$r = Invoke-ScrubRaw (Get-ScrubAscii ($rawHead + 'author ' + $rawIdent + 'committer ' + $rawIdent + "x-note zzbeta`n`nclean message`n"))
Assert-Coord 'SG6 an extra commit header (not author or committer) that holds an entry hits' (@($r.Hits | Where-Object { $_.File -like 'commit headers of *' -and $_.Rule -ceq 'denylist entry 1' }).Count -eq 1) "ok=$($r.DiscoveryOk) $($r.Reason) $(($r.Hits | ForEach-Object { Format-ScrubHit $_ }) -join ';')"
$r = Invoke-ScrubRaw ([byte[]]((Get-ScrubAscii ($rawHead + 'author ' + $rawIdent + 'committer ' + $rawIdent + "`nclean")) + @(0) + (Get-ScrubAscii " zzbeta`n")))
Assert-Coord 'SG6 a commit message with a NUL byte cannot be read whole: it is listed as a NUL text, which a -History run fails' ($r.NulFiles.Count -eq 1 -and $r.NulFiles[0] -like 'commit message *') "nul=$($r.NulFiles -join '|') $(($r.Hits | ForEach-Object { Format-ScrubHit $_ }) -join ';')"
$r = Invoke-ScrubRaw (Get-ScrubAscii ($rawHead + 'author ' + $rawIdent + 'committer ' + $rawIdent + "encoding UTF-16LE`n`nmsg zzbeta`n"))
Assert-Coord 'SG6 a commit message is read as stored, whatever its encoding header says (git would re-encode it away)' (@($r.Hits | Where-Object { $_.File -like 'commit message *' -and $_.Rule -ceq 'denylist entry 1' }).Count -eq 1) (($r.Hits | ForEach-Object { Format-ScrubHit $_ }) -join ';')
$r = Invoke-ScrubRaw ([byte[]]((Get-ScrubAscii ($rawHead + 'author Zzcaf')) + @(0xE9) + (Get-ScrubAscii (' <l@example.invalid> 1700000000 +0000' + "`n" + 'committer ' + $rawIdent + "`nclean message`n"))))
Assert-Coord 'SG6 an author line in Windows-1252 (not valid UTF-8) is read as Windows-1252 too and hits' (@($r.Hits | Where-Object { $_.File -like 'author of commit *' -and $_.Rule -ceq 'denylist entry 2' }).Count -ge 1) (($r.Hits | ForEach-Object { Format-ScrubHit $_ }) -join ';')
$r = Invoke-ScrubRaw (Get-ScrubAscii ($rawHead + 'author Pub Q <pub@example.invalid>zzbeta 1700000000 +0000' + "`n" + 'committer ' + $rawIdent + "`nclean message`n")) @('Pub Q <pub@example.invalid>')
Assert-Coord 'SG6 an allowed identity followed by other text before the date is not let through: the rest hits' (@($r.Hits | Where-Object { $_.File -like 'author of commit *' -and $_.Rule -ceq 'denylist entry 1' }).Count -eq 1) "allowed=$($r.IdentAllowed) $(($r.Hits | ForEach-Object { Format-ScrubHit $_ }) -join ';')"
$tagBytes = [byte[]]((Get-ScrubAscii ("object $rawParent`ntype commit`ntag rel-raw`ntagger " + $rawIdent + "`nrelease zzcaf")) + @(0xE9) + (Get-ScrubAscii "`n"))
$rawTag = New-ScrubRawObject $hRepo 'tag' $tagBytes
$r = Invoke-ScrubHistory -Repo $hRepo -Range "$rawTag ^$rawParent" -Denylist @('zzbeta', $nfc) -AllowEmpty
Assert-Coord 'SG6 an annotated tag message in Windows-1252 (not valid UTF-8) is read as Windows-1252 too and hits' (@($r.Hits | Where-Object { $_.File -like 'tag *' -and $_.Rule -ceq 'denylist entry 2' }).Count -eq 1) "ok=$($r.DiscoveryOk) $($r.Reason) $(($r.Hits | ForEach-Object { Format-ScrubHit $_ }) -join ';')"
# git replace: the scan must read the objects a push sends, not their replacements.
Invoke-HookTestGit $hRepo @('checkout', '--quiet', '-b', 'replaced', $rawParent)
Set-CoordFile $hRepo 'rep.txt' "zzbeta here`n"
Add-ScrubTestCommit $hRepo 'msg zzbeta'
$repOrig = Get-CoordGitOut $hRepo @('rev-parse', 'HEAD')
Set-CoordFile $hRepo 'rep.txt' "clean`n"
Invoke-HookTestGit $hRepo @('add', '-A')
Invoke-HookTestGit $hRepo @('commit', '--quiet', '--amend', '-m', 'clean')
$repClean = Get-CoordGitOut $hRepo @('rev-parse', 'HEAD')
Invoke-HookTestGit $hRepo @('replace', $repOrig, $repClean)
try { $r = Invoke-ScrubHistory -Repo $hRepo -Range "$repOrig ^$rawParent" -Denylist @('zzbeta') }
finally { Invoke-HookTestGit $hRepo @('replace', '-d', $repOrig); Invoke-HookTestGit $hRepo @('checkout', '--quiet', 'main') }
Assert-Coord 'SG6 a commit with a replace ref is read as itself: its message and its blob hit' (@($r.Hits | Where-Object { $_.File -like 'commit message *' }).Count -eq 1 -and @($r.Hits | Where-Object { $_.File -like 'rep.txt*' }).Count -eq 1) (($r.Hits | ForEach-Object { Format-ScrubHit $_ }) -join ';')

# the real range, when the run names one
if ($History) {
    # Allowed identities: exact "Name <email>" author, committer and tagger
    # lines (the public ones), from the private file this variable names. Unset:
    # every identity line is scanned. Set to a missing or empty file: a broken
    # setup, a FAIL.
    $identVar = [string]$env:TRACKSTEWARD_SCRUB_ALLOW_IDENT
    $allowIdent = Read-ScrubIdentAllow $identVar
    if ($identVar -and -not $allowIdent) { Assert-Coord 'SG6 allowed identities: TRACKSTEWARD_SCRUB_ALLOW_IDENT is set, but the file is missing or holds no entry' $false 'fix the path or the file' }
    $pushRefList = @($PushRefs -split '\s+' | Where-Object { $_ })
    $real = Invoke-ScrubHistory -Repo $repoRoot -Range $History -SelfRel $selfName -Denylist $denylist -AllowIdent $allowIdent -RefNames $pushRefList -AllowEmpty:$AllowEmptyRange
    Assert-Coord "SG6 history discovery: git lists the commits of $History" $real.DiscoveryOk $real.Reason
    if ($real.DiscoveryOk) {
        Write-Host "(SG6) no private content in $($real.Commits) commits, $($real.Tags) annotated tags, $($real.Idents) identity lines ($($real.IdentAllowed) allowed), $($pushRefList.Count) pushed ref names and $($real.Blobs) blob versions of $History"
        if (-not $identVar) { Write-Host '(SG6) TRACKSTEWARD_SCRUB_ALLOW_IDENT is unset: every author, committer and tagger line is scanned, none is let through' }
        if ($real.NonUtf8.Count -gt 0) { Write-Host "(SG6) read as Windows-1252 too (not valid UTF-8): $($real.NonUtf8.Count) version(s)" }
        # The one id that earlier versions of coord-handoff.ps1 wrote in a comment as an example of an
        # id followed by a note: 1234abcd is not a session id, and the tip no longer holds it. Only this exact text,
        # in a blob of that script or in the message of the commit that explains it, is let through.
        $placeholderIds = @($idPrefix + '1234abcd')
        foreach ($rule in $scrubRules) {
            $hs = @($real.Hits | Where-Object { $_.Rule -ceq $rule.Name -and -not (($rule.Name -ceq 'desktop session id') -and ($placeholderIds -ccontains $_.Text) -and (($_.File -clike 'scripts/coord-handoff.ps1 (blob *') -or ($_.File -ceq 'commit message 2c3b5fc'))) } | ForEach-Object { Format-ScrubHit $_ })
            Assert-Coord "SG6 no '$($rule.Name)' in the history" ($hs.Count -eq 0) ($hs -join "`n")
        }
        if ($denylist) {
            $hs = @($real.Hits | Where-Object { $_.Rule -like 'denylist entry*' } | ForEach-Object { Format-ScrubHit $_ })
            if (@($real.Hits | Where-Object { $_.Rule -like 'denylist entry*' -and $_.File -match '^(author|committer|tagger) of ' }).Count -gt 0) {
                $hs += 'an identity line hit: if it is a public identity of the maintainer, add its exact "Name <email>" to the file TRACKSTEWARD_SCRUB_ALLOW_IDENT names'
            }
            Assert-Coord "SG6 no denylist entry ($($denylist.Count) entries) in the history" ($hs.Count -eq 0) ($hs -join "`n")
        }
        else { Write-ScrubDenylistAbsent 'SG6 history denylist rows' }
        $histRepoRule = Invoke-ScrubRepoRule $real ([string]$env:TRACKSTEWARD_SCRUB_REPOS)
        if ($histRepoRule.Verdict -ceq 'RAN') {
            $hs = @($real.Hits | Where-Object { $_.Rule -ceq $hexRuleName } | ForEach-Object { Format-ScrubHit $_ })
            Assert-Coord "SG6 no hex token that is a commit of the $($histRepoRule.Usable) listed repo(s) in the history" ($hs.Count -eq 0) ($hs -join "`n")
        }
        else { Write-ScrubUnchecked 'SG6 history commit-sha rows' 'TRACKSTEWARD_SCRUB_REPOS is unset, or none of its entries is the top level of a git repo' }
        # A -History run is a gate (the release gate, the pre-push gate): what it
        # could not read is a FAIL, never an UNCHECKED that lets the push through.
        Assert-Coord 'SG6 no history blob with NUL bytes and no BOM (a -History run reads every blob or fails)' ($real.NulFiles.Count -eq 0) ('not scanned: ' + ($real.NulFiles -join ', '))
        Assert-Coord 'SG6 nothing in the history git could not read (blobs, trees, commit messages, identity lines)' ($real.Unreadable.Count -eq 0) ('not scanned: ' + ($real.Unreadable -join ', '))
    }
}
else { Write-ScrubUnchecked 'SG6 the real history' 'no -History range was given (the release gate is -History origin/main..HEAD right after a git fetch, or TRACKSTEWARD_SCRUB_HISTORY set to it)' }

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-CoordUncheckedSummary
Write-Host ""
Write-Host "Passed: $script:coordPass  Failed: $script:coordFail"
if ($script:coordFail -gt 0) { exit 1 }
exit 0
