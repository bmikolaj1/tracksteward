# Test stub for gh (called by gh.cmd in this directory), used by the
# tests/scripts suites.
# Ported from the private coordinate toolkit (gh-coord-stub.ps1), 2026-10-18.
#
# Appends "ARGS=<args joined by one space>" to $env:GH_COORD_LOG (when set).
# Then reads $env:GH_COORD_RESPONSES, a JSON file holding an ordered list of
#   { "match": "<regex>", "stdout": "<text>", "exit": <int> }
# and answers with the FIRST rule whose regex matches the joined arguments:
# prints its stdout (UTF-8) and exits with its exit code (0 when absent).
# No rules file, or no rule matching: an error on stderr, exit 97.

if ($env:GH_COORD_LOG) {
    Add-Content -LiteralPath $env:GH_COORD_LOG -Encoding UTF8 -Value ('ARGS=' + ($args -join ' '))
}
$joined = $args -join ' '
if (-not $env:GH_COORD_RESPONSES -or -not (Test-Path -LiteralPath $env:GH_COORD_RESPONSES)) {
    [Console]::Error.WriteLine("gh-coord-stub: no GH_COORD_RESPONSES file for: $joined")
    exit 97
}
$rules = Get-Content -LiteralPath $env:GH_COORD_RESPONSES -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($r in @($rules)) {
    if ($joined -match [string]$r.match) {
        $stdout = New-Object System.IO.StreamWriter([Console]::OpenStandardOutput(), (New-Object System.Text.UTF8Encoding($false)))
        $stdout.Write([string]$r.stdout)
        $stdout.Flush()
        $code = 0
        if ($r.PSObject.Properties['exit'] -and $null -ne $r.exit) { $code = [int]$r.exit }
        exit $code
    }
}
[Console]::Error.WriteLine("gh-coord-stub: no rule matches: $joined")
exit 97
