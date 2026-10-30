# Tests for scripts/coord-common.ps1, the helpers shared by the coordinate
# scripts. The helpers are dot-sourced into this process; the git rows build
# throwaway repos through the hook fixture.
# Ported from the private coordinate toolkit (coord-common.test.ps1), 2026-10-18.
#
# Dropped rows: none. Every row of the private suite is ported; where the
# ruling differs, the row is changed (C12: the session token, 8 private cases
# became 54 cases for the "only ids bind" rule) or the example data is made
# generic (paths, names).
# The real-profile fence (C21) lists and hashes the user's real index folder
# (COORD_INDEX_DIR as it was before this run, else $HOME/.claude/coordination):
# every file and folder in it except the sessions/ subfolder, which a live
# scope guard on the host writes to at random.
# Changed expectation: C7 no longer expects a "v2 field notes" section (the
# public template has none) and expects a "## Queue" section between Owed
# checks and Decisions.
# New C1 rows: Get-CoordStamp, Expand-CoordNow, Test-CoordTypedTime (the {now}
# helpers coord-set.ps1 uses).
# New rows: C12 Test-CoordWindows; the session-token cases of the id rule (a
# bare uuid, an upper-case id or uuid lower-cased, a 7-hex id, a uuid with a
# wrong group length, every plain name -> none, two pairs of backticks, ...), and
# the two rows that pin the id spaces: local_<8 hex> and local_<the same 8 hex>-<rest
# of the uuid> are one token, a bare uuid and local_ plus that uuid are two.
#
#   C1  globs: `*` stays in one folder, `**` crosses folders, `dir/` and
#       `dir/**` cover everything below, `?` is one character, matching is
#       case-sensitive, `!glob` excludes, comma/semicolon/space lists split;
#       a path holding a control character (LF, CR) is never in scope, and the
#       anchors are \z (a path, sha or date ending in LF is refused)
#   C2  the Tracks table: columns by header name in any order, escaped pipes,
#       backticks, comments before the table, a missing Scope column and a
#       ragged row throw naming the ledger, no Tracks section -> no rows
#   C3  check rollup: CheckRun and StatusContext shapes, pending and failing
#       states, an item of unknown shape fails, and so does a null item
#   C4  changed files: a rename lists both paths; a bad ref is not "no files"
#   C5  conflict preview: clean, conflicted paths, failed (bad ref)
#   C6  ledger Repo cell -> repo: full path (trailing separator, case), unique
#       leaf, shared leaf -> ambiguous, no match
#   C7  the real ledger-template.md parses (no rows), and a row added under its
#       Tracks header parses into its cells (C7b), so template and parser
#       cannot drift
#   C8  gh pr view validation: each missing or malformed field is named
#   C9  ledger path: the main checkout's, also from a linked worktree
#   C10 Test-CoordRowTerminal: MERGED or DONE as the first word (upper case,
#       whole word) is terminal; NOT MERGED, "running; round 1 DONE",
#       "REPORT in", lower case, DONEish, MERGED-ish and empty are live
#   C11 the optional Model column: read by name, '' when absent; a row of the
#       template's Tracks table that lacks the Model cell is ragged and throws
#   The scope guard helpers. The whole run uses a scratch COORD_INDEX_DIR and
#   ends by comparing the real index folder with its digest from the start:
#   C12 Get-CoordIndexDir, Get-CoordIndexPath, Get-CoordSessionToken,
#       Test-CoordWindows
#   C13 Invoke-CoordGitBounded: success, failure, UTF-8, a hung git (stub
#       git.cmd first on PATH), a child holding stdout, a timeout of 0 ms
#   C14 Get-CoordMainRoot -Git: every git call goes through the invoker
#   C15 Test-CoordLedgerCanonical: main checkout, stale worktree copy, case and
#       separators, wrong date, no repo, UNC, git unavailable
#   C16 Get-CoordIndexedLedgers: torn line, CRLF, blanks, duplicates, invalid
#       line, 8 distinct, the 64 KiB bound, -Path (missing, directory, writer)
#   C17 Register-CoordLedger: add, repeat, stale copy, torn index, full index,
#       64 KiB, lock held, two racing processes, four racing for two places
#   C18 Test-CoordLedgerTrusted: the trust cases (tracked, case variant, 8.3
#       alias, junctions, a directory, failing git ls-files)
#   C19 Read-CoordLedgerTracksBounded: 16 KiB, 78 KiB, 900 KiB, after the cap,
#       cut by the cap, no end before EOF, missing column, ragged row
#   C20 Test-CoordInScope -IgnoreCase
#   C21 the real index folder is byte-unchanged at the end of the run
#   C22 -TimeoutMs on Get-CoordIndexedLedgers and Read-CoordLedgerTracksBounded:
#       a normal read under a bound is unchanged; 0 or negative is TimedOut, no read
#   C23 Read-CoordStreamBounded on a pipe whose read never completes (TimedOut
#       within the bound, no hang), on a stream with data, and each reader passing
#       its -TimeoutMs on to it (a wrapper records the value)
#   C24 (S2) Get-CoordLedgerDate (anchored with z), ConvertTo-CoordRootedPath,
#       Test-CoordLocalFixedPath, ConvertTo-CoordArgLine (a backslash before a
#       final LF is not doubled)
#   C25 (F5) Test-CoordGitFloor: 2.37.9 refused, 2.38.0 and 2.45.1.windows.1 ok,
#       garbage and empty refused (-VersionText), and a stub git.cmd on PATH
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\scripts\coord-common.test.ps1 [-ScriptPath <mutant copy of coord-common.ps1>]
#       (-CommonPath is an alias of -ScriptPath)
# Exit: 0 = all passed, 1 = a case failed.
param([Alias('CommonPath')][string]$ScriptPath = '')

$testsDir = Split-Path -Parent $PSScriptRoot
$fixturesDir = Join-Path $testsDir 'fixtures'
try { . (Join-Path $fixturesDir 'hook-test-fixture.ps1') } catch { Write-Error "could not load hook-test-fixture.ps1: $_"; exit 1 }
Clear-HookRunnerGitEnv
. (Join-Path $fixturesDir 'coord-test-fixture.ps1')
if (-not $ScriptPath) { $ScriptPath = Join-Path $coordScriptsDir 'coord-common.ps1' }
$CommonPath = [System.IO.Path]::GetFullPath($ScriptPath)
. $CommonPath
$ErrorActionPreference = 'Stop'

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('coord-common-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory($root)
# Nothing in this run may reach the real index folder.
$realIndexBefore = Get-CoordRealIndexDigest
$null = New-CoordScratchIndex $root

Write-Host "(C1) globs"
$g = Split-CoordScope @('docs/**, src/*.txt;  !docs/secret/** README.md', '`tests/`')
Assert-Coord 'C1 split: five globs plus tests/ -> tests/**' (($g -join '|') -ceq 'docs/**|src/*.txt|!docs/secret/**|README.md|tests/**') ($g -join '|')
$cases = @(
    @('docs/a.md', @('docs/**'), $true),
    @('docs/x/y/z.md', @('docs/**'), $true),
    @('docs', @('docs/**'), $false),
    @('src/app.txt', @('src/*.txt'), $true),
    @('src/sub/app.txt', @('src/*.txt'), $false),
    @('src/sub/app.txt', @('src/**/*.txt'), $true),
    @('src/app.txt', @('src/**/*.txt'), $true),
    @('a.md', @('?.md'), $true),
    @('ab.md', @('?.md'), $false),
    @('x/a.md', @('?.md'), $false),
    @('Docs/a.md', @('docs/**'), $false),
    @('docs/secret/k.md', @('docs/**', '!docs/secret/**'), $false),
    @('docs/public/k.md', @('docs/**', '!docs/secret/**'), $true),
    @('docs/a.md', @('!docs/secret/**'), $false),
    @('a+b(1).md', @('a+b(1).md'), $true),
    @('docs\win.md', @('docs/*.md'), $true),
    @('anything/at/all', @('**'), $true)
)
foreach ($c in $cases) {
    $got = Test-CoordInScope $c[0] $c[1]
    Assert-Coord "C1 '$($c[0])' vs $($c[1] -join ',') -> $($c[2])" ($got -eq $c[2])
}
Assert-Coord "C1 './x/' becomes 'x/**'" ((Split-CoordScope @('./x/')) -join '' -ceq 'x/**')

# Anchor and control characters (ported from the private toolkit): the anchor must
# be \z. A '$' also matches before a final LF, so a path ending in LF used to pass a literal scope.
# With \z alone, '*' and '?' (compiled to [^/]* and [^/]) match an LF while '.' in '.*' does not, so a
# '!' exclusion failed OPEN for a path ending in LF, and an LF in the MIDDLE of a path was never
# excluded. A path holding a control character (LF, CR, ...) is never in scope.
$lf = [string][char]10
$cr = [string][char]13
foreach ($c in @(
        @(('README.md' + $lf), @('README.md'), $false),
        @(('docs/a.md' + $lf), @('docs/a.md'), $false),
        @(('src/app.txt' + $lf), @('src/*.txt'), $false),
        @(('docs/a.md' + $lf), @('docs/**'), $false),
        @('README.md', @('README.md'), $true),
        @(('docs/a.md' + $lf), @('docs/*', '!docs/a.md'), $false),
        @(('src/private/a.md' + $lf), @('src/**/*', '!src/private/**'), $false),
        @(('secret/x.md' + $lf), @('**/*', '!secret/**'), $false),
        @(('secret/x' + $lf + 'y'), @('**/*', '!secret/**'), $false),
        @(('docs/a.md' + $cr), @('docs/*', '!docs/a.md'), $false),
        @(('docs/a' + $lf + '.md'), @('docs/*'), $false),
        @('docs/b.md', @('docs/*', '!docs/a.md'), $true),
        @('docs/a.md', @('docs/*', '!docs/a.md'), $false),
        @('secret/x.md', @('**/*', '!secret/**'), $false)
    )) {
    Assert-Coord "C1 LF: $($c[0] -replace "`n",'<LF>') vs $($c[1] -join ',') -> $($c[2])" ((Test-CoordInScope $c[0] $c[1]) -eq $c[2])
    Assert-Coord "C1 LF -IgnoreCase: $($c[0] -replace "`n",'<LF>') vs $($c[1] -join ',') -> $($c[2])" ((Test-CoordInScope $c[0] $c[1] -IgnoreCase) -eq $c[2])
}
Assert-Coord 'C1 LF: the converted regex ends in \z, not $' ((ConvertTo-CoordGlobRegex 'a.md').EndsWith('\z'))
Assert-Coord 'C1 LF: Test-CoordSha40 refuses a sha ending in LF' (-not (Test-CoordSha40 (('a' * 40) + $lf)))
Assert-Coord 'C1 LF: Test-CoordSha40 still accepts 40 hex' (Test-CoordSha40 ('a' * 40))
$cl = Test-CoordLedgerCanonical -Path (Join-Path $root 'x.md') -Date ('2026-03-05' + $lf)
Assert-Coord 'C1 LF: Test-CoordLedgerCanonical refuses a date ending in LF' (-not $cl.Ok -and "$($cl.Error)".Contains('not yyyy-MM-dd')) "$($cl.Error)"

# The stamp and the {now} placeholder coord-set.ps1 writes a time with.
$t0 = [datetime]::new(2026, 10, 22, 9, 5, 0)
Assert-Coord 'C1 Get-CoordStamp: HH:mm, two digits, from the given time' ((Get-CoordStamp $t0) -ceq '09:05')
Assert-Coord 'C1 Expand-CoordNow: every {now} becomes the stamp; other braces stay' ((Expand-CoordNow 'a {now} b {now} {x} {NOW}' $t0) -ceq 'a 09:05 b 09:05 {x} {NOW}')
Assert-Coord 'C1 Test-CoordTypedTime: a typed H:mm / HH:mm is found, with or without {now} beside it, also glued to letters or seconds, and an id or port with a colon' ((Test-CoordTypedTime 'ACK 08:40') -and (Test-CoordTypedTime 'at 9:05.') -and (Test-CoordTypedTime '{now} then 14:10 Sonnet') -and (Test-CoordTypedTime '9:05pm') -and (Test-CoordTypedTime '09:12Z') -and (Test-CoordTypedTime 'T10:22') -and (Test-CoordTypedTime 'ACK08:40') -and (Test-CoordTypedTime '09:12:30') -and (Test-CoordTypedTime 'F3:12') -and (Test-CoordTypedTime '80:80'))
$fwColon = [string][char]0xFF1A
Assert-Coord 'C1 Test-CoordTypedTime: a time with the fullwidth colon (U+FF1A) is found, also glued to letters' ((Test-CoordTypedTime ('at 10' + $fwColon + '22')) -and (Test-CoordTypedTime ('ACK9' + $fwColon + '05pm')))
Assert-Coord 'C1 Test-CoordTypedTime: 10h22 is found, also glued to letters' ((Test-CoordTypedTime 'at 10h22') -and (Test-CoordTypedTime 'ACK08h40.'))
Assert-Coord 'C1 Test-CoordTypedTime: 10.22 is found, also glued to letters or at the end of a sentence' ((Test-CoordTypedTime 'at 10.22') -and (Test-CoordTypedTime 'done at 9.05.') -and (Test-CoordTypedTime 'T10.22'))
Assert-Coord 'C1 Test-CoordTypedTime: a longer dotted or h number is no time (1.10.22, 110.22, 1.5.3, 100h22, 10h225, 10.225)' (-not ((Test-CoordTypedTime 'v1.10.22') -or (Test-CoordTypedTime 'ip 110.22') -or (Test-CoordTypedTime 'v1.5.3') -or (Test-CoordTypedTime '100h22') -or (Test-CoordTypedTime '10h225') -or (Test-CoordTypedTime '10.225')))
Assert-Coord 'C1 Test-CoordTypedTime: no time in {now}, 1.5, v1:2, 10:420 or a file:line reference' (-not ((Test-CoordTypedTime 'merged {now}') -or (Test-CoordTypedTime '1.5 days') -or (Test-CoordTypedTime 'v1:2') -or (Test-CoordTypedTime '10:420 is no time') -or (Test-CoordTypedTime 'see coord-brief.ps1:96') -or (Test-CoordTypedTime 'x.ps1:80') -or (Test-CoordTypedTime 'at coord-log.ps1:217')))

Write-Host "(C2) Tracks table"
$ledger = Join-Path $root 'ledger.md'
[System.IO.File]::WriteAllText($ledger, @"
# Coordination ledger

## Baseline

| Repo | origin/main |
|------|-------------|
| x | y |

## Tracks

<!-- comment before the table -->

| Status | Branch | Repo | Scope | Track | PR |
|--------|--------|------|-------|-------|----|
| live | ``worktree-a`` | C:\src\a | ``docs/**``, src/*.txt | A | #3 |
| idle | b\|c | B | x/** | B | |

## Merge slots

| not | a | tracks | row |
"@, $coordUtf8)
$rows = @(Read-CoordLedgerTracks $ledger)
Assert-Coord 'C2 two rows' ($rows.Count -eq 2) "$($rows.Count)"
Assert-Coord 'C2 columns found by name, backticks removed' ($rows[0].Branch -ceq 'worktree-a' -and $rows[0].Repo -ceq 'C:\src\a' -and $rows[0].Scope -ceq 'docs/**, src/*.txt' -and $rows[0].PR -ceq '#3')
Assert-Coord 'C2 escaped pipe stays in its cell' ($rows[1].Branch -ceq 'b|c')
Assert-Coord 'C2 a missing optional column reads empty' ($rows[0].Session -ceq '' -and $rows[0].Cwd -ceq '')
[System.IO.File]::WriteAllText($ledger, "## Tracks`n| Repo | Branch |`n|--|--|`n| a | b |`n", $coordUtf8)
$threw = $null
try { $null = Read-CoordLedgerTracks $ledger } catch { $threw = "$_" }
Assert-Coord 'C2 a missing Scope column throws, naming the ledger and the column' ($threw -and $threw.Contains($ledger) -and $threw.Contains("'Scope'")) "$threw"
[System.IO.File]::WriteAllText($ledger, "## Tracks`n| Repo | Branch | Scope |`n|--|--|--|`n| a | b |`n", $coordUtf8)
$threw = $null
try { $null = Read-CoordLedgerTracks $ledger } catch { $threw = "$_" }
Assert-Coord 'C2 a ragged row throws' ($threw -and $threw.Contains('cells')) "$threw"
[System.IO.File]::WriteAllText($ledger, "# no tracks here`n", $coordUtf8)
Assert-Coord 'C2 no Tracks section -> no rows' (@(Read-CoordLedgerTracks $ledger).Count -eq 0)

Write-Host "(C3) check rollup"
$roll = @(
    [pscustomobject](New-CoordCheckRun 'ok'),
    [pscustomobject](New-CoordCheckRun 'skipped' 'COMPLETED' 'SKIPPED'),
    [pscustomobject](New-CoordCheckRun 'neutral' 'COMPLETED' 'NEUTRAL'),
    [pscustomobject](New-CoordCheckRun 'running' 'IN_PROGRESS' ''),
    [pscustomobject](New-CoordCheckRun 'queued' 'QUEUED' ''),
    [pscustomobject](New-CoordCheckRun 'bad' 'COMPLETED' 'FAILURE'),
    [pscustomobject](New-CoordCheckRun 'cancelled' 'COMPLETED' 'CANCELLED'),
    [pscustomobject](New-CoordStatusContext 'ctx-ok' 'SUCCESS'),
    [pscustomobject](New-CoordStatusContext 'ctx-pending' 'PENDING'),
    [pscustomobject](New-CoordStatusContext 'ctx-expected' 'EXPECTED'),
    [pscustomobject](New-CoordStatusContext 'ctx-error' 'ERROR'),
    [pscustomobject]@{ name = 'weird'; foo = 1 }
)
$s = Get-CoordCheckSummary $roll
Assert-Coord 'C3 pass = ok, skipped, neutral, ctx-ok' ((($s.Pass | Sort-Object) -join ',') -ceq 'ctx-ok,neutral,ok,skipped') ($s.Pass -join ',')
Assert-Coord 'C3 pending = running, queued, ctx-pending, ctx-expected' ((($s.Pending | Sort-Object) -join ',') -ceq 'ctx-expected,ctx-pending,queued,running') ($s.Pending -join ',')
Assert-Coord 'C3 fail = bad, cancelled, ctx-error, weird (unknown shape)' ((($s.Fail | ForEach-Object { ($_ -split '=')[0] } | Sort-Object) -join ',') -ceq 'bad,cancelled,ctx-error,weird') ($s.Fail -join ',')
$n = Get-CoordCheckSummary @($null)
Assert-Coord 'C3 a null item fails (dropping it would read as no checks)' ($n.Fail.Count -eq 1 -and $n.Pass.Count -eq 0 -and $n.Pending.Count -eq 0) ($n.Fail -join ',')
$n = Get-CoordCheckSummary @([pscustomobject](New-CoordCheckRun 'ok'), $null)
Assert-Coord 'C3 a null item beside a pass still fails' ($n.Fail.Count -eq 1 -and $n.Pass.Count -eq 1) ($n.Fail -join ',')
$e = Get-CoordCheckSummary @()
Assert-Coord 'C3 empty rollup -> nothing in any list' ($e.Pass.Count + $e.Pending.Count + $e.Fail.Count -eq 0)

Write-Host "(C4, C5) changed files and conflict preview"
$fx = New-CoordFixture $root 'c4'
$mv = New-CoordBranch $fx 'mv' -Move @('src/app.txt', 'docs/app.txt')
Invoke-HookTestGit $fx.Launch @('fetch', '--quiet', 'origin')
$cf = Get-CoordChangedFiles $fx.Launch 'origin/main' $mv
Assert-Coord 'C4 ok' $cf.Ok
Assert-Coord 'C4 a rename lists the old and the new path' ((($cf.Files | Sort-Object) -join ',') -ceq 'docs/app.txt,src/app.txt') ($cf.Files -join ',')
# A non-ASCII name (git C-quotes it by default; Windows forbids '"' in names).
Initialize-CoordConsole
$oddName = 'docs/gr' + [string][char]0x00FC + 'n file.md'
$odd = New-CoordBranch $fx 'odd' -Write @{ $oddName = "q`n" }
Invoke-HookTestGit $fx.Launch @('fetch', '--quiet', 'origin')
$cfOdd = Get-CoordChangedFiles $fx.Launch 'refs/remotes/origin/main' $odd
Assert-Coord 'C4 a non-ASCII path comes back as itself, not C-quoted' (($cfOdd.Files -join ',') -ceq $oddName) ($cfOdd.Files -join ',')
$bad = Get-CoordChangedFiles $fx.Launch 'origin/main' 'no-such-ref'
Assert-Coord 'C4 a bad ref is a failure, not an empty list' (-not $bad.Ok -and $bad.Error)
$a = New-CoordBranch $fx 'conf-a' -Write @{ 'src/app.txt' = "line1`nA`nline3`n" }
$null = Merge-CoordIntoMain $fx $a
$b = New-CoordBranch $fx 'conf-b' -Write @{ 'src/app.txt' = "line1`nB`nline3`n"; 'docs/b.md' = "b`n" } -From "$a~1"
$c = New-CoordBranch $fx 'clean-c' -Write @{ 'docs/c.md' = "c`n" }
Invoke-HookTestGit $fx.Launch @('fetch', '--quiet', 'origin')
$p = Get-CoordConflictPreview $fx.Launch 'origin/main' $b
Assert-Coord 'C5 conflicts on src/app.txt only' ($p.State -eq 'conflicts' -and ($p.Files -join ',') -ceq 'src/app.txt') "$($p.State) $($p.Files -join ',')"
$p = Get-CoordConflictPreview $fx.Launch 'origin/main' $c
Assert-Coord 'C5 a clean branch is clean' ($p.State -eq 'clean')
$p = Get-CoordConflictPreview $fx.Launch 'origin/main' 'no-such-ref'
Assert-Coord 'C5 a bad ref is failed, not clean' ($p.State -eq 'failed')

Write-Host "(C6) ledger Repo cell -> repo"
$repos = @('C:\src\alpha', 'C:\src\beta', 'D:\Other\beta', 'C:\src\tools')
$r = Resolve-CoordLedgerRepo 'c:\src\alpha\' $repos
Assert-Coord 'C6 full path, trailing separator and case ignored' ($r.Match -eq 'C:\src\alpha' -and -not $r.Ambiguous)
$r = Resolve-CoordLedgerRepo 'tools' $repos
Assert-Coord 'C6 a unique leaf matches' ($r.Match -eq 'C:\src\tools')
$r = Resolve-CoordLedgerRepo 'beta' $repos
Assert-Coord 'C6 a shared leaf is ambiguous and matches nothing' ($null -eq $r.Match -and $r.Ambiguous)
$r = Resolve-CoordLedgerRepo 'D:\Other\beta' $repos
Assert-Coord 'C6 a full path picks one of two same-leaf repos' ($r.Match -eq 'D:\Other\beta')
$r = Resolve-CoordLedgerRepo 'Nope' $repos
Assert-Coord 'C6 no match' ($null -eq $r.Match -and -not $r.Ambiguous)

Write-Host "(C7) the real ledger template"
$tpl = Join-Path $coordTemplatesDir 'ledger-template.md'
$threw = $null
try { $rows = @(Read-CoordLedgerTracks $tpl) } catch { $threw = "$_" }
Assert-Coord 'C7 ledger-template.md parses with no rows' (-not $threw -and $rows.Count -eq 0) "$threw"
$tplText = [System.IO.File]::ReadAllText($tpl)
$order = @('## Baseline', '## Tracks', '## Merge slots', '## Owed checks', '## Queue', '## Decisions', '## Findings', '## Log') | ForEach-Object { $tplText.IndexOf($_) }
$sorted = $true
for ($k = 0; $k -lt $order.Count; $k++) { if ($order[$k] -lt 0 -or ($k -gt 0 -and $order[$k] -le $order[$k - 1])) { $sorted = $false } }
Assert-Coord 'C7 template sections present, current state before the append-only ones' $sorted ($order -join ',')
# C7b: a row added under the template's own Tracks header parses into its
# cells (zero rows alone would also pass with the Tracks section removed).
# The template has the optional Model column: nine cells.
$tplRow = '| T1 | C:\src\x | track-one | model-a high | C:\src\x | feat-x | docs/**, src/** | #1 | open |'
$tplLines = [System.Collections.Generic.List[string]]@($tplText -split "`r?`n")
$delim = -1
for ($k = 0; $k -lt $tplLines.Count; $k++) { if ($tplLines[$k] -match '^\|-+\|-+\|' -and $k -gt 0 -and $tplLines[$k - 1] -match '^\| Track \|') { $delim = $k; break } }
$tplCopy = Join-Path ([System.IO.Path]::GetTempPath()) ('coord-c7b-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.md')
$rows = @()
if ($delim -ge 0) {
    $tplLines.Insert($delim + 1, $tplRow)
    [System.IO.File]::WriteAllText($tplCopy, ($tplLines -join "`n"), $coordUtf8)
    try { $rows = @(Read-CoordLedgerTracks $tplCopy) } catch { $rows = @() }
    Remove-Item -LiteralPath $tplCopy -Force -ErrorAction SilentlyContinue
}
Assert-Coord 'C7b a row under the template Tracks header parses into Repo, Branch and Scope' ($rows.Count -eq 1 -and $rows[0].Repo -ceq 'C:\src\x' -and $rows[0].Branch -ceq 'feat-x' -and $rows[0].Scope -ceq 'docs/**, src/**') "delim=$delim rows=$($rows.Count)"
Assert-Coord 'C7b ... and its Model cell' ($rows.Count -eq 1 -and $rows[0].PSObject.Properties['Model'] -and $rows[0].Model -ceq 'model-a high') "rows=$($rows.Count)"
# C11: a row of the old eight-cell shape under the nine-column template header
# is ragged: refused, never read with its cells shifted one column.
$threw = $null
if ($delim -ge 0) {
    $tplLines[$delim + 1] = '| T1 | C:\src\x | track-one | C:\src\x | feat-x | docs/**, src/** | #1 | open |'
    [System.IO.File]::WriteAllText($tplCopy, ($tplLines -join "`n"), $coordUtf8)
    try { [void]@(Read-CoordLedgerTracks $tplCopy) } catch { $threw = "$_" }
    Remove-Item -LiteralPath $tplCopy -Force -ErrorAction SilentlyContinue
}
Assert-Coord 'C11 a row without the Model cell under the template header is ragged and throws' ($threw -and $threw.Contains('cells')) "delim=$delim threw=$threw"
$mFile = Join-Path $root 'model.md'
[System.IO.File]::WriteAllText($mFile, "## Tracks`n| Track | Repo | Branch | Scope |`n|---|---|---|---|`n| A | C:\src\y | b | x/** |`n", $coordUtf8)
$mr = @(Read-CoordLedgerTracks $mFile)
Assert-Coord 'C11 no Model column: Model reads empty' ($mr.Count -eq 1 -and $mr[0].PSObject.Properties['Model'] -and $mr[0].Model -ceq '') "$($mr | Out-String)"

Write-Host "(C8) gh pr view validation"
$sha = 'a' * 40
$ok = ConvertFrom-Json (New-CoordPrJson -Number 1 -Head $sha -HeadRef 'b')
Assert-Coord 'C8 a valid open PR passes' ($null -eq (Test-CoordPrView $ok -Checks))
Assert-Coord 'C8 a valid open PR passes -Draft' ($null -eq (Test-CoordPrView $ok -Checks -Draft))
$nd = ConvertFrom-Json ('{"state":"OPEN","headRefOid":"' + $sha + '","headRefName":"b","baseRefName":"main","statusCheckRollup":[]}')
Assert-Coord 'C8 -Draft names a missing isDraft' ([string](Test-CoordPrView $nd -Checks -Draft) -match 'isDraft')
Assert-Coord 'C8 without -Draft a missing isDraft is not checked' ($null -eq (Test-CoordPrView $nd -Checks))
$bads = @(
    @('state missing', ('{"headRefOid":"' + $sha + '","headRefName":"b","baseRefName":"main","statusCheckRollup":[]}'), 'state'),
    @('short sha', (New-CoordPrJson -Number 1 -Head 'abc123' -HeadRef 'b'), 'headRefOid'),
    @('upper-case sha', (New-CoordPrJson -Number 1 -Head ('A' * 40) -HeadRef 'b'), 'headRefOid'),
    @('no headRefName', (New-CoordPrJson -Number 1 -Head $sha -HeadRef ''), 'headRefName'),
    @('no rollup', ('{"state":"OPEN","headRefOid":"' + $sha + '","headRefName":"b","baseRefName":"main"}'), 'statusCheckRollup'),
    @('rollup not a list', ('{"state":"OPEN","headRefOid":"' + $sha + '","headRefName":"b","baseRefName":"main","statusCheckRollup":{"x":1}}'), 'statusCheckRollup')
)
foreach ($b in $bads) {
    $why = Test-CoordPrView (ConvertFrom-Json $b[1]) -Checks
    Assert-Coord "C8 $($b[0]) -> names $($b[2])" ($why -and $why.Contains($b[2])) "$why"
}
$merged = ConvertFrom-Json (New-CoordPrJson -Number 1 -Head $sha -HeadRef 'b' -State 'MERGED')
Assert-Coord 'C8 MERGED without mergeCommit fails with -MergeCommit' ([string](Test-CoordPrView $merged -MergeCommit)).Contains('mergeCommit')
Assert-Coord 'C8 an array is not one PR' ($null -ne (Test-CoordPrView @($ok, $ok)))
Assert-Coord 'C8 -Fork passes a boolean isCrossRepository' ($null -eq (Test-CoordPrView $ok -Fork))
$noFork = ConvertFrom-Json ('{"state":"OPEN","headRefOid":"' + $sha + '","headRefName":"b","baseRefName":"main"}')
Assert-Coord 'C8 -Fork rejects a missing isCrossRepository' ([string](Test-CoordPrView $noFork -Fork)).Contains('isCrossRepository')
$strFork = ConvertFrom-Json ('{"state":"OPEN","headRefOid":"' + $sha + '","headRefName":"b","baseRefName":"main","isCrossRepository":"false"}')
Assert-Coord 'C8 -Fork rejects a string isCrossRepository' ([string](Test-CoordPrView $strFork -Fork)).Contains('isCrossRepository')

Write-Host "(C9) ledger path"
$fx9 = New-CoordFixture $root 'c9'
$wt = Join-Path $fx9.Base 'wt'
New-HookTestWorktree -Repo $fx9.Launch -Path $wt -Branch 'c9-wt'
$today = Get-CoordToday
$want = Join-Path $fx9.Launch ".claude\coordination\$today.md"
$fromMain = Get-CoordLedgerPath $fx9.Launch
$fromWt = Get-CoordLedgerPath $wt
Assert-Coord 'C9 from the main checkout' ([string]::Equals((ConvertTo-CoordFullPath $fromMain), (ConvertTo-CoordFullPath $want), 'OrdinalIgnoreCase')) "$fromMain"
Assert-Coord 'C9 from a linked worktree: still the main checkout' ([string]::Equals((ConvertTo-CoordFullPath $fromWt), (ConvertTo-CoordFullPath $want), 'OrdinalIgnoreCase')) "$fromWt"
Assert-Coord 'C9 outside a repo: null' ($null -eq (Get-CoordLedgerPath $root))
# --separate-git-dir: git lists the git dir as the main worktree, so only a
# directory in the main checkout resolves (to itself); a linked worktree: null.
$sepMain = Join-Path $root 'c9-sep-main'
$sepGit = Join-Path $root 'c9-sep-gitdir'
$sepWt = Join-Path $root 'c9-sep-wt'
$ErrorActionPreference = 'Continue'
& git -c init.defaultBranch=main init --quiet --separate-git-dir $sepGit $sepMain 2>$null | Out-Null
[System.IO.File]::WriteAllText((Join-Path $sepMain 'f.txt'), "f`n", $coordUtf8)
& git -C $sepMain add -A 2>$null | Out-Null
& git -C $sepMain -c user.name=t -c user.email=t@example.invalid -c core.hooksPath=NUL commit --quiet -m sep 2>$null | Out-Null
& git -C $sepMain worktree add --quiet -b c9-sep-wt $sepWt 2>$null | Out-Null
$ErrorActionPreference = 'Stop'
$m = Get-CoordMainRoot $sepMain
Assert-Coord 'C9 separate git dir, from the main checkout: itself' ($m -and [string]::Equals((ConvertTo-CoordFullPath $m), (ConvertTo-CoordFullPath $sepMain), 'OrdinalIgnoreCase')) "$m"
Assert-Coord 'C9 separate git dir, from a linked worktree: null' ($null -eq (Get-CoordMainRoot $sepWt)) "$(Get-CoordMainRoot $sepWt)"

Write-Host "(C10) Test-CoordRowTerminal"
$term = @(
    @('MERGED 1a2b3c4 13:05', $true), @('MERGED', $true), @('DONE', $true), @('DONE; report placed', $true),
    @('  DONE, closed', $true), @('MERGED (#66)', $true),
    @('NOT MERGED', $false), @('running; round 1 DONE', $false), @('REPORT in', $false), @('', $false),
    @('merged per gh', $false), @('Done', $false), @('DONEish', $false), @('MERGED-ish', $false), @('MERGEDX', $false),
    @('(from 2026-10-14) MERGED abc', $false)
)
foreach ($c in $term) {
    $got = $null
    try { $got = Test-CoordRowTerminal $c[0] } catch { $got = "threw: $_" }
    Assert-Coord "C10 '$($c[0])' -> $($c[1])" ($got -eq $c[1]) "$got"
}

# ===========================================================================
# Scope guard helpers (the ledger index and the bounded reads). Every case below
# uses the scratch COORD_INDEX_DIR set at the top; C21 checks that the real index
# folder was not touched.
# ===========================================================================
$d16 = '2026-10-16'

function ConvertTo-IdxBytes {
    param([string[]]$Lines, [string]$Nl = "`n", [bool]$Terminated = $true)
    $t = ($Lines -join $Nl)
    if ($Terminated -and $Lines.Count -gt 0) { $t += $Nl }
    return , $coordUtf8.GetBytes($t)
}
function Get-IdxText([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '<no file>' }
    return $coordUtf8.GetString([System.IO.File]::ReadAllBytes($Path))
}
function Join-IdxEntries($Result) { return (@($Result.Entries) -join '|') }
# Writes the index of $d16 in the current scratch index folder; returns its path.
function Set-IdxText([string]$Text) {
    $f = Get-CoordIndexPath -Date $d16
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $f))
    [System.IO.File]::WriteAllBytes($f, $coordUtf8.GetBytes($Text))
    return $f
}

# Git invokers handed to the -Git parameters. Plain scriptblocks that keep their
# settings in $global: (a closure could not see this script's functions).
#   $gitLogging  logs every call; delegates to Invoke-CoordGit, except that
#                stubLsMode 'fake' answers `ls-files` with stubLsCode/stubLsOut
#                and a non-empty stubTop answers `--show-toplevel`
#   $gitDead     every call fails (exit 128)
#   $gitUnc      answers as a repo whose main checkout is on a UNC share
$global:stubCalls = New-Object System.Collections.Generic.List[string]
$global:stubLsMode = 'real'
$global:stubLsCode = 0
$global:stubLsOut = @()
$global:stubTop = ''
$gitLogging = {
    param($Repo, $GitArgs)
    $global:stubCalls.Add(($GitArgs -join ' '))
    if ($global:stubLsMode -eq 'fake' -and (@($GitArgs) -contains 'ls-files')) {
        return [pscustomobject]@{ Code = $global:stubLsCode; Out = [string[]]@($global:stubLsOut) }
    }
    if ($global:stubTop -and (@($GitArgs) -contains '--show-toplevel')) {
        return [pscustomobject]@{ Code = 0; Out = [string[]]@($global:stubTop) }
    }
    return (Invoke-CoordGit $Repo $GitArgs)
}
$gitDead = {
    param($Repo, $GitArgs)
    $global:stubCalls.Add(($GitArgs -join ' '))
    return [pscustomobject]@{ Code = 128; Out = [string[]]@() }
}
$gitUnc = {
    param($Repo, $GitArgs)
    $global:stubCalls.Add(($GitArgs -join ' '))
    $j = $GitArgs -join ' '
    if ($j -eq 'worktree list --porcelain') {
        return [pscustomobject]@{ Code = 0; Out = [string[]]@('worktree //localhost/fxshare/repo', 'HEAD 0000000000000000000000000000000000000000', 'branch refs/heads/main') }
    }
    if ($j -like 'rev-parse*') { return [pscustomobject]@{ Code = 0; Out = [string[]]@('//localhost/fxshare/repo') } }
    return [pscustomobject]@{ Code = 128; Out = [string[]]@() }
}

Write-Host "(C12) index folder, index path, session token"
$scratchIdx = $env:COORD_INDEX_DIR
Assert-Coord 'C12 COORD_INDEX_DIR names the index folder, as a full path' ((Get-CoordIndexDir) -ceq [System.IO.Path]::GetFullPath($scratchIdx)) (Get-CoordIndexDir)
$env:COORD_INDEX_DIR = (Join-Path $root 'idx-env\sub\..\up')
Assert-Coord 'C12 ... dot segments resolved' ((Get-CoordIndexDir) -ceq [System.IO.Path]::GetFullPath((Join-Path $root 'idx-env\up'))) (Get-CoordIndexDir)
$env:COORD_INDEX_DIR = 'rel-idx'
Assert-Coord 'C12 ... a relative value becomes a full path' ((Get-CoordIndexDir) -ceq [System.IO.Path]::GetFullPath('rel-idx')) (Get-CoordIndexDir)
Remove-Item -LiteralPath 'Env:\COORD_INDEX_DIR' -ErrorAction SilentlyContinue
# Compared exactly (no GetFullPath on either side): on Windows the default is
# "$HOME\.claude\coordination", spelled that way.
$homeIdx = if (Test-CoordWindows) { "$HOME\.claude\coordination" } else { [System.IO.Path]::Combine($HOME, '.claude', 'coordination') }
Assert-Coord 'C12 unset: the default folder is $HOME/.claude/coordination, exactly' ((Get-CoordIndexDir) -ceq $homeIdx) "got '$(Get-CoordIndexDir)' expected '$homeIdx'"
$env:COORD_INDEX_DIR = $scratchIdx
$idxFull = [System.IO.Path]::GetFullPath($scratchIdx)
Assert-Coord 'C12 Get-CoordIndexPath -Date: <index folder>\<date>.ledgers' ((Get-CoordIndexPath -Date $d16) -ceq (Join-Path $idxFull ($d16 + '.ledgers'))) (Get-CoordIndexPath -Date $d16)
Assert-Coord 'C12 ... today by default' ((Get-CoordIndexPath) -ceq (Join-Path $idxFull ((Get-CoordToday) + '.ledgers'))) (Get-CoordIndexPath)
# The session token ("only ids bind"): a Session cell yields a token only when,
# after a trim and after one pair of surrounding backticks or double quotes is
# stripped, it is exactly ONE id: the desktop session prefix plus 8 or more hex
# digits, the prefix plus a uuid (8-4-4-4-12 hex digits), or a bare uuid. A
# prefixed id comes back as the prefix plus its LEADING hex run, lower-cased, so
# the prefix plus a uuid is the prefix plus the first 8 hex digits of the uuid:
# the short and the full form of one session are the same token. A bare uuid
# comes back as itself, lower-cased. Every plain name ('none', 'TBD', 'main',
# 'docs', 'S-One', a 64
# character name), an empty cell, two words, an id plus a note or a name, and two
# ids have no token ($null, strictly). Ids and the uuid are built at run time, so
# this file holds no id-shaped literal.
$idp = 'local_'
$uuid = 'abcd' + 'ef12' + [Guid]::NewGuid().ToString().Substring(8)
$uuidUp = $uuid.ToUpperInvariant()
$bt = '`'
$tokCases = @(
    @('an id of 8 hex digits comes back as written', ($idp + '1111aaaa'), ($idp + '1111aaaa')),
    @('an id of 12 hex digits comes back as written', ($idp + 'ab12cd34ef56'), ($idp + 'ab12cd34ef56')),
    @('an upper-case id comes back lower-cased', ($idp + 'AB12CD34EF56'), ($idp + 'ab12cd34ef56')),
    @('an id with spaces around it', ('  ' + $idp + '1111aaaa  '), ($idp + '1111aaaa')),
    @('a backticked id', ($bt + $idp + '1111aaaa' + $bt), ($idp + '1111aaaa')),
    @('a double-quoted upper-case id', ('"' + $idp + '1111AAAA"'), ($idp + '1111aaaa')),
    @('a bare uuid comes back as written', $uuid, $uuid),
    @('an upper-case uuid comes back lower-cased', $uuidUp, $uuid),
    @('a backticked uuid', ($bt + $uuid + $bt), $uuid),
    @('a double-quoted upper-case uuid', ('"' + $uuidUp + '"'), $uuid),
    @('the prefix plus a uuid is the prefix plus the uuid''s first 8 hex digits', ($idp + $uuid), ($idp + $uuid.Substring(0, 8))),
    @('the prefix plus an upper-case uuid is lower-cased the same way', ($idp + $uuidUp), ($idp + $uuid.Substring(0, 8))),
    @('a backticked prefix plus uuid', ($bt + $idp + $uuid + $bt), ($idp + $uuid.Substring(0, 8))),
    @('an id of only 7 hex digits', ($idp + 'abc1234'), $null),
    @('an id with non-hex characters', ($idp + 'zzzzzzzz'), $null),
    @('an id of 8 hex digits followed by a non-hex letter', ($idp + '1111aaaag'), $null),
    @('the prefix alone', $idp, $null),
    @('8 hex digits without the prefix', '1111aaaa', $null),
    @('an id plus a note', ($idp + '1111aaaa (the title)'), $null),
    @('a name before an id', ('s-one ' + $idp + '1111aaaa'), $null),
    @('a name after an id', ($idp + '1111aaaa s-one'), $null),
    @('two ids', ($idp + 'aaaaaaaa and ' + $idp + 'bbbbbbbb'), $null),
    @('two ids on two lines', ($idp + "aaaaaaaa`n" + $idp + 'bbbbbbbb'), $null),
    @('an id followed by a line feed and a word', ($idp + "1111aaaa`nx"), $null),
    @('two pairs of backticks around an id (one pair is stripped)', ($bt + $bt + $idp + '1111aaaa' + $bt + $bt), $null),
    @('a backtick and a double quote around an id', ($bt + $idp + '1111aaaa"'), $null),
    @('a uuid of 7-4-4-4-12 digits', $uuid.Substring(1), $null),
    @('a uuid of 8-4-4-4-11 digits', $uuid.Substring(0, 35), $null),
    @('a uuid of 8-4-4-4-13 digits', ($uuid + 'a'), $null),
    @('the prefix plus a uuid of 7-4-4-4-12 digits', ($idp + $uuid.Substring(1)), $null),
    @('the prefix plus a uuid of 8-4-4-4-13 digits', ($idp + $uuid + 'a'), $null),
    @('the prefix plus a uuid plus a note', ($idp + $uuid + ' (the title)'), $null),
    @('an upper-case prefix before 8 hex digits', ('LOCAL_' + '1111aaaa'), $null),
    @('a uuid of 8-5-4-4-12 digits', $uuid.Insert(9, 'a'), $null),
    @('32 hex digits without hyphens', $uuid.Replace('-', ''), $null),
    @('a uuid with a non-hex character', ('g' + $uuid.Substring(1)), $null),
    @('a uuid plus a note', ($uuid + ' (the title)'), $null),
    @('the name none', 'none', $null),
    @('the name TBD', 'TBD', $null),
    @('the name main', 'main', $null),
    @('the name docs', 'docs', $null),
    @('the name S-One', 'S-One', $null),
    @('the name s-one', 's-one', $null),
    @('a backticked name', ($bt + 's-one' + $bt), $null),
    @('a name with dots and digits', 'track.name_v2', $null),
    @('a name of 64 characters', ('a' * 64), $null),
    @('a name of 65 characters', ('a' * 65), $null),
    @('an empty cell', '', $null),
    @('only spaces', '   ', $null),
    @('two words', 's-one extra', $null),
    @('a name plus a note', 's-one (the title)', $null)
)
foreach ($c in $tokCases) {
    $got = Get-CoordSessionToken $c[1]
    $ok = if ($null -eq $c[2]) { $null -eq $got } else { $got -ceq $c[2] }
    Assert-Coord "C12 session token, $($c[0]) -> $(if ($null -eq $c[2]) { 'none' } else { 'the token (local_ plus the leading hex run, lower-cased; a bare uuid lower-cased)' })" $ok "cell '$($c[1])' got '$got'"
}
Assert-Coord 'C12 a null cell has no token' ($null -eq (Get-CoordSessionToken $null))
$tokShort = Get-CoordSessionToken ($idp + $uuid.Substring(0, 8))
$tokFull = Get-CoordSessionToken ($idp + $uuid)
Assert-Coord 'C12 one session, one token: local_<8 hex> and local_<the same 8 hex>-<rest of the uuid> give the same token' ($null -ne $tokShort -and $tokShort -ceq $tokFull) "short '$tokShort' full '$tokFull'"
$tokBare = Get-CoordSessionToken $uuid
Assert-Coord 'C12 separate id spaces: a bare uuid and local_ plus the same uuid give DIFFERENT tokens' ($null -ne $tokBare -and $null -ne $tokFull -and $tokBare -cne $tokFull) "bare '$tokBare' prefixed '$tokFull'"
$win = Test-CoordWindows
Assert-Coord 'C12 Test-CoordWindows is $true on Windows (the only platform this suite runs on)' ($win -is [bool] -and $win -eq $true) "got '$win'"

Write-Host "(C13) Invoke-CoordGitBounded"
$fx13 = New-CoordCanonRepo $root 'c13' -Commit
$r = Invoke-CoordGitBounded -Repo $fx13 -GitArgs @('rev-parse', '--is-inside-work-tree') -TimeoutMs 10000
Assert-Coord 'C13 a git call that succeeds: Code 0, its stdout in Out, not timed out' ($r.Code -eq 0 -and -not $r.TimedOut -and (@($r.Out) -join '') -ceq 'true') "code=$($r.Code) timedOut=$($r.TimedOut) out=$(@($r.Out) -join '|')"
$r = Invoke-CoordGitBounded -Repo $fx13 -GitArgs @('rev-parse', '--verify', 'refs/heads/no-such-branch') -TimeoutMs 10000
Assert-Coord 'C13 a git call that fails: its exit code, not timed out, stderr kept out of Out' ($r.Code -eq 128 -and -not $r.TimedOut -and (@($r.Out) -join '').Length -eq 0) "code=$($r.Code) timedOut=$($r.TimedOut) out=$(@($r.Out) -join '|')"
$odd = 'gr' + [string][char]0x00FC + 'n.md'
Set-CoordFile $fx13 $odd "x`n"
Invoke-HookTestGit $fx13 @('-c', 'core.autocrlf=false', 'add', '-A')
# A legacy console code page makes a decoder that trusts the console fail this row.
$prevCp = $null
try { $prevCp = [Console]::OutputEncoding; [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(437) } catch { }
try { $r = Invoke-CoordGitBounded -Repo $fx13 -GitArgs @('-c', 'core.quotepath=off', 'ls-files') -TimeoutMs 10000 }
finally { if ($prevCp) { try { [Console]::OutputEncoding = $prevCp } catch { } } }
Assert-Coord 'C13 stdout is decoded as UTF-8 (a non-ASCII file name comes back as itself)' (@($r.Out) -ccontains $odd) "out=$(@($r.Out) -join '|')"

function New-GitStub {
    param([string]$Name, [string[]]$BatLines)
    $dir = Join-Path $root ('gitstub-' + $Name)
    [void][IO.Directory]::CreateDirectory($dir)
    [System.IO.File]::WriteAllText((Join-Path $dir 'git.cmd'), (($BatLines -join "`r`n") + "`r`n"), [System.Text.Encoding]::ASCII)
    return $dir
}
# Processes whose command line holds any of $Needles (the stub's folder, or the
# unique -w value its ping child was given): what a stub leaves behind.
function Get-StubProcs([string[]]$Needles) {
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    return @($all | Where-Object { $cl = [string]$_.CommandLine; $cl -and (@($Needles | Where-Object { $cl.Contains($_) }).Count -gt 0) })
}
# Runs Invoke-CoordGitBounded with $StubDir first on PATH. Which = the git that
# PATH resolves to, so a row can show the stub (not the real git) was the one run.
function Invoke-GitBoundedWithStub {
    param([string]$StubDir, [string]$Repo, [string[]]$GitArgs, [int]$TimeoutMs)
    $prev = $env:PATH
    try {
        $env:PATH = $StubDir + [System.IO.Path]::PathSeparator + $prev
        $which = (Get-Command git -CommandType Application | Select-Object -First 1).Source
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-CoordGitBounded -Repo $Repo -GitArgs $GitArgs -TimeoutMs $TimeoutMs
        $sw.Stop()
    }
    finally { $env:PATH = $prev }
    return [pscustomobject]@{ R = $r; Ms = $sw.ElapsedMilliseconds; Which = $which }
}

$pingSleep = Get-Random -Minimum 700000 -Maximum 749999
$pingHeld = Get-Random -Minimum 750000 -Maximum 799999
$stubSleep = New-GitStub 'sleep' @('@echo off', "ping -n 11 -w $pingSleep 127.0.0.1 >nul", 'exit /b 0')
$stubHeld = New-GitStub 'held' @('@echo off', 'echo stub-output', ('start "" /b ping -n 11 -w ' + $pingHeld + ' 127.0.0.1'), 'exit /b 0')
$stubMark = New-GitStub 'mark' @('@echo off', 'echo ran> "%~dp0ran.txt"', 'exit /b 0')

$x = Invoke-GitBoundedWithStub $stubSleep $fx13 @('status') 2000
Assert-Coord 'C13 the stub git.cmd is the git first on PATH (the rows below run it)' ($x.Which -ieq (Join-Path $stubSleep 'git.cmd')) $x.Which
Assert-Coord 'C13 a git that sleeps 10 s: TimedOut, Code -1, back inside ~2.6 s for a 2 s bound' ($x.R.TimedOut -and $x.R.Code -eq -1 -and $x.Ms -ge 1800 -and $x.Ms -lt 3200) "timedOut=$($x.R.TimedOut) code=$($x.R.Code) ms=$($x.Ms)"
$left = @()
for ($k = 0; $k -lt 10; $k++) {
    $left = @(Get-StubProcs @($stubSleep, "-w $pingSleep "))
    if ($left.Count -eq 0) { break }
    Start-Sleep -Milliseconds 200
}
Assert-Coord 'C13 ... and no stub process (cmd.exe, ping.exe) is left running' ($left.Count -eq 0) (($left | ForEach-Object { "$($_.ProcessId) $($_.CommandLine)" }) -join "`n")
foreach ($l in $left) { Stop-Process -Id $l.ProcessId -Force -ErrorAction SilentlyContinue }

$x = Invoke-GitBoundedWithStub $stubHeld $fx13 @('status') 6000
Assert-Coord 'C13 a git that exits at once but leaves a child holding its stdout: returns promptly, Code 0, not timed out' ($x.Which -ieq (Join-Path $stubHeld 'git.cmd') -and $x.R.Code -eq 0 -and -not $x.R.TimedOut -and $x.Ms -lt 3500) "which=$($x.Which) code=$($x.R.Code) timedOut=$($x.R.TimedOut) ms=$($x.Ms)"
foreach ($l in @(Get-StubProcs @("-w $pingHeld "))) { Stop-Process -Id $l.ProcessId -Force -ErrorAction SilentlyContinue }

$ran = Join-Path $stubMark 'ran.txt'
$x = Invoke-GitBoundedWithStub $stubMark $fx13 @('status') 0
Start-Sleep -Milliseconds 1500
Assert-Coord 'C13 TimeoutMs 0: TimedOut, and git is not started' ($x.R.TimedOut -and -not (Test-Path -LiteralPath $ran)) "timedOut=$($x.R.TimedOut) ran=$(Test-Path -LiteralPath $ran)"
$x = Invoke-GitBoundedWithStub $stubMark $fx13 @('status') -5
Start-Sleep -Milliseconds 1500
Assert-Coord 'C13 a negative TimeoutMs: TimedOut, and git is not started' ($x.R.TimedOut -and -not (Test-Path -LiteralPath $ran)) "timedOut=$($x.R.TimedOut) ran=$(Test-Path -LiteralPath $ran)"
$x = Invoke-GitBoundedWithStub $stubMark $fx13 @('status') 10000
Assert-Coord 'C13 the same stub with a real bound does run (control for the two rows above)' ($x.R.Code -eq 0 -and -not $x.R.TimedOut -and (Test-Path -LiteralPath $ran)) "code=$($x.R.Code) timedOut=$($x.R.TimedOut) ran=$(Test-Path -LiteralPath $ran)"

Write-Host "(C14) Get-CoordMainRoot -Git"
$global:stubCalls.Clear()
$mPlain = Get-CoordMainRoot $fx13
$mVia = Get-CoordMainRoot $fx13 -Git $gitLogging
Assert-Coord 'C14 with an invoker: the same main root as without' ($mPlain -and $mVia -ceq $mPlain) "plain=$mPlain via=$mVia"
Assert-Coord 'C14 ... and git was asked through the invoker' (@($global:stubCalls | Where-Object { $_ -like 'worktree list*' }).Count -ge 1) ($global:stubCalls -join '|')
$global:stubCalls.Clear()
$mDead = Get-CoordMainRoot $fx13 -Git $gitDead
Assert-Coord 'C14 an invoker whose git fails: no main root, though the folder is a repo (nothing bypasses the invoker)' ($null -eq $mDead -and $global:stubCalls.Count -ge 1) "root=$mDead calls=$($global:stubCalls.Count)"

Write-Host "(C15) Test-CoordLedgerCanonical"
$repoA = New-CoordCanonRepo $root 'c15a' -Commit
$wtA = Join-Path $root 'c15a-wt'
New-HookTestWorktree -Repo $repoA -Path $wtA -Branch 'c15-wt'
$mainA = Get-CoordMainRoot $repoA
$ledA = New-CoordCanonLedger $repoA $d16
$staleA = Join-Path $wtA ".claude\coordination\$d16.md"
Set-CoordTextFile $staleA "# stale copy made when the worktree was created`n"
$c = Test-CoordLedgerCanonical -Path $ledA -Date $d16
Assert-Coord 'C15 the main checkout''s ledger of the date is canonical, and names itself' ($c.Ok -and $c.Canonical -ieq $ledA) "ok=$($c.Ok) canonical=$($c.Canonical) error=$($c.Error)"
$c = Test-CoordLedgerCanonical -Path $staleA -Date $d16
Assert-Coord 'C15 a stale copy in a linked worktree is not canonical' (-not $c.Ok) "ok=$($c.Ok)"
Assert-Coord 'C15 ... the error names the stale path and the canonical path' ($c.Canonical -ieq $ledA -and $c.Error -ceq ($staleA + " is not the canonical ledger; the coordinator's ledger is " + $c.Canonical)) "canonical=$($c.Canonical) error=$($c.Error)"
$variants = @(
    @('upper case', $ledA.ToUpperInvariant()),
    @('forward slashes', $ledA.Replace('\', '/')),
    @('dot segments', (Join-Path $mainA ".claude\coordination\..\coordination\$d16.md"))
)
foreach ($v in $variants) {
    $c = Test-CoordLedgerCanonical -Path $v[1] -Date $d16
    Assert-Coord "C15 the canonical ledger spelled with $($v[0]) is still canonical" ($c.Ok) "path=$($v[1]) error=$($c.Error)"
}
$otherDay = Join-Path $mainA '.claude\coordination\2026-10-15.md'
Set-CoordTextFile $otherDay "# the day before`n"
$c = Test-CoordLedgerCanonical -Path $otherDay -Date $d16
Assert-Coord 'C15 a ledger not named for the index''s date is refused' (-not $c.Ok -and $c.Error) "ok=$($c.Ok) error=$($c.Error)"
$notes = Join-Path $mainA '.claude\coordination\notes.md'
Set-CoordTextFile $notes "notes`n"
$c = Test-CoordLedgerCanonical -Path $notes -Date $d16
Assert-Coord 'C15 a file in the coordination folder that is no date is refused' (-not $c.Ok) "ok=$($c.Ok)"
$plain = Join-Path $root 'c15-plain'
Set-CoordTextFile (Join-Path $plain "$d16.md") "scratch ledger`n"
$c = Test-CoordLedgerCanonical -Path (Join-Path $plain "$d16.md") -Date $d16
Assert-Coord 'C15 a ledger outside any repo is refused, with no canonical path' (-not $c.Ok -and $null -eq $c.Canonical) "ok=$($c.Ok) canonical=$($c.Canonical)"
# The invoker below makes git agree that the repo is on the UNC share, so the
# only rule left to refuse the path is the one against UNC paths.
$uncLedger = '\\localhost\fxshare\repo\.claude\coordination\' + $d16 + '.md'
$c = Test-CoordLedgerCanonical -Path $uncLedger -Date $d16 -Git $gitUnc
Assert-Coord 'C15 a UNC path is refused even when git names the same UNC path as the main checkout' (-not $c.Ok -and $c.Error) "ok=$($c.Ok) canonical=$($c.Canonical) error=$($c.Error)"
$global:stubCalls.Clear()
$c = Test-CoordLedgerCanonical -Path $ledA -Date $d16 -Git $gitDead
Assert-Coord 'C15 git unavailable (every call fails): refused, and the call went through -Git' (-not $c.Ok -and $null -eq $c.Canonical -and $global:stubCalls.Count -ge 1) "ok=$($c.Ok) calls=$($global:stubCalls.Count)"

Write-Host "(C16) Get-CoordIndexedLedgers"
$e1 = 'C:\L\a\x.md'
$e2 = 'C:\L\b\x.md'
$ix = Get-CoordIndexedLedgers -Bytes (ConvertTo-IdxBytes @($e1, $e2))
Assert-Coord 'C16 two complete lines: both, in file order, nothing missing or overflowing' ($ix.Ok -and (Join-IdxEntries $ix) -ceq "$e1|$e2" -and -not $ix.Overflow -and -not $ix.Missing) (Join-IdxEntries $ix)
$ix = Get-CoordIndexedLedgers -Bytes (ConvertTo-IdxBytes @($e1, $e2) -Nl "`r`n")
Assert-Coord 'C16 CRLF line ends: the CR is not part of the entry' ($ix.Ok -and (Join-IdxEntries $ix) -ceq "$e1|$e2") (Join-IdxEntries $ix)
$ix = Get-CoordIndexedLedgers -Bytes (ConvertTo-IdxBytes @($e1, $e2, 'C:\L\c\x.md') -Terminated $false)
Assert-Coord 'C16 a last line with no newline (a torn write) is dropped' ($ix.Ok -and (Join-IdxEntries $ix) -ceq "$e1|$e2") (Join-IdxEntries $ix)
$ix = Get-CoordIndexedLedgers -Bytes (ConvertTo-IdxBytes @($e1, '', $e2))
Assert-Coord 'C16 a blank line is skipped' ($ix.Ok -and (Join-IdxEntries $ix) -ceq "$e1|$e2") (Join-IdxEntries $ix)
$ix = Get-CoordIndexedLedgers -Bytes (ConvertTo-IdxBytes @($e1, 'c:\l\A\X.MD', 'C:/L/a/x.md', 'C:\L\a\..\a\x.md'))
Assert-Coord 'C16 the same path in another case, with / separators and with dot segments counts once, as first spelled' ($ix.Ok -and @($ix.Entries).Count -eq 1 -and @($ix.Entries)[0] -ceq $e1 -and -not $ix.Overflow) (Join-IdxEntries $ix)
$ix = Get-CoordIndexedLedgers -Bytes (ConvertTo-IdxBytes @('C:\L\dir\', $e1))
Assert-Coord 'C16 a trailing separator is trimmed from an entry' ($ix.Ok -and (Join-IdxEntries $ix) -ceq "C:\L\dir|$e1") (Join-IdxEntries $ix)
$badLine = 'C:\L\bad' + [string][char]0 + 'x.md'
$ix = Get-CoordIndexedLedgers -Bytes (ConvertTo-IdxBytes @($e1, $badLine, $e2))
Assert-Coord 'C16 a line GetFullPath rejects is skipped, its neighbours kept' ($ix.Ok -and (Join-IdxEntries $ix) -ceq "$e1|$e2") (Join-IdxEntries $ix)
$many = @(1..9 | ForEach-Object { "C:\L\r$_\x.md" })
$ix = Get-CoordIndexedLedgers -Bytes (ConvertTo-IdxBytes $many[0..7])
Assert-Coord 'C16 eight distinct entries: all eight, no overflow' ($ix.Ok -and @($ix.Entries).Count -eq 8 -and -not $ix.Overflow) (Join-IdxEntries $ix)
$ix = Get-CoordIndexedLedgers -Bytes (ConvertTo-IdxBytes $many)
Assert-Coord 'C16 a ninth distinct entry: the first eight kept, Overflow' ($ix.Ok -and @($ix.Entries).Count -eq 8 -and (Join-IdxEntries $ix) -ceq ($many[0..7] -join '|') -and $ix.Overflow) (Join-IdxEntries $ix)
$ix = Get-CoordIndexedLedgers -Bytes (ConvertTo-IdxBytes ($many[0..7] + @('c:\l\R1\X.MD')))
Assert-Coord 'C16 a ninth line that repeats one of the eight (other case) is no overflow' ($ix.Ok -and @($ix.Entries).Count -eq 8 -and -not $ix.Overflow) (Join-IdxEntries $ix)
$ix = Get-CoordIndexedLedgers -Bytes (ConvertTo-IdxBytes (@('C:\A\x.md') * 6600))
Assert-Coord 'C16 one path repeated past 64 KiB: one entry, Overflow' ($ix.Ok -and @($ix.Entries).Count -eq 1 -and $ix.Overflow) "entries=$(Join-IdxEntries $ix) overflow=$($ix.Overflow)"
$ix = Get-CoordIndexedLedgers -Bytes (ConvertTo-IdxBytes ((@('C:\A\x.md') * 6600) + @('C:\B\y.md')))
Assert-Coord 'C16 a distinct entry after the first 64 KiB is not read' ($ix.Ok -and (Join-IdxEntries $ix) -ceq 'C:\A\x.md' -and $ix.Overflow) (Join-IdxEntries $ix)
$ix = Get-CoordIndexedLedgers -Bytes (ConvertTo-IdxBytes ((@('C:\A\x.md') * 6553) + @('C:\B\y.md')))
Assert-Coord 'C16 a line cut by the 64 KiB cap is dropped, not read short' ($ix.Ok -and (Join-IdxEntries $ix) -ceq 'C:\A\x.md' -and $ix.Overflow) (Join-IdxEntries $ix)
$ix = Get-CoordIndexedLedgers -Bytes (ConvertTo-IdxBytes ((@('C:\A\x.md') * 6553) + @('C:\Zz')))
Assert-Coord 'C16 an index of exactly 65536 bytes ending in a complete line: that last line is read, no overflow' ($ix.Ok -and (Join-IdxEntries $ix) -ceq 'C:\A\x.md|C:\Zz' -and -not $ix.Overflow) (Join-IdxEntries $ix)
$pIdx = Join-Path $root 'c16-index.ledgers'
[System.IO.File]::WriteAllBytes($pIdx, (ConvertTo-IdxBytes @($e1, $e2)))
$ix = Get-CoordIndexedLedgers -Path $pIdx
Assert-Coord 'C16 -Path: a file is read like its bytes' ($ix.Ok -and -not $ix.Missing -and (Join-IdxEntries $ix) -ceq "$e1|$e2") (Join-IdxEntries $ix)
$ix = Get-CoordIndexedLedgers -Path (Join-Path $root 'c16-nope.ledgers')
Assert-Coord 'C16 -Path: no file is Ok, Missing, no entries' ($ix.Ok -and $ix.Missing -and @($ix.Entries).Count -eq 0) "ok=$($ix.Ok) missing=$($ix.Missing)"
$pEmpty = Join-Path $root 'c16-empty.ledgers'
[System.IO.File]::WriteAllBytes($pEmpty, [byte[]]@())
$ix = Get-CoordIndexedLedgers -Path $pEmpty
Assert-Coord 'C16 -Path: an empty file is Ok, not Missing, no entries' ($ix.Ok -and -not $ix.Missing -and @($ix.Entries).Count -eq 0) "ok=$($ix.Ok) missing=$($ix.Missing)"
$ix = Get-CoordIndexedLedgers -Path $root
Assert-Coord 'C16 -Path: a folder cannot be read: not Ok' (-not $ix.Ok) "ok=$($ix.Ok)"
$wh = New-Object System.IO.FileStream($pIdx, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
try { $ix = Get-CoordIndexedLedgers -Path $pIdx } finally { $wh.Dispose() }
Assert-Coord 'C16 -Path: a file another process holds open for writing is still read' ($ix.Ok -and (Join-IdxEntries $ix) -ceq "$e1|$e2") "ok=$($ix.Ok) error=$($ix.Error)"

Write-Host "(C17) Register-CoordLedger"
$repoB = New-CoordCanonRepo $root 'c17b'
$repoC = New-CoordCanonRepo $root 'c17c'
$repoD = New-CoordCanonRepo $root 'c17d'
$ledB = New-CoordCanonLedger $repoB $d16
$ledC = New-CoordCanonLedger $repoC $d16
$ledD = New-CoordCanonLedger $repoD $d16
$ix = New-CoordScratchIndex $root
$idxFile = Get-CoordIndexPath -Date $d16
$existedBefore = Test-Path -LiteralPath $ix
$r = Register-CoordLedger -Ledger $ledA -Date $d16
Assert-Coord 'C17 a canonical ledger registers: Ok, Added, in the index of the date' ($r.Ok -and $r.Added -and $r.Index -ceq $idxFile) "ok=$($r.Ok) added=$($r.Added) index=$($r.Index) error=$($r.Error)"
Assert-Coord 'C17 ... the index folder was made and the index holds that one full path and a newline' (-not $existedBefore -and (Get-IdxText $idxFile) -ceq ($ledA + "`n")) (Get-IdxText $idxFile)
Assert-Coord 'C17 ... and no lock file is left beside the index' (-not (Test-Path -LiteralPath ($idxFile + '.lock')))
$text1 = Get-IdxText $idxFile
$r = Register-CoordLedger -Ledger $ledA -Date $d16
Assert-Coord 'C17 a repeat registration adds no line' ($r.Ok -and -not $r.Added -and (Get-IdxText $idxFile) -ceq $text1) "ok=$($r.Ok) added=$($r.Added) text=$(Get-IdxText $idxFile)"
$r = Register-CoordLedger -Ledger $ledA.ToUpperInvariant() -Date $d16
Assert-Coord 'C17 ... also when the same path is spelled in upper case' ($r.Ok -and -not $r.Added -and (Get-IdxText $idxFile) -ceq $text1) "ok=$($r.Ok) added=$($r.Added) text=$(Get-IdxText $idxFile)"
$r = Register-CoordLedger -Ledger $ledB -Date $d16
Assert-Coord 'C17 a second ledger is appended on its own line' ($r.Ok -and $r.Added -and (Get-IdxText $idxFile) -ceq ($ledA + "`n" + $ledB + "`n")) (Get-IdxText $idxFile)

$null = New-CoordScratchIndex $root
$idxFile = Get-CoordIndexPath -Date $d16
$r = Register-CoordLedger -Ledger $staleA -Date $d16
Assert-Coord 'C17 a stale copy in a linked worktree is refused, the error names the canonical path, nothing is written' (-not $r.Ok -and ([string]$r.Error).IndexOf($ledA, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and -not (Test-Path -LiteralPath $idxFile)) "ok=$($r.Ok) error=$($r.Error)"
$r = Register-CoordLedger -Ledger $otherDay -Date $d16
Assert-Coord 'C17 a ledger not named for the date is refused, nothing is written' (-not $r.Ok -and -not (Test-Path -LiteralPath $idxFile)) "ok=$($r.Ok) error=$($r.Error)"
$r = Register-CoordLedger -Ledger (Join-Path $plain "$d16.md") -Date $d16
Assert-Coord 'C17 a scratch ledger outside any repo is refused, nothing is written' (-not $r.Ok -and -not (Test-Path -LiteralPath $idxFile)) "ok=$($r.Ok) error=$($r.Error)"
$r = Register-CoordLedger -Ledger $uncLedger -Date $d16
Assert-Coord 'C17 a UNC path is refused, nothing is written' (-not $r.Ok -and -not (Test-Path -LiteralPath $idxFile)) "ok=$($r.Ok) error=$($r.Error)"

$null = New-CoordScratchIndex $root
$seedTorn = "C:\Seed\a.md`nC:\Seed\to"
$f = Set-IdxText $seedTorn
$r = Register-CoordLedger -Ledger $ledA -Date $d16
Assert-Coord 'C17 an index whose last line is torn: the new entry lands on its own line' ($r.Ok -and $r.Added -and (Get-IdxText $f) -ceq ($seedTorn + "`n" + $ledA + "`n")) (Get-IdxText $f)
Assert-Coord 'C17 ... and the discovery read finds it' (@((Get-CoordIndexedLedgers -Path $f).Entries) -contains $ledA)

$null = New-CoordScratchIndex $root
$seed7t = ((1..7 | ForEach-Object { "C:\Seed\s$_.md" }) -join "`n") + "`nC:\Seed\s8.md"
$f = Set-IdxText $seed7t
$r = Register-CoordLedger -Ledger $ledA -Date $d16
$found = @((Get-CoordIndexedLedgers -Path $f).Entries) -contains $ledA
Assert-Coord 'C17 seven complete entries plus a torn eighth: refused with the index unchanged, or landed where the discovery read finds it' ((-not $r.Ok -and (Get-IdxText $f) -ceq $seed7t) -or ($r.Ok -and $found)) "ok=$($r.Ok) error=$($r.Error) found=$found"

$null = New-CoordScratchIndex $root
$seed64 = ((1..6600 | ForEach-Object { 'C:\Seed\a.md' }) -join "`n") + "`n"
$f = Set-IdxText $seed64
$r = Register-CoordLedger -Ledger $ledA -Date $d16
Assert-Coord 'C17 an index of one path repeated past 64 KiB: refused naming the bound, index unchanged' (-not $r.Ok -and ([string]$r.Error) -match '64 KiB' -and (Get-IdxText $f) -ceq $seed64) "ok=$($r.Ok) error=$($r.Error)"

$fake = @(1..8 | ForEach-Object { "C:\Seed\r$_\.claude\coordination\$d16.md" })
$null = New-CoordScratchIndex $root
$seed8 = ($fake -join "`n") + "`n"
$f = Set-IdxText $seed8
$r = Register-CoordLedger -Ledger $ledA -Date $d16
Assert-Coord 'C17 eight distinct ledgers already: a ninth is refused naming the limit, index unchanged' (-not $r.Ok -and ([string]$r.Error) -match '8 distinct' -and (Get-IdxText $f) -ceq $seed8) "ok=$($r.Ok) error=$($r.Error)"
$null = New-CoordScratchIndex $root
$f = Set-IdxText ((($fake[0..6] + @($ledA.ToUpperInvariant())) -join "`n") + "`n")
$text8 = Get-IdxText $f
$r = Register-CoordLedger -Ledger $ledA -Date $d16
Assert-Coord 'C17 eight distinct already, one of them this ledger: Ok, nothing added' ($r.Ok -and -not $r.Added -and (Get-IdxText $f) -ceq $text8) "ok=$($r.Ok) added=$($r.Added) error=$($r.Error)"
$null = New-CoordScratchIndex $root
$f = Set-IdxText ((($fake[0..6]) -join "`n") + "`n")
$r = Register-CoordLedger -Ledger $ledA -Date $d16
Assert-Coord 'C17 seven distinct already: the eighth lands and the discovery read finds it' ($r.Ok -and $r.Added -and (@((Get-CoordIndexedLedgers -Path $f).Entries) -contains $ledA)) "ok=$($r.Ok) error=$($r.Error)"
$text9 = Get-IdxText $f
$r = Register-CoordLedger -Ledger $ledB -Date $d16
Assert-Coord 'C17 ... and then a ninth distinct ledger is refused, index unchanged' (-not $r.Ok -and (Get-IdxText $f) -ceq $text9) "ok=$($r.Ok) error=$($r.Error)"

$null = New-CoordScratchIndex $root
$f = Set-IdxText ''
$held = New-Object System.IO.FileStream(($f + '.lock'), [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try { $r = Register-CoordLedger -Ledger $ledA -Date $d16 } finally { $held.Dispose() }
$sw.Stop()
Assert-Coord 'C17 the index lock held by someone else: refused after waiting about 5 s, index unchanged' (-not $r.Ok -and $sw.Elapsed.TotalSeconds -ge 4 -and $sw.Elapsed.TotalSeconds -lt 15 -and (Get-IdxText $f) -ceq '') "ok=$($r.Ok) seconds=$($sw.Elapsed.TotalSeconds) error=$($r.Error)"
Remove-Item -LiteralPath ($f + '.lock') -Force -ErrorAction SilentlyContinue
$r = Register-CoordLedger -Ledger $ledA -Date $d16
Assert-Coord 'C17 ... released, the next registration lands' ($r.Ok -and $r.Added -and (Get-IdxText $f) -ceq ($ledA + "`n")) "ok=$($r.Ok) error=$($r.Error)"

# Racing processes. Each child dot-sources coord-common, signals ready, waits for
# one go file, then registers: the calls start together, not a process start apart.
$childScript = Join-Path $root 'c17-child.ps1'
[System.IO.File]::WriteAllText($childScript, @'
param([string]$Common, [string]$Ledger, [string]$Date, [string]$Ready, [string]$Go)
$ErrorActionPreference = 'Stop'
. $Common
[System.IO.File]::WriteAllText($Ready, 'ready')
$until = [DateTime]::Now.AddSeconds(60)
while (-not (Test-Path -LiteralPath $Go) -and [DateTime]::Now -lt $until) { Start-Sleep -Milliseconds 5 }
$r = Register-CoordLedger -Ledger $Ledger -Date $Date
if ($r.Ok) { Write-Output 'OK'; exit 0 }
Write-Output ('REFUSED: ' + $r.Error)
exit 3
'@, $coordUtf8)
function Start-RegisterRace {
    param([string[]]$Ledgers, [string]$Tag)
    $go = Join-Path $root "$Tag.go"
    $procs = @()
    $readys = @()
    $i = 0
    foreach ($led in $Ledgers) {
        $i++
        $ready = Join-Path $root "$Tag.ready$i"
        $readys += $ready
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = Get-HookTestShellPath
        $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $childScript + '" -Common "' + $CommonPath + '" -Ledger "' + $led + '" -Date ' + $d16 + ' -Ready "' + $ready + '" -Go "' + $go + '"'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $procs += [System.Diagnostics.Process]::Start($psi)
    }
    $until = [DateTime]::Now.AddSeconds(90)
    while (@($readys | Where-Object { -not (Test-Path -LiteralPath $_) }).Count -gt 0 -and [DateTime]::Now -lt $until) { Start-Sleep -Milliseconds 20 }
    [System.IO.File]::WriteAllText($go, 'go')
    $results = @()
    foreach ($pr in $procs) {
        $out = $pr.StandardOutput.ReadToEnd().Trim()
        [void]$pr.WaitForExit(120000)
        $results += [pscustomobject]@{ Code = $pr.ExitCode; Out = $out }
    }
    return $results
}
$null = New-CoordScratchIndex $root
$f = Get-CoordIndexPath -Date $d16
$res = @(Start-RegisterRace @($ledA, $ledB) 'race2')
$t = Get-IdxText $f
$lines = @($t -split "`n" | Where-Object { $_ -ne '' })
Assert-Coord 'C17 two processes register different ledgers at the same moment: both exit 0' (@($res | Where-Object { $_.Code -eq 0 }).Count -eq 2) (($res | ForEach-Object { "$($_.Code) $($_.Out)" }) -join "`n")
Assert-Coord 'C17 ... and both land, each on its own complete line, no blank or torn line' ($lines.Count -eq 2 -and ($lines -contains $ledA) -and ($lines -contains $ledB) -and $t.EndsWith("`n") -and -not $t.Contains("`r") -and -not $t.Contains("`n`n")) $t
$null = New-CoordScratchIndex $root
$seed6 = (($fake[0..5]) -join "`n") + "`n"
$f = Set-IdxText $seed6
$racers = @($ledA, $ledB, $ledC, $ledD)
$res = @(Start-RegisterRace $racers 'race4')
$entries = @((Get-CoordIndexedLedgers -Path $f).Entries)
$agree = $true
for ($k = 0; $k -lt $racers.Count; $k++) { if (($res[$k].Code -eq 0) -ne ($entries -contains $racers[$k])) { $agree = $false } }
Assert-Coord 'C17 four processes race for the two places left in the index: exactly two exit 0, two are refused' (@($res | Where-Object { $_.Code -eq 0 }).Count -eq 2 -and @($res | Where-Object { $_.Code -eq 3 }).Count -eq 2) (($res | ForEach-Object { "$($_.Code) $($_.Out)" }) -join "`n")
Assert-Coord 'C17 ... every process that exited 0 is found by the discovery read, and no refused one is in the index' ($agree -and $entries.Count -eq 8) "entries=$($entries -join '|') results=$(($res | ForEach-Object { $_.Code }) -join ',')"

Write-Host "(C18) Test-CoordLedgerTrusted"
function New-TrustRepo([string]$Name) {
    $repo = New-CoordCanonRepo $root $Name -Commit
    $led = New-CoordCanonLedger $repo $d16 -Text "# Coordination ledger - $d16`n"
    return [pscustomobject]@{ Repo = $repo; Ledger = $led; Main = (Get-CoordMainRoot $repo) }
}
$t1 = New-TrustRepo 'c18-ok'
$global:stubCalls.Clear()
$global:stubLsMode = 'real'
$tr = Test-CoordLedgerTrusted -Path $t1.Ledger -Git $gitLogging
Assert-Coord 'C18 an untracked regular file in a plain .claude\coordination is trusted' ($tr.Ok) "error=$($tr.Error)"
$lsCalls = @($global:stubCalls | Where-Object { $_ -like '*ls-files*' })
$relPath = ".claude/coordination/$d16.md"
Assert-Coord 'C18 ... after one case-insensitive git ls-files -s over .claude, .claude/coordination, the ledger and the two 8.3 globs' ($lsCalls.Count -eq 1 -and $lsCalls[0].Contains('--icase-pathspecs') -and $lsCalls[0].Contains(' -s ') -and $lsCalls[0].Contains(' .claude ') -and $lsCalls[0].Contains(' .claude/coordination ') -and $lsCalls[0].Contains($relPath) -and $lsCalls[0].Contains(':(glob)**/*~[0-9]*') -and $lsCalls[0].Contains(':(glob)**/*~[0-9]*/**')) ($lsCalls -join '|')
$trPlain = Test-CoordLedgerTrusted -Path $t1.Ledger
Assert-Coord 'C18 ... the same answer with the default git invoker' ($trPlain.Ok) "error=$($trPlain.Error)"
$lsCases = @(
    @('the ledger itself in another letter case', @("100644 aaaa 0`t.Claude/Coordination/$d16.md"), $false),
    @('.claude as a submodule', @("160000 aaaa 0`t.claude"), $false),
    @('.claude/coordination as a symlink entry', @("120000 aaaa 0`t.claude/coordination"), $false),
    @('.CLAUDE as an entry in another case', @("160000 aaaa 0`t.CLAUDE"), $false),
    @('an 8.3 alias of the coordination folder', @("100644 aaaa 0`t.claude/coordi~1/$d16.md"), $false),
    @('an 8.3 alias of .claude', @("100644 aaaa 0`tclaude~1/coordination/$d16.md"), $false),
    @('a tracked sibling file in the folder', @("100644 aaaa 0`t.claude/coordination/README.md"), $true),
    @('nothing', @(), $true)
)
foreach ($c in $lsCases) {
    $global:stubLsMode = 'fake'
    $global:stubLsCode = 0
    $global:stubLsOut = $c[1]
    $tr = Test-CoordLedgerTrusted -Path $t1.Ledger -Git $gitLogging
    Assert-Coord "C18 git ls-files lists $($c[0]): trusted = $($c[2])" ($tr.Ok -eq $c[2]) "ok=$($tr.Ok) error=$($tr.Error)"
}
foreach ($code in @(128, 1)) {
    $global:stubLsMode = 'fake'
    $global:stubLsCode = $code
    $global:stubLsOut = @()
    $tr = Test-CoordLedgerTrusted -Path $t1.Ledger -Git $gitLogging
    Assert-Coord "C18 git ls-files failing with exit $code and no output: not trusted (fails closed)" (-not $tr.Ok) "ok=$($tr.Ok)"
}
$global:stubLsMode = 'real'
$global:stubTop = 'C:\Elsewhere'
$tr = Test-CoordLedgerTrusted -Path $t1.Ledger -Git $gitLogging
$global:stubTop = ''
Assert-Coord 'C18 git''s top level of the main checkout differs from the main checkout: not trusted' (-not $tr.Ok) "ok=$($tr.Ok)"
$tr = Test-CoordLedgerTrusted -Path $t1.Ledger -Git $gitDead
Assert-Coord 'C18 git unavailable altogether: not trusted' (-not $tr.Ok) "ok=$($tr.Ok)"
$tr = Test-CoordLedgerTrusted -Path (Join-Path $plain "$d16.md")
Assert-Coord 'C18 a ledger outside any repo: not trusted' (-not $tr.Ok) "ok=$($tr.Ok)"

$t2 = New-TrustRepo 'c18-missing'
Remove-Item -LiteralPath $t2.Ledger -Force
$tr = Test-CoordLedgerTrusted -Path $t2.Ledger
Assert-Coord 'C18 a ledger that does not exist: not trusted' (-not $tr.Ok -and $tr.Error) "ok=$($tr.Ok) error=$($tr.Error)"

$t3 = New-TrustRepo 'c18-tracked'
Invoke-HookTestGit $t3.Repo @('-c', 'core.autocrlf=false', 'add', '-A')
Invoke-HookTestGit $t3.Repo @('-c', 'core.autocrlf=false', 'commit', '--quiet', '-m', 'ship a ledger')
$tr = Test-CoordLedgerTrusted -Path $t3.Ledger
Assert-Coord 'C18 a ledger committed to the repo is not trusted' (-not $tr.Ok) "ok=$($tr.Ok)"

# A committed path in another letter case opens the same file on NTFS (the trust check must see it).
foreach ($v in @('all', 'sub')) {
    $r4 = New-CoordCanonRepo $root "c18-case-$v" -Commit
    Invoke-HookTestGit $r4 @('config', 'core.ignorecase', 'false')
    if ($v -eq 'sub') {
        Set-CoordTextFile (Join-Path $r4 '.claude\handovers\keep.md') "keep`n"
        $caseRel = ".claude/Coordination/$d16.md"
        Set-CoordTextFile (Join-Path $r4 ".claude\Coordination\$d16.md") "# ledger`n"
    }
    else {
        $caseRel = ".Claude/Coordination/$d16.md"
        Set-CoordTextFile (Join-Path $r4 ".Claude\Coordination\$d16.md") "# ledger`n"
    }
    Invoke-HookTestGit $r4 @('-c', 'core.autocrlf=false', 'add', '-A')
    Invoke-HookTestGit $r4 @('-c', 'core.autocrlf=false', 'commit', '--quiet', '-m', 'ship a ledger, other case')
    $lower = Join-Path (Get-CoordMainRoot $r4) ".claude\coordination\$d16.md"
    $recorded = (Get-CoordGitOut $r4 @('ls-files')).Split("`n")
    if ((Test-Path -LiteralPath $lower) -and ($recorded -ccontains $caseRel)) {
        $tr = Test-CoordLedgerTrusted -Path $lower
        Assert-Coord "C18 a ledger committed as $caseRel (opens at the lower-case path) is not trusted" (-not $tr.Ok) "ok=$($tr.Ok)"
    }
    else { Write-CoordUnchecked "C18 case-variant $v" "the variant path was not recorded as $caseRel or does not open at the lower-case path" }
}

# A committed 8.3 alias, .claude/coordi~1/<date>.md, beside a tracked .claude/coordination/keep.md.
$r5 = New-CoordCanonRepo $root 'c18-83' -Commit
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$keepSha = ('keep' | & git -C $r5 hash-object -w --stdin)
$blobSha = ("ledger`n" | & git -C $r5 hash-object -w --stdin)
& git -C $r5 update-index --add --cacheinfo "100644,$keepSha,.claude/coordination/keep.md" --cacheinfo "100644,$blobSha,.claude/coordi~1/$d16.md" 2>$null | Out-Null
& git -C $r5 checkout-index -a -f 2>$null | Out-Null
$ErrorActionPreference = $prevEap
$l5 = Join-Path (Get-CoordMainRoot $r5) ".claude\coordination\$d16.md"
if ((Test-Path -LiteralPath $l5) -and @(Get-ChildItem -LiteralPath (Join-Path $r5 '.claude') -Directory -Force).Count -eq 1) {
    $tr = Test-CoordLedgerTrusted -Path $l5
    Assert-Coord 'C18 a committed 8.3 alias of the coordination folder is not trusted' (-not $tr.Ok) "ok=$($tr.Ok)"
}
else { Write-CoordUnchecked 'C18 8.3 alias' 'the alias did not land in .claude\coordination (short names off on this volume?)' }

$t6 = New-TrustRepo 'c18-junction'
$tr0 = Test-CoordLedgerTrusted -Path $t6.Ledger
$tgt6 = Join-Path $root 'c18-junction-target'
[void][IO.Directory]::CreateDirectory($tgt6)
$coord6 = Join-Path $t6.Main '.claude\coordination'
Move-Item -LiteralPath $coord6 -Destination (Join-Path $tgt6 'coordination')
if (New-CoordJunction $coord6 (Join-Path $tgt6 'coordination')) {
    $tr = Test-CoordLedgerTrusted -Path $t6.Ledger
    Remove-CoordJunction $coord6
    Assert-Coord 'C18 .claude\coordination a junction to a folder holding the ledger: not trusted (the same repo and ledger were trusted as a plain folder)' ($tr0.Ok -and -not $tr.Ok) "before=$($tr0.Ok) junctioned=$($tr.Ok)"
}
else { Write-CoordUnchecked 'C18 junctioned coordination' 'could not create a junction' }

$t7 = New-TrustRepo 'c18-junction-dot'
$tr0 = Test-CoordLedgerTrusted -Path $t7.Ledger
$tgt7 = Join-Path $root 'c18-junction-dot-target'
[void][IO.Directory]::CreateDirectory($tgt7)
$dot7 = Join-Path $t7.Main '.claude'
Move-Item -LiteralPath $dot7 -Destination (Join-Path $tgt7 '.claude')
if (New-CoordJunction $dot7 (Join-Path $tgt7 '.claude')) {
    $tr = Test-CoordLedgerTrusted -Path $t7.Ledger
    Remove-CoordJunction $dot7
    Assert-Coord 'C18 .claude itself a junction: not trusted (the same repo and ledger were trusted as a plain folder)' ($tr0.Ok -and -not $tr.Ok) "before=$($tr0.Ok) junctioned=$($tr.Ok)"
}
else { Write-CoordUnchecked 'C18 junctioned .claude' 'could not create a junction' }

$t8 = New-TrustRepo 'c18-dir'
Remove-Item -LiteralPath $t8.Ledger -Force
[void][IO.Directory]::CreateDirectory($t8.Ledger)
$tr = Test-CoordLedgerTrusted -Path $t8.Ledger
Assert-Coord 'C18 a folder at the ledger path is not a regular file: not trusted' (-not $tr.Ok) "ok=$($tr.Ok)"

$t9 = New-TrustRepo 'c18-symlink'
$real9 = Join-Path $root 'c18-symlink-real.md'
Set-CoordTextFile $real9 "real`n"
Remove-Item -LiteralPath $t9.Ledger -Force
$linked = $false
try { New-Item -ItemType SymbolicLink -Path $t9.Ledger -Target $real9 -ErrorAction Stop | Out-Null; $linked = $true } catch { }
if ($linked) {
    $tr = Test-CoordLedgerTrusted -Path $t9.Ledger
    Assert-Coord 'C18 the ledger a symbolic link: not trusted' (-not $tr.Ok) "ok=$($tr.Ok)"
}
else { Write-CoordUnchecked 'C18 symlinked ledger' 'could not create a file symlink (needs developer mode or elevation)' }

Write-Host "(C19) Read-CoordLedgerTracksBounded"
$trkHeader = '| Track | Repo | Session | Cwd | Branch | Scope | PR | Status |'
$trkDelim = '|-------|------|---------|-----|--------|-------|----|--------|'
$trkRows = @(
    '| A1 | C:\Fx\r | sess-a | C:\Fx\w1 | br-a | docs/**, src/** | #1 | running |',
    '| A2 | C:\Fx\r | sess-b | C:\Fx\w2 | br-b | lib/** | none | briefed |'
)
$trkFiller = '10:00 filler line of the append-only log, long enough to pad the file out 0123456789abcdef'
$trkTail = "`n## Merge slots`n`n1. (none)`n`n## Log`n`n08:00 ledger created`n"
# A ledger with the Tracks table near the top (after $PadBefore bytes of filler in
# Baseline when given) and filler after it in the Log until $PadAfter bytes.
function New-TracksLedger {
    param([string]$Path, [int]$PadBefore = 0, [int]$PadAfter = 0, [string[]]$Rows = $trkRows, [string]$Header = $trkHeader,
        [string]$Delim = $trkDelim, [string]$Tail = $trkTail, [bool]$Heading = $true)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("# Coordination ledger - $d16`n`n")
    [void]$sb.Append('Coordinator: session "coord-test", cwd `C:\Fx\r`.' + "`n`n")
    [void]$sb.Append("## Baseline`n`n")
    while ($sb.Length -lt $PadBefore) { [void]$sb.Append($trkFiller + "`n") }
    if ($Heading) { [void]$sb.Append("## Tracks`n`n") }
    [void]$sb.Append('<!-- Repo: the full path. -->' + "`n`n")
    [void]$sb.Append($Header + "`n" + $Delim + "`n")
    foreach ($row in $Rows) { [void]$sb.Append($row + "`n") }
    [void]$sb.Append($Tail)
    while ($sb.Length -lt $PadAfter) { [void]$sb.Append($trkFiller + "`n") }
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), $coordUtf8)
}
$lp = Join-Path $root 'c19.md'
foreach ($sz in @(@('16 KiB', 16384), @('78 KiB', 78175), @('900 KiB', 921600))) {
    $want = $sz[1]
    New-TracksLedger $lp -PadAfter $want
    $len = (Get-Item -LiteralPath $lp).Length
    $b = Read-CoordLedgerTracksBounded -Path $lp
    $rowsB = @($b.Rows)
    Assert-Coord "C19 a $($sz[0]) ledger with Tracks near the top: Ok, both rows with their cells" ($len -ge $want -and $b.Ok -and $rowsB.Count -eq 2 -and $rowsB[0].Branch -ceq 'br-a' -and $rowsB[0].Scope -ceq 'docs/**, src/**' -and $rowsB[1].Branch -ceq 'br-b' -and $rowsB[1].Repo -ceq 'C:\Fx\r') "len=$len ok=$($b.Ok) rows=$($rowsB.Count) error=$($b.Error)"
}
New-TracksLedger $lp -PadAfter 78175
$old = @(Read-CoordLedgerTracks $lp)
$b = Read-CoordLedgerTracksBounded -Path $lp
$sig = { param($rs) (@($rs | ForEach-Object { "$($_.Track)|$($_.Repo)|$($_.Session)|$($_.Model)|$($_.Cwd)|$($_.Branch)|$($_.Scope)|$($_.PR)|$($_.Status)" }) -join ';') }
Assert-Coord 'C19 the rows are exactly those Read-CoordLedgerTracks returns' ($b.Ok -and (& $sig $b.Rows) -ceq (& $sig $old) -and $old.Count -eq 2) "bounded=$(& $sig $b.Rows) old=$(& $sig $old)"
New-TracksLedger $lp -Tail ("`n## Merge slots`n`n| Slot | Holder |`n|---|---|`n| 1 | x |`n")
$b = Read-CoordLedgerTracksBounded -Path $lp
Assert-Coord 'C19 a later table in another section is not read: only the Tracks rows' ($b.Ok -and @($b.Rows).Count -eq 2) "ok=$($b.Ok) rows=$(@($b.Rows).Count) error=$($b.Error)"
New-TracksLedger $lp -Rows @()
$b = Read-CoordLedgerTracksBounded -Path $lp
Assert-Coord 'C19 a Tracks table with a header row and no data rows: Ok, no rows' ($b.Ok -and @($b.Rows).Count -eq 0) "ok=$($b.Ok) rows=$(@($b.Rows).Count) error=$($b.Error)"
New-TracksLedger $lp -PadBefore 1100000
$b = Read-CoordLedgerTracksBounded -Path $lp
Assert-Coord 'C19 a Tracks heading after the 1 MiB cap: malformed, the error names Tracks' (-not $b.Ok -and ([string]$b.Error) -match 'Tracks') "ok=$($b.Ok) error=$($b.Error)"
$rows30 = @(1..30 | ForEach-Object { "| R$_ | C:\Fx\r | sess-a | C:\Fx\w | br-$_ | docs/** | none | running |" })
New-TracksLedger $lp -Rows $rows30
$b = Read-CoordLedgerTracksBounded -Path $lp
Assert-Coord 'C19 control: 30 Tracks rows near the top are all read' ($b.Ok -and @($b.Rows).Count -eq 30) "ok=$($b.Ok) rows=$(@($b.Rows).Count) error=$($b.Error)"
New-TracksLedger $lp -Rows $rows30 -PadBefore (1048576 - 300)
$b = Read-CoordLedgerTracksBounded -Path $lp
Assert-Coord 'C19 a Tracks table that starts before the 1 MiB cap and is cut by it: malformed, never used in part' (-not $b.Ok -and ([string]$b.Error) -match 'Tracks') "ok=$($b.Ok) rows=$(@($b.Rows).Count) error=$($b.Error)"
New-TracksLedger $lp -Tail ''
$b = Read-CoordLedgerTracksBounded -Path $lp
Assert-Coord 'C19 a Tracks table with no line after it before end of file: malformed' (-not $b.Ok -and ([string]$b.Error) -match 'Tracks') "ok=$($b.Ok) rows=$(@($b.Rows).Count) error=$($b.Error)"
New-TracksLedger $lp -Tail "`n"
$b = Read-CoordLedgerTracksBounded -Path $lp
Assert-Coord 'C19 ... but one blank line after the rows ends the table' ($b.Ok -and @($b.Rows).Count -eq 2) "ok=$($b.Ok) rows=$(@($b.Rows).Count) error=$($b.Error)"
New-TracksLedger $lp -Heading $false
$b = Read-CoordLedgerTracksBounded -Path $lp
Assert-Coord 'C19 no ## Tracks heading: malformed' (-not $b.Ok -and ([string]$b.Error) -match 'Tracks') "ok=$($b.Ok) error=$($b.Error)"
New-TracksLedger $lp -Header '| Track | Repo | Branch |' -Delim '|---|---|---|' -Rows @('| A1 | C:\Fx\r | br-a |')
$b = Read-CoordLedgerTracksBounded -Path $lp
Assert-Coord 'C19 a table with no Scope column: malformed, the error names Scope' (-not $b.Ok -and ([string]$b.Error) -match 'Scope') "ok=$($b.Ok) error=$($b.Error)"
New-TracksLedger $lp -Rows @('| A1 | C:\Fx\r | sess-a | C:\Fx\w1 | br-a | docs/** | #1 |')
$b = Read-CoordLedgerTracksBounded -Path $lp
Assert-Coord 'C19 a row with fewer cells than the header: malformed, the error says cells' (-not $b.Ok -and ([string]$b.Error) -match 'cells') "ok=$($b.Ok) error=$($b.Error)"
$b = Read-CoordLedgerTracksBounded -Path (Join-Path $root 'c19-nope.md')
Assert-Coord 'C19 a ledger that does not exist: not Ok' (-not $b.Ok) "ok=$($b.Ok)"

Write-Host "(C20) Test-CoordInScope -IgnoreCase"
$ic = @(
    @('docs/A.md', @('docs/**'), $true, $true),
    @('Docs/a.md', @('docs/**'), $true, $false),
    @('docs\A.md', @('docs/**'), $true, $true),
    @('docs/Secret/k.md', @('docs/**', '!docs/secret/**'), $false, $true),
    @('Docs/Secret/k.md', @('docs/**', '!docs/secret/**'), $false, $false),
    @('src/a.ps1', @('src/*.PS1'), $true, $false)
)
foreach ($c in $ic) {
    $withCase = Test-CoordInScope $c[0] $c[1] -IgnoreCase
    $without = Test-CoordInScope $c[0] $c[1]
    Assert-Coord "C20 '$($c[0])' vs $($c[1] -join ',') with -IgnoreCase -> $($c[2])" ($withCase -eq $c[2]) "got $withCase"
    Assert-Coord "C20 ... without it (unchanged, case-sensitive) -> $($c[3])" ($without -eq $c[3]) "got $without"
}

Write-Host "(C22) -TimeoutMs on the two bounded readers"
# No fixture can stall a local read, so these rows cover the parameter only: a
# normal read under a bound is unchanged; 0 or a negative bound is TimedOut with
# nothing read (a missing file is then TimedOut, not Missing).
$pT = Join-Path $root 'c22-index.ledgers'
[System.IO.File]::WriteAllBytes($pT, (ConvertTo-IdxBytes @($e1, $e2)))
$ix = Get-CoordIndexedLedgers -Path $pT -TimeoutMs 10000
Assert-Coord 'C22 Get-CoordIndexedLedgers -Path under a 10 s bound: the same entries as without one, not timed out' ($ix.Ok -and (Join-IdxEntries $ix) -ceq "$e1|$e2" -and -not $ix.TimedOut) "ok=$($ix.Ok) error=$($ix.Error)"
foreach ($ms in @(0, -5)) {
    $ix = Get-CoordIndexedLedgers -Path $pT -TimeoutMs $ms
    Assert-Coord "C22 Get-CoordIndexedLedgers -TimeoutMs ${ms}: TimedOut, not Ok, no entries, the error says timed out" (-not $ix.Ok -and $ix.TimedOut -eq $true -and @($ix.Entries).Count -eq 0 -and ([string]$ix.Error) -match 'timed out') "ok=$($ix.Ok) timedOut=$($ix.TimedOut) error=$($ix.Error)"
    $ix = Get-CoordIndexedLedgers -Path (Join-Path $root 'c22-nope.ledgers') -TimeoutMs $ms
    Assert-Coord "C22 ... TimeoutMs $ms on a file that does not exist: still TimedOut (nothing was read), not Missing" (-not $ix.Ok -and $ix.TimedOut -eq $true) "ok=$($ix.Ok) timedOut=$($ix.TimedOut) missing=$($ix.Missing)"
}
New-TracksLedger $lp
$b = Read-CoordLedgerTracksBounded -Path $lp -TimeoutMs 10000
Assert-Coord 'C22 Read-CoordLedgerTracksBounded under a 10 s bound: both rows as without one, not timed out' ($b.Ok -and @($b.Rows).Count -eq 2 -and @($b.Rows)[0].Branch -ceq 'br-a' -and -not $b.TimedOut) "ok=$($b.Ok) error=$($b.Error)"
foreach ($ms in @(0, -5)) {
    $b = Read-CoordLedgerTracksBounded -Path $lp -TimeoutMs $ms
    Assert-Coord "C22 Read-CoordLedgerTracksBounded -TimeoutMs ${ms}: TimedOut, not Ok, no rows, the error says timed out" (-not $b.Ok -and $b.TimedOut -eq $true -and @($b.Rows).Count -eq 0 -and ([string]$b.Error) -match 'timed out') "ok=$($b.Ok) timedOut=$($b.TimedOut) error=$($b.Error)"
    $b = Read-CoordLedgerTracksBounded -Path (Join-Path $root 'c22-nope.md') -TimeoutMs $ms
    Assert-Coord "C22 ... TimeoutMs $ms on a ledger that does not exist: TimedOut (nothing was read)" (-not $b.Ok -and $b.TimedOut -eq $true) "ok=$($b.Ok) timedOut=$($b.TimedOut) error=$($b.Error)"
}

Write-Host "(C23) Read-CoordStreamBounded: a read that never completes"
# The helper both readers use. An AnonymousPipeServerStream whose client end never
# writes is a stream whose read stays pending, which no local file can be. The call
# runs in its own runspace so that a helper that hangs fails the row (after 15 s)
# instead of hanging the suite.
function Invoke-StreamBoundedInRunspace {
    param($Stream, [int]$MaxBytes, [int]$Ms)
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
        param($Common, $S, $Max, $T)
        . $Common
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Read-CoordStreamBounded -Stream $S -MaxBytes $Max -TimeoutMs $T
        [pscustomobject]@{ R = $r; Ms = $sw.ElapsedMilliseconds }
    }).AddArgument($CommonPath).AddArgument($Stream).AddArgument($MaxBytes).AddArgument($Ms)
    $ar = $ps.BeginInvoke()
    if ($ar.AsyncWaitHandle.WaitOne(15000)) {
        $res = @($ps.EndInvoke($ar))
        $ps.Dispose()
        return [pscustomobject]@{ Done = $true; R = $res[0].R; Ms = $res[0].Ms }
    }
    return [pscustomobject]@{ Done = $false; R = $null; Ms = 15000 }
}
$srv = New-Object System.IO.Pipes.AnonymousPipeServerStream([System.IO.Pipes.PipeDirection]::In)
$cli = New-Object System.IO.Pipes.AnonymousPipeClientStream([System.IO.Pipes.PipeDirection]::Out, $srv.ClientSafePipeHandle)
try { $x = Invoke-StreamBoundedInRunspace $srv 1024 1000 }
finally { $cli.Dispose(); $srv.Dispose() }
Assert-Coord 'C23 a stream whose read never completes (pipe, no writer data), 1 s bound: returns, TimedOut, not Ok, no hang' ($x.Done -and $x.R.TimedOut -eq $true -and -not $x.R.Ok) "done=$($x.Done) ok=$($x.R.Ok) timedOut=$($x.R.TimedOut) error=$($x.R.Error)"
Assert-Coord 'C23 ... back within about the bound plus 500 ms (waited the bound, not less; 2.2 s allows for load)' ($x.Done -and $x.Ms -ge 800 -and $x.Ms -lt 2200) "ms=$($x.Ms)"
$data = $coordUtf8.GetBytes(('0123456789' * 10))
$ms1 = New-Object System.IO.MemoryStream(, $data)
$x = Invoke-StreamBoundedInRunspace $ms1 1024 5000
Assert-Coord 'C23 a stream holding 100 bytes: Ok, all 100 bytes, not timed out' ($x.Done -and $x.R.Ok -and -not $x.R.TimedOut -and [Convert]::ToBase64String([byte[]]$x.R.Bytes) -ceq [Convert]::ToBase64String($data)) "done=$($x.Done) ok=$($x.R.Ok) error=$($x.R.Error)"
$ms2 = New-Object System.IO.MemoryStream(, $data)
$x = Invoke-StreamBoundedInRunspace $ms2 40 5000
Assert-Coord 'C23 a stream holding 100 bytes read with -MaxBytes 40: Ok, the first 40 bytes' ($x.Done -and $x.R.Ok -and @($x.R.Bytes).Count -eq 40 -and [Convert]::ToBase64String([byte[]]$x.R.Bytes) -ceq [Convert]::ToBase64String([byte[]]$data[0..39])) "done=$($x.Done) ok=$($x.R.Ok) count=$(@($x.R.Bytes).Count)"

# Each reader passes its -TimeoutMs on to the helper: the wrapper records what the
# helper is called with, then runs the real one. A reader that drops the bound
# calls it with none (0), or not at all, and these rows go red.
$global:origStreamReader = (Get-Command Read-CoordStreamBounded -CommandType Function).ScriptBlock
$global:streamCalls = New-Object System.Collections.Generic.List[string]
function Read-CoordStreamBounded {
    param($Stream, $MaxBytes, $TimeoutMs)
    $global:streamCalls.Add([string]$TimeoutMs)
    & $global:origStreamReader -Stream $Stream -MaxBytes $MaxBytes -TimeoutMs $TimeoutMs
}
try {
    $ix = Get-CoordIndexedLedgers -Path $pT -TimeoutMs 7777
    $cv = @($global:streamCalls | ForEach-Object { [int]$_ })
    Assert-Coord 'C23 Get-CoordIndexedLedgers passes its -TimeoutMs to Read-CoordStreamBounded (called, every time a positive value no larger than the bound, the first near it)' ($ix.Ok -and $cv.Count -ge 1 -and @($cv | Where-Object { $_ -le 0 -or $_ -gt 7777 }).Count -eq 0 -and $cv[0] -ge 5000) "ok=$($ix.Ok) calls=$($cv -join ',')"
    $global:streamCalls.Clear()
    New-TracksLedger $lp
    $b = Read-CoordLedgerTracksBounded -Path $lp -TimeoutMs 7777
    $cv = @($global:streamCalls | ForEach-Object { [int]$_ })
    Assert-Coord 'C23 Read-CoordLedgerTracksBounded passes its -TimeoutMs to Read-CoordStreamBounded (called, every time a positive value no larger than the bound, the first near it)' ($b.Ok -and $cv.Count -ge 1 -and @($cv | Where-Object { $_ -le 0 -or $_ -gt 7777 }).Count -eq 0 -and $cv[0] -ge 5000) "ok=$($b.Ok) calls=$($cv -join ',')"
}
finally { Set-Item -Path 'Function:\Read-CoordStreamBounded' -Value $global:origStreamReader }

Write-Host "(C24) ledger date, rooted Repo path, local fixed path, argument quoting"
# Get-CoordLedgerDate: the leaf when ALL of it is yyyy-MM-dd; \z, so a trailing LF is not a date.
$todayC24 = Get-CoordToday
foreach ($c in @(
        @('2026-10-15', '2026-10-15'), @('2026-02-28', '2026-02-28'), @('2026-13-45', $todayC24), @('2026-02-30', $todayC24),
        @((([char]0x0662).ToString() + '026-10-15'), $todayC24), @("2026-10-15`n", $todayC24), @('2026-10-1', $todayC24), @('x2026-10-15', $todayC24),
        @('2026-10-15x', $todayC24), @('', $todayC24), @('not-a-date', $todayC24))) {
    $got = Get-CoordLedgerDate $c[0]
    Assert-Coord ("C24 Get-CoordLedgerDate '" + ($c[0] -replace "`n", '<LF>') + "' -> '" + ($c[1] -replace "`n", '<LF>') + "'") ($got -ceq $c[1]) $got
}
# ConvertTo-CoordRootedPath: one rooted full path, or $null.
if (Test-CoordWindows) {
    foreach ($c in @(
            @('C:\a\b', 'C:\a\b'), @('C:/a/b', 'C:\a\b'), @('C:\a\b\', 'C:\a\b'), @('  C:\a  ', 'C:\a'), @('c:\a', 'c:\a'), @('\\host\share\', '\\host\share'), @('\\host\share\x', '\\host\share\x'))) {
        $got = ConvertTo-CoordRootedPath $c[0]
        Assert-Coord "C24 ConvertTo-CoordRootedPath '$($c[0])' -> '$($c[1])'" ($got -ceq $c[1]) "got '$got'"
    }
    foreach ($bad in @('', '   ', 'alpha', 'C:a', '/c/x', '\a', '.\x', 'Fx\x', '\\host', '\\?\C:\x', '\\.\C:\x', 'C:\', 'c:\', 'C:\.', 'C:\..', 'C:/', 'C:\a, C:\b', 'C:\a; C:\b', 'C:\a (main)')) {
        $got = ConvertTo-CoordRootedPath $bad
        Assert-Coord "C24 ConvertTo-CoordRootedPath '$bad' -> `$null" ($null -eq $got) "got '$got'"
    }
    # Test-CoordLocalFixedPath
    $sysDrive = [System.IO.Path]::GetPathRoot($env:SystemRoot)
    $fx = Test-CoordLocalFixedPath ($sysDrive + 'Windows')
    Assert-Coord 'C24 Test-CoordLocalFixedPath: a path on the system drive is a local fixed path' ($fx.Ok -and $fx.Type -ceq 'Fixed') "Ok=$($fx.Ok) Type=$($fx.Type)"
    $unc = Test-CoordLocalFixedPath '\\localhost\share\x'
    Assert-Coord 'C24 Test-CoordLocalFixedPath: a UNC path is not' ((-not $unc.Ok) -and $unc.Type -ceq 'Network') "Ok=$($unc.Ok) Type=$($unc.Type)"
    $used = @([System.IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpperInvariant() })
    $free = @('Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z') | Where-Object { $used -cnotcontains $_ } | Select-Object -First 1
    if ($free) {
        $gone = Test-CoordLocalFixedPath ($free + ':\x')
        Assert-Coord "C24 Test-CoordLocalFixedPath: a path on a drive that does not exist ($free`:) is not" (-not $gone.Ok) "Ok=$($gone.Ok) Type=$($gone.Type)"
    }
    else { Write-CoordUnchecked 'C24 Test-CoordLocalFixedPath on a missing drive' 'every drive letter from Q to Z is in use' }
}
else {
    Write-CoordUnchecked 'C24 ConvertTo-CoordRootedPath and Test-CoordLocalFixedPath (Windows forms)' 'not Windows'
    Assert-Coord 'C24 ConvertTo-CoordRootedPath: a path from / is rooted; //host and a drive letter are not' ((ConvertTo-CoordRootedPath '/a/b') -ceq '/a/b' -and $null -eq (ConvertTo-CoordRootedPath '//h/s') -and $null -eq (ConvertTo-CoordRootedPath 'C:\a'))
}
# ConvertTo-CoordArgLine: backslashes are doubled only in front of the closing quote.
# '$' would also match before a final LF and double the backslash that sits before it.
$lf = "`n"
foreach ($c in @(
        @(("a\" + $lf), ('"a\' + $lf + '"')), @(("a b\" + $lf), ('"a b\' + $lf + '"')), @(("a\\" + $lf), ('"a\\' + $lf + '"')),
        @('a b\', '"a b\\"'), @('a b\\', '"a b\\\\"'), @('a\', 'a\'), @('a"b', '"a\"b"'), @('a\"b', '"a\\\"b"'), @('', '""'), @('x y', '"x y"'))) {
    $got = ConvertTo-CoordArgLine @($c[0])
    $show = { param($s) ($s -replace "`n", '<LF>') }
    Assert-Coord ("C24 ConvertTo-CoordArgLine '" + (& $show $c[0]) + "' -> " + (& $show $c[1])) ($got -ceq $c[1]) ("got " + (& $show $got))
}

Write-Host "(C25) Test-CoordGitFloor"
# The parser: -VersionText stands in for the output of `git --version`.
foreach ($c in @(
        @('2.37.9', 'git version 2.37.9', $false, '2.37.9'),
        @('2.37.9 with a Windows suffix', 'git version 2.37.9.windows.1', $false, '2.37.9'),
        @('2.9.5 (the minor is a number, not text)', 'git version 2.9.5', $false, '2.9.5'),
        @('1.9.0', 'git version 1.9.0', $false, '1.9.0'),
        @('2.38.0', 'git version 2.38.0', $true, '2.38.0'),
        @('2.38 with no patch', 'git version 2.38', $true, '2.38'),
        @('2.45.1.windows.1', 'git version 2.45.1.windows.1', $true, '2.45.1'),
        @('2.100.0 (the minor is a number, not text)', 'git version 2.100.0', $true, '2.100.0'),
        @('3.0.0', 'git version 3.0.0', $true, '3.0.0'),
        @('Apple suffix', 'git version 2.39.3 (Apple Git-145)', $true, '2.39.3')
    )) {
    $x = Test-CoordGitFloor -VersionText $c[1]
    Assert-Coord "C25 '$($c[0])': Ok is $($c[2]), Version $($c[3])" ($x.Ok -eq $c[2] -and $x.Version -ceq $c[3]) "ok=$($x.Ok) version=$($x.Version) error=$($x.Error)"
    if ($c[2]) { Assert-Coord "C25 '$($c[0])': no error text" ($x.Error -ceq '') $x.Error }
    else { Assert-Coord "C25 '$($c[0])': one line naming the version found and the 2.38 floor" ($x.Error -notmatch '[\r\n]' -and $x.Error.Contains("git $($c[3]) ") -and $x.Error.Contains('2.38')) $x.Error }
}
foreach ($c in @(
        @('garbage', 'banana'),
        @('empty', ''),
        @('a version without the git prefix', '2.45.1'),
        @('only a major', 'git version 2'),
        @('a letter for the major', 'git version x.45.1')
    )) {
    $x = Test-CoordGitFloor -VersionText $c[1]
    Assert-Coord "C25 unparseable ($($c[0])): refused, one line saying it could not be read and naming 2.38" (-not $x.Ok -and $x.Error -notmatch '[\r\n]' -and $x.Error.Contains('could not be read') -and $x.Error.Contains('2.38')) "ok=$($x.Ok) error=$($x.Error)"
}
# Without -VersionText it runs the first git on PATH: a stub git.cmd answers.
function Invoke-GitFloorWithStub([string]$StubDir) {
    $prev = $env:PATH
    try {
        $env:PATH = $StubDir + [System.IO.Path]::PathSeparator + $prev
        return (Test-CoordGitFloor)
    }
    finally { $env:PATH = $prev }
}
$stubOld = New-GitStub 'floor-old' @('@echo off', 'echo git version 2.37.9.windows.1', 'exit /b 0')
$stubNew = New-GitStub 'floor-new' @('@echo off', 'echo git version 2.45.1.windows.1', 'exit /b 0')
$stubJunk = New-GitStub 'floor-junk' @('@echo off', 'echo not a version', 'exit /b 0')
$x = Invoke-GitFloorWithStub $stubOld
Assert-Coord 'C25 the git on PATH answers 2.37.9: refused, naming 2.37.9 and 2.38' (-not $x.Ok -and $x.Error.Contains('git 2.37.9 ') -and $x.Error.Contains('2.38')) "ok=$($x.Ok) error=$($x.Error)"
$x = Invoke-GitFloorWithStub $stubNew
Assert-Coord 'C25 the git on PATH answers 2.45.1.windows.1: ok' ($x.Ok -and $x.Version -ceq '2.45.1') "ok=$($x.Ok) version=$($x.Version) error=$($x.Error)"
$x = Invoke-GitFloorWithStub $stubJunk
Assert-Coord 'C25 the git on PATH answers text that is no version: refused as unreadable' (-not $x.Ok -and $x.Error.Contains('could not be read')) "ok=$($x.Ok) error=$($x.Error)"

Write-Host "(C21-pre) what the real-index digest covers"
# The digest function itself, pointed at a scratch folder through the fixture's
# $coordRealIndexDir (restored right after). It must change when a top-level
# file or another folder changes, and stay the same when only sessions/ changes.
$savedRealIndexDir = $coordRealIndexDir
try {
    $dg = Join-Path $root 'digest-idx'
    $coordRealIndexDir = $dg
    Assert-Coord 'C21 digest of a folder that does not exist: absent' ((Get-CoordRealIndexDigest) -ceq 'index folder: absent')
    Set-CoordTextFile (Join-Path $dg 'a.ledgers') "one`n"
    Set-CoordTextFile (Join-Path $dg 'other.txt') "x`n"
    Set-CoordTextFile (Join-Path $dg 'sub\f.txt') "y`n"
    Set-CoordTextFile (Join-Path $dg 'sessions\s1.json') "{}`n"
    $d0 = Get-CoordRealIndexDigest
    Set-CoordTextFile (Join-Path $dg 'sessions\s1.json') "{ changed }`n"
    Set-CoordTextFile (Join-Path $dg 'sessions\s2.json') "{}`n"
    Assert-Coord 'C21 a file changed or added only under sessions/ does not change the digest' ((Get-CoordRealIndexDigest) -ceq $d0)
    Set-CoordTextFile (Join-Path $dg 'a.ledgers') "two`n"
    $d1 = Get-CoordRealIndexDigest
    Assert-Coord 'C21 a changed top-level *.ledgers file changes the digest' ($d1 -cne $d0)
    Set-CoordTextFile (Join-Path $dg 'other.txt') "xx`n"
    Assert-Coord 'C21 a changed top-level file that is not *.ledgers changes the digest' ((Get-CoordRealIndexDigest) -cne $d1)
    $d2 = Get-CoordRealIndexDigest
    Set-CoordTextFile (Join-Path $dg 'sub\f.txt') "yy`n"
    Assert-Coord 'C21 a changed file in another subfolder changes the digest' ((Get-CoordRealIndexDigest) -cne $d2)
}
finally { $coordRealIndexDir = $savedRealIndexDir }

Write-Host "(C21) the real index folder"
Assert-Coord 'C21 the real index folder (COORD_INDEX_DIR as before this run, else $HOME/.claude/coordination: its listing and the SHA-256 of every file outside sessions/, or still absent) is unchanged by this run' ((Get-CoordRealIndexDigest) -ceq $realIndexBefore) "before:`n$realIndexBefore`nafter:`n$(Get-CoordRealIndexDigest)"
Write-CoordUncheckedSummary

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "Passed: $script:coordPass  Failed: $script:coordFail"
if ($script:coordFail -gt 0) { exit 1 }
exit 0
