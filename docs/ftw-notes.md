# First Time Wizard behaviour — what the automation has to allow for

## Management servers do not reboot

A Security Management / Endpoint Security Management Server completes
`config_system` and stays up. Observed on A-EPM (R81.20): the wizard ran for about
15 minutes and never rebooted, then CPM sat in "during initialization" for several
more minutes with the API stopped.

So for a management server the meaningful signals are, in order:

1. `pgrep -f "config_system -f"` — still working
2. `/etc/.wizard_accepted` — the wizard finished
3. `api status` — refuses outright before the wizard, then reports CPM `Starting` /
   "during initialization" until the server is genuinely usable
4. `API readiness test SUCCESSFUL` — actually ready for SmartConsole

`cpwd_admin list` showing CPM/FWM/CPD in state `E` is **not** sufficient — the
watchdog reports the processes started well before the management server is usable.

`Wait-CPFtwComplete` and `Wait-CPManagementReady` in `lib\CPLab.Ssh.ps1` implement
exactly this sequence.

## Security Gateways DO reboot - and blink is where that bites

A Security Gateway reboots after its First Time Wizard; a management server does not.
That reboot on its own is expected and harmless.

**The premature-reboot problem belongs to blink, not to FTW or `config_system`.** In a
blink (image-based) automated deployment the reboot fires about 60 seconds after the
wizard hands back, which can cut across configuration the blink procedure has not
finished applying - leaving a gateway that looks deployed and is not. `config_system`
itself does not do this to you; it is the blink procedure's own post-wizard timing.

The fix belongs in the blink answer file, not in the calling script. In the CCAS
R81.20 labs:

```xml
<reboot_delay>300</reboot_delay>
```

in `answers.xml` (see `ClaudeCowork\CCAS-R8120-automation\Full-Automation\Lab-1B\answers.xml`),
giving the blink deployment time to complete before the reboot takes the box away.

**If this repo ever grows a gateway build**, it needs a reboot wait rather than the
management-server flow above - and if that build is driven by blink, it needs the
delay raised the same way.

## Related work

`github.com/Don-Paterson/CCAS-LabRunner` covers the CCAS R81.20 labs with the same
shape — `irm | iex` bootstrap, `plink -m` transport to the Gaia hosts, a menu with
paced and auto modes, completion state and per-run logs under
`%USERPROFILE%\.ccas-labrunner\`. Worth reading before extending this repo, and worth
mirroring for consistency if this one grows beyond a single build sequence.
