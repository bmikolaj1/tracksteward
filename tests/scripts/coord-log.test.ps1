# Tests for scripts/coord-log.ps1: one stamped line appended under a named
# append-only section of the coordination ledger.
# Ported from the private coordinate toolkit (coord-log.test.ps1), 2026-10-18.
#
# The script runs in this process (`& <script> -Section ... -Text ...`; its
# `exit` ends only the script and sets $LASTEXITCODE), so any text reaches it
# verbatim. L12, L15, L17 and L19 also run it through powershell.exe -File
# (the Bash-tool route; the documented call is the in-process one).
#
# Dropped rows (the public ledger template has no "v2 field notes" section, so
# the script no longer appends to one):
#   - L1 "v2 field notes" appended after the section's last line (one of four
#     section rows; the Decisions, Findings and Log rows stay)
#   - L13 the real template accepts a line in "v2 field notes" (the template
#     has three append-only sections, not four)
# Retargeted rows: L2 (a section at the end of the file) appends to Log, now the
# last section of the sample ledger; the sample's last section is "Notes", a
# section the script refuses.
# New rows: L5 refuses -Section 'v2 field notes'; L13 checks that the template's
# append-only sections are exactly the four the script accepts (Queue, Decisions,
# Findings, Log); L34 covers the Queue section.
#
#   L1  each append-only section: the line lands after the section's last
#       non-blank line, before the blank line and the next header; every
#       other line is unchanged; the stamp is HH:mm from the clock at the run
#   L2  a section at the end of the file; the trailing newline is kept
#   L3  an empty section (only its comment, or only its header)
#   L4  the section name is case-insensitive; the canonical name is reported
#   L5  sections edited in place, an unknown or empty name, and the dropped
#       "v2 field notes": refused, unchanged
#   L6  text refused: empty, line breaks and control characters (also at
#       either end, before the trim), a leading time;
#       text allowed: a tab, a time later in the line, "1.5", a leading '#' or
#       '-' (the stamp comes first), double quotes
#   L7  surrounding spaces are trimmed
#   L8  encoding: BOM kept / not added, CRLF kept, mixed ends become CRLF, LF kept, non-ASCII text
#       round-trips, a file that is not UTF-8 is refused unchanged
#   L9  the header twice or missing: refused, unchanged
#   L10 a missing ledger is refused and not created
#   L11 without -Ledger: today's ledger, from the main checkout; outside a repo
#       refused
#   L12 through powershell.exe -File: exit 0 written, exit 2 refused; through
#       Git Bash (bash -c, MSYS_NO_PATHCONV=1 powershell.exe -File ...): the
#       text the user's "go" and a text that starts with '/' are persisted
#       exactly (UNCHECKED without a bash.exe other than the WSL launcher); with
#       no git on PATH: the NOT WRITTEN line, exit 2, ledger byte-unchanged
#   L13 the real ledger-template.md accepts a line in each of the four
#       append-only sections (template and script cannot drift)
#   L14 no temp or lock file is left next to the ledger, after a write or a
#       refusal (runs last of the file rows)
#   L15 8 runs in parallel: every line kept, all in the section
#   L16 the lock held by someone else: refused after ~5 s, unchanged; released,
#       the next run writes
#   L17 an unusable -Ledger path: the NOT WRITTEN line and exit 2, in process
#       and through -File; a non-FileSystem path (Env:\...) is refused, and
#       nothing is written under the process directory
#   L18 the ledger changes between the read and the re-check before the swap
#       (a global Get-Date that appends to it): refused, the editor's line kept
#   L19 words left over after the parameters (how a 5.1 caller splits a
#       quoted -Text), also without -Ledger (no positional binding) and an
#       unknown -parameter: refused with exit 2, in process and through -File
#   L20 the swap's first try fails (a handle without delete sharing): released
#       during the retry, written; an editor's write during the retry, refused
#   L21 a read-only ledger: every try fails, refused, temp file removed
#   L22 the ledger gone when the run fails (deleted during the retry, as a
#       half-failed swap leaves it; moved away before the swap, as a day-close
#       archive does): refused, never recreated, the temp file kept and named
#   L23 a run that dies in process while holding the lock (an injected throw)
#       releases it
#   L24 without -Ledger from a linked worktree: refused (it would reach the
#       main checkout's live ledger); with -Ledger: written
#   L25 a relative -Ledger after cd resolves against the PowerShell location
#   The scope guard's ledger index. The whole run uses a scratch COORD_INDEX_DIR:
#   L26 a canonical ledger (today's, in the repo's main checkout) is registered
#       in the index before the line is appended; a repeat adds no index line
#   L27 a failed registration (a full index): exit 2, ledger byte-unchanged,
#       refused before the ledger lock is taken; the same call later is written once
#   L28 a ledger that is not today's canonical one (scratch, stale worktree copy,
#       another day) is appended to and not registered
#   L29 -Register: registers and writes nothing to the ledger; not canonical,
#       a full index, -Section/-Text, a linked worktree: exit 2
#   L30 the real index folder is unchanged at the end of the run
#   L31 git failing on a canonical-shaped ledger: exit 2, "cannot tell whether", ledger
#       and index unchanged; control: a stale worktree copy is still appended
#   L32 the Bash form shown in the script header and in SKILL.md (same text),
#       run as written through Git Bash, plugin root in C:/... and /c/... form:
#       exit 0 and a text starting with '/' written intact; controls: without
#       cygpath -w a /c/... script path is not found, without MSYS_NO_PATHCONV=1
#       the leading / is rewritten (UNCHECKED without a Git Bash)
#   L35 {now} in -Text: every one becomes the stamp's HH:mm (as coord-set.ps1)
#   L34 the Queue section: a Q<n> line and an outcome line append like any
#       other; a ledger with no ## Queue is refused; the section list names Queue
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\scripts\coord-log.test.ps1 [-ScriptPath <mutant copy of coord-log.ps1>]
#       (a mutant copy needs coord-common.ps1 next to it: it dot-sources it)
# Exit: 0 = all passed, 1 = a case failed.
# The mutants run against this suite are listed in the slice's PR body.
#
# NOT covered: checking that the ledger exists before taking the lock, not
# under it. The race it guards against (another run's swap leaves no file at
# the name for an instant) has no row of its own here.
param([string]$ScriptPath = '')

$testsDir = Split-Path -Parent $PSScriptRoot
$fixturesDir = Join-Path $testsDir 'fixtures'
try { . (Join-Path $fixturesDir 'hook-test-fixture.ps1') } catch { Write-Error "could not load hook-test-fixture.ps1: $_"; exit 1 }
Clear-HookRunnerGitEnv
. (Join-Path $fixturesDir 'coord-test-fixture.ps1')
if (-not $ScriptPath) { $ScriptPath = Join-Path $coordScriptsDir 'coord-log.ps1' }
$ScriptPath = [System.IO.Path]::GetFullPath($ScriptPath)
. (Join-Path $coordScriptsDir 'coord-common.ps1')
$ErrorActionPreference = 'Stop'

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('coord-log-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory($root)
# Nothing in this run may reach the real index folder.
$realIndexBefore = Get-CoordRealIndexDigest
$null = New-CoordScratchIndex $root

$sample = @(
    '# Coordination ledger - 2026-10-10',
    '',
    '## Baseline',
    '',
    '| Repo | origin/main | Open PRs | CI | Verified at |',
    '|------|-------------|----------|----|-------------|',
    '',
    '## Owed checks',
    '',
    '- [ ] one',
    '',
    '## Decisions',
    '',
    '<!-- HH:MM "the user''s words, quoted" (where they typed them) -> what it changes -->',
    '10:44 "first" (the user, typed)',
    '',
    '## Findings',
    '',
    '<!-- HH:MM F<n> from <track>: ... -->',
    '',
    '## Log',
    '',
    '<!-- HH:MM <event> -->',
    '10:42 ledger created',
    '  continuation of the 10:42 line',
    '',
    '## Notes',
    '',
    '<!-- free text -->',
    'note one'
)

$caseN = 0
function New-Ledger {
    param([string[]]$Lines, [string]$Nl = "`n", [bool]$Bom = $false, [bool]$TrailingNl = $true)
    $script:caseN++
    $dir = Join-Path $root ('c' + $script:caseN)
    [void][IO.Directory]::CreateDirectory($dir)
    $p = Join-Path $dir 'ledger.md'
    $text = ($Lines -join $Nl)
    if ($TrailingNl) { $text += $Nl }
    [System.IO.File]::WriteAllText($p, $text, (New-Object System.Text.UTF8Encoding($Bom)))
    return $p
}

# Runs the script in this process. Returns { Code; Out; Before; After }.
function Invoke-Log {
    param([string]$Section, [string]$Text, [string]$Ledger = '', [string]$Cwd = '')
    $before = Get-Date
    $global:LASTEXITCODE = $null
    if ($Cwd) { Push-Location -LiteralPath $Cwd -ErrorAction Stop }
    try {
        $out = if ($Ledger) { @(& $ScriptPath -Section $Section -Text $Text -Ledger $Ledger 2>&1) } else { @(& $ScriptPath -Section $Section -Text $Text 2>&1) }
        $code = $LASTEXITCODE
    }
    catch { $out = @("THREW: $_"); $code = 'threw' }
    finally { if ($Cwd) { Pop-Location } }
    return [pscustomobject]@{ Code = $code; Out = (($out | ForEach-Object { [string]$_ }) -join "`n"); Before = $before; After = (Get-Date) }
}

function Get-Stamps($r) {
    return @($r.Before.ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture), $r.After.ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture))
}
function Read-Lines([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return , ([string[]]@("<no file at $Path>")) }
    return , ([string[]]([System.IO.File]::ReadAllText($Path) -split "`r?`n"))
}
function Get-Bytes([string]$Path) { return [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Path)) }

# Expected: $Lines with "<stamp> $Text" inserted at index $At, plus the
# trailing empty element when the file ends in a newline.
function Test-Inserted {
    param([string]$Label, $R, [string]$Path, [string[]]$Lines, [int]$At, [string]$Text, [bool]$TrailingNl = $true)
    $got = Read-Lines $Path
    $ok = $false
    foreach ($s in (Get-Stamps $R)) {
        $exp = [System.Collections.Generic.List[string]]::new($Lines)
        $exp.Insert($At, "$s $Text")
        if ($TrailingNl) { $exp.Add('') }
        if (($got -join "`n") -ceq ($exp -join "`n")) { $ok = $true }
    }
    Assert-Coord $Label ($R.Code -eq 0 -and $ok) "code=$($R.Code) out=$($R.Out)`n--- got ---`n$($got -join "`n")"
}

Write-Host "(L1) each append-only section"
foreach ($c in @(@('Decisions', 15), @('Findings', 19), @('Log', 25))) {
    $p = New-Ledger $sample
    $r = Invoke-Log $c[0] "event for $($c[0])" $p
    Test-Inserted "L1 $($c[0]): appended after the section's last line" $r $p $sample $c[1] "event for $($c[0])"
    $stampOk = $false
    foreach ($s in (Get-Stamps $r)) { if ($r.Out -ceq "COORD-LOG $p [$($c[0])]: $s event for $($c[0])") { $stampOk = $true } }
    Assert-Coord "L1 $($c[0]): reports the ledger, section and line" $stampOk $r.Out
}
$p = New-Ledger $sample
$r = Invoke-Log 'Log' 'second' $p
$r2 = Invoke-Log 'Log' 'third' $p
$got = Read-Lines $p
Assert-Coord 'L1 two appends keep their order' ($got[25] -match ' second$' -and $got[26] -match ' third$' -and $got[27] -ceq '' -and $got[28] -ceq '## Notes') ($got -join "`n")

Write-Host "(L2) section at the end of the file"
# The sample up to the end of its Log section (index 24 is Log's last line).
$logLast = @($sample[0..24])
$p = New-Ledger $logLast -TrailingNl $false
$r = Invoke-Log 'Log' 'last' $p
Test-Inserted 'L2 no trailing newline: appended, still none' $r $p $logLast 25 'last' -TrailingNl $false
$p = New-Ledger ($logLast + @('', ''))
$r = Invoke-Log 'Log' 'last' $p
Test-Inserted 'L2 trailing blank lines: appended before them' $r $p ($logLast + @('', '')) 25 'last'

Write-Host "(L3) empty sections"
$p = New-Ledger $sample
$r = Invoke-Log 'Findings' 'F1 from X: y' $p
Test-Inserted 'L3 only a comment: after the comment' $r $p $sample 19 'F1 from X: y'
$bare = @('# L', '', '## Log', '', '## Notes', '')
$p = New-Ledger $bare
$r = Invoke-Log 'Log' 'x' $p
Test-Inserted 'L3 only the header: right after it' $r $p $bare 3 'x'

Write-Host "(L4) case-insensitive section"
$p = New-Ledger $sample
$r = Invoke-Log 'LOG' 'upper' $p
Test-Inserted 'L4 LOG -> ## Log' $r $p $sample 25 'upper'
Assert-Coord 'L4 reports the canonical name' ($r.Out -match '\[Log\]: ') $r.Out
$p = New-Ledger ($sample | ForEach-Object { if ($_ -ceq '## Log') { '## log  ' } else { $_ } })
$r = Invoke-Log 'Log' 'lower header' $p
Assert-Coord 'L4 a lower-case header with trailing spaces matches' ($r.Code -eq 0 -and (Read-Lines $p)[25] -match ' lower header$') $r.Out

Write-Host "(L5) refused sections"
foreach ($s in @('Baseline', 'Tracks', 'Merge slots', 'Owed checks', 'Nope', '', '  ')) {
    $p = New-Ledger $sample
    $b = Get-Bytes $p
    $r = Invoke-Log $s 'x' $p
    Assert-Coord "L5 '$s' refused, unchanged" ($r.Code -eq 2 -and $r.Out -match '^COORD-LOG: NOT WRITTEN - -Section must be one of' -and (Get-Bytes $p) -ceq $b) "code=$($r.Code) out=$($r.Out)"
}
# A section the private toolkit appended to and the public template does not
# have. The ledger below holds it, so a script that accepted the name would
# write the line; it is refused as a section name, the ledger unchanged.
$p = New-Ledger ($sample + @('', '## v2 field notes', '', '<!-- free text -->', 'note two'))
$b = Get-Bytes $p
$r = Invoke-Log 'v2 field notes' 'x' $p
Assert-Coord "L5 'v2 field notes' refused although the ledger has that section, unchanged" ($r.Code -eq 2 -and $r.Out -match '^COORD-LOG: NOT WRITTEN - -Section must be one of' -and (Get-Bytes $p) -ceq $b) "code=$($r.Code) out=$($r.Out)"

Write-Host "(L6) text"
$refused = @(
    @('empty', ''), @('spaces', '   '), @('LF', "a`nb"), @('CR', "a`rb"), @('CRLF', "a`r`nb"),
    @('NUL', "a$([char]0)b"), @('U+0085', "a$([char]0x85)b"), @('U+2028', "a$([char]0x2028)b"), @('U+2029', "a$([char]0x2029)b"),
    @('trailing LF', "ab`n"), @('leading CR', "`rab"), @('trailing U+2028', "ab$([char]0x2028)"),
    @('10:42', '10:42 typed time'), @('9:05', '9:05 typed'), @('spaces then 10:42', '  10:42 typed')
)
foreach ($c in $refused) {
    $p = New-Ledger $sample
    $b = Get-Bytes $p
    $r = Invoke-Log 'Log' $c[1] $p
    Assert-Coord "L6 refused: $($c[0])" ($r.Code -eq 2 -and $r.Out -match '^COORD-LOG: NOT WRITTEN - -Text ' -and (Get-Bytes $p) -ceq $b) "code=$($r.Code) out=$($r.Out)"
}
foreach ($c in @(@('tab', "a`tb"), @('time later', 'merged at 10:42'), @('1.5', '1.5 days late'), @('10:420', '10:420 is no time'), @('F3', 'F3 from track-a: x | evidence'),
    @('# first', '#154 merged 14:05'), @('## Log', '## Log'), @('quotes', '"merge #40 when ready" (the user, typed) -> x'), @('leading -', '-> merged'))) {
    $p = New-Ledger $sample
    $r = Invoke-Log 'Log' $c[1] $p
    Test-Inserted "L6 allowed: $($c[0])" $r $p $sample 25 $c[1]
}

Write-Host "(L7) trim"
$p = New-Ledger $sample
$r = Invoke-Log 'Log' '   padded   ' $p
Test-Inserted 'L7 surrounding spaces trimmed' $r $p $sample 25 'padded'

Write-Host "(L8) encoding and line ends"
$p = New-Ledger $sample -Bom $true
$r = Invoke-Log 'Log' 'bom' $p
$bytes = [System.IO.File]::ReadAllBytes($p)
Assert-Coord 'L8 BOM kept (exactly one)' ($r.Code -eq 0 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF -and -not ($bytes[3] -eq 0xEF -and $bytes[4] -eq 0xBB)) $r.Out
Test-Inserted 'L8 BOM file: content right' $r $p $sample 25 'bom'
$p = New-Ledger $sample
$r = Invoke-Log 'Log' 'nobom' $p
$bytes = [System.IO.File]::ReadAllBytes($p)
Assert-Coord 'L8 no BOM stays without' ($r.Code -eq 0 -and $bytes[0] -ne 0xEF) $r.Out
$p = New-Ledger $sample -Nl "`r`n"
$r = Invoke-Log 'Log' 'crlf' $p
$t = [System.IO.File]::ReadAllText($p)
Assert-Coord 'L8 CRLF kept on every line' ($r.Code -eq 0 -and ($t -replace "`r`n", '') -notmatch "[`r`n]" -and $t.Contains("crlf`r`n")) $r.Out
Test-Inserted 'L8 CRLF file: content right' $r $p $sample 25 'crlf'
$p = New-Ledger $sample -Nl "`r`n"
$t = [System.IO.File]::ReadAllText($p).Replace("note one`r`n", "note one`n")
[System.IO.File]::WriteAllText($p, $t, $coordUtf8)
$r = Invoke-Log 'Log' 'mixed' $p
$t = [System.IO.File]::ReadAllText($p)
Assert-Coord 'L8 mixed line ends: written with CRLF throughout' ($r.Code -eq 0 -and ($t -replace "`r`n", '') -notmatch "[`r`n]" -and $t.EndsWith("note one`r`n")) $r.Out
$p = New-Ledger $sample
$r = Invoke-Log 'Log' 'lf' $p
Assert-Coord 'L8 LF stays LF' ($r.Code -eq 0 -and -not [System.IO.File]::ReadAllText($p).Contains("`r")) $r.Out
$p = New-Ledger ($sample | ForEach-Object { if ($_ -ceq 'note one') { "Notes 2026-10-09 $([char]0xB7) tools" } else { $_ } })
$r = Invoke-Log 'Log' "caf$([char]0xE9) $([char]0x2192) done" $p
$got = Read-Lines $p
Assert-Coord 'L8 non-ASCII round-trips' ($r.Code -eq 0 -and $got[25] -match "caf$([char]0xE9) $([char]0x2192) done$" -and $got[30] -ceq "Notes 2026-10-09 $([char]0xB7) tools") ($got -join "`n")
$p = New-Ledger $sample
$raw = [System.Collections.Generic.List[byte]]::new([System.IO.File]::ReadAllBytes($p))
$raw.InsertRange(2, [byte[]](0xC3, 0x28))
[System.IO.File]::WriteAllBytes($p, $raw.ToArray())
$b = Get-Bytes $p
$r = Invoke-Log 'Log' 'x' $p
Assert-Coord 'L8 not UTF-8: refused, unchanged' ($r.Code -eq 2 -and $r.Out -match 'not valid UTF-8' -and (Get-Bytes $p) -ceq $b) $r.Out

Write-Host "(L9) header count"
$p = New-Ledger ($sample + @('', '## Log', ''))
$b = Get-Bytes $p
$r = Invoke-Log 'Log' 'x' $p
Assert-Coord 'L9 two headers: refused, unchanged' ($r.Code -eq 2 -and $r.Out -match "found 2 '## Log' headers" -and (Get-Bytes $p) -ceq $b) $r.Out
$p = New-Ledger ($sample | Where-Object { $_ -cne '## Findings' })
$b = Get-Bytes $p
$r = Invoke-Log 'Findings' 'x' $p
Assert-Coord 'L9 no header: refused, unchanged' ($r.Code -eq 2 -and $r.Out -match "found 0 '## Findings' headers" -and (Get-Bytes $p) -ceq $b) $r.Out
$p = New-Ledger ($sample | ForEach-Object { if ($_ -ceq '## Log') { '### Log' } else { $_ } })
$r = Invoke-Log 'Log' 'x' $p
Assert-Coord 'L9 a ### header is not the section' ($r.Code -eq 2) $r.Out

Write-Host "(L10) missing ledger"
$missing = Join-Path $root 'nope\2026-10-10.md'
$r = Invoke-Log 'Log' 'x' $missing
Assert-Coord 'L10 refused, not created' ($r.Code -eq 2 -and $r.Out -match 'no ledger at' -and -not (Test-Path -LiteralPath $missing)) $r.Out

Write-Host "(L11) default ledger"
$repo = Join-Path $root 'repo'
New-HookTestRepo $repo
$today = [DateTime]::Now.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
$dl = Join-Path $repo ".claude\coordination\$today.md"
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $dl))
[System.IO.File]::WriteAllText($dl, (($sample -join "`n") + "`n"), $coordUtf8)
$sub = Join-Path $repo 'docs'
[void][IO.Directory]::CreateDirectory($sub)
$r = Invoke-Log 'Log' 'from a subfolder' -Cwd $sub
Test-Inserted "L11 today's ledger of the current repo" $r $dl $sample 25 'from a subfolder'
$plain = Join-Path $root 'plain'
[void][IO.Directory]::CreateDirectory($plain)
$prevCeil = $env:GIT_CEILING_DIRECTORIES
$env:GIT_CEILING_DIRECTORIES = $root
try { $r = Invoke-Log 'Log' 'x' -Cwd $plain } finally { $env:GIT_CEILING_DIRECTORIES = $prevCeil }
Assert-Coord 'L11 outside a repo: refused' ($r.Code -eq 2 -and $r.Out -match 'not in a git repository; pass -Ledger') $r.Out

Write-Host "(L12) through powershell.exe -File"
$p = New-Ledger $sample
$x = Invoke-HookTestPowerShell -Script $ScriptPath -StartDir $root -ScriptArgs "-Section Log -Text `"via file`" -Ledger `"$p`""
Assert-Coord 'L12 written: exit 0' ($x.Code -eq 0 -and (Read-Lines $p)[25] -match '^\d\d:\d\d via file$') "code=$($x.Code) out=$($x.Out) err=$($x.Err)"
$x = Invoke-HookTestPowerShell -Script $ScriptPath -StartDir $root -ScriptArgs "-Section Tracks -Text `"x`" -Ledger `"$p`""
Assert-Coord 'L12 refused: exit 2' ($x.Code -eq 2 -and ([string]$x.Out) -match 'NOT WRITTEN') "code=$($x.Code) out=$($x.Out) err=$($x.Err)"
# The Bash route the skill documents: bash -c running
# `MSYS_NO_PATHCONV=1 powershell.exe -ExecutionPolicy Bypass -File ...` with the
# text in single quotes, an apostrophe written '\'' and double quotes inside.
# The prefix is part of the documented form; the second Bash row checks that a
# text starting with '/' reaches the ledger intact through it. What the route
# does to such a text without the prefix is tested by L32's no-prefix control row (needs a Git Bash).
# The WSL launcher (System32 or WindowsApps bash.exe) is not used: it runs
# the command in a Linux distribution, not the Git Bash the route is about.
# Git Bash: <Git>\bin\bash.exe, found from where git.exe sits (cmd\, bin\ or mingw64\bin\ under the Git root),
# then the usual install folders. bash.exe on PATH may be the WSL launcher (System32, WindowsApps), which runs
# a Linux distribution and is not Git Bash.
function Find-GitBash {
    $cands = New-Object System.Collections.Generic.List[string]
    $g = (Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if ($g) {
        $d = Split-Path $g
        for ($i = 0; $i -lt 4 -and $d; $i++) { $cands.Add((Join-Path $d 'bin\bash.exe')); $cands.Add((Join-Path $d 'usr\bin\bash.exe')); $d = Split-Path $d }
    }
    $ep = (& git --exec-path 2>$null | Select-Object -First 1)
    if ($ep) { $d = ($ep -replace '/', '\'); for ($i = 0; $i -lt 5 -and $d; $i++) { $cands.Add((Join-Path $d 'bin\bash.exe')); $d = Split-Path $d } }
    foreach ($r in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Programs'))) {
        if ($r) { $cands.Add((Join-Path $r 'Git\bin\bash.exe')) }
    }
    foreach ($c in $cands) { if ($c -notmatch '\\(System32|WindowsApps)\\' -and (Test-Path -LiteralPath $c)) { return $c } }
    return ''
}
$bashExe = Find-GitBash
if (-not $bashExe) {
    # Not silent when a bash is on PATH that the search above missed (a Git layout it does not know).
    $pathBash = @(Get-Command bash.exe -CommandType Application -All -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch '\\(System32|WindowsApps)\\' })
    Assert-Coord 'L12 no bash.exe is on PATH that Find-GitBash missed (else the Git Bash rows would be skipped on a host that has it)' ($pathBash.Count -eq 0) (($pathBash | ForEach-Object { $_.Source }) -join '; ')
    $bashExe = $null
}
# Runs the documented Bash call with $ShText, already quoted for the shell, as
# the -Text value. Returns { Code; Out; Before; After }.
function Invoke-LogViaBash([string]$ShText, [string]$LedgerPath) {
    $shScript = $ScriptPath.Replace('\', '/')
    $shLedger = $LedgerPath.Replace('\', '/')
    $bashCmd = "MSYS_NO_PATHCONV=1 powershell.exe -NoProfile -ExecutionPolicy Bypass -File '$shScript' -Section Log -Text $ShText -Ledger '$shLedger'"
    $bpsi = New-Object System.Diagnostics.ProcessStartInfo
    $bpsi.FileName = $bashExe
    $bpsi.Arguments = '-c "' + ($bashCmd -replace '"', '\"') + '"'
    $bpsi.WorkingDirectory = $root
    $bpsi.UseShellExecute = $false
    $bpsi.RedirectStandardInput = $true
    $bpsi.RedirectStandardOutput = $true
    $bpsi.RedirectStandardError = $true
    $bpsi.CreateNoWindow = $true
    $bBefore = Get-Date
    $bp = [System.Diagnostics.Process]::Start($bpsi)
    $bp.StandardInput.Close()
    $bOutRead = $bp.StandardOutput.ReadToEndAsync()
    $bErrRead = $bp.StandardError.ReadToEndAsync()
    $bCode = 'no exit within 120 s'
    if ($bp.WaitForExit(120000)) { $bp.WaitForExit(); $bCode = $bp.ExitCode }
    else { & taskkill.exe /T /F /PID $bp.Id 2>$null | Out-Null }
    $bOut = if ($bOutRead.Wait(10000)) { [string]$bOutRead.Result } else { '<stdout still open>' }
    $bErr = if ($bErrRead.Wait(10000)) { ([string]$bErrRead.Result).Trim() } else { '<stderr still open>' }
    return [pscustomobject]@{ Code = $bCode; Out = ($bOut + $bErr); Before = $bBefore; After = (Get-Date) }
}
if (-not $bashExe) {
    Write-CoordUnchecked 'L12 through Bash: the text the user''s "go" is persisted exactly' 'no bash.exe (other than the WSL launcher) on PATH'
    Write-CoordUnchecked 'L12 through Bash: a text that starts with / is persisted exactly' 'no bash.exe (other than the WSL launcher) on PATH'
}
else {
    $p = New-Ledger $sample
    $rb = Invoke-LogViaBash ("'the user'\''s `"go`"'") $p
    Test-Inserted 'L12 through Bash: the text the user''s "go" is persisted exactly (apostrophe and double quotes intact), exit 0' $rb $p $sample 25 'the user''s "go"'
    $p = New-Ledger $sample
    $rb = Invoke-LogViaBash "'/review-code returned APPROVE'" $p
    Test-Inserted 'L12 through Bash: a text that starts with / is persisted exactly (not rewritten into a Windows path), exit 0' $rb $p $sample 25 '/review-code returned APPROVE'
}
# No git on PATH: the child's PATH holds only System32. The script refuses at
# once (before it reads or locks the ledger) and says why.
$sysDir = Join-Path $env:SystemRoot 'System32'
$gitInSys = @('git.exe', 'git.cmd', 'git.bat' | Where-Object { Test-Path -LiteralPath (Join-Path $sysDir $_) })
if ($gitInSys.Count -gt 0) { Write-CoordUnchecked 'L12 no git on PATH: NOT WRITTEN, exit 2, ledger unchanged' "System32 holds $($gitInSys -join ', '), so a PATH of System32 alone still has git" }
else {
    $p = New-Ledger $sample
    $bytesBefore = Get-Bytes $p
    $x = Invoke-HookTestPowerShell -Script $ScriptPath -StartDir $root -ExtraEnv @{ PATH = $sysDir } -ScriptArgs "-Section Log -Text `"no git`" -Ledger `"$p`""
    $okOut = ([string]$x.Out).Trim().StartsWith('COORD-LOG: NOT WRITTEN - git is not on PATH', [System.StringComparison]::Ordinal)
    Assert-Coord 'L12 no git on PATH: the NOT WRITTEN line says git is not on PATH, exit 2, ledger byte-unchanged, no lock file left' ($x.Code -eq 2 -and $okOut -and (Get-Bytes $p) -ceq $bytesBefore -and -not (Test-Path -LiteralPath ($p + '.coord-log.lock'))) "code=$($x.Code) out=$($x.Out) err=$($x.Err)"
}

Write-Host "(L13) the real ledger-template.md"
$tpl = Read-Lines (Join-Path $coordTemplatesDir 'ledger-template.md')
if ($tpl[$tpl.Count - 1] -ceq '') { $tpl = $tpl[0..($tpl.Count - 2)] }
# The template's append-only sections are exactly the ones the script accepts:
# every '## ' section but the four edited in place.
$tplAppend = @($tpl | Where-Object { $_ -match '^## ' } | ForEach-Object { $_.Substring(3).Trim() } | Where-Object { @('Baseline', 'Tracks', 'Merge slots', 'Owed checks') -cnotcontains $_ })
Assert-Coord 'L13 the template''s append-only sections are exactly Queue, Decisions, Findings, Log' (($tplAppend -join '|') -ceq 'Queue|Decisions|Findings|Log') ($tplAppend -join '|')
foreach ($s in @('Queue', 'Decisions', 'Findings', 'Log')) {
    $p = New-Ledger $tpl
    $h = [Array]::IndexOf($tpl, "## $s")
    $at = $h + 1
    for ($k = $h + 1; $k -lt $tpl.Count -and $tpl[$k] -notmatch '^#{1,2}\s'; $k++) { if ($tpl[$k].Trim()) { $at = $k + 1 } }
    $r = Invoke-Log $s "tpl $s" $p
    Assert-Coord "L13 template has '## $s'" ($h -ge 0)
    Test-Inserted "L13 template ${s}: after its comment line" $r $p $tpl $at "tpl $s"
}

Write-Host "(L34) the Queue section"
$qs = @($sample[0..10]) + @('## Queue', '', '<!-- HH:MM Q<n> <what> [<gate>] owner: ...; source: ... -->', '09:10 Q1 first item [after #12 merges] owner: coordinator; source: F3', '') + @($sample[11..($sample.Count - 1)])
$p = New-Ledger $qs
$r = Invoke-Log 'Queue' 'Q2 port the next slice [after 2026-10-28 23:00Z] owner: user; source: plan Q3' $p
Test-Inserted 'L34 Queue: a Q<n> line is appended after the section''s last line' $r $p $qs 15 'Q2 port the next slice [after 2026-10-28 23:00Z] owner: user; source: plan Q3'
Assert-Coord 'L34 Queue: reported under its canonical name' ($r.Out -match '\[Queue\]: \d\d:\d\d Q2 ') $r.Out
$p = New-Ledger $qs
$r = Invoke-Log 'queue' 'Q1 outcome: started as track slice-2' $p
Test-Inserted 'L34 queue (lower case) -> ## Queue; an outcome line is an ordinary append' $r $p $qs 15 'Q1 outcome: started as track slice-2'
$p = New-Ledger $sample
$b = Get-Bytes $p
$r = Invoke-Log 'Queue' 'Q1 x' $p
Assert-Coord 'L34 a ledger with no ## Queue section (one made before the section existed): refused, unchanged' ($r.Code -eq 2 -and $r.Out -match "found 0 '## Queue' headers" -and (Get-Bytes $p) -ceq $b) $r.Out
$r = Invoke-Log 'Owed checks' 'x' (New-Ledger $sample)
Assert-Coord 'L34 the refusal for a section edited in place names Queue among the append-only ones' ($r.Code -eq 2 -and $r.Out -match '-Section must be one of: Queue, Decisions, Findings, Log \(got') $r.Out

Write-Host "(L35) {now} in the text"
$p = New-Ledger $sample
$r = Invoke-Log 'Log' 'ACK at {now}, again {now} {x} {NOW}' $p
$gotL = Read-Lines $p
$mL = @($gotL | ForEach-Object { [regex]::Match($_, '^(\d\d:\d\d) ACK at (\d\d:\d\d), again (\d\d:\d\d) \{x\} \{NOW\}$') } | Where-Object { $_.Success })
$okL = ($mL.Count -eq 1) -and ($mL[0].Groups[1].Value -ceq $mL[0].Groups[2].Value) -and ($mL[0].Groups[1].Value -ceq $mL[0].Groups[3].Value) -and ((Get-Stamps $r) -contains $mL[0].Groups[1].Value)
Assert-Coord 'L35 every {now} in -Text becomes the stamp''s HH:mm (one clock read); {x} and {NOW} stay as typed' ($r.Code -eq 0 -and $okL -and $gotL.Count -eq ($sample.Count + 2)) "code=$($r.Code) out=$($r.Out)`n$($gotL -join "`n")"
Assert-Coord 'L35 the printed line shows the expanded text' ($r.Out -match '\[Log\]: \d\d:\d\d ACK at \d\d:\d\d, again \d\d:\d\d \{x\}') $r.Out

Write-Host "(L15) parallel runs"
$p = New-Ledger $sample
$procs = @()
for ($i = 1; $i -le 8; $i++) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Get-HookTestShellPath
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -Section Log -Text `"par $i`" -Ledger `"$p`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $procs += [System.Diagnostics.Process]::Start($psi)
}
$codes = @()
$outs = @()
foreach ($pr in $procs) { $outs += $pr.StandardOutput.ReadToEnd().Trim(); [void]$pr.WaitForExit(120000); $codes += $pr.ExitCode }
$got = Read-Lines $p
$par = @($got | Where-Object { $_ -match '^\d\d:\d\d par \d$' })
$tail = @($got[25..32] | Where-Object { $_ -match '^\d\d:\d\d par \d$' })
$each = @(1..8 | Where-Object { $i = $_; @($got | Where-Object { $_ -match "^\d\d:\d\d par $i$" }).Count -eq 1 })
$rest = @($got[0..24]) + @($got[33..($got.Count - 1)])
$restExp = @($sample[0..24]) + @($sample[25..($sample.Count - 1)]) + @('')
Assert-Coord 'L15 8 parallel runs: all exit 0, par 1..8 each once, in the Log section, the rest intact' (($codes | Where-Object { $_ -ne 0 }).Count -eq 0 -and $par.Count -eq 8 -and $tail.Count -eq 8 -and $each.Count -eq 8 -and ($rest -join "`n") -ceq ($restExp -join "`n") -and $got[33] -ceq '' -and $got[34] -ceq '## Notes') "codes=$($codes -join ',')`n$($outs -join "`n")`n--- ledger ---`n$($got -join "`n")"

Write-Host "(L16) a held lock"
$p = New-Ledger $sample
$b = Get-Bytes $p
$held = New-Object System.IO.FileStream(($p + '.coord-log.lock'), [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
try { $r = Invoke-Log 'Log' 'x' $p } finally { $held.Dispose() }
Assert-Coord 'L16 lock held elsewhere: refused after waiting, unchanged' ($r.Code -eq 2 -and $r.Out -match 'cannot take .*coord-log\.lock within 5 s' -and (Get-Bytes $p) -ceq $b -and ($r.After - $r.Before).TotalSeconds -ge 4) "code=$($r.Code) out=$($r.Out)"
Remove-Item -LiteralPath ($p + '.coord-log.lock') -Force -ErrorAction SilentlyContinue
$r = Invoke-Log 'Log' 'after release' $p
Test-Inserted 'L16 lock released: the next run writes' $r $p $sample 25 'after release'

Write-Host "(L17) unusable -Ledger path"
$r = Invoke-Log 'Log' 'x' 'C:\bad|path.md'
Assert-Coord 'L17 in process: refused with the NOT WRITTEN line' ($r.Code -eq 2 -and $r.Out -match '^COORD-LOG: NOT WRITTEN - -Ledger is not a usable path') $r.Out
$x = Invoke-HookTestPowerShell -Script $ScriptPath -StartDir $root -ScriptArgs '-Section Log -Text x -Ledger "C:\bad|path.md"'
Assert-Coord 'L17 through -File: exit 2, NOT WRITTEN' ($x.Code -eq 2 -and ([string]$x.Out) -match 'NOT WRITTEN - -Ledger is not a usable path') "code=$($x.Code) out=$($x.Out) err=$($x.Err)"
$envProbe = Join-Path ([Environment]::CurrentDirectory) 'coord-log-envprobe.md'
$r = Invoke-Log 'Log' 'x' 'Env:\coord-log-envprobe.md'
Assert-Coord 'L17 a non-FileSystem -Ledger: refused, nothing under the process directory' ($r.Code -eq 2 -and $r.Out -match '-Ledger is not a file path \(provider Environment\)' -and -not (Test-Path -LiteralPath $envProbe)) $r.Out

Write-Host "(L18) the ledger changes between the read and the swap"
# The script's one Get-Date call sits between its read and its re-check, so a
# global Get-Date that appends to the ledger is an editor writing in that window.
$p = New-Ledger $sample
$global:l18Ledger = $p
function global:Get-Date { [System.IO.File]::AppendAllText($global:l18Ledger, "editor line`n"); Microsoft.PowerShell.Utility\Get-Date @args }
$global:LASTEXITCODE = $null
try { $out = (@(& $ScriptPath -Section Log -Text 'x' -Ledger $p 2>&1) | ForEach-Object { [string]$_ }) -join "`n"; $code = $LASTEXITCODE }
catch { $out = "THREW: $_"; $code = 'threw' }
finally { Remove-Item -LiteralPath 'Function:\Get-Date' -Force -ErrorAction SilentlyContinue }
$exp = (($sample -join "`n") + "`neditor line`n")
Assert-Coord "L18 refused; the editor's line kept, no line of ours" ($code -eq 2 -and $out -match 'changed while this run read it' -and [System.IO.File]::ReadAllText($p) -ceq $exp) "code=$code out=$out"

Write-Host "(L19) leftover arguments"
$p = New-Ledger $sample
$b = Get-Bytes $p
$global:LASTEXITCODE = $null
$out = (@(& $ScriptPath -Section Decisions -Text merge '#40' when ready -Ledger $p 2>&1) | ForEach-Object { [string]$_ }) -join "`n"
Assert-Coord 'L19 in process: words after the parameters refused, unchanged' ($LASTEXITCODE -eq 2 -and $out -match 'unexpected words after the parameters \(#40 when ready\)' -and (Get-Bytes $p) -ceq $b) "code=$LASTEXITCODE out=$out"
$x = Invoke-HookTestPowerShell -Script $ScriptPath -StartDir $root -ScriptArgs "-Section Decisions -Text merge #40 when ready -Ledger `"$p`""
Assert-Coord 'L19 through -File: the split a 5.1 caller makes is refused, exit 2' ($x.Code -eq 2 -and ([string]$x.Out) -match 'NOT WRITTEN - unexpected words' -and (Get-Bytes $p) -ceq $b) "code=$($x.Code) out=$($x.Out) err=$($x.Err)"

# No -Ledger: the first leftover word must not bind to -Ledger by position.
$global:LASTEXITCODE = $null
$out = (@(& $ScriptPath -Section Log -Text merge 40 2>&1) | ForEach-Object { [string]$_ }) -join "`n"
Assert-Coord 'L19 no -Ledger, in process: refused as leftover words, not read as a ledger path' ($LASTEXITCODE -eq 2 -and $out -match 'unexpected words after the parameters \(40\)') "code=$LASTEXITCODE out=$out"
$x = Invoke-HookTestPowerShell -Script $ScriptPath -StartDir $root -ScriptArgs '-Section Decisions -Text merge #40 (the user, typed)'
Assert-Coord 'L19 no -Ledger, through -File: refused as leftover words' ($x.Code -eq 2 -and ([string]$x.Out) -match 'unexpected words after the parameters \(#40 \(the user, typed\)\)') "code=$($x.Code) out=$($x.Out) err=$($x.Err)"
$x = Invoke-HookTestPowerShell -Script $ScriptPath -StartDir $root -ScriptArgs "-Section Log -Text x -Bogus y -Ledger `"$p`""
Assert-Coord 'L19 an unknown -parameter is a leftover word: exit 2, not a binder error' ($x.Code -eq 2 -and ([string]$x.Out) -match 'unexpected words after the parameters \(-Bogus y\)' -and (Get-Bytes $p) -ceq $b) "code=$($x.Code) out=$($x.Out) err=$($x.Err)"

Write-Host "(L20) the swap is retried"
# A handle without delete sharing fails File.Replace; the script's retry sleep
# is a global Start-Sleep that releases it (and, in L20b, writes as an editor).
foreach ($v in @('a', 'b')) {
    $p = New-Ledger $sample
    $global:l20Handle = [System.IO.File]::Open($p, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $global:l20Ledger = $p
    $global:l20Edit = ($v -eq 'b')
    $global:l20Sleeps = 0
    function global:Start-Sleep {
        $global:l20Sleeps++
        if ($global:l20Handle) { $global:l20Handle.Dispose(); $global:l20Handle = $null; if ($global:l20Edit) { [System.IO.File]::AppendAllText($global:l20Ledger, "editor line`n") } }
        Microsoft.PowerShell.Utility\Start-Sleep @args
    }
    try { $r = Invoke-Log 'Log' "retry $v" $p }
    finally { Remove-Item -LiteralPath 'Function:\Start-Sleep' -Force -ErrorAction SilentlyContinue; if ($global:l20Handle) { $global:l20Handle.Dispose(); $global:l20Handle = $null } }
    if ($v -eq 'a') {
        Assert-Coord 'L20a the first try failed (the retry ran)' ($global:l20Sleeps -ge 1) "sleeps=$($global:l20Sleeps)"
        Test-Inserted 'L20a handle released during the retry: written' $r $p $sample 25 'retry a'
    }
    else {
        $exp = (($sample -join "`n") + "`neditor line`n")
        Assert-Coord "L20b an editor's write during the retry: refused, its line kept" ($r.Code -eq 2 -and $r.Out -match 'changed while this run read it' -and [System.IO.File]::ReadAllText($p) -ceq $exp) "code=$($r.Code) out=$($r.Out)"
    }
}

Write-Host "(L21) a read-only ledger"
$p = New-Ledger $sample
$b = Get-Bytes $p
Set-ItemProperty -LiteralPath $p -Name IsReadOnly -Value $true
try { $r = Invoke-Log 'Log' 'x' $p } finally { Set-ItemProperty -LiteralPath $p -Name IsReadOnly -Value $false }
Assert-Coord 'L21 every try fails: refused, unchanged, temp file removed' ($r.Code -eq 2 -and $r.Out -match '^COORD-LOG: NOT WRITTEN - cannot write ' -and (Get-Bytes $p) -ceq $b -and @(Get-ChildItem -LiteralPath (Split-Path -Parent $p) -Filter '*.tmp').Count -eq 0) "code=$($r.Code) out=$($r.Out)"

Write-Host "(L22) the ledger is gone when the run fails"
# L22a: the first Replace fails on a held handle and the retry sleep deletes the
# ledger (the state a half-failed swap leaves). L22b: Get-Date, between the
# read and the first re-check, moves the ledger away like a day-close archive.
# Either way the ledger is not recreated and the temp file is kept and named.
foreach ($v in @('a', 'b')) {
    $p = New-Ledger $sample
    $global:l22Ledger = $p
    $global:l22Handle = $null
    if ($v -eq 'a') {
        $global:l22Handle = [System.IO.File]::Open($p, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        function global:Start-Sleep {
            if ($global:l22Handle) { $global:l22Handle.Dispose(); $global:l22Handle = $null; [System.IO.File]::Delete($global:l22Ledger) }
            Microsoft.PowerShell.Utility\Start-Sleep @args
        }
    }
    else {
        function global:Get-Date { [System.IO.File]::Move($global:l22Ledger, $global:l22Ledger + '.archived'); Remove-Item -LiteralPath 'Function:\Get-Date' -Force; Microsoft.PowerShell.Utility\Get-Date @args }
    }
    $global:LASTEXITCODE = $null
    try { $out = (@(& $ScriptPath -Section Log -Text "gone $v" -Ledger $p 2>&1) | ForEach-Object { [string]$_ }) -join "`n"; $code = $LASTEXITCODE }
    catch { $out = "THREW: $_"; $code = 'threw' }
    finally {
        Remove-Item -LiteralPath 'Function:\Start-Sleep', 'Function:\Get-Date' -Force -ErrorAction SilentlyContinue
        if ($global:l22Handle) { $global:l22Handle.Dispose(); $global:l22Handle = $null }
    }
    $tmps = @(Get-ChildItem -LiteralPath (Split-Path -Parent $p) -Filter '*.coord-log-*.tmp')
    $tmpText = if ($tmps.Count -eq 1) { Read-Lines $tmps[0].FullName } else { @() }
    $tmpOk = ($tmpText.Count -eq ($sample.Count + 2) -and $tmpText[25] -match "^\d\d:\d\d gone $v$" -and (($tmpText[0..24] + $tmpText[26..($tmpText.Count - 1)]) -join "`n") -ceq (($sample + @('')) -join "`n"))
    Assert-Coord "L22$v refused, the ledger not recreated, the temp file kept, named and complete" ($code -eq 2 -and $out -match 'is gone \(moved away, or a failed swap\)' -and $tmps.Count -eq 1 -and $out.Contains($tmps[0].FullName) -and $tmpOk -and -not (Test-Path -LiteralPath $p)) "code=$code out=$out tmps=$($tmps.Count)"
    if ($v -eq 'b') { Assert-Coord 'L22b the archived copy is untouched' ([System.IO.File]::ReadAllText($p + '.archived') -ceq (($sample -join "`n") + "`n")) }
    foreach ($t in $tmps) { Remove-Item -LiteralPath $t.FullName -Force }
}

Write-Host "(L23) the lock after a run that dies in process"
# The script is called directly: Invoke-Log's own Get-Date would throw first.
$p = New-Ledger $sample
$global:l23Locked = $null
function global:Get-Date { $global:l23Locked = Test-Path -LiteralPath ($global:l23Ledger + '.coord-log.lock'); throw 'injected failure' }
$global:l23Ledger = $p
$died = ''
try { & $ScriptPath -Section Log -Text 'dies' -Ledger $p | Out-Null } catch { $died = "$_" } finally { Remove-Item -LiteralPath 'Function:\Get-Date' -Force -ErrorAction SilentlyContinue }
Assert-Coord 'L23 the run died inside the script, holding the lock' ($died -match 'injected failure' -and $global:l23Locked -eq $true) "died=$died locked=$($global:l23Locked)"
Assert-Coord 'L23 the dying run left no lock file' (-not (Test-Path -LiteralPath ($p + '.coord-log.lock')))
$r = Invoke-Log 'Log' 'next' $p
Test-Inserted 'L23 the next run in the same process writes' $r $p $sample 25 'next'
Assert-Coord 'L23 ... without waiting for the lock' (($r.After - $r.Before).TotalSeconds -lt 3) "took $(($r.After - $r.Before).TotalSeconds) s"

Write-Host "(L24) no default ledger from a linked worktree"
Set-CoordFile $repo 'README.md' "readme`n"
Invoke-HookTestGit $repo @('-c', 'core.autocrlf=false', 'add', 'README.md')
Invoke-HookTestGit $repo @('-c', 'core.autocrlf=false', 'commit', '--quiet', '-m', 'base')
$wt = Join-Path $root 'repo-wt'
Invoke-HookTestGit $repo @('worktree', 'add', '--quiet', '-b', 'wt', $wt)
$b = Get-Bytes $dl
$r = Invoke-Log 'Log' 'from a worktree' -Cwd $wt
Assert-Coord "L24 refused from a linked worktree; the main checkout's ledger unchanged" ($r.Code -eq 2 -and $r.Out -match "is not the repo's main checkout; pass -Ledger" -and (Get-Bytes $dl) -ceq $b) $r.Out
$r = Invoke-Log 'Log' 'named from a worktree' $dl -Cwd $wt
Assert-Coord 'L24 with -Ledger from a linked worktree: written' ($r.Code -eq 0 -and @((Read-Lines $dl) -match ' named from a worktree$').Count -eq 1) $r.Out

Write-Host "(L25) a relative -Ledger after cd"
# In process, Set-Location moves the PowerShell location, not the process
# directory: the relative path must resolve against the former.
$p = New-Ledger $sample
$r = Invoke-Log 'Log' 'relative' 'ledger.md' -Cwd (Split-Path -Parent $p)
Test-Inserted 'L25 resolved against the PowerShell location' $r $p $sample 25 'relative'

Write-Host "(L26) a canonical ledger is registered before the line is appended"
# The scope guard finds ledgers through the index <COORD_INDEX_DIR>\<date>.ledgers.
# This whole run uses a scratch COORD_INDEX_DIR; L30 checks the real index folder
# was not touched.
function Get-IdxText([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '<no file>' }
    return $coordUtf8.GetString([System.IO.File]::ReadAllBytes($Path))
}
$l26Today = Get-CoordToday
$sampleText = ($sample -join "`n") + "`n"
$canonRepo = New-CoordCanonRepo $root 'canon' -Commit
$canonLedger = New-CoordCanonLedger $canonRepo $l26Today -Text $sampleText
$canonWt = Join-Path $root 'canon-wt'
New-HookTestWorktree -Repo $canonRepo -Path $canonWt -Branch 'canon-wt'
$null = New-CoordScratchIndex $root
$idxFile = Get-CoordIndexPath
$r = Invoke-Log 'Log' 'canon event' $canonLedger
Test-Inserted 'L26 a canonical ledger: the line is appended' $r $canonLedger $sample 25 'canon event'
Assert-Coord 'L26 ... and the ledger is registered: the index of today holds its full path on one line' ((Get-IdxText $idxFile) -ceq ($canonLedger + "`n")) (Get-IdxText $idxFile)
$r = Invoke-Log 'Log' 'canon event two' $canonLedger
Assert-Coord 'L26 a second append: written, and the repeat registration adds no line' ($r.Code -eq 0 -and (Get-IdxText $idxFile) -ceq ($canonLedger + "`n")) "code=$($r.Code) out=$($r.Out)`n$(Get-IdxText $idxFile)"

Write-Host "(L27) a registration that fails: nothing is appended"
$null = New-CoordScratchIndex $root
$idxFile = Get-CoordIndexPath
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $idxFile))
$fake = @(1..8 | ForEach-Object { "C:\Seed\r$_\.claude\coordination\$l26Today.md" })
$seedFull = ($fake -join "`n") + "`n"
[System.IO.File]::WriteAllBytes($idxFile, $coordUtf8.GetBytes($seedFull))
$b = Get-Bytes $canonLedger
$r = Invoke-Log 'Log' 'refused event' $canonLedger
Assert-Coord 'L27 eight distinct ledgers already: exit 2, "ledger not registered", ledger byte-unchanged' ($r.Code -eq 2 -and $r.Out -match '^COORD-LOG: NOT WRITTEN - ledger not registered: ' -and (Get-Bytes $canonLedger) -ceq $b) "code=$($r.Code) out=$($r.Out)"
Assert-Coord 'L27 ... the index unchanged and no temp file next to the ledger' ((Get-IdxText $idxFile) -ceq $seedFull -and @(Get-ChildItem -LiteralPath (Split-Path -Parent $canonLedger) -Filter '*.coord-log-*.tmp').Count -eq 0) (Get-IdxText $idxFile)
# Registration comes BEFORE the lock on the ledger: with that lock held by someone
# else the refusal is still the registration's, at once, not "cannot take ... lock" after 5 s.
$held = New-Object System.IO.FileStream(($canonLedger + '.coord-log.lock'), [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
try { $r = Invoke-Log 'Log' 'refused event' $canonLedger } finally { $held.Dispose() }
Remove-Item -LiteralPath ($canonLedger + '.coord-log.lock') -Force -ErrorAction SilentlyContinue
Assert-Coord 'L27 registration runs before the ledger lock is taken: refused for the index, within 3 s, with the ledger lock held' ($r.Code -eq 2 -and $r.Out -match 'ledger not registered' -and ($r.After - $r.Before).TotalSeconds -lt 3 -and (Get-Bytes $canonLedger) -ceq $b) "code=$($r.Code) out=$($r.Out) seconds=$(($r.After - $r.Before).TotalSeconds)"
Remove-Item -LiteralPath $idxFile -Force
$r = Invoke-Log 'Log' 'retry event' $canonLedger
$gotRetry = Read-Lines $canonLedger
Assert-Coord 'L27 the same call again, once the index has room: written exactly once, and the refused call left no line' ($r.Code -eq 0 -and @($gotRetry -match ' retry event$').Count -eq 1 -and @($gotRetry -match ' refused event$').Count -eq 0) "code=$($r.Code) out=$($r.Out)"

Write-Host "(L28) a ledger that is not today's canonical one: appended to, not registered"
$null = New-CoordScratchIndex $root
$idxFile = Get-CoordIndexPath
$p = New-Ledger $sample
$r = Invoke-Log 'Log' 'scratch' $p
Test-Inserted 'L28 a scratch ledger outside any repo: appended' $r $p $sample 25 'scratch'
Assert-Coord 'L28 ... and nothing was registered' (-not (Test-Path -LiteralPath $idxFile))
$staleLedger = Join-Path $canonWt ".claude\coordination\$l26Today.md"
Set-CoordTextFile $staleLedger $sampleText
$r = Invoke-Log 'Log' 'stale copy' $staleLedger
Test-Inserted 'L28 the stale copy in a linked worktree: appended' $r $staleLedger $sample 25 'stale copy'
Assert-Coord 'L28 ... and nothing was registered' (-not (Test-Path -LiteralPath $idxFile))
$oldLedger = New-CoordCanonLedger $canonRepo '2026-01-01' -Text $sampleText
$r = Invoke-Log 'Log' 'old day' $oldLedger
Test-Inserted 'L28 the main checkout''s ledger of another day: appended' $r $oldLedger $sample 25 'old day'
Assert-Coord 'L28 ... and nothing was registered (only today''s canonical ledger is)' (-not (Test-Path -LiteralPath $idxFile))

Write-Host "(L29) -Register"
function Invoke-LogRegister {
    param([string]$Ledger = '', [string]$Cwd = '', [string]$Section = '', [string]$Text = '')
    $global:LASTEXITCODE = $null
    if ($Cwd) { Push-Location -LiteralPath $Cwd -ErrorAction Stop }
    try {
        $a = @{ Register = $true }
        if ($Ledger) { $a['Ledger'] = $Ledger }
        if ($Section) { $a['Section'] = $Section }
        if ($Text) { $a['Text'] = $Text }
        $out = @(& $ScriptPath @a 2>&1)
        $code = $LASTEXITCODE
    }
    catch { $out = @("THREW: $_"); $code = 'threw' }
    finally { if ($Cwd) { Pop-Location } }
    return [pscustomobject]@{ Code = $code; Out = (($out | ForEach-Object { [string]$_ }) -join "`n") }
}
$null = New-CoordScratchIndex $root
$idxFile = Get-CoordIndexPath
$b = Get-Bytes $canonLedger
$r = Invoke-LogRegister -Ledger $canonLedger
Assert-Coord 'L29 -Register on the canonical ledger: exit 0 and the REGISTERED line' ($r.Code -eq 0 -and $r.Out -ceq "COORD-LOG REGISTERED $canonLedger in $idxFile") "code=$($r.Code) out=$($r.Out)"
Assert-Coord 'L29 ... the index holds the ledger and the ledger is byte-unchanged' ((Get-IdxText $idxFile) -ceq ($canonLedger + "`n") -and (Get-Bytes $canonLedger) -ceq $b) (Get-IdxText $idxFile)
$r = Invoke-LogRegister -Ledger $canonLedger
Assert-Coord 'L29 -Register again: the same line, exit 0, no second index line' ($r.Code -eq 0 -and $r.Out -ceq "COORD-LOG REGISTERED $canonLedger in $idxFile" -and (Get-IdxText $idxFile) -ceq ($canonLedger + "`n")) "code=$($r.Code) out=$($r.Out)`n$(Get-IdxText $idxFile)"
$null = New-CoordScratchIndex $root
$idxFile = Get-CoordIndexPath
$r = Invoke-LogRegister -Cwd $canonRepo
Assert-Coord 'L29 -Register without -Ledger, from the main checkout: registers today''s ledger there' ($r.Code -eq 0 -and $r.Out -match '^COORD-LOG REGISTERED ' -and (Get-IdxText $idxFile) -ceq ($canonLedger + "`n")) "code=$($r.Code) out=$($r.Out)`n$(Get-IdxText $idxFile)"
$null = New-CoordScratchIndex $root
$idxFile = Get-CoordIndexPath
$b = Get-Bytes $canonLedger
$r = Invoke-LogRegister -Cwd $canonWt
Assert-Coord 'L29 -Register without -Ledger, from a linked worktree: refused (exit 2), nothing registered' ($r.Code -eq 2 -and -not (Test-Path -LiteralPath $idxFile) -and (Get-Bytes $canonLedger) -ceq $b) "code=$($r.Code) out=$($r.Out)"
$r = Invoke-LogRegister -Ledger $p
Assert-Coord 'L29 -Register on a scratch ledger: NOT REGISTERED, exit 2, nothing registered' ($r.Code -eq 2 -and $r.Out -match '^COORD-LOG: NOT REGISTERED - ' -and -not (Test-Path -LiteralPath $idxFile)) "code=$($r.Code) out=$($r.Out)"
$r = Invoke-LogRegister -Ledger $staleLedger
Assert-Coord 'L29 -Register on the stale copy: NOT REGISTERED, the message names the canonical ledger, nothing registered' ($r.Code -eq 2 -and $r.Out -match '^COORD-LOG: NOT REGISTERED - ' -and $r.Out.IndexOf($canonLedger, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and -not (Test-Path -LiteralPath $idxFile)) "code=$($r.Code) out=$($r.Out)"
$r = Invoke-LogRegister -Ledger $canonLedger -Section 'Log' -Text 'x'
Assert-Coord 'L29 -Register with -Section and -Text: refused (exit 2), nothing registered, ledger unchanged' ($r.Code -eq 2 -and -not (Test-Path -LiteralPath $idxFile) -and (Get-Bytes $canonLedger) -ceq $b) "code=$($r.Code) out=$($r.Out)"
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $idxFile))
[System.IO.File]::WriteAllBytes($idxFile, $coordUtf8.GetBytes($seedFull))
$r = Invoke-LogRegister -Ledger $canonLedger
Assert-Coord 'L29 -Register into a full index: NOT REGISTERED, exit 2, index unchanged' ($r.Code -eq 2 -and $r.Out -match '^COORD-LOG: NOT REGISTERED - ' -and (Get-IdxText $idxFile) -ceq $seedFull) "code=$($r.Code) out=$($r.Out)"
$null = New-CoordScratchIndex $root
$idxFile = Get-CoordIndexPath
$x = Invoke-HookTestPowerShell -Script $ScriptPath -StartDir $root -ScriptArgs "-Register -Ledger `"$canonLedger`""
Assert-Coord 'L29 through powershell.exe -File: exit 0, REGISTERED, the index holds the ledger' ($x.Code -eq 0 -and ([string]$x.Out) -match 'COORD-LOG REGISTERED ' -and (Get-IdxText $idxFile) -ceq ($canonLedger + "`n")) "code=$($x.Code) out=$($x.Out) err=$($x.Err)"

Write-Host "(L14) no temp or lock files"
$left = @(Get-ChildItem -LiteralPath $root -Recurse -Force | Where-Object { $_.Name -like '*.coord-log-*.tmp' -or $_.Name -like '*.coord-log.lock' })
Assert-Coord 'L14 no *.coord-log-*.tmp or *.coord-log.lock left under the case folders' ($left.Count -eq 0) (($left | ForEach-Object { $_.FullName }) -join "`n")

Write-Host "(L31) a canonical-shaped ledger whose canonical check cannot be decided"
# A git that fails (but answers --version, so the 2.38 floor check passes)
# makes Test-CoordLedgerCanonical unable to decide. The ledger's
# path has the canonical SHAPE <X>\.claude\coordination\<today>.md, so coord-log
# must not append to it unregistered. Control: with the real git back, a stale
# worktree copy (positively not canonical) is still appended, unregistered, and
# the canonical-shaped ledger is written and registered.
$failDir = Join-Path $root 'gitstub-fail'
[void][IO.Directory]::CreateDirectory($failDir)
[System.IO.File]::WriteAllText((Join-Path $failDir 'git.cmd'), "@echo off`r`nif `"%~1`"==`"--version`" goto ver`r`nexit /b 128`r`n:ver`r`necho git version 2.45.1.windows.1`r`nexit /b 0`r`n", [System.Text.Encoding]::ASCII)
$null = New-CoordScratchIndex $root
$idxFile = Get-CoordIndexPath
$b = Get-Bytes $canonLedger
$prevPath = $env:PATH
try {
    $env:PATH = $failDir + [System.IO.Path]::PathSeparator + $prevPath
    $which = (Get-Command git -CommandType Application | Select-Object -First 1).Source
    $r = Invoke-Log 'Log' 'git is down' $canonLedger
}
finally { $env:PATH = $prevPath }
Assert-Coord 'L31 the failing git stub is the git first on PATH' ($which -ieq (Join-Path $failDir 'git.cmd')) $which
Assert-Coord 'L31 git failing on a canonical-shaped ledger: exit 2, "cannot tell whether ... is canonical", ledger byte-unchanged, nothing registered' ($r.Code -eq 2 -and $r.Out -match '^COORD-LOG: NOT WRITTEN - cannot tell whether ' -and $r.Out.Contains($canonLedger) -and (Get-Bytes $canonLedger) -ceq $b -and -not (Test-Path -LiteralPath $idxFile)) "code=$($r.Code) out=$($r.Out)"
$r = Invoke-Log 'Log' 'stale copy after git is back' $staleLedger
Assert-Coord 'L31 control: with the real git, the stale worktree copy is appended and not registered' ($r.Code -eq 0 -and @((Read-Lines $staleLedger) -match ' stale copy after git is back$').Count -eq 1 -and -not (Test-Path -LiteralPath $idxFile)) "code=$($r.Code) out=$($r.Out)"
$r = Invoke-Log 'Log' 'canonical after git is back' $canonLedger
Assert-Coord 'L31 control: the canonical-shaped ledger itself is then written and registered' ($r.Code -eq 0 -and @((Read-Lines $canonLedger) -match ' canonical after git is back$').Count -eq 1 -and (Get-IdxText $idxFile) -ceq ($canonLedger + "`n")) "code=$($r.Code) out=$($r.Out)"

Write-Host "(L32) the documented Bash form: MSYS_NO_PATHCONV=1 and the script path through cygpath -w"
# Git Bash (MSYS) rewrites an argument that looks like a POSIX path before a native exe sees it:
# '/review-code ...' arrives as 'C:/Program Files/Git/review-code ...', exit 0. The documented Bash
# form (script header and SKILL.md) must (a) carry MSYS_NO_PATHCONV=1, (b) name the script in a way
# whose path survives that setting (with the conversion off Bash hands powershell.exe a /c/... path
# as it is, and that is not a path powershell.exe can open; cygpath -w makes the Windows path),
# and (c) write the text intact. The form is READ from the header and from SKILL.md (the
# ${CLAUDE_PLUGIN_ROOT} of SKILL.md read as <plugin root>) and RUN as written through Git Bash, with
# <plugin root> set to a scratch copy of the scripts folder and a scratch -Ledger; only <event> is
# filled in. Scratch index (set above); the real one is compared in L30.
function Get-FlatText([string]$Text) { return ([regex]::Replace(($Text -replace '(?m)^\s*#', ' '), '\s+', ' ')) }
$formRx = '(MSYS_NO_PATHCONV=1 powershell\.exe -ExecutionPolicy Bypass -File "\$\(cygpath -w "<plugin root>/scripts/coord-log\.ps1"\)" -Section Log -Text ''<event>'')'
$hdrFlat = Get-FlatText ([System.IO.File]::ReadAllText($ScriptPath))
$skillFlat = (Get-FlatText ([System.IO.File]::ReadAllText((Join-Path $coordScriptsDir '..\skills\coordinate\SKILL.md')))).Replace('${CLAUDE_PLUGIN_ROOT}', '<plugin root>')
$hm = [regex]::Match($hdrFlat, $formRx)
$sm = [regex]::Match($skillFlat, $formRx)
Assert-Coord 'L32 the coord-log.ps1 header shows the Bash form: MSYS_NO_PATHCONV=1 and the script path through cygpath -w' $hm.Success
Assert-Coord 'L32 SKILL.md shows the same Bash form' ($sm.Success -and $hm.Success -and $sm.Groups[1].Value -ceq $hm.Groups[1].Value) "header='$($hm.Groups[1].Value)' skill='$($sm.Groups[1].Value)'"
if (-not $bashExe) {
    Write-CoordUnchecked 'L32 Git Bash run' 'no Git Bash (bin\bash.exe under the Git root, or in an install folder) on this machine'
}
else {
    $bashPlugin = Join-Path $root 'bashplugin'
    [void][IO.Directory]::CreateDirectory($bashPlugin)
    Copy-Item -LiteralPath (Split-Path $ScriptPath) -Destination (Join-Path $bashPlugin 'scripts') -Recurse -Force
    $winRoot = $bashPlugin.Replace('\', '/')
    $posixRoot = '/' + $winRoot.Substring(0, 1).ToLowerInvariant() + $winRoot.Substring(2)
    function Invoke-BashForm([string]$Form, [string]$PluginRoot, [string]$Ledger) {
        $cmd = $Form.Replace('<plugin root>', $PluginRoot).Replace('<event>', '/review-code panel') + ' -Ledger "' + $Ledger.Replace('\', '/') + '"'
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $bashExe
        $psi.Arguments = '-c "' + $cmd.Replace('"', '\"') + '"'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $o = $proc.StandardOutput.ReadToEndAsync(); $e = $proc.StandardError.ReadToEndAsync()
        [void]$proc.WaitForExit(60000)
        return [pscustomobject]@{ Code = $proc.ExitCode; Out = $o.Result; Err = $e.Result }
    }
    $form = $hm.Groups[1].Value
    foreach ($rootForm in @(@('C:/... form', $winRoot), @('/c/... form', $posixRoot))) {
        $p = New-Ledger $sample
        $x = Invoke-BashForm $form $rootForm[1] $p
        $lines = Read-Lines $p
        Assert-Coord "L32 the documented Bash form, run as written through Git Bash with the plugin root in $($rootForm[0]): exit 0 and '/review-code panel' is written intact" ($form -and $x.Code -eq 0 -and @($lines -match '^\d\d:\d\d /review-code panel$').Count -eq 1) "bash=$bashExe form='$form' code=$($x.Code) out=$($x.Out) err=$($x.Err)"
    }
    $p = New-Ledger $sample
    $x = Invoke-BashForm 'MSYS_NO_PATHCONV=1 powershell.exe -ExecutionPolicy Bypass -File "<plugin root>/scripts/coord-log.ps1" -Section Log -Text ''<event>''' $posixRoot $p
    Assert-Coord 'L32 control: a /c/... script path without cygpath -w and with MSYS_NO_PATHCONV=1 is not found (nothing written): why the form uses cygpath -w' ($x.Code -ne 0 -and @((Read-Lines $p) -match 'review-code panel').Count -eq 0) "code=$($x.Code) out=$($x.Out) err=$($x.Err)"
    $p = New-Ledger $sample
    $x = Invoke-BashForm ($form -replace '^MSYS_NO_PATHCONV=1 ', '') $winRoot $p
    $lines = Read-Lines $p
    Assert-Coord 'L32 control: without MSYS_NO_PATHCONV=1 MSYS rewrites the leading / (exit 0, a mangled line): why the form needs it' ($form -and $x.Code -eq 0 -and @($lines -match '^\d\d:\d\d /review-code panel$').Count -eq 0 -and @($lines -match '^\d\d:\d\d .*review-code panel$').Count -eq 1) "code=$($x.Code) out=$($x.Out) err=$($x.Err)"
}
Write-Host "(L30) the real index folder"
Assert-Coord 'L30 the real index folder (COORD_INDEX_DIR as before this run, else $HOME/.claude/coordination: its listing and the SHA-256 of every file outside sessions/, or still absent) is unchanged by this run' ((Get-CoordRealIndexDigest) -ceq $realIndexBefore) "before:`n$realIndexBefore`nafter:`n$(Get-CoordRealIndexDigest)"
Write-Host "(F5) git below 2.38 is refused at the start"
$gitOldDir = Join-Path $root 'gitstub-floor-old'
[void][IO.Directory]::CreateDirectory($gitOldDir)
[System.IO.File]::WriteAllText((Join-Path $gitOldDir 'git.cmd'), "@echo off`r`necho git version 2.37.9.windows.1`r`nexit /b 0`r`n", [System.Text.Encoding]::ASCII)
$gitOldEnv = @{ PATH = $gitOldDir + [System.IO.Path]::PathSeparator + $env:PATH }
$ledgerNone = Join-Path $root 'floor-no-such-ledger.md'
$x = Invoke-HookTestPowerShell -Script $ScriptPath -StartDir $root -ExtraEnv $gitOldEnv -ScriptArgs "-Section Log -Text `"floor`" -Ledger `"$ledgerNone`""
$xOut = ([string]$x.Out).Trim()
Assert-Coord 'F5 coord-log: a git that answers 2.37.9 is refused with exit 2, one line starting "COORD-LOG: NOT WRITTEN - " that names git 2.37.9 and the 2.38 floor' ($x.Code -eq 2 -and $xOut.StartsWith('COORD-LOG: NOT WRITTEN - ', [System.StringComparison]::Ordinal) -and $xOut -notmatch '[\r\n]' -and $xOut.Contains('git 2.37.9 ') -and $xOut.Contains('2.38')) "code=$($x.Code) out=$($x.Out) err=$($x.Err)"
Assert-Coord 'F5 coord-log: ... and the ledger is not created' (-not (Test-Path -LiteralPath $ledgerNone)) ''

Write-CoordUncheckedSummary

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Passed: $script:coordPass  Failed: $script:coordFail"
if ($script:coordFail -gt 0) { exit 1 }
exit 0
