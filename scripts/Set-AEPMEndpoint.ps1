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
if (-not $TargetIp)     { $TargetIp = $cfg.AEpmIp }
if (-not $GaiaUser)     { $GaiaUser = $cfg.GaiaUser }
if (-not $GaiaPassword) { $GaiaPassword = $cfg.GaiaPassword }
if (-not $ObjectName)   { $ObjectName = $cfg.AEpmObjectName }
if (-not $NatIpv4)      { $NatIpv4 = $cfg.AEpmNatIp }

Start-CPLog (Join-Path $cfg.LogPath ('A-EPM-Endpoint_{0:yyyyMMdd-HHmmss}.log' -f (Get-Date)))
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
            -EndpointPolicy        ([bool]$cfg.EnableEndpointPolicy) `
            -SmartEventServer      ([bool]$cfg.EnableSmartEventServer) `
            -SmartEventCorrelation ([bool]$cfg.EnableSmartEventCorrelation) `
            -LoggingAndStatus      ([bool]$cfg.EnableLoggingAndStatus) `
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
