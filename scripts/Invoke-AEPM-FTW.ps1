<#
.SYNOPSIS
    Builds A-EPM in the CCES R81.20 lab: First Time Wizard, licence, service contract
    and CPUSE Deployment Agent. Run it on A-GUI.

.DESCRIPTION
    Stage 1 of the lab build. It:
      1. Connects to A-EPM (10.1.1.103) over SSH as admin.
      2. Sets the Expert password and gets shell access.
      3. Runs the First Time Wizard from config\A-EPM_ftw.sh (validated with --dry-run
         first), then waits for the reboot and for the management processes to start.
      4. Installs Licenses\A-EPM.lic and Licenses\ServiceContract.xml.
         CPUSE will not install a Jumbo without these - the 15 day evaluation is not enough.
      5. Installs the CPUSE Deployment Agent, unless the one on the box is already
         the same build or newer.

    It is safe to re-run: a machine that has already completed the wizard is detected
    and skipped, and the licence / contract / agent steps are idempotent.

    Afterwards, do the manual SmartConsole work (enable Endpoint Policy Management and
    SmartEvent, configure NAT), then run Install-JumboT26.ps1.

.PARAMETER GaiaPassword
    Gaia admin password from the lab credentials sheet. Defaults to the value in
    config\lab-settings.psd1.

.PARAMETER DryRun
    Validate the answer file with config_system --dry-run and stop.

.PARAMETER ApplyClishConfig
    Also apply config\A-EPM_config.sh after the wizard. Read that file first - it sets
    the admin password hash and a GRUB password.

.EXAMPLE
    .\Invoke-AEPM-FTW.ps1

.EXAMPLE
    .\Invoke-AEPM-FTW.ps1 -GaiaPassword 'Chkp!234' -Verbose

.EXAMPLE
    .\Invoke-AEPM-FTW.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$SettingsPath,
    [string]$TargetIp,
    [string]$GaiaUser,
    [string]$GaiaPassword,
    [string]$ToolsPath,
    [ValidateSet('Auto', 'Plink', 'PoshSSH')][string]$Transport = 'Auto',
    [switch]$DryRun,
    [switch]$SkipLicense,
    [switch]$SkipContract,
    [switch]$SkipDeploymentAgent,
    [switch]$TryOnlineAgentUpdate,
    [switch]$ApplyClishConfig,
    [switch]$KeepBashShell
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\CPLab.Ssh.ps1')

# ---------------------------------------------------------------- settings --
if (-not $SettingsPath) { $SettingsPath = Join-Path $root 'config\lab-settings.psd1' }
$cfg = Import-PowerShellDataFile -LiteralPath $SettingsPath
if (-not $TargetIp)     { $TargetIp = $cfg.AEpmIp }
if (-not $GaiaUser)     { $GaiaUser = $cfg.GaiaUser }
if (-not $GaiaPassword) { $GaiaPassword = $cfg.GaiaPassword }
if (-not $ToolsPath)    { $ToolsPath = $cfg.ToolsPath }

Start-CPLog (Join-Path $cfg.LogPath ('A-EPM-FTW_{0:yyyyMMdd-HHmmss}.log' -f (Get-Date)))
Write-CPLog "CCES R81.20 - building $($cfg.AEpmName) at $TargetIp" STEP

$ftwFile      = Join-Path $root 'config\A-EPM_ftw.sh'
$clishFile    = Join-Path $root 'config\A-EPM_config.sh'
$licPath      = Join-Path $ToolsPath $cfg.LicenseFile
$contractPath = Join-Path $ToolsPath $cfg.ContractFile
$agentPath    = Join-Path $ToolsPath $cfg.DeploymentAgent

if (-not (Test-Path -LiteralPath $ftwFile)) { throw "Answer file not found: $ftwFile" }
foreach ($p in @(@{P = $licPath; S = $SkipLicense }, @{P = $contractPath; S = $SkipContract }, @{P = $agentPath; S = $SkipDeploymentAgent })) {
    if (-not $p.S -and -not (Test-Path -LiteralPath $p.P)) { Write-CPLog "Missing file: $($p.P)" WARN }
}

# ------------------------------------------------------------------ connect --
$xport = Get-CPTransport -Prefer $Transport -AllowInstall
$session = Connect-CPHost -HostName $TargetIp -UserName $GaiaUser -Password $GaiaPassword -Transport $xport

try {
    $alreadyBuilt = $false
    if (-not (Initialize-CPShellAccess -Session $session -ExpertPassword $cfg.ExpertPassword -ExpertPasswordHash $cfg.ExpertPasswordHash)) {
        throw 'Could not get shell access on the target. See the README troubleshooting section.'
    }

    if (Test-CPFtwDone -Session $session) {
        Write-CPLog 'The First Time Wizard has already been run on this machine.' WARN
        $alreadyBuilt = $true
    }

    # ---------------------------------------------------------------- wizard --
    if (-not $alreadyBuilt) {
        $answer = Get-Content -LiteralPath $ftwFile -Raw
        Write-CPLog "Using answer file $ftwFile" INFO

        $state = Invoke-CPFtw -Session $session -AnswerFileContent $answer -RemotePath '/home/admin/A-EPM_ftw.sh' -DryRunOnly:$DryRun
        if ($DryRun) {
            Write-CPLog 'Dry run finished - the answer file is valid. Re-run without -DryRun to build.' OK
            return
        }

        Write-CPLog 'The wizard is running. Watching for the reboot...' INFO
        Start-Sleep -Seconds 60
        $null = Wait-CPReboot -HostName $TargetIp -DownTimeoutSec 900 -UpTimeoutSec 2400

        Disconnect-CPHost -Session $session
        Start-Sleep -Seconds 20
        $session = Connect-CPHost -HostName $TargetIp -UserName $GaiaUser -Password $GaiaPassword -Transport $xport
        if (-not (Initialize-CPShellAccess -Session $session -ExpertPassword $cfg.ExpertPassword -ExpertPasswordHash $cfg.ExpertPasswordHash)) {
            throw 'Lost shell access after the reboot.'
        }

        if (-not (Test-CPFtwDone -Session $session)) {
            $log = Invoke-CPBash -Session $session -Command 'tail -n 40 /var/log/cces_ftw.log 2>/dev/null' -TimeoutSec 120
            throw "The First Time Wizard does not look finished. Last of /var/log/cces_ftw.log:`n$($log.Output)"
        }
        Write-CPLog 'First Time Wizard completed.' OK

        if (-not (Wait-CPManagementReady -Session $session -TimeoutSec 2400)) {
            Write-CPLog 'Management processes did not all come up - continuing anyway, but check cpwd_admin list.' WARN
        }
    }

    # ------------------------------------------------------- licence/contract --
    if (-not $SkipLicense -and (Test-Path -LiteralPath $licPath)) {
        $null = Install-CPLicense -Session $session -LocalLicensePath $licPath
    } else { Write-CPLog 'Skipping the licence step.' WARN }

    if (-not $SkipContract -and (Test-Path -LiteralPath $contractPath)) {
        $null = Install-CPServiceContract -Session $session -LocalContractPath $contractPath
    } else { Write-CPLog 'Skipping the service contract step - apply it by hand if CPUSE complains.' WARN }

    # ------------------------------------------------------- deployment agent --
    if (-not $SkipDeploymentAgent -and (Test-Path -LiteralPath $agentPath)) {
        $null = Install-CPDeploymentAgent -Session $session -LocalAgentPath $agentPath -TryOnlineFirst:$TryOnlineAgentUpdate
    } else { Write-CPLog 'Skipping the Deployment Agent step.' WARN }

    # ---------------------------------------------------------- clish config --
    if ($ApplyClishConfig -and (Test-Path -LiteralPath $clishFile)) {
        Write-CPLog 'Applying config\A-EPM_config.sh (this also sets the admin and GRUB passwords).' WARN
        $null = New-CPRemoteTextFile -Session $session -RemotePath '/home/admin/A-EPM_config.sh' -Content (Get-Content -LiteralPath $clishFile -Raw)
        $r = Invoke-CPBash -Session $session -Command 'clish -s -f /home/admin/A-EPM_config.sh' -TimeoutSec 600
        Write-CPLog 'Clish configuration applied (any per-line errors are listed above).' OK
    }

    # ----------------------------------------------------------------- tidy up --
    if (-not $KeepBashShell -and $cfg.RestoreClishShell) { Restore-CPClishShell -Session $session }

    Write-CPLog '' INFO
    Write-CPLog '================ A-EPM is ready for the manual steps ================' OK
    Write-CPLog "1. SmartConsole to $TargetIp as $($cfg.MgmtAdminUser)" INFO
    Write-CPLog '2. Enable Endpoint Policy Management and SmartEvent on the management object' INFO
    Write-CPLog '3. Configure NAT as per the lab guide, then install the policy' INFO
    Write-CPLog '4. Run:  .\Install-JumboT26.ps1' INFO
    Write-CPLog '=====================================================================' OK
} finally {
    if ($session) { Disconnect-CPHost -Session $session }
}
