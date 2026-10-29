# Runs every *.test.ps1 under tests/ (recursively, sorted by path), each as its
# own child process, and prints the result of each suite plus a total.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1 [-Shell powershell|pwsh] [-Filter <wildcard>] [-TimeoutMinutes <n>] [-Strict]
#
# -Shell      the host each suite runs under: powershell (Windows PowerShell
#             5.1, the default) or pwsh (PowerShell 7). The choice is passed to
#             the suites in $env:TRACKSTEWARD_TEST_SHELL, so the child
#             PowerShell processes they start use the same host. One thing does
#             not follow it: the gh stub (tests\stubs\gh.cmd) always starts
#             Windows PowerShell 5.1 (powershell.exe), under either -Shell.
# -Filter     a wildcard matched against each suite's file name (for example
#             coord-log*) or its path relative to tests\ (for example scripts\*).
# -TimeoutMinutes  a suite still running after this long is stopped (its own
#             process and the processes it started, by process id) and counts as failed.
# -Strict     a suite that reports any UNCHECKED row counts as failed, so a run
#             with a check that could not run is not green.
#
# A suite PASSES only when its exit code is 0 AND its output holds a summary
# line "Passed: <n>  Failed: 0" with n greater than 0. A suite with no such line
# (it died early, or printed no summary) FAILS, and the failure line names the
# suite and the missing line. A suite that passes but could not run some rows
# still has those rows forwarded: every "UNCHECKED:" line it printed and its
# "Unchecked: <n>" line are printed under its result, passed or not.
#
# For each suite it prints the suite's last "Passed: n  Failed: m" line (or its
# last output line when there is none), its exit code, the forwarded UNCHECKED
# lines, and, for a suite that failed, why and its FAIL lines. Then one line:
#   RUN: <n> suites, <p> passed, <f> failed, <u> unchecked
# (<u> adds up the unchecked rows of all suites). Exit: 0 when every suite passed
# (and at least one ran), 1 otherwise, including no suite matching the filter.
param(
    [ValidateSet('powershell', 'pwsh')][string]$Shell = 'powershell',
    [string]$Filter = '',
    [int]$TimeoutMinutes = 30,
    [switch]$Strict
)

$testsDir = $PSScriptRoot
$shellName = if ($Shell -eq 'pwsh') { 'pwsh' } else { 'powershell.exe' }
$shellCmd = @(Get-Command $shellName -CommandType Application -ErrorAction SilentlyContinue)
if ($shellCmd.Count -eq 0) {
    Write-Host "run.ps1: the shell '$Shell' ($shellName) was not found on PATH"
    exit 1
}
$shellExe = [string]$shellCmd[0].Source
$env:TRACKSTEWARD_TEST_SHELL = $Shell
# Windows is told apart by the platform id, which both 5.1 and 7 have (5.1 has
# no $IsWindows).
$onWindows = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)

$suites = @(Get-ChildItem -LiteralPath $testsDir -Recurse -File -Filter '*.test.ps1' | Sort-Object { $_.FullName })
if ($Filter) {
    $suites = @($suites | Where-Object {
            $rel = $_.FullName.Substring($testsDir.Length).TrimStart('\', '/')
            ($_.Name -like $Filter) -or ($rel -like $Filter)
        })
}
if ($suites.Count -eq 0) {
    Write-Host "run.ps1: no suite matches under $testsDir"
    Write-Host 'RUN: 0 suites, 0 passed, 0 failed, 0 unchecked'
    exit 1
}

$passed = 0
$failed = 0
$uncheckedTotal = 0
foreach ($s in $suites) {
    $rel = $s.FullName.Substring($testsDir.Length).TrimStart('\', '/')
    Write-Host "== $rel ($Shell)"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $shellExe
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $s.FullName + '"'
    $psi.WorkingDirectory = $testsDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $outRead = $p.StandardOutput.ReadToEndAsync()
    $errRead = $p.StandardError.ReadToEndAsync()
    $code = $null
    if ($p.WaitForExit($TimeoutMinutes * 60 * 1000)) {
        $p.WaitForExit()
        $code = $p.ExitCode
    }
    else {
        # Stops the suite process and its children, by the id of the process this
        # runner started. Windows: taskkill /T /F /PID. Elsewhere (not verified
        # off Windows): Kill($true) ends the process tree on PowerShell 7; the
        # one-argument fallback ends the process alone.
        if ($onWindows) { & taskkill.exe /T /F /PID $p.Id 2>$null | Out-Null }
        else {
            try { $p.Kill($true) }
            catch { try { $p.Kill() } catch { } }
        }
        $code = "timed out after $TimeoutMinutes min"
    }
    $out = if ($outRead.Wait(10000)) { [string]$outRead.Result } else { '' }
    $err = if ($errRead.Wait(10000)) { [string]$errRead.Result } else { '' }
    $lines = @(($out -split "`r?`n") | Where-Object { $_.Trim() })
    # The last "Passed: <n>  Failed: <m>" line, matched case-sensitively.
    $sumLine = $null
    $sumPassed = $null
    $sumFailed = $null
    foreach ($l in $lines) {
        if ($l -cmatch '^\s*Passed:\s*(\d+)\s+Failed:\s*(\d+)\s*$') {
            $sumLine = $l
            $sumPassed = [int]$Matches[1]
            $sumFailed = [int]$Matches[2]
        }
    }
    $summary = $sumLine
    if (-not $summary -and $lines.Count) { $summary = $lines[$lines.Count - 1] }
    # The unchecked rows: the "UNCHECKED:" lines and the "Unchecked: <n>" line
    # (both matched case-sensitively; the larger count is used).
    $uncheckedLines = @($lines | Where-Object { $_ -cmatch '^\s*UNCHECKED:' })
    $uncheckedCount = $uncheckedLines.Count
    $uncheckedSummary = $null
    foreach ($l in $lines) {
        if ($l -cmatch '^\s*Unchecked:\s*(\d+)') {
            $uncheckedSummary = $l
            if ([int]$Matches[1] -gt $uncheckedCount) { $uncheckedCount = [int]$Matches[1] }
        }
    }
    $uncheckedTotal += $uncheckedCount

    $why = New-Object System.Collections.Generic.List[string]
    if (-not (($code -is [int]) -and ($code -eq 0))) { $why.Add("exit code is $code, not 0") }
    if ($null -eq $sumLine) { $why.Add("no summary line 'Passed: <n>  Failed: 0' in its output") }
    elseif ($sumFailed -gt 0) { $why.Add("its summary says Failed: $sumFailed") }
    elseif ($sumPassed -le 0) { $why.Add("its summary says Passed: 0 (no check ran)") }
    if ($Strict -and $uncheckedCount -gt 0) { $why.Add("-Strict: $uncheckedCount unchecked row(s)") }

    Write-Host ("   " + $(if ($summary) { $summary.Trim() } else { '(no output)' }) + "   exit code: $code")
    foreach ($l in $uncheckedLines) { Write-Host ("   " + $l.Trim()) }
    if ($uncheckedSummary) { Write-Host ("   " + $uncheckedSummary.Trim()) }
    if ($why.Count -gt 0) {
        Write-Host ("   FAILED SUITE ${rel}: " + ($why -join '; '))
        foreach ($l in @($lines | Where-Object { $_ -cmatch '^\s*FAIL:' })) { Write-Host ("   " + $l.Trim()) }
        if ($err.Trim()) { Write-Host ("   stderr: " + ($err.Trim() -split "`r?`n")[0]) }
        $failed++
    }
    else { $passed++ }
}
Write-Host "RUN: $($suites.Count) suites, $passed passed, $failed failed, $uncheckedTotal unchecked"
if ($failed -gt 0) { exit 1 }
exit 0
