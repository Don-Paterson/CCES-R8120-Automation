<#
.SYNOPSIS
    One-liner bootstrap for the CCES R81.20 lab automation. Run this on A-GUI.

.DESCRIPTION
    Downloads the repository to the desktop, unblocks it, and puts up a menu of the
    lab build stages. Any lab-settings.psd1 you have already edited is preserved
    across a refresh.

    Menu:
        irm https://raw.githubusercontent.com/Don-Paterson/CCES-R8120-Automation/main/bootstrap.ps1 | iex

    Straight to one stage (parameters need the scriptblock form):
        & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Don-Paterson/CCES-R8120-Automation/main/bootstrap.ps1))) -Action Prereqs

.PARAMETER Action
    Menu (default), Prereqs, DryRun, Ftw, Jumbo, Secondary, SecondaryJumbo, Settings, DownloadOnly.

.PARAMETER InstallPath
    Where to put the files. Default: Desktop\CCES-Automation.

.PARAMETER GaiaPassword
    Overrides the Gaia admin password from lab-settings.psd1 for this run.

.PARAMETER Branch
    Branch to pull. Default: main.
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Prereqs', 'DryRun', 'Ftw', 'Endpoint', 'Jumbo', 'Full', 'Secondary', 'SecondaryJumbo', 'Settings', 'DownloadOnly')]
    [string]$Action = 'Menu',
    [string]$InstallPath,
    [string]$GaiaPassword,
    [string]$Branch = 'main'
)

$ErrorActionPreference = 'Stop'
$repo = 'Don-Paterson/CCES-R8120-Automation'

function Write-Head {
    Write-Host ''
    Write-Host '  CCES R81.20 lab automation' -ForegroundColor Cyan
    Write-Host '  A-EPM / A-EPM-02 build - run from A-GUI' -ForegroundColor DarkGray
    Write-Host ''
}
function Write-Step { param([string]$T) Write-Host "  $T" -ForegroundColor Cyan }
function Write-Note { param([string]$T) Write-Host "    $T" -ForegroundColor Gray }
function Write-Bad  { param([string]$T) Write-Host "    $T" -ForegroundColor Red }

# --------------------------------------------------------------- download ----
function Get-Repo {
    param([string]$Dest, [string]$Br)

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

    $zip = Join-Path $env:TEMP "cces-$Br.zip"
    $tmp = Join-Path $env:TEMP "cces-extract-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $url = "https://github.com/$repo/archive/refs/heads/$Br.zip"

    Write-Step "Downloading $repo ($Br)..."
    try {
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    } catch {
        Write-Bad "Download failed: $($_.Exception.Message)"
        Write-Bad 'A-GUI may have no route to github.com. Copy the repo folder into the lab by hand instead.'
        throw
    }

    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
    $src = Get-ChildItem -Path $tmp -Directory | Select-Object -First 1

    # Keep any settings the user has already edited.
    $settings = Join-Path $Dest 'config\lab-settings.psd1'
    $saved = $null
    if (Test-Path -LiteralPath $settings) {
        $saved = Get-Content -LiteralPath $settings -Raw
        Write-Note 'Existing lab-settings.psd1 found - it will be kept.'
    }

    if (-not (Test-Path -LiteralPath $Dest)) { New-Item -ItemType Directory -Path $Dest -Force | Out-Null }
    Copy-Item -Path (Join-Path $src.FullName '*') -Destination $Dest -Recurse -Force

    if ($saved) {
        # Keep the user's edits, but the repo may have added keys since it was written.
        # Silently restoring an older file is how a new setting arrives as '' or $false.
        $fresh = Get-Content -LiteralPath $settings -Raw
        Set-Content -LiteralPath $settings -Value $saved -Encoding UTF8

        $freshKeys = [regex]::Matches($fresh, '(?m)^\s*([A-Za-z0-9_]+)\s*=') | ForEach-Object { $_.Groups[1].Value }
        $savedKeys = [regex]::Matches($saved, '(?m)^\s*([A-Za-z0-9_]+)\s*=') | ForEach-Object { $_.Groups[1].Value }
        $missing = $freshKeys | Where-Object { $_ -notin $savedKeys }

        if ($missing) {
            $newPath = "$settings.new"
            Set-Content -LiteralPath $newPath -Value $fresh -Encoding UTF8
            Write-Host ''
            Write-Bad  "Your lab-settings.psd1 is missing $($missing.Count) setting(s) added since you last edited it:"
            foreach ($m in $missing) { Write-Bad "      $m" }
            Write-Note "The current template has been written alongside it as lab-settings.psd1.new"
            Write-Note 'Copy the missing lines across, or delete lab-settings.psd1 and re-run this bootstrap.'
            Write-Host ''
        }
    }

    # Clear the mark-of-the-web the zip leaves behind, or PowerShell blocks every script.
    try { Get-ChildItem -Path $Dest -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue } catch { }
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

    Write-Note "Ready at $Dest"
    return $Dest
}

# ------------------------------------------------------------------ runner ---
function Invoke-Stage {
    param([string]$Name, [string]$Root, [string]$Pwd)

    $s = Join-Path $Root 'scripts'
    $extra = @{}
    if ($Pwd) { $extra['GaiaPassword'] = $Pwd }

    try {
    switch ($Name) {
        'Prereqs'        { & (Join-Path $s 'Test-LabPrereqs.ps1')  @extra }
        'DryRun'         { & (Join-Path $s 'Invoke-AEPM-FTW.ps1')  -DryRun @extra }
        'Ftw'            { & (Join-Path $s 'Invoke-AEPM-FTW.ps1')  @extra }
        'Endpoint'       { & (Join-Path $s 'Set-AEPMEndpoint.ps1') @extra }
        'Jumbo'          { & (Join-Path $s 'Install-JumboT26.ps1') -Target 'A-EPM' @extra }
        'Full' {
            Write-Step 'Full A-EPM build: wizard, licence, contract, agent, Endpoint config, Jumbo.'
            Write-Note 'No SmartConsole step. Allow up to two hours.'
            $began = Get-Date
            try {
                & (Join-Path $s 'Invoke-AEPM-FTW.ps1')  @extra
                & (Join-Path $s 'Set-AEPMEndpoint.ps1') @extra
                & (Join-Path $s 'Install-JumboT26.ps1') -Target 'A-EPM' @extra
                Write-Step ("Full build finished in {0:N0} minutes." -f ((Get-Date) - $began).TotalMinutes)
            } catch {
                Write-Bad "Full build stopped: $($_.Exception.Message)"
                Write-Note 'The later stages were skipped. Fix the cause, then re-run - completed stages are detected and skipped.'
            }
        }
        'Secondary'      { & (Join-Path $s 'Invoke-AEPM02-FTW.ps1') @extra }
        'SecondaryJumbo' { & (Join-Path $s 'Invoke-AEPM02-FTW.ps1') -InstallJumbo @extra }
        'Settings'       { notepad.exe (Join-Path $Root 'config\lab-settings.psd1') }
        'DownloadOnly'   { Write-Note 'Files downloaded, nothing run.' }
    }
    } catch {
        Write-Bad "Stage '$Name' failed: $($_.Exception.Message)"
        Write-Note 'Returning to the menu. Re-running is safe - finished work is detected and skipped.'
    }
}

# -------------------------------------------------------------------- menu ---
function Show-Menu {
    param([string]$Root, [string]$Pwd)

    while ($true) {
        Write-Head
        Write-Host '   1   Pre-flight checks (read-only)'              -ForegroundColor White
        Write-Host '   2   A-EPM  - validate the answer file only'     -ForegroundColor White
        Write-Host ''
        Write-Host '   3   A-EPM  - wizard, licence, contract, CPUSE agent   (Task 2A-1)' -ForegroundColor White
        Write-Host '   4   A-EPM  - Endpoint + SmartEvent + NAT, install db  (Task 2A-2)' -ForegroundColor White
        Write-Host '   5   A-EPM  - install Jumbo Take 26                    (Task 2A-3)' -ForegroundColor White
        Write-Host '   6   A-EPM  - FULL BUILD: 3 + 4 + 5, no SmartConsole needed' -ForegroundColor Green
        Write-Host ''
        Write-Host '   7   A-EPM-02 - build secondary management server' -ForegroundColor White
        Write-Host '   8   A-EPM-02 - build and install Jumbo Take 26'   -ForegroundColor White
        Write-Host ''
        Write-Host '   S   Edit lab settings (IPs, passwords, paths)'  -ForegroundColor DarkGray
        Write-Host '   F   Open the folder'                            -ForegroundColor DarkGray
        Write-Host '   Q   Quit'                                       -ForegroundColor DarkGray
        Write-Host ''
        $c = Read-Host '  Choose'

        switch ($c.ToUpper()) {
            '1' { Invoke-Stage 'Prereqs'        $Root $Pwd }
            '2' { Invoke-Stage 'DryRun'         $Root $Pwd }
            '3' { Invoke-Stage 'Ftw'            $Root $Pwd }
            '4' { Invoke-Stage 'Endpoint'       $Root $Pwd }
            '5' { Invoke-Stage 'Jumbo'          $Root $Pwd }
            '6' { Invoke-Stage 'Full'           $Root $Pwd }
            '7' { Invoke-Stage 'Secondary'      $Root $Pwd }
            '8' { Invoke-Stage 'SecondaryJumbo' $Root $Pwd }
            'S' { Invoke-Stage 'Settings'       $Root $Pwd }
            'F' { Start-Process explorer.exe $Root }
            'Q' { return }
            default { Write-Bad 'Not an option.' }
        }

        if ($c.ToUpper() -notin @('Q', 'F', 'S')) {
            Write-Host ''
            Read-Host '  Press Enter for the menu'
        }
    }
}

# -------------------------------------------------------------------- main ---
Write-Head
if (-not $InstallPath) { $InstallPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'CCES-Automation' }

$root = Get-Repo -Dest $InstallPath -Br $Branch

if ($Action -eq 'Menu') { Show-Menu -Root $root -Pwd $GaiaPassword }
else { Invoke-Stage $Action $root $GaiaPassword }
