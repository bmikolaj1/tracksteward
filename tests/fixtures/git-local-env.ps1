# Git's repo-local environment variables, and a way to run a command without
# them. Dot-sourced by hook-test-fixture.ps1.
# Ported from the private coordinate toolkit (git-local-env.ps1), 2026-10-18.
#
# Inside a git hook, git exports repo-local variables to everything the hook
# starts: an absolute GIT_DIR in a linked worktree, and GIT_INDEX_FILE on every
# commit. Any git a child runs then acts on THAT repository, whatever directory
# it runs in. A test runner that builds throwaway git repos and is started
# from inside a hook would write its fixture's `git init` / `git config`
# (core.bare, an identity, core.autocrlf) into the real repository's shared
# .git/config. So every suite that builds fixture repos clears these variables
# first (Clear-HookRunnerGitEnv, in hook-test-fixture.ps1, uses the list below).

# Git's own list (`git rev-parse --local-env-vars`, git 2.43), unioned with
# what the installed git reports, in case a newer git adds one.
function Get-GitLocalEnvVarNames {
    $names = @('GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_CONFIG', 'GIT_CONFIG_PARAMETERS',
        'GIT_CONFIG_COUNT', 'GIT_OBJECT_DIRECTORY', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_IMPLICIT_WORK_TREE',
        'GIT_GRAFT_FILE', 'GIT_INDEX_FILE', 'GIT_NO_REPLACE_OBJECTS', 'GIT_REPLACE_REF_BASE',
        'GIT_PREFIX', 'GIT_SHALLOW_FILE', 'GIT_COMMON_DIR')
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $names = @($names + @(& git rev-parse --local-env-vars 2>$null) | Where-Object { $_ } | Sort-Object -Unique)
    }
    return $names
}

# Runs $ScriptBlock with every repo-local git variable cleared, then restores
# them, even when the block throws. $LASTEXITCODE is the block's: nothing
# native runs after it. A variable that was set but EMPTY (git exports
# `GIT_PREFIX=` at the repo root) comes back unset, because .NET cannot hold an
# empty value on Windows; git reads the two the same. The locals carry a prefix
# because the block runs in a child scope of this function and sees its
# variables: a plain $name here would shadow a caller's $name inside the block.
function Invoke-WithoutGitLocalEnv {
    param([Parameter(Mandatory = $true)][scriptblock]$ScriptBlock)
    $gitLocalEnvSaved = @{}
    try {
        foreach ($gitLocalEnvName in (Get-GitLocalEnvVarNames)) {
            $gitLocalEnvValue = [Environment]::GetEnvironmentVariable($gitLocalEnvName)
            if ($null -ne $gitLocalEnvValue) {
                $gitLocalEnvSaved[$gitLocalEnvName] = $gitLocalEnvValue
                [Environment]::SetEnvironmentVariable($gitLocalEnvName, $null)
            }
        }
        & $ScriptBlock
    }
    finally {
        foreach ($gitLocalEnvName in $gitLocalEnvSaved.Keys) {
            [Environment]::SetEnvironmentVariable($gitLocalEnvName, $gitLocalEnvSaved[$gitLocalEnvName])
        }
    }
}
