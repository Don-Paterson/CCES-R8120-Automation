<#
.SYNOPSIS
    Installs a CPUSE package (e.g. a Jumbo Hotfix Accumulator) on a lab Gaia host by
    driving Clish interactively from A-GUI with Python + paramiko.

.DESCRIPTION
    The non-interactive routes (clish -c / clish -f, exec channels, keystrokes fed blind
    into plink -t) can get CPUSE to say "installing ..." and then do nothing. This runs
    python\cpuse_install.py, which works like a person at the keyboard:

        installer install <Tab>   -> reads the numbered list
        <number> <Enter>          -> on the same, half-typed line
        y                         -> only if CPUSE actually asks

    then stays attached, follows the reboot and confirms the take is installed.

    Python 3.13 and paramiko are installed automatically if missing (same method as the
    CCAS Python Toolkit's Install-PythonOnAGUI.ps1). Credentials come from
    config\lab-settings.psd1 and are passed to Python in an environment variable, never
    on the command line.

.PARAMETER Target
    A-SMS, A-EPM, A-EPM-02, or an IP address.

.PARAMETER Match
    Regular expression for the package's display name in the numbered list.
    Default 'Jumbo Hotfix Accumulator Take <ExpectedTake>'.

.PARAMETER ExpectedTake
    Jumbo take number used to confirm success.

.PARAMETER ListOnly
    Show the numbered list and which entry would be installed, then stop.

.EXAMPLE
    .\Invoke-CPUSEInstall.ps1 -Target A-SMS -ExpectedTake 170 -ListOnly

.EXAMPLE
    .\Invoke-CPUSEInstall.ps1 -Target A-EPM -ExpectedTake 170
#>
[CmdletBinding()]
param(
    [string]$Target = 'A-EPM',
    [int]$ExpectedTake = 170,
    [string]$Match,
    [switch]$ListOnly,
    [int]$TimeoutMin = 90,
    [string]$SettingsPath,
    [string]$PythonVersion = '3.13.1'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Split-Path -Parent $PSScriptRoot
if (-not $SettingsPath) { $SettingsPath = Join-Path $root 'config\lab-settings.psd1' }
$cfg = Import-PowerShellDataFile -LiteralPath $SettingsPath

function Say([string]$t, [string]$c = 'Cyan') { Write-Host ("{0:HH:mm:ss}  {1}" -f (Get-Date), $t) -ForegroundColor $c }

# ------------------------------------------------------------------ target --
$ip = switch ($Target) {
    'A-SMS'    { if ($cfg.ContainsKey('ASmsIp')) { $cfg.ASmsIp } else { '10.1.1.101' } }
    'A-EPM'    { $cfg.AEpmIp }
    'A-EPM-02' { $cfg.AEpm02Ip }
    default    { $Target }
}
if (-not $Match) { $Match = "Jumbo Hotfix Accumulator Take $ExpectedTake\b" }

# ------------------------------------------------------------------ python --
function Test-PythonOK {
    try {
        $v = & py -3 --version 2>$null
        if ($LASTEXITCODE -eq 0 -and $v -match 'Python (\d+)\.(\d+)') {
            return ([int]$Matches[1] -gt 3 -or ([int]$Matches[1] -eq 3 -and [int]$Matches[2] -ge 11))
        }
    } catch { }
    return $false
}

if (-not (Test-PythonOK)) {
    Say "Python not found - installing Python $PythonVersion (amd64), about a minute..."
    $exe = Join-Path $env:TEMP "python-$PythonVersion-amd64.exe"
    Invoke-WebRequest -Uri "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-amd64.exe" -OutFile $exe -UseBasicParsing
    Start-Process -FilePath $exe -Wait -NoNewWindow -ArgumentList @(
        '/quiet', 'InstallAllUsers=1', 'PrependPath=1', 'Include_pip=1', 'Include_test=0', 'Include_launcher=1')
    Remove-Item $exe -Force -ErrorAction SilentlyContinue
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not (Test-PythonOK)) { throw "Python install finished but 'py -3' is still not usable." }
}
Say "Python: $(& py -3 --version)" 'Gray'

& py -3 -c "import paramiko" 2>$null
if ($LASTEXITCODE -ne 0) {
    Say 'Installing paramiko...'
    & py -3 -m pip install --disable-pip-version-check -q 'paramiko==3.5.1'
    if ($LASTEXITCODE -ne 0) { throw 'pip could not install paramiko.' }
}
Say "paramiko: $(& py -3 -c 'import paramiko; print(paramiko.__version__)')" 'Gray'

# --------------------------------------------------------------------- run --
if (-not (Test-Path -LiteralPath $cfg.LogPath)) { New-Item -ItemType Directory -Path $cfg.LogPath -Force | Out-Null }
$log = Join-Path $cfg.LogPath ('CPUSE_{0}_{1:yyyyMMdd-HHmmss}.log' -f $Target, (Get-Date))
$py = Join-Path $root 'python\cpuse_install.py'

$pyArgs = @('-3', '-u', $py, '--host', $ip, '--user', $cfg.GaiaUser, '--match', $Match,
            '--take', $ExpectedTake, '--timeout-min', $TimeoutMin, '--log', $log)
if ($ListOnly) { $pyArgs += '--list-only' }

Say "Target $Target ($ip), package /$Match/, log $log"
$env:CP_GAIA_PASSWORD = $cfg.GaiaPassword
$env:PYTHONIOENCODING = 'utf-8'
try {
    & py @pyArgs
    $code = $LASTEXITCODE
} finally {
    Remove-Item Env:CP_GAIA_PASSWORD -ErrorAction SilentlyContinue
}
$msg = @{ 0 = 'Finished OK.'; 2 = 'Could not connect or bad arguments.'; 3 = 'Package not found in the numbered list - nothing installed.'
          4 = 'Timed out waiting for the install.'; 5 = 'CPUSE reported a failure.' }[$code]
Say "$msg (exit $code)" $(if ($code -eq 0) { 'Green' } else { 'Red' })
exit $code
