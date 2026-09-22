<#
.SYNOPSIS
    Checks that A-GUI has everything the CCES R81.20 automation needs. Read-only.

.DESCRIPTION
    Run this first. It reports on:
      * PowerShell version and execution policy
      * an SSH transport (plink/pscp or Posh-SSH)
      * the files in the Check Point Tools folder
      * whether A-EPM and A-EPM-02 answer on tcp/22, and whether they have been built

.EXAMPLE
    .\Test-LabPrereqs.ps1
#>
[CmdletBinding()]
param(
    [string]$SettingsPath,
    [string]$GaiaPassword,
    [switch]$SkipHostChecks
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\CPLab.Ssh.ps1')

if (-not $SettingsPath) { $SettingsPath = Join-Path $root 'config\lab-settings.psd1' }
$cfg = Import-PowerShellDataFile -LiteralPath $SettingsPath
if (-not $GaiaPassword) { $GaiaPassword = $cfg.GaiaPassword }

$ok = $true
function Report { param($Name, $Pass, $Detail)
    if ($Pass) { Write-CPLog "$Name - $Detail" OK } else { Write-CPLog "$Name - $Detail" ERROR; $script:ok = $false }
}

Write-CPLog '--- A-GUI ---' STEP
Report 'PowerShell' ($PSVersionTable.PSVersion.Major -ge 5) "version $($PSVersionTable.PSVersion)"
Report 'Execution policy' $true ((Get-ExecutionPolicy -Scope Process).ToString() + ' (process scope)')

try {
    $t = Get-CPTransport -Prefer Auto
    Report 'SSH transport' $true $t.Name
    if ($t.Name -eq 'Plink' -and -not $t.Pscp) { Write-CPLog 'pscp.exe not found - the 2 GB Jumbo copy will fall back to Posh-SSH.' WARN }
} catch {
    Report 'SSH transport' $false $_.Exception.Message
}

Write-CPLog '--- files ---' STEP
$files = @(
    @{ N = 'Answer file A-EPM';     P = (Join-Path $root 'config\A-EPM_ftw.sh') }
    @{ N = 'Answer file A-EPM-02';  P = (Join-Path $root 'config\A-EPM-02_ftw.sh') }
    @{ N = 'Licence A-EPM';         P = (Join-Path $cfg.ToolsPath $cfg.LicenseFile) }
    @{ N = 'Service contract';      P = (Join-Path $cfg.ToolsPath $cfg.ContractFile) }
    @{ N = 'Deployment Agent';      P = (Join-Path $cfg.ToolsPath $cfg.DeploymentAgent) }
    @{ N = 'Jumbo Take 26';         P = (Join-Path $cfg.ToolsPath $cfg.JumboBundle) }
)
foreach ($f in $files) {
    if (Test-Path -LiteralPath $f.P) {
        $mb = [math]::Round((Get-Item -LiteralPath $f.P).Length / 1MB, 1)
        Report $f.N $true ("{0} ({1} MB)" -f $f.P, $mb)
    } else { Report $f.N $false "not found: $($f.P)" }
}

if (-not $SkipHostChecks) {
    Write-CPLog '--- hosts ---' STEP
    foreach ($h in @(@{ N = $cfg.AEpmName; I = $cfg.AEpmIp }, @{ N = $cfg.AEpm02Name; I = $cfg.AEpm02Ip })) {
        if (Test-CPTcpPort -HostName $h.I -Port 22) {
            Report $h.N $true "$($h.I) answering on tcp/22"
            try {
                $t = Get-CPTransport -Prefer Auto
                $s = Connect-CPHost -HostName $h.I -UserName $cfg.GaiaUser -Password $GaiaPassword -Transport $t
                $mode = $s.Shell
                $ftw = 'unknown'
                if ($mode -eq 'bash') {
                    $r = Invoke-CPCommand -Session $s -Command 'test -f /etc/.wizard_accepted && echo DONE || echo PENDING' -Quiet
                    $ftw = ($r.Output -replace '\s', '')
                } else {
                    $r = Invoke-CPCommand -Session $s -Command 'show version all' -Quiet
                    if ($r.Output -match 'R81') { $ftw = 'clish reachable (wizard state unknown until shell access)' }
                }
                Write-CPLog "    login OK, shell=$mode, wizard=$ftw" INFO
                Disconnect-CPHost -Session $s
            } catch { Write-CPLog "    SSH login failed: $($_.Exception.Message)" WARN }
        } else {
            Write-CPLog "$($h.N) - $($h.I) is not answering on tcp/22 (VM powered off?)" WARN
        }
    }
}

Write-CPLog '' INFO
if ($ok) { Write-CPLog 'Pre-flight checks passed.' OK } else { Write-CPLog 'Some checks failed - see above.' ERROR }
