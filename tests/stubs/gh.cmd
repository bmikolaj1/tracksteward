@echo off
rem Test stub for gh, used by the tests/scripts suites. Hands every argument to
rem gh-coord-stub.ps1, which logs the call and answers from the rules file named
rem by GH_COORD_RESPONSES. The exit code is passed through.
rem Windows-only by nature: a .cmd file that starts Windows PowerShell 5.1 from
rem %SystemRoot%. Not verified off Windows (there is no gh stub for it yet).
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0gh-coord-stub.ps1" %*
exit /b %ERRORLEVEL%
