# make-demo.ps1 - renders docs/demo/: one made-up coordinator day, run for real.
#
# Builds a throwaway repo (acme-notes, with a bare origin) under the temp
# folder, writes a ledger with three made-up tracks, and runs the plugin's own
# scripts against it: coord-brief, coord-set, coord-log, coord-status and
# slot-check. gh is the test stub (tests/stubs), answering with made-up PRs, so
# nothing talks to GitHub. Every output is printed as the script printed it,
# with the temp folder replaced by <demo>; then it is written to
# docs/demo/README.md and drawn as one SVG per step.
#
# Times, dates and shas change on every run (the scripts read the clock, and the
# repo is new each time). Every name is made up.
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File docs\demo\make-demo.ps1
# Exit: 0 = written; 1 = the setup failed (the fixtures, the throwaway repo;
# nothing written), or not run between 02:00 and 23:00 (the made-up times
# count back from the clock and must stay on today's date), or a ledger edit or
# a step did not do what the demo shows (nothing written), or a write failed
# (the SVGs are written before the transcript, so some may then be new).
$ErrorActionPreference = 'Continue'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
try { . (Join-Path $repoRoot 'tests\fixtures\hook-test-fixture.ps1') } catch { Write-Error "could not load hook-test-fixture.ps1: $_"; exit 1 }
Clear-HookRunnerGitEnv
. (Join-Path $repoRoot 'tests\fixtures\coord-test-fixture.ps1')
$ErrorActionPreference = 'Stop'

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('tracksteward-demo-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory($root)
$indexDir = Join-Path $root 'index'
[void][IO.Directory]::CreateDirectory($indexDir)
$outDir = $PSScriptRoot
$steps = New-Object System.Collections.Generic.List[object]
$script:shaLabels = @{}

# Every spelling of the temp root a script may print, longest first.
$rootForms = New-Object System.Collections.Generic.List[string]
foreach ($r in @($root, (Get-Item -LiteralPath $root).FullName)) {
    foreach ($f in @($r.TrimEnd('\'), $r.TrimEnd('\').Replace('\', '/'))) { if (-not $rootForms.Contains($f)) { $rootForms.Add($f) } }
}
function Hide-DemoRoot([string]$Text) {
    foreach ($f in ($rootForms | Sort-Object Length -Descending)) {
        $Text = [regex]::Replace($Text, [regex]::Escape($f), '<demo>', 'IgnoreCase')
    }
    # A full 40-character sha is shown as a label: the repo's own scrub suite
    # refuses one in a .md file, and the demo's shas change on every run anyway.
    foreach ($k in $script:shaLabels.Keys) { $Text = $Text.Replace($k, $script:shaLabels[$k]) }
    return $Text
}

function Add-DemoStep {
    param([string]$Id, [string]$Title, [string]$Why, [string]$Command, $R, [string]$Expect, [int]$ExpectCode = 0)
    $out = Hide-DemoRoot (([string]$R.Out).TrimEnd())
    if (($Expect -and $out -notmatch $Expect) -or $out -match 'NOT WRITTEN|NOT READY|COULD NOT CHECK' -or $R.Code -ne $ExpectCode) {
        throw "step $Id did not print what the demo shows (/$Expect/, exit $ExpectCode); exit $($R.Code):`n$out`n$(Hide-DemoRoot ([string]$R.Err))"
    }
    $steps.Add([pscustomobject]@{ Id = $Id; Title = $Title; Why = $Why; Command = $Command; Out = $out })
}

# A ledger edit that must change the text: a template that no longer holds the
# piece would otherwise leave the demo's day quietly wrong.
function Set-DemoText([string]$Text, [string]$Old, [string]$New) {
    if (-not $Text.Contains($Old)) { throw "the ledger text no longer holds: $Old" }
    return $Text.Replace($Old, $New)
}

function Invoke-Demo([string]$Name, [string]$ScriptArgs, [object[]]$Rules = @()) {
    return Invoke-CoordScript -Name $Name -Cwd $fx.Launch -ScriptArgs $ScriptArgs -Rules $Rules -ExtraEnv @{ COORD_INDEX_DIR = $indexDir }
}

try {
    # ---- a made-up repo with three track branches, each with its PR head on origin
    $fx = New-CoordFixture $root 'acme-notes'
    $search = New-CoordBranch $fx 'claude/search' -Write @{ 'src/search.txt' = "find notes by word`n" }
    Publish-CoordPullRef $fx 41 $search
    $export = New-CoordBranch $fx 'claude/export' -Write @{ 'src/export.txt' = "export notes as csv`n"; 'README.md' = "readme, with export`n" }
    Publish-CoordPullRef $fx 42 $export
    $script:shaLabels = @{ $search = '<sha40 of #41>'; $export = '<sha40 of #42>' }
    $mainSha = (Get-CoordGitOut $fx.Launch @('rev-parse', 'HEAD')).Substring(0, 7)

    # ---- the day's ledger, as a coordinator would have it at mid-morning
    $now = Get-Date
    if ($now.Hour -lt 2 -or $now.Hour -ge 23) { throw 'run the demo between 02:00 and 23:00: its made-up times count back up to 95 minutes and forward 10, and must stay on today''s date' }
    $date = $now.ToString('yyyy-MM-dd')
    $at = { param([int]$Minutes) $now.AddMinutes(-$Minutes).ToString('HH:mm') }
    $ledger = Join-Path $fx.Launch ".claude\coordination\$date.md"
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $ledger))
    $repo = $fx.Launch
    $wt = Join-Path $repo '.claude\worktrees'
    $template = [IO.File]::ReadAllText((Join-Path $repoRoot 'templates\ledger-template.md')).Replace("`r`n", "`n")
    $text = Set-DemoText $template '# Coordination ledger - YYYY-MM-DD' "# Coordination ledger - $date"
    $text = Set-DemoText $text 'Coordinator: session "<name>", cwd `<path>`.' ('Coordinator: session "acme coordinator", cwd `' + $repo + '`.')
    $text = Set-DemoText $text ('| Repo | origin/main | Open PRs | CI | Verified at |' + "`n" + '|------|-------------|----------|----|-------------|') (
        '| Repo | origin/main | Open PRs | CI | Verified at |' + "`n" + '|------|-------------|----------|----|-------------|' + "`n" +
        "| $repo | $mainSha | #42 | yes | $(& $at 95) |")
    $tracksHead = '| Track | Repo | Session | Model | Cwd | Branch | Scope | PR | Status |' + "`n" + '|-------|------|---------|-------|-----|--------|-------|----|--------|'
    $rows = @(
        "| search | $repo | search | sonnet high | $wt\search | claude/search | src/search* | | BRIEFED $(& $at 5); brief sent |",
        "| export | $repo | export | sonnet high | $wt\export | claude/export | src/export*, docs/** | #42 | PR-OPEN $(& $at 20); final head reported |",
        "| tidy | $repo | tidy | haiku low | $wt\tidy | claude/tidy | docs/** | | QUEUED $(& $at 90); after #42 merges |"
    )
    $text = Set-DemoText $text $tracksHead ($tracksHead + "`n" + ($rows -join "`n"))
    $text = Set-DemoText $text '- [ ] (none)' "- [ ] search ACK by $(& $at -10)"
    [IO.File]::WriteAllText($ledger, $text.Replace("`r`n", "`n"), $coordUtf8)
    $L = '"' + $ledger + '"'

    # ---- 1. brief a track
    $r = Invoke-Demo 'coord-brief.ps1' "-Track search -Ledger $L"
    Add-DemoStep '1-brief' 'Brief a track' 'The coordinator renders the brief for track `search` from the ledger: baseline, scope, siblings and their files. The slots the ledger cannot answer (this repo''s merge command, its gotchas, who goes first) are filled in by the coordinator session, not typed by the user; `-Check` then refuses a brief with a slot left, and prints the one pointer line the track gets. The track answers `ACK search`.' 'coord-brief.ps1 -Track search' $r 'brief'
    $briefFile = @(Get-ChildItem -LiteralPath (Join-Path (Split-Path -Parent $ledger) 'briefs') -Filter '*.md' -File)[0].FullName
    # Each labelled line with the lines that continue it, up to the next line
    # that starts a label of its own (a word in capitals, then ':' or ',').
    $briefLines = New-Object System.Collections.Generic.List[string]
    $keep = $false
    foreach ($bl in [IO.File]::ReadAllLines($briefFile)) {
        if ($bl -cmatch '^[A-Z][A-Z -]*[:,]') { $keep = ($bl -cmatch '^(TRACK|BASELINE|LIVE TRACKS|FILE SCOPE)(?![A-Za-z])') }
        elseif (-not $bl.Trim()) { $keep = $false }
        if ($keep) { $briefLines.Add($bl) }
    }
    $steps.Add([pscustomobject]@{ Id = '1b-brief-file'; Title = 'What the brief says'; Why = 'The parts of the rendered brief that the ledger answered. The rest (house rules, merge order, report shape) comes from the template.'; Command = '(the brief file)'; Out = (Hide-DemoRoot (($briefLines | ForEach-Object { $_ }) -join "`n")) })

    # ---- 2. the ACK arrives: the row's state, stamped from the clock
    $r = Invoke-Demo 'coord-set.ps1' "-Track search -State RUNNING -Text ""ACK received"" -Ledger $L"
    Add-DemoStep '2-set' 'Record the ACK' 'The Status cell is written with a time from the clock, never a typed one. The owed check for the ACK is ticked by hand.' 'coord-set.ps1 -Track search -State RUNNING -Text "ACK received"' $r 'RUNNING'
    $lt = [IO.File]::ReadAllText($ledger)
    [IO.File]::WriteAllText($ledger, (Set-DemoText $lt '- [ ] search ACK by' '- [x] search ACK by'), $coordUtf8)

    # ---- 3. a finding comes in from a track
    $r = Invoke-Demo 'coord-log.ps1' "-Section Findings -Text ""F1 from export: src/search.txt does not trim the query, so an exported search can differ | read | latent | outcome: PENDING"" -Ledger $L"
    Add-DemoStep '3-finding' 'Log a finding' 'Track `export` noticed something outside its scope. It reports a FINDING instead of fixing it; the coordinator logs it, and the user decides what it becomes.' 'coord-log.ps1 -Section Findings -Text "F1 from export: ..."' $r 'Findings'

    # ---- 4. the board
    $r = Invoke-Demo 'coord-status.ps1' "-Ledger $L"
    Add-DemoStep '4-status' 'The status board' 'One read of the ledger, grouped. Every line ends in the ledger line it came from. `tidy` shares `docs/**` with `export`, so it is queued until #42 merges instead of running alongside it. "not verified": without `-Verify` the board does not check its claims against gh.' 'coord-status.ps1' $r 'RUNNING|WAITING'

    # ---- 5. a PR that strays out of its scope
    $green = @((New-CoordCheckRun 'build'), (New-CoordCheckRun 'test'))
    $rules = @((New-CoordRule '^pr view 42\b' (New-CoordPrJson -Number 42 -Head $export -HeadRef 'claude/export' -Checks $green)))
    $r = Invoke-Demo 'slot-check.ps1' "-Pr 42 -Ledger $L" $rules
    Add-DemoStep '5-hold' 'A PR that left its scope' 'Track `export` reports its final head. slot-check reads the real file list: README.md is outside the row''s scope, so no slot is granted.' 'slot-check.ps1 -Pr 42' $r 'HOLD' 1

    # ---- 5b. search opens its PR and reports its final head
    $r = Invoke-Demo 'coord-set.ps1' "-Track search -State PR-OPEN -Text ""PR 41 open, final head reported"" -Ledger $L"
    Add-DemoStep '5b-pr-open' 'Track search reports its final head' 'The track has pushed, opened PR #41 and reported its head; the coordinator records the state (coord-set writes the Status and Model cells only, so the PR cell gets #41 by hand).' 'coord-set.ps1 -Track search -State PR-OPEN -Text "PR 41 open, final head reported"' $r 'PR-OPEN'
    $lt = [IO.File]::ReadAllText($ledger)
    [IO.File]::WriteAllText($ledger, (Set-DemoText $lt '| claude/search | src/search* | |' '| claude/search | src/search* | #41 |'), $coordUtf8)

    # ---- 6. a PR that is ready for its slot
    $rules = @((New-CoordRule '^pr view 41\b' (New-CoordPrJson -Number 41 -Head $search -HeadRef 'claude/search' -Checks $green)))
    $r = Invoke-Demo 'slot-check.ps1' "-Pr 41 -Ledger $L" $rules
    Add-DemoStep '6-ready' 'A PR ready for its merge slot' 'In scope, checks green, contains the newest main. The coordinator sends the track `SLOT #41 @<sha40>`; the user types the go in the track''s own window, and the merge is bound to that sha.' 'slot-check.ps1 -Pr 41' $r 'READY'

    # ---- nothing private in what is written
    foreach ($s in $steps) {
        if ($s.Out -match '[A-Za-z]:[\\/]' -or $s.Out -match '(?i)/(Users|home)/[^<]' -or $s.Out -match '(?i)(^|[^\w.])/[a-z]/(Users|Projects)/') { throw "step $($s.Id) still holds a local path" }
        if ($s.Out -match '(?<![0-9a-f])[0-9a-f]{40}(?![0-9a-f])') { throw "step $($s.Id) still holds a full sha" }
    }

    # ---- write: one SVG per step, and the transcript
    $xmlEsc = { param([string]$t) $t.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;') }
    $wrap = 104
    $md = New-Object System.Collections.Generic.List[string]
    $md.Add('# A coordinator day: real script output on a made-up repo')
    $md.Add('')
    $md.Add('A made-up repo (`acme-notes`) with three made-up tracks: `search`, `export` and `tidy`. Each step')
    $md.Add('below is the real output of the plugin''s scripts against that repo and its ledger. gh is the test stub,')
    $md.Add('answering with made-up PRs, so nothing here talked to GitHub. The temp folder is shown as `<demo>`,')
    $md.Add('and a full 40-character head sha as `<sha40 of #n>` (the scripts print the sha itself).')
    $md.Add('Regenerate with `powershell -NoProfile -ExecutionPolicy Bypass -File docs\demo\make-demo.ps1`; times')
    $md.Add('and shas change on every run. `launch` in the paths is the fixture''s name for the repo''s main checkout,')
    $md.Add('where the coordinator and its ledger live.')
    foreach ($s in $steps) {
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add('> ' + $s.Command)
        foreach ($l in ($s.Out -split "`r?`n")) {
            # Wrap at the last space before the width, so no token is cut
            # unless a line has no space past column 8 (then it is cut hard).
            while ($l.Length -gt $wrap) {
                $cut = $l.LastIndexOf(' ', $wrap)
                if ($cut -lt 8) { $cut = $wrap }
                $lines.Add($l.Substring(0, $cut)); $l = '  ' + $l.Substring($cut).TrimStart()
            }
            $lines.Add($l)
        }
        $w = 24 + 8 * (($lines | Measure-Object -Property Length -Maximum).Maximum)
        $h = 44 + 18 * $lines.Count
        $svg = New-Object System.Text.StringBuilder
        [void]$svg.Append("<svg xmlns=""http://www.w3.org/2000/svg"" width=""$w"" height=""$h"" viewBox=""0 0 $w $h"">`n")
        [void]$svg.Append("<rect width=""100%"" height=""100%"" rx=""8"" fill=""#1e1f24""/>`n")
        [void]$svg.Append("<text x=""12"" y=""20"" fill=""#8b8f99"" font-family=""Consolas, Menlo, monospace"" font-size=""12"">" + (& $xmlEsc $s.Title) + "</text>`n")
        $y = 44
        $first = $true
        foreach ($l in $lines) {
            $fill = if ($first) { '#7fd1b9' } elseif ($l -match 'READY') { '#8fd18f' } elseif ($l -match 'HOLD|OUT:') { '#f0a35e' } else { '#d8dae0' }
            [void]$svg.Append("<text x=""12"" y=""$y"" fill=""$fill"" font-family=""Consolas, Menlo, monospace"" font-size=""13"" xml:space=""preserve"">" + (& $xmlEsc $l) + "</text>`n")
            $y += 18
            $first = $false
        }
        [void]$svg.Append("</svg>`n")
        [IO.File]::WriteAllText((Join-Path $outDir ($s.Id + '.svg')), $svg.ToString(), (New-Object System.Text.UTF8Encoding($false)))
        $md.Add('')
        $md.Add('## ' + $s.Title)
        $md.Add('')
        $md.Add($s.Why)
        $md.Add('')
        $md.Add('![' + $s.Title + '](' + $s.Id + '.svg)')
        $md.Add('')
        $md.Add('```text')
        $md.Add('> ' + $s.Command)
        $md.Add($s.Out)
        $md.Add('```')
    }
    [IO.File]::WriteAllText((Join-Path $outDir 'README.md'), (($md -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "DEMO: wrote $($steps.Count) steps to docs/demo"
    $code = 0
}
catch {
    Write-Host "DEMO: not written: $(Hide-DemoRoot $_.Exception.Message)"
    foreach ($s in $steps) { Write-Host "--- $($s.Id)"; Write-Host $s.Out }
    $code = 1
}
finally {
    try { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}
exit $code
