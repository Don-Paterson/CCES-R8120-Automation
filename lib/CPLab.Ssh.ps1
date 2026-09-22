<#
.SYNOPSIS
    Shared SSH / SCP transport helpers for the CCES R81.20 lab automation scripts.

.DESCRIPTION
    Dot-source this file from a script running on A-GUI:

        . "$PSScriptRoot\..\lib\CPLab.Ssh.ps1"

    It provides a small transport layer that can talk to a Gaia host over SSH using
    whichever tooling happens to exist on the jump host:

        1. PuTTY  plink.exe / pscp.exe   (preferred - no module install, fastest SCP)
        2. Posh-SSH PowerShell module    (pure PowerShell, needs PSGallery or a staged copy)

    Gaia specifics handled here:
      * The 'admin' user normally lands in Gaia Clish, so an SSH exec channel runs
        Clish commands, not shell commands.
      * Switching admin's shell to /bin/bash (Clish: set user admin shell /bin/bash)
        gives non-interactive Expert-equivalent access (admin is UID 0 on Gaia) and
        also makes SCP work. Restore-CPClishShell puts it back.

    No Set-StrictMode on purpose - it breaks some of the .NET interop below.
#>

$script:CPLogFile = $null

function Start-CPLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $script:CPLogFile = $Path
    Add-Content -LiteralPath $Path -Value ("`r`n===== {0} =====" -f (Get-Date)) -Encoding UTF8
}

function Write-CPLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message,
        [Parameter(Position = 1)][ValidateSet('INFO', 'STEP', 'OK', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $colour = switch ($Level) { 'STEP' { 'Cyan' } 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Gray' } }
    $line = '[{0}] {1,-5} {2}' -f (Get-Date).ToString('HH:mm:ss'), $Level, $Message
    Write-Host $line -ForegroundColor $colour
    if ($script:CPLogFile) { Add-Content -LiteralPath $script:CPLogFile -Value $line -Encoding UTF8 }
}

function Test-CPTcpPort {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [int]$Port = 22,
        [int]$TimeoutMs = 3000
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch { return $false } finally { $client.Close() }
}

function Wait-CPSsh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [int]$TimeoutSec = 900,
        [int]$PollSec = 10,
        [string]$Activity = 'Waiting for SSH'
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    Write-CPLog "$Activity on $HostName (timeout ${TimeoutSec}s)..." STEP
    while ((Get-Date) -lt $deadline) {
        if (Test-CPTcpPort -HostName $HostName -Port 22) {
            Write-CPLog "$HostName is answering on tcp/22." OK
            return $true
        }
        Start-Sleep -Seconds $PollSec
    }
    Write-CPLog "$HostName did not answer on tcp/22 within ${TimeoutSec}s." ERROR
    return $false
}

function Wait-CPReboot {
    <# Waits for the host to drop off the network and come back. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [int]$DownTimeoutSec = 300,
        [int]$UpTimeoutSec = 1800
    )
    Write-CPLog "Waiting for $HostName to go down for reboot..." STEP
    $deadline = (Get-Date).AddSeconds($DownTimeoutSec)
    $wentDown = $false
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-CPTcpPort -HostName $HostName -Port 22 -TimeoutMs 2000)) { $wentDown = $true; break }
        Start-Sleep -Seconds 5
    }
    if ($wentDown) { Write-CPLog "$HostName went down - waiting for it to come back." INFO }
    else { Write-CPLog "$HostName never went down; assuming no reboot was needed." WARN }
    Start-Sleep -Seconds 10
    return (Wait-CPSsh -HostName $HostName -TimeoutSec $UpTimeoutSec -Activity 'Waiting for host to come back')
}

#region transport ------------------------------------------------------------

function Get-CPTransport {
    <#
    .SYNOPSIS  Works out how we can drive SSH from this Windows box.
    .OUTPUTS   PSCustomObject: Name (Plink|PoshSSH), Plink, Pscp
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Auto', 'Plink', 'PoshSSH')][string]$Prefer = 'Auto',
        [switch]$AllowInstall
    )

    $plinkPath = $null; $pscpPath = $null
    $candidates = @(
        (Get-Command plink.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
        'C:\Program Files\PuTTY\plink.exe',
        'C:\Program Files (x86)\PuTTY\plink.exe',
        "$env:USERPROFILE\Desktop\Check Point Tools\plink.exe",
        "$PSScriptRoot\plink.exe"
    ) | Where-Object { $_ }
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { $plinkPath = $c; break } }
    if ($plinkPath) {
        $maybe = Join-Path (Split-Path -Parent $plinkPath) 'pscp.exe'
        if (Test-Path -LiteralPath $maybe) { $pscpPath = $maybe }
        else { $pscpPath = (Get-Command pscp.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source) }
    }

    $posh = Get-Module -ListAvailable -Name Posh-SSH | Select-Object -First 1

    if ($Prefer -eq 'Plink' -and -not $plinkPath) { throw 'plink.exe was requested but is not present on this machine.' }
    if ($Prefer -eq 'PoshSSH' -and -not $posh -and -not $AllowInstall) { throw 'Posh-SSH was requested but is not installed.' }

    if (($Prefer -in 'Auto', 'Plink') -and $plinkPath) {
        Write-CPLog "Transport: PuTTY plink ($plinkPath)" INFO
        return [pscustomobject]@{ Name = 'Plink'; Plink = $plinkPath; Pscp = $pscpPath }
    }

    if (-not $posh -and $AllowInstall) {
        Write-CPLog 'Posh-SSH not found - attempting install from PSGallery (needs internet).' WARN
        try {
            if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
                Install-PackageProvider -Name NuGet -Force -Scope CurrentUser -ErrorAction Stop | Out-Null
            }
            Install-Module -Name Posh-SSH -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            $posh = Get-Module -ListAvailable -Name Posh-SSH | Select-Object -First 1
        } catch { Write-CPLog "Posh-SSH install failed: $($_.Exception.Message)" ERROR }
    }

    if ($posh) {
        Import-Module Posh-SSH -ErrorAction Stop
        Write-CPLog "Transport: Posh-SSH $($posh.Version)" INFO
        return [pscustomobject]@{ Name = 'PoshSSH'; Plink = $null; Pscp = $null }
    }

    throw @'
No usable SSH transport found on this machine.
Install one of the following on A-GUI and re-run:
  * PuTTY (plink.exe + pscp.exe) - offline friendly, put them anywhere on %PATH%
  * Posh-SSH module              - Install-Module Posh-SSH -Scope CurrentUser
'@
}

function Connect-CPHost {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [string]$UserName = 'admin',
        [Parameter(Mandatory)][string]$Password,
        [Parameter(Mandatory)][object]$Transport,
        [int]$ConnectTimeoutSec = 60
    )

    if (-not (Wait-CPSsh -HostName $HostName -TimeoutSec $ConnectTimeoutSec -Activity 'Connecting')) {
        throw "Cannot reach $HostName on tcp/22."
    }

    $session = [pscustomobject]@{
        HostName  = $HostName
        UserName  = $UserName
        Password  = $Password
        Transport = $Transport
        SessionId = $null
        Shell     = 'unknown'
    }

    if ($Transport.Name -eq 'Plink') {
        # Cache the host key so later -batch calls do not stall on the "store key?" prompt.
        $null = cmd.exe /c "echo y | `"$($Transport.Plink)`" -ssh -pw `"$Password`" $UserName@$HostName exit" 2>&1
    } else {
        $sec = ConvertTo-SecureString $Password -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential ($UserName, $sec)
        $s = New-SSHSession -ComputerName $HostName -Credential $cred -AcceptKey -ConnectionTimeout $ConnectTimeoutSec -ErrorAction Stop
        $session.SessionId = $s.SessionId
    }

    $session.Shell = Get-CPShellMode -Session $session
    Write-CPLog "Connected to $HostName as $UserName (shell: $($session.Shell))." OK
    return $session
}

function Disconnect-CPHost {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Session)
    if ($Session.Transport.Name -eq 'PoshSSH' -and $null -ne $Session.SessionId) {
        Remove-SSHSession -SessionId $Session.SessionId -ErrorAction SilentlyContinue | Out-Null
    }
}

function Invoke-CPCommand {
    <#
    .SYNOPSIS  Runs one command over the SSH exec channel exactly as given.
    .OUTPUTS   PSCustomObject: Output (string), ExitStatus (int), Success (bool)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][string]$Command,
        [int]$TimeoutSec = 300,
        [switch]$Quiet
    )

    if (-not $Quiet) { Write-CPLog "ssh $($Session.HostName): $Command" INFO }

    if ($Session.Transport.Name -eq 'Plink') {
        $pargs = @('-ssh', '-batch', '-pw', $Session.Password, "$($Session.UserName)@$($Session.HostName)", $Command)
        $out = & $Session.Transport.Plink @pargs 2>&1 | Out-String
        $code = $LASTEXITCODE
    } else {
        $r = Invoke-SSHCommand -SessionId $Session.SessionId -Command $Command -TimeOut $TimeoutSec -ErrorAction Stop
        $out = ($r.Output -join "`n")
        if ($r.Error) { $out = $out + "`n" + ($r.Error -join "`n") }
        $code = $r.ExitStatus
    }

    $result = [pscustomobject]@{
        Output     = ($out -replace "`r", '').Trim()
        ExitStatus = $code
        Success    = ($code -eq 0)
    }
    if (-not $Quiet -and $result.Output) {
        foreach ($l in ($result.Output -split "`n")) { if ($l.Trim()) { Write-CPLog "    $l" INFO } }
    }
    return $result
}

#endregion transport ---------------------------------------------------------
#region gaia shell handling --------------------------------------------------

function Get-CPShellMode {
    <# Returns 'bash' when the SSH exec channel lands in a real shell, otherwise 'clish'. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Session)
    $r = Invoke-CPCommand -Session $Session -Command 'id -u' -TimeoutSec 30 -Quiet
    if ($r.Output -match '(?m)^\s*0\s*$') { return 'bash' }
    if ($r.Output -match '(?m)^\s*\d+\s*$') { return 'bash' }
    return 'clish'
}

function Enable-CPBashShell {
    <#
    .SYNOPSIS
        Switches the admin user's shell to /bin/bash so the SSH exec channel gives
        non-interactive root access (admin is UID 0 on Gaia) and SCP works.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Session)

    if ($Session.Shell -eq 'bash') { return $true }

    Write-CPLog "Switching $($Session.UserName) shell to /bin/bash on $($Session.HostName)..." STEP
    $null = Invoke-CPCommand -Session $Session -Command "set user $($Session.UserName) shell /bin/bash" -Quiet
    $null = Invoke-CPCommand -Session $Session -Command 'save config' -Quiet

    Disconnect-CPHost -Session $Session
    Start-Sleep -Seconds 3
    $fresh = Connect-CPHost -HostName $Session.HostName -UserName $Session.UserName -Password $Session.Password -Transport $Session.Transport
    $Session.SessionId = $fresh.SessionId
    $Session.Shell = $fresh.Shell

    if ($Session.Shell -eq 'bash') { Write-CPLog 'Shell is now /bin/bash.' OK; return $true }
    Write-CPLog 'Could not switch the admin shell to /bin/bash.' ERROR
    return $false
}

function Restore-CPClishShell {
    <# Puts the admin shell back to Gaia Clish - run this at the end of a lab build. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Session)
    Write-CPLog "Restoring $($Session.UserName) shell to Gaia Clish on $($Session.HostName)..." STEP
    $null = Invoke-CPBash -Session $Session -Command "clish -s -c `"set user $($Session.UserName) shell /etc/cli.sh`"" -Quiet
    $Session.Shell = 'clish'
}

function Invoke-CPBash {
    <# Runs a shell (Expert-equivalent) command. Switches the shell automatically if needed. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][string]$Command,
        [int]$TimeoutSec = 600,
        [switch]$Quiet
    )
    if ($Session.Shell -ne 'bash') {
        if (-not (Enable-CPBashShell -Session $Session)) {
            throw "No shell access on $($Session.HostName). See README - 'If the shell switch is refused'."
        }
    }
    return (Invoke-CPCommand -Session $Session -Command $Command -TimeoutSec $TimeoutSec -Quiet:$Quiet)
}

function Invoke-CPClish {
    <# Runs a Gaia Clish command whichever shell mode we are in. -Save adds 'save config'. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][string]$Command,
        [int]$TimeoutSec = 600,
        [switch]$Save,
        [switch]$Quiet
    )
    if ($Session.Shell -eq 'bash') {
        $saveFlag = if ($Save) { '-s ' } else { '' }
        $escaped = $Command -replace '"', '\"'
        return (Invoke-CPCommand -Session $Session -Command ("clish {0}-c `"{1}`"" -f $saveFlag, $escaped) -TimeoutSec $TimeoutSec -Quiet:$Quiet)
    }
    $r = Invoke-CPCommand -Session $Session -Command $Command -TimeoutSec $TimeoutSec -Quiet:$Quiet
    if ($Save) { $null = Invoke-CPCommand -Session $Session -Command 'save config' -Quiet }
    return $r
}

function Invoke-CPShellScript {
    <#
    .SYNOPSIS
        Fallback for interactive prompts (for example 'set expert-password', or entering
        Expert mode by hand). Feeds a list of lines to an interactive SSH shell and
        returns the whole transcript. Output parsing is best-effort - prefer Invoke-CPBash.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][string[]]$Lines,
        [int]$SettleMs = 1500
    )

    if ($Session.Transport.Name -eq 'Plink') {
        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            Set-Content -LiteralPath $tmp -Value (($Lines + 'exit') -join "`n") -Encoding ASCII -NoNewline:$false
            $pargs = @('-ssh', '-batch', '-pw', $Session.Password, "$($Session.UserName)@$($Session.HostName)")
            return (Get-Content -LiteralPath $tmp -Raw | & $Session.Transport.Plink @pargs 2>&1 | Out-String)
        } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }

    $stream = New-SSHShellStream -SessionId $Session.SessionId -TerminalName 'vt100' -Columns 200 -Rows 50 -Width 1000 -Height 500
    Start-Sleep -Milliseconds $SettleMs
    $transcript = $stream.Read()
    foreach ($line in $Lines) {
        $stream.WriteLine($line)
        Start-Sleep -Milliseconds $SettleMs
        $transcript += $stream.Read()
    }
    $stream.WriteLine('exit')
    Start-Sleep -Milliseconds $SettleMs
    $transcript += $stream.Read()
    $stream.Dispose()
    return $transcript
}

function Set-CPExpertPassword {
    <#
    .SYNOPSIS
        Sets the Expert password. Uses the non-interactive hash form when a hash is
        supplied, otherwise falls back to the interactive 'set expert-password' prompts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Session,
        [string]$PasswordHash,
        [string]$PlainPassword
    )

    if ($PasswordHash) {
        Write-CPLog 'Setting Expert password from hash...' STEP
        $r = Invoke-CPClish -Session $Session -Command "set expert-password-hash $PasswordHash" -Save -Quiet
        if ($r.Output -notmatch 'Invalid|Failed|error') { Write-CPLog 'Expert password set from hash.' OK; return $true }
        Write-CPLog "set expert-password-hash was not accepted: $($r.Output)" WARN
    }

    if ($PlainPassword) {
        Write-CPLog 'Setting Expert password interactively...' STEP
        $t = Invoke-CPShellScript -Session $Session -Lines @('set expert-password', $PlainPassword, $PlainPassword, 'save config')
        if ($t -match 'Expert password|saved|OK') { Write-CPLog 'Expert password set.' OK; return $true }
        Write-CPLog 'Could not confirm the Expert password was set.' WARN
    }
    return $false
}

#endregion gaia shell handling -----------------------------------------------
#region file transfer --------------------------------------------------------

function New-CPRemoteTextFile {
    <#
    .SYNOPSIS
        Creates a text file on the Gaia host without needing SCP, by base64-piping it
        over the exec channel. LF line endings are forced. Good for answer files.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][string]$RemotePath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )
    $lf = ($Content -replace "`r`n", "`n")
    $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($lf))
    Write-CPLog "Writing $RemotePath on $($Session.HostName) ($($lf.Length) bytes)..." STEP
    $cmd = "mkdir -p `$(dirname $RemotePath); echo '$b64' | base64 -d > $RemotePath && chmod 600 $RemotePath && wc -c $RemotePath"
    $r = Invoke-CPBash -Session $Session -Command $cmd -Quiet
    if (-not $r.Success) { throw "Failed to write ${RemotePath}: $($r.Output)" }
    Write-CPLog "Wrote $RemotePath." OK
    return $true
}

function Copy-CPFileToHost {
    <# Copies a local file to a remote directory. Uses pscp when available, else Posh-SSH SCP. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][string]$LocalPath,
        [string]$RemoteDir = '/var/log',
        [switch]$SkipIfSameSize
    )

    if (-not (Test-Path -LiteralPath $LocalPath)) { throw "Local file not found: $LocalPath" }
    $name = Split-Path -Leaf $LocalPath
    $size = (Get-Item -LiteralPath $LocalPath).Length
    $remote = "$RemoteDir/$name"

    if ($Session.Shell -ne 'bash') { $null = Enable-CPBashShell -Session $Session }

    if ($SkipIfSameSize) {
        $chk = Invoke-CPBash -Session $Session -Command "stat -c %s $remote 2>/dev/null || echo 0" -Quiet
        if (($chk.Output -replace '\D', '') -eq "$size") {
            Write-CPLog "$name already present on $($Session.HostName) with the same size - skipping copy." OK
            return $remote
        }
    }

    Write-CPLog ("Copying {0} ({1:N0} MB) to {2}:{3} ..." -f $name, ($size / 1MB), $Session.HostName, $RemoteDir) STEP
    $sw = [Diagnostics.Stopwatch]::StartNew()

    if ($Session.Transport.Name -eq 'Plink' -and $Session.Transport.Pscp) {
        $pargs = @('-batch', '-scp', '-pw', $Session.Password, $LocalPath, "$($Session.UserName)@$($Session.HostName):$RemoteDir/")
        & $Session.Transport.Pscp @pargs
        if ($LASTEXITCODE -ne 0) { throw "pscp failed with exit code $LASTEXITCODE" }
    } else {
        if ($Session.Transport.Name -eq 'Plink') {
            Write-CPLog 'pscp.exe not found - falling back to Posh-SSH for this copy.' WARN
            Import-Module Posh-SSH -ErrorAction Stop
        }
        $sec = ConvertTo-SecureString $Session.Password -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential ($Session.UserName, $sec)
        Set-SCPItem -ComputerName $Session.HostName -Credential $cred -Path $LocalPath -Destination $RemoteDir -AcceptKey -Force -ErrorAction Stop
    }

    $sw.Stop()
    $chk = Invoke-CPBash -Session $Session -Command "stat -c %s $remote" -Quiet
    $got = ($chk.Output -replace '\D', '')
    if ($got -ne "$size") { throw "Copy of $name looks wrong: local $size bytes, remote '$got' bytes." }
    Write-CPLog ("Copied {0} in {1:N0}s." -f $name, $sw.Elapsed.TotalSeconds) OK
    return $remote
}

#endregion file transfer -----------------------------------------------------
#region check point operations -----------------------------------------------

function Test-CPFtwDone {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Session)
    $r = Invoke-CPBash -Session $Session -Command 'test -f /etc/.wizard_accepted && echo FTW_DONE || echo FTW_PENDING' -Quiet
    return ($r.Output -match 'FTW_DONE')
}

function Invoke-CPFtw {
    <#
    .SYNOPSIS
        Runs the Gaia First Time Configuration Wizard from an answer file.
    .DESCRIPTION
        Writes the answer file to the host, validates it with --dry-run, then runs it.
        config_system must run in Expert mode / a real shell - Invoke-CPBash takes care
        of that. The host reboots afterwards when reboot_if_required=true.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][string]$AnswerFileContent,
        [string]$RemotePath = '/home/admin/ftw.sh',
        [switch]$DryRunOnly
    )

    if (Test-CPFtwDone -Session $Session) {
        Write-CPLog "$($Session.HostName) has already completed the First Time Wizard - skipping." WARN
        return 'AlreadyDone'
    }

    $null = New-CPRemoteTextFile -Session $Session -RemotePath $RemotePath -Content $AnswerFileContent

    Write-CPLog 'Validating the answer file (config_system --dry-run)...' STEP
    $dry = Invoke-CPBash -Session $Session -Command "config_system -f $RemotePath --dry-run" -TimeoutSec 300
    if ($dry.Output -match 'ERROR|Invalid|not a valid|failed') {
        throw "config_system --dry-run rejected the answer file:`n$($dry.Output)"
    }
    Write-CPLog 'Answer file validated.' OK
    if ($DryRunOnly) { return 'DryRunOnly' }

    Write-CPLog 'Running the First Time Wizard - this takes several minutes and will reboot the host.' STEP
    # Detached so the SSH drop at reboot does not kill it, output kept for troubleshooting.
    $cmd = "nohup config_system -f $RemotePath > /var/log/cces_ftw.log 2>&1 &"
    $null = Invoke-CPBash -Session $Session -Command $cmd -TimeoutSec 60 -Quiet
    return 'Started'
}

function Wait-CPManagementReady {
    <# Polls until the management processes (CPM / FWM) are up, after FTW or a reboot. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Session,
        [int]$TimeoutSec = 1800,
        [int]$PollSec = 30
    )
    Write-CPLog "Waiting for management services on $($Session.HostName) (up to $([int]($TimeoutSec/60)) min)..." STEP
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-CPBash -Session $Session -Command 'cpwd_admin list 2>/dev/null | egrep "CPM|FWM|CPD" || echo NOT_READY' -TimeoutSec 120 -Quiet
            $lines = $r.Output -split "`n" | Where-Object { $_ -match '^\s*(CPM|FWM|CPD)\b' }
            $running = $lines | Where-Object { $_ -match '\bE\b' }
            if ($lines.Count -gt 0 -and $running.Count -ge $lines.Count) {
                Write-CPLog "Management services are up ($($lines.Count) watchdog entries in state E)." OK
                return $true
            }
            Write-CPLog "Not ready yet ($($running.Count)/$($lines.Count) processes up)..." INFO
        } catch {
            Write-CPLog "Poll failed ($($_.Exception.Message)) - reconnecting..." WARN
            try {
                Disconnect-CPHost -Session $Session
                $fresh = Connect-CPHost -HostName $Session.HostName -UserName $Session.UserName -Password $Session.Password -Transport $Session.Transport
                $Session.SessionId = $fresh.SessionId; $Session.Shell = $fresh.Shell
            } catch { }
        }
        Start-Sleep -Seconds $PollSec
    }
    Write-CPLog 'Timed out waiting for management services.' ERROR
    return $false
}

function Install-CPLicense {
    <# Installs a local .lic file with cplic put, with a per-line fallback. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][string]$LocalLicensePath
    )
    $remote = Copy-CPFileToHost -Session $Session -LocalPath $LocalLicensePath -RemoteDir '/var/log'
    Write-CPLog 'Installing the licence (cplic put -l)...' STEP
    $r = Invoke-CPBash -Session $Session -Command "cplic put -l $remote" -TimeoutSec 300

    if ($r.Output -match 'Usage|failed|Failed|error occurred') {
        Write-CPLog 'cplic put -l did not work - trying line by line.' WARN
        foreach ($line in (Get-Content -LiteralPath $LocalLicensePath)) {
            $t = $line.Trim()
            if (-not $t -or $t.StartsWith('#')) { continue }
            $t = $t -replace '^cplic\s+(put|putlic)\s+', ''
            $null = Invoke-CPBash -Session $Session -Command "cplic put $t" -TimeoutSec 300
        }
    }

    $check = Invoke-CPBash -Session $Session -Command 'cplic print -x' -TimeoutSec 120
    if ($check.Output -match '(?i)no licenses|0 licenses') {
        Write-CPLog 'No licences are showing after the install - check the .lic file matches this IP.' ERROR
        return $false
    }
    Write-CPLog 'Licence installed.' OK
    return $true
}

function Install-CPServiceContract {
    <# Installs a ServiceContract.xml with cplic contract put -o. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][string]$LocalContractPath
    )
    $remote = Copy-CPFileToHost -Session $Session -LocalPath $LocalContractPath -RemoteDir '/var/log'
    Write-CPLog 'Installing the service contract (cplic contract put -o)...' STEP
    $r = Invoke-CPBash -Session $Session -Command "cplic contract put -o $remote" -TimeoutSec 300
    if ($r.Output -match '(?i)error|failed|usage') {
        Write-CPLog 'The service contract did not install cleanly - install it by hand in SmartConsole if CPUSE complains.' WARN
        return $false
    }
    $null = Invoke-CPBash -Session $Session -Command 'contract_util print 2>/dev/null | head -20 || true' -TimeoutSec 120
    Write-CPLog 'Service contract installed.' OK
    return $true
}

function Get-CPDaBuild {
    <# Returns the installed CPUSE Deployment Agent build number, or 0 if it cannot be read. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Session)
    $r = Invoke-CPClish -Session $Session -Command 'show installer status build' -TimeoutSec 180 -Quiet
    if ($r.Output -match '(\d{3,})') { return [int]$Matches[1] }
    return 0
}

function Install-CPDeploymentAgent {
    <#
    .SYNOPSIS
        Installs / upgrades the CPUSE Deployment Agent from a local DeploymentAgent_*.tgz.
    .PARAMETER TryOnlineFirst
        Attempt 'installer agent update' (needs internet + a valid contract) before
        falling back to the bundled package.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][string]$LocalAgentPath,
        [switch]$TryOnlineFirst
    )

    $current = Get-CPDaBuild -Session $Session
    $wanted = 0
    if ((Split-Path -Leaf $LocalAgentPath) -match 'DeploymentAgent[_-]0*(\d+)') { $wanted = [int]$Matches[1] }
    Write-CPLog "Deployment Agent: installed build $current, bundled package build $wanted." INFO

    if ($current -gt 0 -and $wanted -gt 0 -and $current -ge $wanted) {
        Write-CPLog 'The installed Deployment Agent is already the same or newer - nothing to do.' OK
        return $true
    }

    if ($TryOnlineFirst) {
        Write-CPLog 'Trying an online Deployment Agent self-update first...' STEP
        $u = Invoke-CPClish -Session $Session -Command 'installer agent update not-interactive' -TimeoutSec 900
        Start-Sleep -Seconds 20
        $after = Get-CPDaBuild -Session $Session
        if ($after -gt $current) { Write-CPLog "Deployment Agent updated online to build $after." OK; return $true }
        Write-CPLog 'Online update did not change the build - using the bundled package.' WARN
    }

    $remote = Copy-CPFileToHost -Session $Session -LocalPath $LocalAgentPath -RemoteDir '/var/log' -SkipIfSameSize
    Write-CPLog 'Installing the Deployment Agent package...' STEP
    $r = Invoke-CPBash -Session $Session -Command "printf 'y\ny\n' | clish -c `"installer agent install $remote`"" -TimeoutSec 1800
    Start-Sleep -Seconds 30
    $after = Get-CPDaBuild -Session $Session
    if ($wanted -gt 0 -and $after -lt $wanted) {
        Write-CPLog "Expected build $wanted but the agent reports $after - check /var/log/CPda for details." WARN
        return $false
    }
    Write-CPLog "Deployment Agent build is now $after." OK
    return $true
}

function Install-CPUSEPackage {
    <#
    .SYNOPSIS
        Imports and installs a CPUSE package (for example a Jumbo Hotfix Accumulator tar).
    .DESCRIPTION
        installer import local -> show installer packages imported -> installer verify ->
        installer install (detached, so the reboot at the end does not kill the session).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][string]$RemotePackagePath,
        [string]$MatchPattern = 'JUMBO',
        [int]$InstallTimeoutMin = 90,
        [switch]$SkipVerify
    )

    Write-CPLog "Importing $RemotePackagePath into CPUSE (can take a few minutes)..." STEP
    $imp = Invoke-CPClish -Session $Session -Command "installer import local $RemotePackagePath not-interactive" -TimeoutSec 3600
    if ($imp.Output -match '(?i)failed|error') { Write-CPLog "Import reported a problem - continuing to check the package list." WARN }

    $list = Invoke-CPClish -Session $Session -Command 'show installer packages imported' -TimeoutSec 300
    $id = $null
    foreach ($line in ($list.Output -split "`n")) {
        if ($line -match "^\s*(\d+)\s+.*$MatchPattern" -or ($line -match "$MatchPattern" -and $line -match '^\s*(\d+)\s')) {
            $id = $Matches[1]; break
        }
    }
    if (-not $id) { throw "Could not find an imported package matching '$MatchPattern'. Package list was:`n$($list.Output)" }
    Write-CPLog "Imported package id is $id." OK

    if (-not $SkipVerify) {
        Write-CPLog 'Verifying the package against this machine...' STEP
        $v = Invoke-CPClish -Session $Session -Command "installer verify $id not-interactive" -TimeoutSec 1800
        if ($v.Output -match '(?i)cannot be installed|verification failed') {
            throw "CPUSE verification failed:`n$($v.Output)"
        }
        if ($v.Output -match '(?i)contract|licen') { Write-CPLog 'Note: CPUSE mentioned licence/contract in the verify output - read the lines above.' WARN }
    }

    Write-CPLog "Installing package $id - allow up to $InstallTimeoutMin minutes; the host will reboot." STEP
    $log = '/var/log/cces_cpuse_install.log'
    $null = Invoke-CPBash -Session $Session -Command "nohup clish -c `"installer install $id not-interactive`" > $log 2>&1 &" -TimeoutSec 120 -Quiet

    $deadline = (Get-Date).AddMinutes($InstallTimeoutMin)
    $sawReboot = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 60
        try {
            $s = Invoke-CPBash -Session $Session -Command "tail -n 3 $log 2>/dev/null; clish -c 'show installer status all' 2>/dev/null | head -20" -TimeoutSec 180 -Quiet
            foreach ($l in ($s.Output -split "`n")) { if ($l.Trim()) { Write-CPLog "    $l" INFO } }
            if ($s.Output -match '(?i)installed successfully|installation finished|Operation completed') { Write-CPLog 'CPUSE reports the installation finished.' OK; break }
            if ($s.Output -match '(?i)failed') { Write-CPLog 'CPUSE reported a failure - see the log above and /var/log/CPda.' ERROR; break }
        } catch {
            Write-CPLog 'Lost the connection - the host is most likely rebooting after the install.' WARN
            $sawReboot = $true
            $null = Wait-CPReboot -HostName $Session.HostName -DownTimeoutSec 600 -UpTimeoutSec 2400
            try {
                Disconnect-CPHost -Session $Session
                $fresh = Connect-CPHost -HostName $Session.HostName -UserName $Session.UserName -Password $Session.Password -Transport $Session.Transport
                $Session.SessionId = $fresh.SessionId; $Session.Shell = $fresh.Shell
            } catch { }
            break
        }
    }

    if (-not $sawReboot) {
        Write-CPLog 'Waiting for the post-install reboot (if the package asks for one)...' STEP
        $null = Wait-CPReboot -HostName $Session.HostName -DownTimeoutSec 420 -UpTimeoutSec 2400
        try {
            Disconnect-CPHost -Session $Session
            $fresh = Connect-CPHost -HostName $Session.HostName -UserName $Session.UserName -Password $Session.Password -Transport $Session.Transport
            $Session.SessionId = $fresh.SessionId; $Session.Shell = $fresh.Shell
        } catch { }
    }
    return $true
}

function Get-CPInstalledTake {
    <# Reports the Jumbo Hotfix take currently installed. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Session)
    $r = Invoke-CPBash -Session $Session -Command "cpinfo -y all 2>/dev/null | egrep -i 'JUMBO|Take' | head -20" -TimeoutSec 300
    return $r.Output
}

#endregion check point operations --------------------------------------------
#region fallbacks ------------------------------------------------------------

function Enable-CPBashShellViaExpert {
    <#
    .SYNOPSIS
        Last-resort route to a shell when Clish refuses "set user admin shell".
    .DESCRIPTION
        Opens an interactive SSH shell, enters Expert mode with the Expert password,
        and points the admin account at /bin/bash in /etc/passwd. Used only before the
        First Time Wizard has run, where Clish is heavily restricted. After the wizard
        the proper Clish command is used again.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][string]$ExpertPassword
    )
    Write-CPLog 'Clish refused the shell change - trying via Expert mode.' WARN
    $lines = @(
        'expert',
        $ExpertPassword,
        "sed -i '/^$($Session.UserName):/ s|:/etc/cli.sh\$|:/bin/bash|' /etc/passwd",
        "grep '^$($Session.UserName):' /etc/passwd"
    )
    $t = Invoke-CPShellScript -Session $Session -Lines $lines
    if ($t -notmatch '/bin/bash') {
        Write-CPLog 'Could not switch the shell through Expert mode either.' ERROR
        Write-CPLog 'Transcript follows:' INFO
        Write-CPLog $t INFO
        return $false
    }
    Disconnect-CPHost -Session $Session
    Start-Sleep -Seconds 3
    $fresh = Connect-CPHost -HostName $Session.HostName -UserName $Session.UserName -Password $Session.Password -Transport $Session.Transport
    $Session.SessionId = $fresh.SessionId
    $Session.Shell = $fresh.Shell
    if ($Session.Shell -eq 'bash') { Write-CPLog 'Shell access established through Expert mode.' OK; return $true }
    return $false
}

function Initialize-CPShellAccess {
    <# Gets us to a usable shell on a Gaia host, trying Clish first then Expert. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Session,
        [string]$ExpertPassword,
        [string]$ExpertPasswordHash
    )
    if ($Session.Shell -eq 'bash') { return $true }
    if ($ExpertPasswordHash -or $ExpertPassword) {
        $null = Set-CPExpertPassword -Session $Session -PasswordHash $ExpertPasswordHash -PlainPassword $ExpertPassword
    }
    if (Enable-CPBashShell -Session $Session) { return $true }
    if ($ExpertPassword) { return (Enable-CPBashShellViaExpert -Session $Session -ExpertPassword $ExpertPassword) }
    return $false
}

#endregion fallbacks ---------------------------------------------------------
#region ftw progress ---------------------------------------------------------

function Wait-CPFtwComplete {
    <#
    .SYNOPSIS
        Waits for config_system to finish, however long it takes.
    .DESCRIPTION
        A management First Time Wizard can run well past a fixed timeout before it reboots,
        so this watches the actual work rather than the clock:

          * host unreachable        -> the wizard has triggered the reboot; wait for it back
          * config_system running   -> still working, keep waiting and report elapsed time
          * gone, /etc/.wizard_accepted present -> finished without needing a reboot
          * gone, no marker         -> it died; the caller gets $false and the log tail

        Reconnects the session in place on the way out, so the caller can carry straight on.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Session,
        [int]$TimeoutMin = 75,
        [int]$PollSec = 30,
        [int]$BackUpTimeoutSec = 2400
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    $started = Get-Date
    Write-CPLog "Watching the wizard on $($Session.HostName) - up to $TimeoutMin minutes, reboot included." STEP

    while ((Get-Date) -lt $deadline) {
        $mins = [int]((Get-Date) - $started).TotalMinutes

        if (-not (Test-CPTcpPort -HostName $Session.HostName -Port 22 -TimeoutMs 4000)) {
            Write-CPLog "Host went down after ${mins}m - the wizard is rebooting it." OK
            if (-not (Wait-CPSsh -HostName $Session.HostName -TimeoutSec $BackUpTimeoutSec -Activity 'Waiting for the host to come back')) {
                Write-CPLog 'The host did not come back.' ERROR
                return $false
            }
            Start-Sleep -Seconds 20
            try {
                Disconnect-CPHost -Session $Session
                $fresh = Connect-CPHost -HostName $Session.HostName -UserName $Session.UserName -Password $Session.Password -Transport $Session.Transport
                $Session.SessionId = $fresh.SessionId
                $Session.Shell = $fresh.Shell
            } catch {
                Write-CPLog "Reconnect after reboot failed: $($_.Exception.Message)" WARN
            }
            return $true
        }

        try {
            $probe = Invoke-CPBash -Session $Session -TimeoutSec 90 -Quiet -Command @'
pgrep -f "config_system -f" >/dev/null 2>&1 && echo WIZARD_RUNNING || echo WIZARD_GONE
test -f /etc/.wizard_accepted && echo MARKER_PRESENT || echo MARKER_ABSENT
'@
            $running = $probe.Output -match 'WIZARD_RUNNING'
            $marker  = $probe.Output -match 'MARKER_PRESENT'

            if ($running) {
                Write-CPLog "Wizard still running (${mins}m elapsed)..." INFO
            } elseif ($marker) {
                Write-CPLog "Wizard finished after ${mins}m without needing a reboot." OK
                return $true
            } else {
                Write-CPLog "config_system is no longer running and the wizard marker is absent - it failed." ERROR
                $log = Invoke-CPBash -Session $Session -Command 'tail -n 30 /var/log/cces_ftw.log 2>/dev/null' -TimeoutSec 120
                return $false
            }
        } catch {
            # A dropped session usually means the reboot has just started; the next loop catches it.
            Write-CPLog "Probe failed (${mins}m) - most likely the reboot starting. Retrying..." INFO
            try {
                Disconnect-CPHost -Session $Session
                $fresh = Connect-CPHost -HostName $Session.HostName -UserName $Session.UserName -Password $Session.Password -Transport $Session.Transport
                $Session.SessionId = $fresh.SessionId
                $Session.Shell = $fresh.Shell
            } catch { }
        }

        Start-Sleep -Seconds $PollSec
    }

    Write-CPLog "Gave up after $TimeoutMin minutes. The wizard may still be running - check with: pgrep -f config_system" ERROR
    return $false
}

#endregion ftw progress ------------------------------------------------------
