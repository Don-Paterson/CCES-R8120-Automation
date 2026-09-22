<#
.SYNOPSIS
    Installs R81.20 Jumbo Hotfix Accumulator Take 26 on A-EPM (or A-EPM-02) with CPUSE.
    Run it on A-GUI.

.DESCRIPTION
    Stage 2 of the lab build, run after the manual SmartConsole work on A-EPM
    (Endpoint Policy Management + SmartEvent enabled, NAT configured, policy installed).

    It copies Check_Point_R81_20_JUMBO_HF_MAIN_Bundle_T26_FULL.tar from the
    Check Point Tools folder to the target, imports it into CPUSE, verifies it,
    installs it and waits out the reboot.

    On A-EPM a valid licence and service contract must already be on the box - CPUSE
    refuses the Jumbo otherwise, and the 15 day evaluation licence is not enough.
    Invoke-AEPM-FTW.ps1 does that. A-EPM-02 takes the Jumbo without a licence.

.PARAMETER Target
    A-EPM, A-EPM-02, or an IP address.

.EXAMPLE
    .\Install-JumboT26.ps1

.EXAMPLE
    .\Install-JumboT26.ps1 -Target A-EPM-02 -SkipLicenseCheck
#>
[CmdletBinding()]
param(
    [string]$Target = 'A-EPM',
    [string]$SettingsPath,
    [string]$GaiaUser,
    [string]$GaiaPassword,
    [string]$ToolsPath,
    [string]$BundleFile,
    [ValidateSet('Auto', 'Plink', 'PoshSSH')][string]$Transport = 'Auto',
    [int]$InstallTimeoutMin = 120,
    [switch]$SkipLicenseCheck,
    [switch]$SkipVerify,
    [switch]$CopyOnly,
    [switch]$KeepBashShell
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\CPLab.Ssh.ps1')

if (-not $SettingsPath) { $SettingsPath = Join-Path $root 'config\lab-settings.psd1' }
$cfg = Import-PowerShellDataFile -LiteralPath $SettingsPath

$targetIp = switch ($Target) {
    'A-EPM'    { $cfg.AEpmIp }
    'A-EPM-02' { $cfg.AEpm02Ip }
    default    { $Target }
}
if (-not $GaiaUser)     { $GaiaUser = $cfg.GaiaUser }
if (-not $GaiaPassword) { $GaiaPassword = $cfg.GaiaPassword }
if (-not $ToolsPath)    { $ToolsPath = $cfg.ToolsPath }
if (-not $BundleFile)   { $BundleFile = $cfg.JumboBundle }

$bundlePath = Join-Path $ToolsPath $BundleFile
if (-not (Test-Path -LiteralPath $bundlePath)) { throw "Jumbo bundle not found: $bundlePath" }
$bundleMb = [math]::Round((Get-Item -LiteralPath $bundlePath).Length / 1MB)

Start-CPLog (Join-Path $cfg.LogPath ('JumboT26_{0}_{1:yyyyMMdd-HHmmss}.log' -f $Target, (Get-Date)))
Write-CPLog "Installing Jumbo Take 26 on $Target ($targetIp) from $BundleFile (${bundleMb} MB)" STEP

$xport = Get-CPTransport -Prefer $Transport -AllowInstall
$session = Connect-CPHost -HostName $targetIp -UserName $GaiaUser -Password $GaiaPassword -Transport $xport

try {
    if (-not (Initialize-CPShellAccess -Session $session -ExpertPassword $cfg.ExpertPassword -ExpertPasswordHash $cfg.ExpertPasswordHash)) {
        throw 'Could not get shell access on the target.'
    }

    # ------------------------------------------------------------ pre-flight --
    $before = Get-CPInstalledTake -Session $session
    if ($before -match '(?i)JUMBO.*\bTake[:\s]+26\b' -or $before -match '(?i)Take[:\s]+26\b') {
        Write-CPLog 'Take 26 already looks installed on this machine.' WARN
        Write-CPLog 'Re-run with -Force is not supported; remove the hotfix in CPUSE first if you really want to reinstall.' INFO
        return
    }

    # df -k wraps onto two lines when the device name is long, which Gaia's LVM names are,
    # so the Available column lands in a different field. -P forces one line per filesystem.
    $df = Invoke-CPBash -Session $session -Command "df -kP /var/log | tail -1 | tr -s ' ' | cut -d' ' -f4" -TimeoutSec 120 -Quiet
    $freeKb = 0
    foreach ($l in ($df.Output -split "`n")) {
        if ($l.Trim() -match '^(\d+)$') { $freeKb = [int64]$Matches[1]; break }
    }
    $freeMb = [math]::Round($freeKb / 1024)

    if ($freeKb -le 0) {
        Write-CPLog 'Could not read the free space in /var/log - skipping the space check.' WARN
    } else {
        Write-CPLog ("Free space in /var/log: {0:N0} MB (the bundle needs about {1:N0} MB plus room to unpack)" -f $freeMb, ($bundleMb * 2)) INFO
        if ($freeMb -lt ($bundleMb * 2)) {
            Write-CPLog 'There may not be enough room in /var/log. Clear old packages with: installer clean or remove /var/log/*.tar.' WARN
        }
    }

    if (-not $SkipLicenseCheck) {
        $lic = Invoke-CPBash -Session $session -Command 'cplic print -x 2>/dev/null' -TimeoutSec 180
        if ($lic.Output -match '(?i)no licenses|eval') {
            Write-CPLog 'This machine has no licence, or only an evaluation licence. CPUSE is likely to refuse the Jumbo.' WARN
            Write-CPLog 'Install Licenses\A-EPM.lic and Licenses\ServiceContract.xml first (Invoke-AEPM-FTW.ps1 does this).' WARN
        }
    }

    # ----------------------------------------------------------------- copy --
    $remote = Copy-CPFileToHost -Session $session -LocalPath $bundlePath -RemoteDir '/var/log' -SkipIfSameSize
    if ($CopyOnly) {
        Write-CPLog "Copied only, as asked. The package is at $remote." OK
        return
    }

    # -------------------------------------------------------------- install --
    $null = Install-CPUSEPackage -Session $session -RemotePackagePath $remote -MatchPattern 'JUMBO|Jumbo|Take_26|T26' -InstallTimeoutMin $InstallTimeoutMin -SkipVerify:$SkipVerify

    if (-not (Wait-CPManagementReady -Session $session -TimeoutSec 2400)) {
        Write-CPLog 'Services did not all come back - check cpwd_admin list on the box.' WARN
    }

    $after = Get-CPInstalledTake -Session $session
    Write-CPLog '' INFO
    Write-CPLog '======================= installed version =======================' OK
    foreach ($l in ($after -split "`n")) { if ($l.Trim()) { Write-CPLog "    $l" INFO } }
    Write-CPLog '=================================================================' OK

    if (-not $KeepBashShell -and $cfg.RestoreClishShell) { Restore-CPClishShell -Session $session }
} finally {
    if ($session) { Disconnect-CPHost -Session $session }
}
