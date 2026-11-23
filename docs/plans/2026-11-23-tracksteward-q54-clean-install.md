# Q54: clean-profile install from GitHub (release gate 4 substitute)

Date: 2026-11-23. Base: main at c2adbf6 (0.2.11, not tagged). Question: can someone who has
never seen the repo install tracksteward from GitHub using the README alone, and does the
skill then work?

Placeholders: `<home>` is an empty folder used as the user profile, `<scratch>` a scratch
folder. Nothing touched a real user profile (checked, see Isolation).

## Set-up

- `<home>` is empty. In every command: `USERPROFILE`, `HOME` = `<home>`,
  `CLAUDE_CONFIG_DIR` = `<home>\.claude`, `LOCALAPPDATA` = `<home>\AppData\Local`,
  `APPDATA` = `<home>\AppData\Roaming`.
- `TRACKSTEWARD_SCRUB_DENYLIST` and `TRACKSTEWARD_SCRUB_REPOS` unset, as a newcomer has neither.
- Claude Code 2.1.330, Windows 11, Windows PowerShell 5.1.

## Step log

| # | Command | Exit | Result | README enough? |
|---|---------|------|--------|----------------|
| 1 | `git clone https://github.com/bmikolaj1/tracksteward <scratch>\tracksteward` | 0 | main at c2adbf6 | yes |
| 2 | `claude plugin marketplace add bmikolaj1/tracksteward` | 0 | tries SSH, falls back to HTTPS by itself, marketplace `tracksteward` added | yes |
| 3 | `claude plugin install coordinate@tracksteward` | 0 | installed, scope user | yes |
| 4 | `claude plugin list` | 0 | `coordinate@tracksteward` 0.2.11, enabled | yes |
| 5 | `tests\run.ps1` in the clone | 0 | 14 suites, 14 passed, 0 failed, 8 unchecked; the denylist rows read "NOT CHECKED: denylist absent" (not FAIL) | yes |
| 6 | one login by the maintainer, `claude -p` with the clean config | 0 | skill listed as `coordinate:coordinate` | yes |
| 7 | `claude -p`: three sessions in separate worktrees, "Coordinate these sessions" | 0 | skill `coordinate:coordinate` chosen; proposes today's ledger, `coord-log.ps1 -Register`, `repo-snapshot.ps1`, then one list and briefing | yes |
| 8 | the same with two sessions in one repo | 0 | skill declined, citing its own "three or more sessions or two repos" rule | consistent with the README's "Before you start" |

No README gap found: no step needed a guess. No README or CHANGELOG change is made in this PR.

## Findings about the check itself (not about the README)

1. **A redirected profile is not a clean one.** First full run: `prune-scan` failed 4 rows
   (P9, P29). Cause: only `USERPROFILE` and `HOME` were redirected. Windows PowerShell then
   wrote a `Microsoft\Windows\PowerShell\ModuleAnalysisCache` into the working folder, which
   the suite counts as an untracked file. With `LOCALAPPDATA` and `APPDATA` redirected too the
   same suite passes (210/0) and the full run is green. The repo is not at fault.
2. **Claude Code finds its home through the OS, not the environment.** With the redirected
   profile, a session still loaded the real user's global `CLAUDE.md`, and the first
   trigger answer leaned on it. Setting `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` removed it (probe:
   "none"), and steps 7 and 8 were run that way. Anyone repeating this check needs it.
3. The account's own plugins and skills appear in the clean profile after login; they come
   with the account, not with `<home>`.
4. The login opens the default browser, which with the redirected `LOCALAPPDATA` creates its
   own profile inside `<home>` and keeps files there open. Close that browser instance before
   deleting `<home>`.

## Isolation

A snapshot (name, size, modified time) of the real profile's top-level config files was taken
before the login and compared after the login and after steps 6 to 8: no file changed, none
was added or removed. The credential store held no entry for the tool (file-based). `<home>`
held the only new credentials file; it and the scratch folders were deleted after the run.

## UNCHECKED

- The private-name scrub (denylist) and the commit-sha rows: the check has no denylist by design.
- Symlink and odd-filename rows in the suites: this user cannot create symlinks.
- A second person's machine: this is one person's clean profile, not another human.
