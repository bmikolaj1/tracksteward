# Tests for tests/run.ps1, the runner. A copy of the runner is started in a scratch
# folder that holds fake suites (each a few lines of output and an exit code), so
# nothing here runs the real suites.
#
#   R1 a suite passes only with exit 0 and a "Passed: <n>  Failed: 0" line, n > 0:
#      no summary, "Passed: 0", a non-zero exit with a clean summary, and exit 0
#      with "Failed: 1" each fail the suite, and the failure line names the suite
#   R2 UNCHECKED lines and the "Unchecked: <n>" line of a passing suite are
#      forwarded, and counted in the total line
#   R3 -Strict: a suite with an unchecked row fails; without it, the run is green
#   R4 the total line, and the exit code for a filter that matches nothing
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.test.ps1
# Exit: 0 = all passed, 1 = a case failed.
param()

$testsDir = $PSScriptRoot
$fixturesDir = Join-Path $testsDir 'fixtures'
try { . (Join-Path $fixturesDir 'hook-test-fixture.ps1') } catch { Write-Error "could not load hook-test-fixture.ps1: $_"; exit 1 }
Clear-HookRunnerGitEnv
. (Join-Path $fixturesDir 'coord-test-fixture.ps1')
$ErrorActionPreference = 'Stop'

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('run-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory($root)
Copy-Item -LiteralPath (Join-Path $testsDir 'run.ps1') -Destination (Join-Path $root 'run.ps1')
$fakes = [ordered]@{
    'a-pass.test.ps1'      = "Write-Host 'Passed: 3  Failed: 0'`nexit 0`n"
    'b-nosummary.test.ps1' = "Write-Host 'hello'`nexit 0`n"
    'c-zero.test.ps1'      = "Write-Host 'Passed: 0  Failed: 0'`nexit 0`n"
    'd-failed.test.ps1'    = "Write-Host '  FAIL: a case'`nWrite-Host 'Passed: 1  Failed: 1'`nexit 1`n"
    'e-exit1.test.ps1'     = "Write-Host 'Passed: 2  Failed: 0'`nexit 1`n"
    'f-unchecked.test.ps1' = "Write-Host '  UNCHECKED: row one (no tool)'`nWrite-Host 'Unchecked: 1 (see the UNCHECKED lines above)'`nWrite-Host 'Passed: 2  Failed: 0'`nexit 0`n"
    'g-failed-exit0.test.ps1' = "Write-Host 'Passed: 2  Failed: 1'`nexit 0`n"
}
foreach ($k in $fakes.Keys) { [System.IO.File]::WriteAllText((Join-Path $root $k), $fakes[$k], $coordUtf8) }

function Invoke-FakeRun([string]$RunArgs) {
    return Invoke-HookTestPowerShell -Script (Join-Path $root 'run.ps1') -StartDir $root -ScriptArgs $RunArgs -Seconds 300
}

Write-Host "(R1) a suite passes only with exit 0 and a Passed: n  Failed: 0 line, n > 0"
$all = Invoke-FakeRun ''
$o = [string]$all.Out
Assert-Coord 'R1 a suite with no summary line fails, and the failure names it and the missing line' ($o -cmatch 'FAILED SUITE b-nosummary\.test\.ps1: [^\r\n]*no summary line') "out=$o err=$($all.Err)"
Assert-Coord 'R1 a suite whose summary says Passed: 0 fails' ($o -cmatch 'FAILED SUITE c-zero\.test\.ps1: [^\r\n]*Passed: 0') $o
Assert-Coord 'R1 a suite with Failed: 1 fails, and its FAIL line is shown' ($o -cmatch 'FAILED SUITE d-failed\.test\.ps1: [^\r\n]*Failed: 1' -and $o -cmatch 'FAIL: a case') $o
Assert-Coord 'R1 a suite with a clean summary but exit code 1 fails' ($o -cmatch 'FAILED SUITE e-exit1\.test\.ps1: [^\r\n]*exit code is 1') $o
Assert-Coord 'R1 a suite with exit code 0 but Failed: 1 in its summary fails' ($o -cmatch 'FAILED SUITE g-failed-exit0\.test\.ps1: [^\r\n]*Failed: 1') $o
Assert-Coord 'R1 a suite with Passed: 3 Failed: 0 and exit 0 is not reported as failed' ($o -cnotmatch 'FAILED SUITE a-pass') $o

Write-Host "(R2) unchecked rows are forwarded and counted"
Assert-Coord 'R2 the UNCHECKED line and the Unchecked: n line of a passing suite are printed' ($o -cmatch 'UNCHECKED: row one \(no tool\)' -and $o -cmatch 'Unchecked: 1 ') $o
Assert-Coord 'R2 the passing suite with an unchecked row is not reported as failed (not -Strict)' ($o -cnotmatch 'FAILED SUITE f-unchecked') $o

Write-Host "(R4) the total line and the exit code"
Assert-Coord 'R4 the total counts 7 suites, 2 passed, 5 failed, 1 unchecked, and the run exits 1' ($o -cmatch '(?m)^RUN: 7 suites, 2 passed, 5 failed, 1 unchecked\s*$' -and $all.Code -eq 1) "code=$($all.Code) out=$o"
$one = Invoke-FakeRun '-Filter "a-pass*"'
Assert-Coord 'R4 a filter on the passing suite: RUN: 1 suites, 1 passed, 0 failed, 0 unchecked, exit 0' ($one.Code -eq 0 -and ([string]$one.Out) -cmatch '(?m)^RUN: 1 suites, 1 passed, 0 failed, 0 unchecked\s*$') "code=$($one.Code) out=$($one.Out)"
$none = Invoke-FakeRun '-Filter "no-such-suite*"'
Assert-Coord 'R4 a filter that matches nothing exits 1 with a zero total line' ($none.Code -eq 1 -and ([string]$none.Out) -cmatch '(?m)^RUN: 0 suites, 0 passed, 0 failed, 0 unchecked\s*$') "code=$($none.Code) out=$($none.Out)"

Write-Host "(R3) -Strict"
$un = Invoke-FakeRun '-Filter "f-unchecked*"'
Assert-Coord 'R3 without -Strict a suite with an unchecked row passes: exit 0, 1 unchecked in the total' ($un.Code -eq 0 -and ([string]$un.Out) -cmatch '(?m)^RUN: 1 suites, 1 passed, 0 failed, 1 unchecked\s*$') "code=$($un.Code) out=$($un.Out)"
$st = Invoke-FakeRun '-Filter "f-unchecked*" -Strict'
Assert-Coord 'R3 with -Strict that suite fails, naming the unchecked rows: exit 1' ($st.Code -eq 1 -and ([string]$st.Out) -cmatch 'FAILED SUITE f-unchecked\.test\.ps1: [^\r\n]*-Strict: 1 unchecked' -and ([string]$st.Out) -cmatch '(?m)^RUN: 1 suites, 0 passed, 1 failed, 1 unchecked\s*$') "code=$($st.Code) out=$($st.Out)"

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
Write-CoordUncheckedSummary
Write-Host ""
Write-Host "Passed: $script:coordPass  Failed: $script:coordFail"
if ($script:coordFail -gt 0) { exit 1 }
exit 0
