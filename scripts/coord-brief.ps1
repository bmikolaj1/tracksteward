# Ported from the private coordinate toolkit (coord-brief.ps1), 2026-10-25.
#
# coord-brief.ps1 - render a track's coordination brief into a file, and check
# it before the coordinator sends the one-line pointer to it.
#
# A brief sent as a message can be held in the queue, arrive after the state it
# describes has changed, or be lost to the track's compaction. A brief in a
# file is re-read instead; the message is one pointer line. Two steps, so a
# hand-filled brief is never overwritten and never sent half-filled:
#
#   coord-brief.ps1 -Track <name> [-Repo <full path>] [-Ledger <path>] [-Force]
#     renders the fenced brief in ../templates/brief-template.md for the
#     ledger's live Tracks row <name> into <ledger folder>/briefs/. The
#     template has one kind of coordinator slot, {like this}. The script fills
#     the slots the ledger can answer: the coordinator's name (the ledger's
#     first `Coordinator: session "<name>"` line), the track, repo, branch and
#     session cells, this file's own path, the Baseline row of the track's
#     repo, the other live rows of the same repo (LIVE TRACKS), and the track's
#     scope and the other live scopes (FILE SCOPE). Every other slot stays as
#     the template has it, for the coordinator. The Baseline slots stay too
#     unless exactly one Baseline row fits the repo and every Baseline Repo cell
#     is a clean leaf name or a rooted path that fits at most one live repo (a
#     cell with parentheses, a comma or a semicolon, an empty one, or an
#     ambiguous leaf anywhere leaves the slots for every track; a rooted path
#     with words after it, "C:\x after #65", is read as another repo's path);
#     the branch-from slot stays unless that row's origin/main cell names
#     exactly one sha (a cell appended to during the day lists them oldest
#     first, so the script never guesses). Refused (exit 2, nothing written):
#     an existing brief without -Force (-Force first copies it to
#     <file>.<yyyyMMdd-HHmmss>[-k].bak and never overwrites an earlier copy), a
#     row with no Scope, Session or Branch (or a Track cell holding a double
#     quote), a live row whose Repo cell is not one
#     rooted path (see ConvertTo-CoordRootedPath), no Coordinator line (or one
#     still holding the template's <name> placeholder), an unreadable ledger or
#     Tracks table, a ledger inside a linked worktree or under any
#     .claude/worktrees/ folder (the stale copy a tool can make when it creates
#     a worktree, also after git has forgotten that worktree), a template that
#     lacks a slot this script fills, and any unexpected error. The ledger
#     checks and the Repo-cell check apply to -Check too.
#   coord-brief.ps1 -Track <name> [-Repo <full path>] [-Ledger <path>] -Check
#     re-reads the file and prints exactly one line,
#       BRIEF: <absolute path>; reply "ACK <track>" when read
#     only when its identity line names the selected row, none of the
#     template's own slots is left (a slot is found by its name, so a damaged
#     one such as "{their words", "{location" or "their words}" counts, in any
#     case; the one-word slots this script fills count only whole, and a
#     group that closes on its line, such as a glob lib/{location,auth}/**,
#     is not a slot; see Get-OpenSlots), every fixed line of the template (TRACK, THIS FILE, MERGE ORDER,
#     ACK, WIP, REPORT BACK ...; not the optional SUPERSEDES and CROSS-REPO) is
#     still there, the row's Repo cell is a full path on a local fixed disk (the guard binds
#     the row by it), and the ledger is one the scope guard reads: today's
#     canonical ledger (Test-CoordLedgerCanonical), among the entries of
#     today's index (Get-CoordIndexedLedgers; coord-log.ps1 -Register puts it
#     there), trusted (Test-CoordLedgerTrusted) and with a Tracks table the
#     guard's bounded read accepts (Read-CoordLedgerTracksBounded). So a
#     scratch -Ledger can be rendered but never passes -Check. Otherwise it
#     names what is wrong and exits 2. It writes nothing, and it does not
#     compare the brief with the ledger again: a brief rendered before a ledger
#     change is re-rendered with -Force.
#
# Row selection: the LIVE rows (Status not led by MERGED or DONE, see
# Test-CoordRowTerminal) whose Track cell equals -Track, ignoring case, and,
# with -Repo, whose Repo cell is that full path. Exactly one must match; none,
# or two (one name in two repos: pass -Repo; one name twice in one repo: fix
# the ledger), is refused.
#
# File name: <date>-<repo leaf>-<track>-<id8>.md. <date> is the ledger file's
# name when it is a yyyy-MM-dd date, else today. <repo leaf> and <track> have
# every character outside [A-Za-z0-9._-] replaced by '-' (readability only;
# <track> is cut at 64 characters); <id8> is the first 8 hex of the SHA-256 of
# the full Repo path (lower-cased where paths compare ignoring case), a newline
# and the exact Track cell, so two rows of one name in two repos, or `api/a`
# and `api\a`, never share a file. A readable part with no letter or digit
# (`..`, `---`), a Windows device name (CON, NUL, COM1 ...), or a Track cell
# holding `-->` is refused, and the full path must sit directly inside the
# briefs folder. The file's first line is
#   <!-- coord-brief repo=<full Repo path> track=<Track cell> -->
#
# Without -Ledger: today's ledger, <main checkout>/.claude/coordination/
# <yyyy-MM-dd>.md, and only when the current directory is that repo's MAIN
# checkout (as coord-log.ps1). Anything that probes or tests this script passes
# a scratch -Ledger (or a fixture repo's ledger, and a scratch COORD_INDEX_DIR,
# for a -Check that passes); its brief then lands in that folder's briefs/. A
# -Ledger inside a linked worktree is refused (see above).
#
# Usage, from the PowerShell tool, in process:
#   & "<plugin root>/scripts/coord-brief.ps1" -Track '<name>' [-Repo '<path>']
#   (fill the slots left in the file it names)
#   & "<plugin root>/scripts/coord-brief.ps1" -Track '<name>' [-Repo '<path>'] -Check
# Prints: COORD-BRIEF WROTE <path> and a line naming the slots to fill
#     or: COORD-BRIEF: NOT WRITTEN - <reason>        (render refused)
#     or: BRIEF: <path>; reply "ACK <track>" when read   (-Check passed)
#     or: COORD-BRIEF: NOT READY - <reason>          (-Check refused)
# Exit: 0 written / ready; 2 refused.
# (Not through `powershell.exe -File` from Windows PowerShell 5.1 with a -Track
# value that holds double quotes: it drops them. A call PowerShell cannot bind
# at all fails before the script runs: exit 1, nothing written.)

[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Track = '',
    [string]$Repo = '',
    [string]$Ledger = '',
    [switch]$Check,
    [switch]$Force,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest = @()
)

$ErrorActionPreference = 'Stop'

function Exit-Refused([string]$Reason) {
    if ($Check) { Write-Output "COORD-BRIEF: NOT READY - $Reason" }
    else { Write-Output "COORD-BRIEF: NOT WRITTEN - $Reason" }
    exit 2
}

# Anything unforeseen is a refusal (exit 2), never a raw error with exit 1.
# Defined before the dot-source, so a missing coord-common.ps1 is caught too.
trap { Exit-Refused "unexpected error: $($_.Exception.Message)" }

. (Join-Path $PSScriptRoot 'coord-common.ps1')
Initialize-CoordConsole
$cmp = Get-CoordPathComparison

if ($Rest.Count) { Exit-Refused "unexpected words after the parameters ($($Rest -join ' ')); quote the -Track value" }
$Track = $Track.Trim()
if (-not $Track) { Exit-Refused '-Track is empty' }

# ---- the ledger
if (-not $Ledger) {
    $here = (Get-Location).Path
    $Ledger = Get-CoordLedgerPath $here
    if (-not $Ledger) { Exit-Refused "$here is not in a git repository; pass -Ledger" }
    $top = Invoke-CoordGit $here @('rev-parse', '--show-toplevel')
    $main = Get-CoordMainRoot $here
    if ($top.Code -ne 0 -or -not $top.Out.Count -or -not $main -or
        -not [string]::Equals((ConvertTo-CoordFullPath $top.Out[0].Trim()), (ConvertTo-CoordFullPath $main), $cmp)) {
        Exit-Refused "$here is not the repo's main checkout; pass -Ledger (the default would be $Ledger)"
    }
}
try {
    $prov = $null
    $drive = $null
    $Ledger = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Ledger, [ref]$prov, [ref]$drive)
    if ($prov.Name -ne 'FileSystem') { Exit-Refused "-Ledger must be a file path (got a $($prov.Name) path)" }
}
catch { Exit-Refused "-Ledger is not a usable path: $($_.Exception.Message)" }
if (-not (Test-Path -LiteralPath $Ledger -PathType Leaf)) { Exit-Refused "no ledger at $Ledger" }
# Tools that create a worktree can copy the gitignored .claude/coordination/
# into it: a ledger inside a linked worktree is that stale copy, never the live
# one. A worktree folder keeps its copy after git forgets it (a failed
# `worktree remove` can leave the folder with a .git file pointing nowhere, and
# git then exits 128 there, or with no .git at all). So any path through a
# .claude/worktrees/ segment is refused without asking git.
if ((ConvertTo-CoordFullPath $Ledger) -match '(?i)[\\/]\.claude[\\/]worktrees[\\/]') {
    Exit-Refused "$Ledger is under a .claude/worktrees/ folder (a worktree's stale copy of the ledgers); pass the main checkout's ledger"
}
$ledgerDir = Split-Path -Parent $Ledger
$lTop = Invoke-CoordGit $ledgerDir @('rev-parse', '--show-toplevel')
if ($lTop.Code -eq 0 -and $lTop.Out.Count) {
    $lMain = Get-CoordMainRoot $ledgerDir
    if ($lMain -and -not [string]::Equals((ConvertTo-CoordFullPath $lTop.Out[0].Trim()), (ConvertTo-CoordFullPath $lMain), $cmp)) {
        Exit-Refused "$Ledger is inside a linked worktree ($($lTop.Out[0].Trim())): that is the stale copy made when the worktree was created; pass the main checkout's ledger ($lMain/.claude/coordination/)"
    }
}
try {
    $ledgerText = [System.IO.File]::ReadAllText($Ledger, [System.Text.Encoding]::UTF8)
    $rows = @(Read-CoordLedgerTracks $Ledger)
}
catch { Exit-Refused "$($_.Exception.Message)" }
$ledgerLines = $ledgerText -split '\r\n|\r|\n'

# ---- the row
$live = @($rows | Where-Object { -not (Test-CoordRowTerminal $_.Status) })
$hits = @($live | Where-Object { [string]::Equals($_.Track.Trim(), $Track, [System.StringComparison]::OrdinalIgnoreCase) })
# Every live row's Repo must be a usable full path: a bad cell anywhere would
# otherwise drop a sibling from LIVE TRACKS and NOT yours without a word.
foreach ($lr in $live) {
    if (-not (ConvertTo-CoordRootedPath $lr.Repo)) {
        Exit-Refused "live Tracks row '$($lr.Track.Trim())': the Repo cell '$($lr.Repo)' is not one rooted path (a drive letter and separator and a folder, or \\server\share, or a path from /; no , ; or parentheses; not a drive root alone or a \\?\ device path); fix the ledger row"
    }
}
if ($Repo) {
    $want = ConvertTo-CoordRootedPath $Repo
    if (-not $want) { Exit-Refused "-Repo '$Repo' is not a usable path" }
    $hits = @($hits | Where-Object { [string]::Equals((ConvertTo-CoordFullPath $_.Repo), $want, $cmp) })
}
if ($hits.Count -eq 0) {
    $any = @($rows | Where-Object { [string]::Equals($_.Track.Trim(), $Track, [System.StringComparison]::OrdinalIgnoreCase) })
    $why = if ($any.Count) { "no LIVE Tracks row '$Track'$(if ($Repo) { " in $Repo" }) (its rows are MERGED or DONE, or in another repo)" } else { "no Tracks row '$Track'" }
    Exit-Refused "$why in $Ledger"
}
if ($hits.Count -gt 1) {
    $repos = @($hits | ForEach-Object { $p = ConvertTo-CoordFullPath $_.Repo; if ($cmp -eq [System.StringComparison]::OrdinalIgnoreCase) { $p.ToLowerInvariant() } else { $p } } | Sort-Object -Unique)
    if ($repos.Count -lt $hits.Count) { Exit-Refused "two or more live Tracks rows named '$Track' (ignoring case) share a repo in $Ledger; rename one in the ledger" }
    Exit-Refused "$($hits.Count) live Tracks rows '$Track' in $Ledger (repos: $(($hits | ForEach-Object { $_.Repo }) -join ', ')); pass -Repo <full path>"
}
$row = $hits[0]
$trackCell = $row.Track.Trim()
$repoFull = ConvertTo-CoordFullPath $row.Repo

# ---- the file
function ConvertTo-SafeName([string]$s) { return ($s -replace '[^A-Za-z0-9._-]', '-') }
if ($trackCell.Contains('-->')) { Exit-Refused "the Track cell '$trackCell' holds '-->'" }
if ($trackCell.Contains('"')) { Exit-Refused "the Track cell '$trackCell' holds a double quote (it would break the pointer line)" }
$safeTrack = ConvertTo-SafeName $trackCell
if ($safeTrack.Length -gt 64) { $safeTrack = $safeTrack.Substring(0, 64) }
$safeLeaf = ConvertTo-SafeName (Split-Path -Leaf $repoFull)
foreach ($part in @($safeTrack, $safeLeaf)) {
    if ($part -notmatch '[A-Za-z0-9]') { Exit-Refused "the Track cell '$trackCell' or the repo leaf gives no readable file name ('$part')" }
    if (($part -split '\.')[0] -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { Exit-Refused "'$part' is a Windows device name" }
}
$sha = [System.Security.Cryptography.SHA256]::Create()
$idRepo = if ($cmp -eq [System.StringComparison]::OrdinalIgnoreCase) { $repoFull.ToLowerInvariant() } else { $repoFull }
try { $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($idRepo + "`n" + $trackCell)) }
finally { $sha.Dispose() }
$id8 = -join ($hash[0..3] | ForEach-Object { $_.ToString('x2') })
$ledgerLeaf = [System.IO.Path]::GetFileNameWithoutExtension($Ledger)
$date = Get-CoordLedgerDate $ledgerLeaf
$briefDir = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $Ledger) 'briefs'))
$briefPath = [System.IO.Path]::GetFullPath((Join-Path $briefDir "$date-$safeLeaf-$safeTrack-$id8.md"))
if (-not [string]::Equals((Split-Path -Parent $briefPath), $briefDir.TrimEnd('\', '/'), $cmp)) {
    Exit-Refused "the brief path $briefPath is not directly inside $briefDir"
}
$identity = "<!-- coord-brief repo=$repoFull track=$trackCell -->"

# ---- the template
# The brief is the first fenced block of brief-template.md (the text around it
# documents the template). Its coordinator slots are {like this}: one pair of
# braces, no brace or line break inside.
$tplPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', 'templates', 'brief-template.md'))
if (-not (Test-Path -LiteralPath $tplPath -PathType Leaf)) { Exit-Refused "no brief-template.md at $tplPath" }
$tplLines = [System.IO.File]::ReadAllText($tplPath, [System.Text.Encoding]::UTF8) -split '\r\n|\r|\n'
$fenceAt = @(0..($tplLines.Count - 1) | Where-Object { $tplLines[$_] -match '^```' })
if ($fenceAt.Count -ne 2) { Exit-Refused "brief-template.md at $tplPath must hold exactly one fenced block (the brief); it has $($fenceAt.Count) fence line(s)" }
if ($fenceAt[1] -le $fenceAt[0] + 1) { Exit-Refused "brief-template.md at $tplPath has an empty fenced block" }
$tplBlock = @($tplLines[($fenceAt[0] + 1)..($fenceAt[1] - 1)])
$slotRegex = '\{([^{}\r\n]+)\}'
$tplSlots = @([regex]::Matches(($tplBlock -join "`n"), $slotRegex) | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique -CaseSensitive)
# The slots this script fills, by name ({globs} is only in the LIVE TRACKS line,
# which is built whole). A name that is not here is the coordinator's.
$fillKeys = @('coordinator session name', 'track', 'repo', 'branch', 'session name', 'absolute path of this file', 'your globs', 'globs not yours',
    'verified at', 'baseline repo', 'origin/main sha', 'list or none', 'branch-from sha', 'globs')

# The template slots left in $Text, by name. A slot counts when its text is
# there exactly. A slot the script does not fill, and any slot of two or more
# words, also counts when it is damaged in one of three ways, in any case:
#   - spelled with other spacing or case: "{ Their  Words }";
#   - opened and not closed before the line's next brace or its end, from its
#     first two words on: "{their words", "{old brief path, and what";
#   - closed with no opener earlier on its line, the whole name before the
#     brace: "their words}" (the whole name, because two slots share their
#     last words, "..., or none").
# A group that closes on its line is another group, not a damaged slot, so a
# glob such as lib/{location,auth}/** or {branch-a,b} is not taken for one. A
# one-word slot the script fills ({track}, {repo}, {branch}, {globs}) is
# matched only exactly. A ledger value that is itself a slot's exact text, such
# as a Scope cell of {branch}, is copied by the render and then refused here:
# rename it. Known limits, accepted (the seam is frozen): a slot cut shorter
# than its first two words ("{their"), cut from the front ("... commit
# conventions}"), split between two words by a line break, or cut short and
# closed ("{their words, quoted}") is not found; an earlier brace on the same
# line blinds the closing-brace form; and text that spells a slot, such as
# `/api/{location}`, `{{location}}`, `x = { location: loc,` or `foo $location }`,
# is refused until it is renamed.
function Get-OpenSlots([string]$Text) {
    $open = New-Object System.Collections.Generic.List[string]
    foreach ($name in $tplSlots) {
        $found = $Text.Contains('{' + $name + '}')
        $words = @($name -split '\s+' | Where-Object { $_ })
        if (-not $found -and -not ($words.Count -eq 1 -and $fillKeys -ccontains $name)) {
            # Spaces and tabs only between the pieces, never a line break: a
            # slot name sits on one line, and `{` or `}` on another is other text.
            $esc = @($words | ForEach-Object { [regex]::Escape($_) })
            $whole = $esc -join '[ \t]+'
            $head = @($esc | Select-Object -First 2) -join '[ \t]+'
            $opt = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Multiline -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
            $found = [regex]::IsMatch($Text, '\{[ \t]*' + $whole + '[ \t]*\}', $opt) -or
                [regex]::IsMatch($Text, '\{[ \t]*' + $head + '(?![A-Za-z0-9])[^{}\r\n]*(?=\r?$|\{)', $opt) -or
                [regex]::IsMatch($Text, '^[^{}\r\n]*(?<![A-Za-z0-9_-])' + $whole + '[ \t]*\}', $opt)
        }
        if ($found) { $open.Add($name) }
    }
    return @($open)
}
# The labels the brief's fixed lines start with (TRACK, THIS FILE, FILE SCOPE,
# MERGE ORDER, ACK, WIP, REPORT BACK ...). -Check wants each one at the start of
# a line, so a brief cut down to its first line does not pass. SUPERSEDES and
# CROSS-REPO are the template's optional lines.
$tplLabels = @($tplBlock | ForEach-Object { if ($_ -cmatch '^([A-Z][A-Z -]{2,}?)\s*[:,(]') { $Matches[1] } } |
        Where-Object { $_ -cne 'SUPERSEDES' -and $_ -cne 'CROSS-REPO' } | Sort-Object -Unique -CaseSensitive)

# ---- -Check
if ($Check) {
    if (-not (Test-Path -LiteralPath $briefPath -PathType Leaf)) { Exit-Refused "no brief at $briefPath; render it first (without -Check)" }
    $bt = [System.IO.File]::ReadAllText($briefPath, [System.Text.Encoding]::UTF8)
    $first = ($bt -split '\r\n|\r|\n')[0]
    if ($first -cne $identity) { Exit-Refused "$briefPath does not belong to row '$trackCell' in $repoFull (its first line is '$first')" }
    $lost = @($tplLabels | Where-Object { $bt -cnotmatch ('(?m)^' + [regex]::Escape($_) + '\s*[:,(]') })
    if ($lost.Count) { Exit-Refused "$briefPath has lost the template's line(s): $($lost -join ', ')" }
    $left = @(Get-OpenSlots $bt)
    if ($left.Count) { Exit-Refused "$($left.Count) template slot(s) left in ${briefPath}: $(($left | ForEach-Object { '{' + $_ + '}' }) -join ', ')" }
    # The pointer goes out only for a ledger the scope guard reads: the same
    # canonical rule, index read, trust rules and bounded Tracks read, so a
    # brief cannot pass while the guard would guard nothing. The guard binds a
    # row by its Repo full path, on a local fixed disk only.
    $fixed = Test-CoordLocalFixedPath $repoFull
    if (-not $fixed.Ok) { Exit-Refused "row '$trackCell': the Repo cell '$($row.Repo)' is not a full path on a local fixed drive (drive type $($fixed.Type)), so the scope guard cannot bind the row; fix the ledger row" }
    $today = Get-CoordToday
    $canon = Test-CoordLedgerCanonical -Path $Ledger -Date $today
    if (-not $canon.Ok) { Exit-Refused "the scope guard reads only today's canonical ledger: $($canon.Error)" }
    $idxPath = Get-CoordIndexPath -Date $today
    $ix = Get-CoordIndexedLedgers -Path $idxPath
    if (-not $ix.Ok) { Exit-Refused "$($ix.Error)" }
    $listed = $false
    foreach ($e in @($ix.Entries)) { if ([string]::Equals($e, $canon.Canonical, $cmp)) { $listed = $true } }
    if (-not $listed) { Exit-Refused "$Ledger is not among the ledgers the scope guard reads from $idxPath; run coord-log.ps1 -Register, then -Check again" }
    $trust = Test-CoordLedgerTrusted -Path $Ledger
    if (-not $trust.Ok) { Exit-Refused "the scope guard does not trust ${Ledger}: $($trust.Error)" }
    $bounded = Read-CoordLedgerTracksBounded -Path $Ledger
    if (-not $bounded.Ok) { Exit-Refused "the scope guard cannot use the Tracks table: $($bounded.Error)" }
    Write-Output "BRIEF: $briefPath; reply `"ACK $trackCell`" when read"
    exit 0
}

# ---- render
if (-not $row.Scope.Trim()) { Exit-Refused "row '$trackCell' has no Scope; fill the ledger row first" }
if (-not $row.Session.Trim()) { Exit-Refused "row '$trackCell' has no Session; fill the ledger row first" }
if (-not $row.Branch.Trim()) { Exit-Refused "row '$trackCell' has no Branch; fill the ledger row first" }
if ((Test-Path -LiteralPath $briefPath) -and -not $Force) { Exit-Refused "$briefPath exists (it may be hand-filled); pass -Force to render again, keeping it as .bak" }

# The ledger's first Coordinator line: Coordinator: session "<name>", cwd `<path>`.
$coordMatch = @($ledgerLines | Where-Object { $_ -match '^Coordinator:' } | Select-Object -First 1)
if (-not $coordMatch.Count -or $coordMatch[0] -notmatch '^Coordinator:\s*session\s+"([^"]+)"') {
    Exit-Refused ('no `Coordinator: session "<name>", ...` line in ' + $Ledger)
}
$coordName = $Matches[1].Trim()
if ($coordName -match '^<.*>$') { Exit-Refused "the Coordinator line in $Ledger still holds the template's placeholder $coordName; put the coordinator session's name there" }

# Baseline rows of the track's repo (the Repo cell there is usually a leaf name).
# Exactly one must fit; none or several leave the Baseline slots.
$liveRepos = @($live | ForEach-Object { ConvertTo-CoordFullPath $_.Repo } | Sort-Object -Unique)
$baseDoubt = $false
$baseRows = New-Object System.Collections.Generic.List[object]
$inBase = $false
$bHead = $null
foreach ($l in $ledgerLines) {
    if (-not $inBase) { if ($l -match '^##\s+Baseline\s*$') { $inBase = $true }; continue }
    if ($l -match '^#{1,2}\s') { break }
    if (-not $l.TrimStart().StartsWith('|')) { if ($bHead) { break } else { continue } }
    $cells = Split-CoordTableRow $l
    if (-not $bHead) { $bHead = $cells; continue }
    if ($l -match '^[\s|:-]+$' -and $l.Contains('-')) { continue }
    $o = @{}
    for ($k = 0; $k -lt [Math]::Min($bHead.Length, $cells.Length); $k++) { $o[$bHead[$k]] = $cells[$k] }
    # Resolved against every live row's repo, so a leaf name two live repos
    # share fits neither (Ambiguous), never both. Fail-safe: a Repo cell that is
    # neither a clean leaf name nor a rooted path, or that fits ambiguously,
    # leaves the Baseline slots for every track; it is never skipped, so an
    # older clean row cannot win by default. (A rooted path with words after
    # it, "C:\x after #65", is a path of another repo and is compared as one.)
    $cell = ([string]$o['Repo']).Trim()
    if ($cell -notmatch '^[A-Za-z0-9._-]+$' -and -not (ConvertTo-CoordRootedPath $cell)) { $baseDoubt = $true; continue }
    try { $res = Resolve-CoordLedgerRepo $cell $liveRepos } catch { $baseDoubt = $true; continue }
    if ($res.Ambiguous) { $baseDoubt = $true; continue }
    if (-not $res.Match -or -not [string]::Equals((ConvertTo-CoordFullPath $res.Match), $repoFull, $cmp)) { continue }
    $baseRows.Add($o)
}

# The slots the script fills, by name; a name that is not in $values stays in
# the brief as the template has it.
$others = @($live | Where-Object { $_ -ne $row -and [string]::Equals((ConvertTo-CoordFullPath $_.Repo), $repoFull, $cmp) })
$lt = New-Object System.Collections.Generic.List[string]
$lt.Add("(1) YOU, $($row.Branch)")
$n = 2
foreach ($o in $others) {
    $lt.Add("($n) `"$($o.Session.Trim())`", branch $($o.Branch), owns $($o.Scope)")
    $n++
}
$liveTracks = 'LIVE TRACKS: ' + ($lt -join '; ') + '.'
$notYours = if ($others.Count) { ($others | ForEach-Object { "$($_.Scope) ($($_.Track.Trim()))" }) -join '; ' } else { 'nothing listed (no other live track in this repo)' }

$values = @{
    'coordinator session name'   = $coordName
    'track'                      = $trackCell
    'repo'                       = $repoFull
    'branch'                     = $row.Branch
    'session name'               = $row.Session
    'absolute path of this file' = $briefPath
    'your globs'                 = $row.Scope
    'globs not yours'            = $notYours
}
if ($baseRows.Count -eq 1 -and -not $baseDoubt) {
    $b = $baseRows[0]
    $shaCell = [string]$b['origin/main']
    # A cell the coordinator appended to during the day ("3c4d5e6 (#60); 2b3a4c5
    # after #65") names several shas, oldest first: never guess which is current.
    $shas = @([regex]::Matches($shaCell, '(?<![0-9A-Za-z])[0-9a-fA-F]{7,40}(?![0-9A-Za-z])') | ForEach-Object { $_.Value })
    $baseValues = @{
        'verified at'     = [string]$b['Verified at']
        'baseline repo'   = [string]$b['Repo']
        'origin/main sha' = $shaCell
        'list or none'    = [string]$b['Open PRs']
    }
    if ($shas.Count -eq 1) { $baseValues['branch-from sha'] = $shas[0] }
    foreach ($k in $baseValues.Keys) { if ($baseValues[$k].Trim()) { $values[$k] = $baseValues[$k].Trim() } }
}

# The slots this script fills must be in the template: one that is not means the
# template was edited past what the script knows.
$missing = @($fillKeys | Where-Object { $tplSlots -cnotcontains $_ })
if ($missing.Count) { Exit-Refused "brief-template.md has no {$($missing -join '}, {')} slot; the script fills it" }
if (-not @($tplBlock | Where-Object { $_.StartsWith('LIVE TRACKS:') }).Count) { Exit-Refused 'brief-template.md has no LIVE TRACKS: line' }

# One pass per line, so a ledger value that holds {...} is copied, never
# expanded. The LIVE TRACKS line is built whole.
$evaluator = [System.Text.RegularExpressions.MatchEvaluator] {
    param($m)
    $name = $m.Groups[1].Value
    if ($values.ContainsKey($name)) { return [string]$values[$name] }
    return $m.Value
}
$body = New-Object System.Collections.Generic.List[string]
$body.Add($identity)
foreach ($l in $tplBlock) {
    if ($l.StartsWith('LIVE TRACKS:')) { $body.Add($liveTracks) }
    else { $body.Add([regex]::Replace($l, $slotRegex, $evaluator)) }
}
$text = ($body -join [Environment]::NewLine).TrimEnd() + [Environment]::NewLine

try {
    [void][System.IO.Directory]::CreateDirectory($briefDir)
    if (Test-Path -LiteralPath $briefPath) {
        $stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
        $k = 0
        do { $bak = "$briefPath.$stamp$(if ($k) { "-$k" }).bak"; $k++ } while (Test-Path -LiteralPath $bak)
        [System.IO.File]::Copy($briefPath, $bak, $false)
    }
    [System.IO.File]::WriteAllText($briefPath, $text, (New-Object System.Text.UTF8Encoding($false)))
}
catch { Exit-Refused "could not write ${briefPath}: $($_.Exception.Message)" }
$slots = @(Get-OpenSlots $text)
Write-Output "COORD-BRIEF WROTE $briefPath"
Write-Output "COORD-BRIEF: fill $($slots.Count) slot(s) by hand: $(($slots | ForEach-Object { '{' + $_ + '}' }) -join ', '); delete the SUPERSEDES line and the CROSS-REPO block unless they apply; then run with -Check and send its BRIEF: line"
exit 0
