<#
.SYNOPSIS
    Commits and pushes changes in this repository to GitHub.

.DESCRIPTION
    A small wrapper round the add / commit / pull / push cycle, with the checks that
    usually catch people out: it refuses to run outside a git repo, tells you what it is
    about to commit, brings down anything new on the remote first, and says nothing was
    needed when nothing was.

    Run it from anywhere - it works on the repository it lives in unless you point it
    somewhere else with -Path.

.PARAMETER Message
    Commit message. Defaults to "Update - <n> file(s) - <date>".

.PARAMETER Path
    Repository to work on. Defaults to the folder this script is in.

.PARAMETER Force
    Skip the confirmation prompt.

.PARAMETER NoPull
    Do not pull before pushing. Only sensible when you know nobody else has touched the remote.

.PARAMETER ShowDiff
    Print the diff of what is about to be committed.

.EXAMPLE
    .\Update-Repo.ps1
    Stages everything, shows it, asks, commits with a generated message and pushes.

.EXAMPLE
    .\Update-Repo.ps1 -Message "Add maintenance_hash to the secondary answer file" -Force

.EXAMPLE
    .\Update-Repo.ps1 -Path $HOME\Documents\ClaudeCowork\SomeOtherRepo -ShowDiff
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Message,
    [string]$Path,
    [switch]$Force,
    [switch]$NoPull,
    [switch]$ShowDiff
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Text) Write-Host "`n$Text" -ForegroundColor Cyan }
function Write-Note { param([string]$Text) Write-Host "  $Text" -ForegroundColor Gray }

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git is not on PATH.' }

if (-not $Path) {
    # Prefer wherever you are, so the script works from inside any repo even when it
    # lives somewhere else entirely. Falls back to its own folder.
    $cwd = (Get-Location).Path
    $here = git -C $cwd rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -eq 0 -and "$here".Trim() -eq 'true') { $Path = $cwd }
    elseif ($PSScriptRoot) { $Path = $PSScriptRoot }
    else { $Path = $cwd }
}

Push-Location $Path
try {
    $inside = git rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -ne 0 -or $inside.Trim() -ne 'true') { throw "$Path is not inside a git repository." }

    $root   = (git rev-parse --show-toplevel).Trim()
    $branch = (git rev-parse --abbrev-ref HEAD).Trim()
    $remote = (git remote get-url origin 2>$null)
    Write-Host "Repository : $root"      -ForegroundColor White
    Write-Host "Branch     : $branch"    -ForegroundColor White
    Write-Host "Remote     : $remote"    -ForegroundColor White

    # ---------------------------------------------------------------- remote --
    Write-Step 'Checking the remote...'
    git fetch origin --quiet
    if ($LASTEXITCODE -ne 0) { throw 'git fetch failed - check your network or credentials.' }

    $counts = (git rev-list --left-right --count "origin/$branch...HEAD" 2>$null)
    $behind = 0; $ahead = 0
    if ($counts) { $parts = $counts -split '\s+'; $behind = [int]$parts[0]; $ahead = [int]$parts[1] }
    Write-Note "$behind commit(s) behind, $ahead commit(s) ahead of origin/$branch"

    # ------------------------------------------------------------ local work --
    $status = git status --porcelain
    if ($status) {
        Write-Step 'Changes to commit:'
        foreach ($line in $status) {
            $code = $line.Substring(0, 2).Trim()
            $file = $line.Substring(3)
            $what = switch -Regex ($code) {
                '^\?\?' { 'new     ' }
                '^D'    { 'deleted ' }
                '^R'    { 'renamed ' }
                default { 'modified' }
            }
            Write-Host ("  {0}  {1}" -f $what, $file) -ForegroundColor Yellow
        }
        if ($ShowDiff) {
            Write-Step 'Diff:'
            git --no-pager diff
            git --no-pager diff --cached
        }
    } elseif ($ahead -eq 0) {
        Write-Step 'Nothing to do - no local changes and nothing waiting to push.'
        if ($behind -gt 0 -and -not $NoPull) {
            Write-Note "Pulling $behind commit(s) from the remote."
            git pull --rebase origin $branch
        }
        return
    } else {
        Write-Step "No new changes, but $ahead commit(s) are waiting to push."
    }

    # -------------------------------------------------------------- confirm --
    if (-not $Force -and $status) {
        $answer = Read-Host "`nCommit and push these changes? [Y/n]"
        if ($answer -and $answer -notmatch '^[Yy]') { Write-Host 'Cancelled - nothing was changed.' -ForegroundColor Yellow; return }
    }

    # --------------------------------------------------------------- commit --
    if ($status) {
        if (-not $Message) {
            $n = @($status).Count
            $Message = 'Update - {0} file{1} - {2}' -f $n, $(if ($n -eq 1) { '' } else { 's' }), (Get-Date -Format 'yyyy-MM-dd HH:mm')
        }
        Write-Step "Committing: $Message"
        git add -A
        git commit -m $Message
        if ($LASTEXITCODE -ne 0) { throw 'git commit failed.' }
    }

    # ----------------------------------------------------------------- pull --
    if (-not $NoPull -and $behind -gt 0) {
        Write-Step "Rebasing onto $behind commit(s) from the remote..."
        git pull --rebase origin $branch
        if ($LASTEXITCODE -ne 0) {
            throw "The rebase hit a conflict. Resolve it, then run: git rebase --continue  (or git rebase --abort to back out)."
        }
    }

    # ----------------------------------------------------------------- push --
    Write-Step "Pushing to origin/$branch..."
    git push origin $branch
    if ($LASTEXITCODE -ne 0) {
        throw @'
git push failed.
  403 / permission denied -> the token has expired or lost its Contents: Read and write permission
                             (github.com/settings/personal-access-tokens)
  401 / invalid token     -> re-store it:
                             "protocol=https`nhost=github.com`nusername=<user>`npassword=<token>`n" | git credential approve
'@
    }

    Write-Step 'Done.'
    git --no-pager log --oneline -3
    if ($remote -match 'github\.com[:/](.+?)(\.git)?$') {
        Write-Host "`n  https://github.com/$($Matches[1])" -ForegroundColor Green
    }
} finally {
    Pop-Location
}
