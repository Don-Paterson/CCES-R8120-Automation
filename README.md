# CCES-R8120-Automation

PowerShell automation for the **Check Point Certified Endpoint Specialist (CCES) R81.20** lab,
run from **A-GUI**. It builds the Endpoint Security Management Servers end to end:

| Stage | Script | What it does |
|---|---|---|
| 0 | `scripts\Test-LabPrereqs.ps1` | Read-only pre-flight: transport, files, hosts |
| 1 | `scripts\Invoke-AEPM-FTW.ps1` | A-EPM First Time Wizard, licence, service contract, CPUSE Deployment Agent |
| — | *manual* | SmartConsole: enable Endpoint Policy Management + SmartEvent, configure NAT, install policy |
| 2 | `scripts\Install-JumboT26.ps1` | R81.20 Jumbo Hotfix Accumulator **Take 26** via CPUSE |
| 3 | `scripts\Invoke-AEPM02-FTW.ps1` | A-EPM-02 secondary management server (Lab 6B), agent, optionally the Jumbo |

## Lab topology (Site Alpha)

```
A-MGMT-NET 10.1.1.0/24, default gateway 10.1.1.1 (A-GW eth0)
  A-GUI      10.1.1.201   <- you run these scripts here
  A-SMS      10.1.1.101
  A-EPM      10.1.1.103   Endpoint Security Management (primary)
  A-EPM-02   10.1.1.104   Endpoint Security Management (secondary)
A-INT-NET  192.168.11.0/24
  A-LDAP     192.168.11.101 (also the DNS server used in the answer files)
```

## Requirements on A-GUI

* PowerShell 5.1 (what ships with the lab image) and an execution policy that allows scripts:
  `powershell -ExecutionPolicy Bypass -File .\scripts\Test-LabPrereqs.ps1`
* An SSH transport, either of:
  * **PuTTY** `plink.exe` + `pscp.exe` anywhere on `%PATH%`, in `C:\Program Files\PuTTY`,
    or dropped next to `lib\`. Preferred — no module install and much faster for the 2 GB Jumbo.
  * **Posh-SSH** module — `Install-Module Posh-SSH -Scope CurrentUser` (needs PSGallery access).
    The scripts try to install it automatically if no plink is found.
* `C:\Users\Admin\Desktop\Check Point Tools` containing:
  * `Licenses\A-EPM.lic`, `Licenses\A-EPM-02.lic`, `Licenses\ServiceContract.xml`
  * `DeploymentAgent_000002337_1.tgz`
  * `Check_Point_R81_20_JUMBO_HF_MAIN_Bundle_T26_FULL.tar`

Paths, IPs and passwords all live in **`config\lab-settings.psd1`** — edit that, not the scripts.

## Order of operations

```powershell
cd <repo>
.\scripts\Test-LabPrereqs.ps1

# Stage 1 - validate the answer file first if you like
.\scripts\Invoke-AEPM-FTW.ps1 -DryRun
.\scripts\Invoke-AEPM-FTW.ps1

# --- manual, in SmartConsole against A-EPM ---
#   * enable Endpoint Policy Management and SmartEvent on the management object
#   * configure NAT per the lab guide, install policy
# ---------------------------------------------

# Stage 2
.\scripts\Install-JumboT26.ps1

# Stage 3 (optional) - create the Secondary Security Management Server object in
# SmartConsole first, with a one-time password, then:
.\scripts\Invoke-AEPM02-FTW.ps1 -SicKey 'Chkp!234' -InstallJumbo
```

Logs go to `C:\CCES-Automation-Logs` (change `LogPath` in the settings file).

## Why the licence step matters

CPUSE will not install a Jumbo Hotfix unless the machine has a **valid licence with an active
Software Subscription / support contract, plus the contract file**. The 15-day evaluation
licence is not enough. `Invoke-AEPM-FTW.ps1` therefore runs, in this order:

```
cplic put -l /var/log/A-EPM.lic
cplic contract put -o /var/log/ServiceContract.xml
```

If either is refused, the script says so and carries on — install them by hand and re-run with
`-SkipLicense -SkipContract` as appropriate. **A-EPM-02 does not need this**: a secondary
management server takes the Jumbo without a licence, which is why `Invoke-AEPM02-FTW.ps1`
passes `-SkipLicenseCheck` when it chains into the Jumbo install.

## How the scripts talk to Gaia

Gaia's `admin` user normally lands in **Clish**, so an SSH exec channel runs Clish commands,
not shell commands — and `scp` does not work at all. `config_system`, `cplic` and friends need
a real shell. The helper library therefore:

1. sets the Expert password non-interactively with `set expert-password-hash`;
2. runs Clish `set user admin shell /bin/bash` + `save config`, which gives non-interactive
   root access (`admin` is UID 0 on Gaia) and makes SCP work;
3. falls back to an interactive Expert-mode session if Clish refuses that before the wizard;
4. puts the shell back to `/etc/cli.sh` at the end, unless you pass `-KeepBashShell`
   or set `RestoreClishShell = $false`.

Answer files are pushed with base64 over the exec channel rather than SCP, so the wizard can
run before SCP is available.

## Repository layout

```
config\
  lab-settings.psd1     all IPs, credentials, file names and paths
  A-EPM_ftw.sh          First Time Wizard answer file, primary management  (as supplied)
  A-EPM-02_ftw.sh       First Time Wizard answer file, secondary management
  A-EPM_config.sh       post-wizard Clish settings (as supplied; the 'sset' typo is fixed)
  A-EPM-build.txt       original manual build notes
lib\
  CPLab.Ssh.ps1         transport, Gaia shell handling, licence / CPUSE helpers
scripts\
  Test-LabPrereqs.ps1
  Invoke-AEPM-FTW.ps1
  Install-JumboT26.ps1
  Invoke-AEPM02-FTW.ps1
docs\
  manual-steps.md       the SmartConsole work the scripts deliberately leave to you
```

## Re-running

Everything is written to be safe to re-run. A machine that has already completed the wizard is
detected (`/etc/.wizard_accepted`) and skipped; file copies are skipped when the remote size
matches; the Deployment Agent is skipped when the installed build is the same or newer; the
Jumbo step stops if Take 26 is already on the box.

## Troubleshooting

| Symptom | What to do |
|---|---|
| `No usable SSH transport found` | Install PuTTY on A-GUI, or `Install-Module Posh-SSH -Scope CurrentUser` |
| `Could not get shell access on the target` | The lab password is wrong, or Clish is refusing the shell change. Set the Expert password by hand (`set expert-password`), then re-run |
| `config_system --dry-run rejected the answer file` | Read the message — R81.20 builds sometimes want `maintenance_hash`; there is a commented line for it in `A-EPM-02_ftw.sh` |
| CPUSE verify mentions contract / licence | The licence or `ServiceContract.xml` did not take. Check `cplic print -x` and `contract_util print` on the box |
| Jumbo copy is slow | Install `pscp.exe` (PuTTY) — the Posh-SSH fallback is noticeably slower for 2 GB |
| Not enough room in `/var/log` | Remove old imported packages: Clish `installer clean`, or delete stale `/var/log/*.tar` |

## Notes

* The wizard answer files set `reboot_if_required="true"`, so the hosts reboot themselves;
  the scripts wait for them to drop and come back.
* `config\A-EPM_config.sh` is **not** applied by default — it sets the admin password hash and
  a GRUB password. Pass `-ApplyClishConfig` to `Invoke-AEPM-FTW.ps1` if you want it.
* Credentials in `lab-settings.psd1` are lab credentials only. Don't put anything real in there.
