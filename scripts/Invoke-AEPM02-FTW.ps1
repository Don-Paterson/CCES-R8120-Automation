<#
.SYNOPSIS
    Builds A-EPM-02, the secondary Endpoint Security Management Server (Lab 6B).
    Run it on A-GUI.

.DESCRIPTION
    Runs the First Time Wizard on A-EPM-02 (10.1.1.104) from config\A-EPM-02_ftw.sh,
    using the SIC one-time password you set on the Secondary Security Management Server
    object in SmartConsole, then installs the CPUSE Deployment Agent.

    Unlike A-EPM, this machine does not need a licence before the Jumbo goes on, so
    -InstallJumbo can take it all the way in one run.

    Do this first, in SmartConsole on A-EPM:
      New object > Secondary Security Management Server, name A-EPM-02, IP 10.1.1.104,
      set the one-time password, then publish.

.PARAMETER SicKey
    The one-time password from that SmartConsole object. Defaults to the value in
    config\lab-settings.psd1.

.EXAMPLE
    .\Invoke-AEPM02-FTW.ps1 -SicKey 'Chkp!234'

.EXAMPLE
    .\Invoke-AEPM02-FTW.ps1 -InstallJumbo
#>
[CmdletBinding()]
param(
    [string]$SettingsPath,
    [string]$TargetIp,
    [string]$GaiaUser,
    [string]$GaiaPassword,
    [string]$SicKey,
    [string]$ToolsPath,
    [ValidateSet('Auto', 'Plink', 'PoshSSH')][string]$Transport = 'Auto',
    [switch]$DryRun,
    [switch]$SkipDeploymentAgent,
    [switch]$InstallLicense,
    [switch]$InstallJumbo,
    [switch]$KeepBashShell
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\CPLab.Ssh.ps1')

if (-not $SettingsPath) { $SettingsPath = Join-Path $root 'config\lab-settings.psd1' }
$cfg = Import-PowerShellDataFile -LiteralPath $SettingsPath
if (-not $TargetIp)     { $TargetIp = $cfg.AEpm02Ip }
if (-not $GaiaUser)     { $GaiaUser = $cfg.GaiaUser }
if (-not $GaiaPassword) { $GaiaPassword = $cfg.GaiaPassword }
if (-not $SicKey)       { $SicKey = $cfg.SicKey }
if (-not $ToolsPath)    { $ToolsPath = $cfg.ToolsPath }

Start-CPLog (Join-Path $cfg.LogPath ('A-EPM-02-FTW_{0:yyyyMMdd-HHmmss}.log' -f (Get-Date)))
Write-CPLog "CCES R81.20 - building $($cfg.AEpm02Name) (secondary management) at $TargetIp" STEP

$ftwFile   = Join-Path $root 'config\A-EPM-02_ftw.sh'
$agentPath = Join-Path $ToolsPath $cfg.DeploymentAgent
$licPath   = Join-Path $ToolsPath $cfg.License02File
if (-not (Test-Path -LiteralPath $ftwFile)) { throw "Answer file not found: $ftwFile" }

Write-CPLog 'Reminder: the Secondary Security Management Server object must already exist' WARN
Write-CPLog "in SmartConsole on $($cfg.AEpmName), with one-time password '$SicKey'." WARN

if (Test-CPTcpPort -HostName $cfg.AEpmIp -Port 22) {
    Write-CPLog "Primary $($cfg.AEpmName) ($($cfg.AEpmIp)) is reachable." OK
} else {
    Write-CPLog "Primary $($cfg.AEpmName) ($($cfg.AEpmIp)) is not answering - SIC will fail. Start it first." ERROR
}

$transport = Get-CPTransport -Prefer $Transport -AllowInstall
$session = Connect-CPHost -HostName $TargetIp -UserName $GaiaUser -Password $GaiaPassword -Transport $transport

try {
    if (-not (Initialize-CPShellAccess -Session $session -ExpertPassword $cfg.ExpertPassword -ExpertPasswordHash $cfg.ExpertPasswordHash)) {
        throw 'Could not get shell access on the target.'
    }

    if (Test-CPFtwDone -Session $session) {
        Write-CPLog 'The First Time Wizard has already been run on A-EPM-02 - skipping to the agent step.' WARN
    } else {
        $answer = Get-Content -LiteralPath $ftwFile -Raw
        $answer = [regex]::Replace($answer, '(?m)^\s*ftw_sic_key=.*$', ('ftw_sic_key="{0}"' -f $SicKey))
        if ($answer -notmatch 'ftw_sic_key=') { throw "No ftw_sic_key line in $ftwFile" }

        $null = Invoke-CPFtw -Session $session -AnswerFileContent $answer -RemotePath '/home/admin/A-EPM-02_ftw.sh' -DryRunOnly:$DryRun
        if ($DryRun) {
            Write-CPLog 'Dry run finished - the answer file is valid. Re-run without -DryRun to build.' OK
            return
        }

        Start-Sleep -Seconds 60
        $null = Wait-CPReboot -HostName $TargetIp -DownTimeoutSec 900 -UpTimeoutSec 2400
        Disconnect-CPHost -Session $session
        Start-Sleep -Seconds 20
        $session = Connect-CPHost -HostName $TargetIp -UserName $GaiaUser -Password $GaiaPassword -Transport $transport
        if (-not (Initialize-CPShellAccess -Session $session -ExpertPassword $cfg.ExpertPassword -ExpertPasswordHash $cfg.ExpertPasswordHash)) {
            throw 'Lost shell access after the reboot.'
        }
        if (-not (Test-CPFtwDone -Session $session)) {
            $log = Invoke-CPBash -Session $session -Command 'tail -n 40 /var/log/cces_ftw.log 2>/dev/null' -TimeoutSec 120
            throw "The wizard does not look finished. Last of /var/log/cces_ftw.log:`n$($log.Output)"
        }
        Write-CPLog 'First Time Wizard completed on A-EPM-02.' OK
        $null = Wait-CPManagementReady -Session $session -TimeoutSec 2400

        $sic = Invoke-CPBash -Session $session -Command 'cpca_client lscert 2>/dev/null | head -5; cp_conf sic state 2>/dev/null' -TimeoutSec 180
        Write-CPLog 'SIC state reported above. Finish synchronisation from SmartConsole on the primary.' INFO
    }

    if ($InstallLicense -and (Test-Path -LiteralPath $licPath)) {
        $null = Install-CPLicense -Session $session -LocalLicensePath $licPath
    }

    if (-not $SkipDeploymentAgent -and (Test-Path -LiteralPath $agentPath)) {
        $null = Install-CPDeploymentAgent -Session $session -LocalAgentPath $agentPath
    }

    if (-not $KeepBashShell -and $cfg.RestoreClishShell -and -not $InstallJumbo) { Restore-CPClishShell -Session $session }
} finally {
    if ($session) { Disconnect-CPHost -Session $session }
}

if ($InstallJumbo) {
    Write-CPLog 'Handing over to Install-JumboT26.ps1 for A-EPM-02...' STEP
    & (Join-Path $PSScriptRoot 'Install-JumboT26.ps1') -Target 'A-EPM-02' -SettingsPath $SettingsPath -GaiaPassword $GaiaPassword -SkipLicenseCheck
}

Write-CPLog '' INFO
Write-CPLog '=============== A-EPM-02 build finished ===============' OK
Write-CPLog "In SmartConsole on $($cfg.AEpmName): check the secondary object shows SIC trust," INFO
Write-CPLog 'then run Management High Availability synchronisation.' INFO
Write-CPLog '=======================================================' OK
