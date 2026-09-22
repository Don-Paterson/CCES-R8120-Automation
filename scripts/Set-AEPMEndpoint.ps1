<#
.SYNOPSIS
    Does Lab 2A Task 2A-2 - the SmartConsole work - through the management API.
    Run it on A-GUI, after Invoke-AEPM-FTW.ps1 and before Install-JumboT26.ps1.

.DESCRIPTION
    Replaces pages 165 to 174 of the CCES R81.20 lab guide:

      * enables Endpoint Policy Management, SmartEvent and Logging & Status on the
        A-EPM management object
      * sets static NAT (translate to 203.0.113.103, automatic rules, install on All)
      * publishes the session
      * installs the database - A-EPM is a management host, not a gateway, so there is
        no access policy to install

    Everything runs in one mgmt_cli session on the box, as root via 'mgmt_cli -r true',
    so no SmartConsole administrator credentials are needed anywhere.

    Safe to re-run: setting a blade that is already on is a no-op, and the publish
    simply has nothing to commit.

.PARAMETER SkipNat
    Leave the NAT settings alone and only touch the blades.

.EXAMPLE
    .\Set-AEPMEndpoint.ps1

.EXAMPLE
    .\Set-AEPMEndpoint.ps1 -NatIpv4 203.0.113.103 -Verbose
#>
[CmdletBinding()]
param(
    [string]$SettingsPath,
    [string]$TargetIp,
    [string]$GaiaUser,
    [string]$GaiaPassword,
    [string]$ObjectName,
    [string]$NatIpv4,
    [ValidateSet('Auto', 'Plink', 'PoshSSH')][string]$Transport = 'Auto',
    [int]$ApiWaitMin = 40,
    [switch]$SkipNat,
    [switch]$KeepBashShell
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\CPLab.Ssh.ps1')

if (-not $SettingsPath) { $SettingsPath = Join-Path $root 'config\lab-settings.psd1' }
$cfg = Import-PowerShellDataFile -LiteralPath $SettingsPath
# Never read $cfg.<key> directly - a settings file written before a key existed simply
# does not have it, and an empty object name reaches the API as "object [] not found".
if (-not $TargetIp)     { $TargetIp     = Get-CPSetting $cfg 'AEpmIp'         '10.1.1.103' }
if (-not $GaiaUser)     { $GaiaUser     = Get-CPSetting $cfg 'GaiaUser'       'admin' }
if (-not $GaiaPassword) { $GaiaPassword = Get-CPSetting $cfg 'GaiaPassword'   'Chkp!234' }
if (-not $ObjectName)   { $ObjectName   = Get-CPSetting $cfg 'AEpmObjectName' 'A-EPM' }
if (-not $NatIpv4)      { $NatIpv4      = Get-CPSetting $cfg 'AEpmNatIp'      '203.0.113.103' }

$bladeEndpoint    = [bool](Get-CPSetting $cfg 'EnableEndpointPolicy'        $true)
$bladeSeServer    = [bool](Get-CPSetting $cfg 'EnableSmartEventServer'      $false)
$bladeSeCorrelate = [bool](Get-CPSetting $cfg 'EnableSmartEventCorrelation' $true)
$bladeLogging     = [bool](Get-CPSetting $cfg 'EnableLoggingAndStatus'      $true)

if (-not $cfg.ContainsKey('AEpmObjectName')) {
    Write-CPLog 'Your lab-settings.psd1 predates the Task 2A-2 settings - using built-in defaults.' WARN
    Write-CPLog 'Delete it and re-run the bootstrap to pick up the current template.' WARN
}

Start-CPLog (Join-Path (Get-CPSetting $cfg 'LogPath' 'C:\CCES-Automation-Logs') ('A-EPM-Endpoint_{0:yyyyMMdd-HHmmss}.log' -f (Get-Date)))
Write-CPLog "CCES R81.20 - configuring the $ObjectName management object (Task 2A-2)" STEP

$xport = Get-CPTransport -Prefer $Transport -AllowInstall
$session = Connect-CPHost -HostName $TargetIp -UserName $GaiaUser -Password $GaiaPassword -Transport $xport

try {
    if (-not (Initialize-CPShellAccess -Session $session -ExpertPassword $cfg.ExpertPassword -ExpertPasswordHash $cfg.ExpertPasswordHash)) {
        throw 'Could not get shell access on the target.'
    }

    if (-not (Test-CPFtwDone -Session $session)) {
        throw 'The First Time Wizard has not been run on this machine. Run Invoke-AEPM-FTW.ps1 first.'
    }

    # mgmt_cli needs the management API up, not merely the processes started.
    if (-not (Wait-CPManagementReady -Session $session -TimeoutSec ($ApiWaitMin * 60))) {
        throw "The management API did not come up within $ApiWaitMin minutes - mgmt_cli would fail. Check 'api status' on the host."
    }

    $ok = Set-CPEndpointManagement -Session $session `
            -ObjectName $ObjectName `
            -NatIpv4 $NatIpv4 `
            -EndpointPolicy        $bladeEndpoint `
            -SmartEventServer      $bladeSeServer `
            -SmartEventCorrelation $bladeSeCorrelate `
            -LoggingAndStatus      $bladeLogging `
            -SkipNat:$SkipNat

    if (-not $ok) { throw 'The management object was not configured. See the output above.' }

    if (-not $KeepBashShell -and $cfg.RestoreClishShell) { Restore-CPClishShell -Session $session }

    Write-CPLog '' INFO
    Write-CPLog '=========== A-EPM is configured - no SmartConsole needed ===========' OK
    Write-CPLog 'Endpoint Policy Management, SmartEvent and NAT are set, published and' INFO
    Write-CPLog 'the database is installed. Next: install Jumbo Take 26 (Task 2A-3).' INFO
    Write-CPLog '====================================================================' OK
} finally {
    if ($session) { Disconnect-CPHost -Session $session }
}
