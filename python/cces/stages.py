"""The lab build stages - same order and behaviour as the PowerShell scripts they replace.

  prereqs          Test-LabPrereqs.ps1       read-only pre-flight
  ftw [--dry-run]  Invoke-AEPM-FTW.ps1       A-EPM wizard, licence, contract, CPUSE agent   (Task 2A-1)
  endpoint         Set-AEPMEndpoint.ps1      Endpoint + SmartEvent + NAT, install database  (Task 2A-2)
  jumbo            Install-JumboT26.ps1      Jumbo via CPUSE - Take and source from settings (Task 2A-3)
  full             ftw + endpoint + jumbo, no SmartConsole
  secondary        Invoke-AEPM02-FTW.ps1     A-EPM-02 secondary management (Lab 6B)
"""
import os
import re
import sys
import time

from . import cpuse, log, ops
from .gaia import Gaia, port_open


def connect(s, host):
    return Gaia(host, s.GaiaUser, s.GaiaPassword, s.get("ExpertPassword"), s.get("ExpertPasswordHash")).connect()


def target_ip(s, target):
    return {"A-EPM": s.AEpmIp, "A-EPM-02": s.AEpm02Ip, "A-SMS": s.ASmsIp}.get(target, target)


def finish(g, s, keep_bash):
    if not keep_bash and s.RestoreClishShell and g.shell == "bash":
        g.restore_clish()


def tool(s, key):
    return os.path.join(s.ToolsPath, s[key])


def deployment_agent(s):
    """The newest DeploymentAgent_<build>_*.tgz in the Check Point Tools folder (e.g. 2806 beats
    2337), or the one named in the settings if none can be listed. CPUSE refuses Jumbo work
    until the agent is current, so an old name left in the settings must not win."""
    best, best_build = tool(s, "DeploymentAgent"), -1
    m = re.search(r"DeploymentAgent[_-]0*(\d+)", os.path.basename(best))
    if m and os.path.isfile(best):
        best_build = int(m.group(1))
    try:
        for n in os.listdir(s.ToolsPath):
            m = re.match(r"(?i)DeploymentAgent[_-]0*(\d+).*\.tgz$", n)
            if m and int(m.group(1)) > best_build:
                best, best_build = os.path.join(s.ToolsPath, n), int(m.group(1))
    except OSError:
        pass
    return best


def find_bundle(s, take):
    """A Jumbo bundle for `take` in the Check Point Tools folder, whatever its exact name:
    Check_Point_R81_20_jumbo_hf_main_Bundle_T170_FULL.tar / .tgz, JUMBO_HF_MAIN_..._T170... etc.
    JumboBundle from the settings wins if it names this take and exists."""
    named = tool(s, "JumboBundle")
    if re.search(rf"(?i)_T{take}[._]", os.path.basename(named)) and os.path.isfile(named):
        return named
    try:
        names = os.listdir(s.ToolsPath)
    except OSError:
        return None
    hits = sorted(n for n in names if re.search(rf"(?i)jumbo.*_T{take}[._].*\.(tar|tgz)$", n))
    return os.path.join(s.ToolsPath, hits[0]) if hits else None


def jumbo_route(s, take, source):
    """('local', path) or ('cloud', None) for Auto/Local/Cloud."""
    source = (source or "auto").lower()
    path = find_bundle(s, take)
    if source == "cloud":
        return "cloud", None
    if source == "local":
        if not path:
            raise FileNotFoundError(f"No Jumbo Take {take} bundle in {s.ToolsPath} (JumboSource = Local).")
        return "local", path
    return ("local", path) if path else ("cloud", None)


# ---------------------------------------------------------------- prereqs --
def prereqs(s, **_):
    ok = True

    def report(name, passed, detail):
        nonlocal ok
        (log.ok if passed else log.error)(f"{name} - {detail}")
        ok = ok and passed

    import paramiko
    log.step("--- A-GUI ---")
    report("Python", sys.version_info >= (3, 11), sys.version.split()[0])
    report("paramiko", True, paramiko.__version__)
    log.step("--- files ---")
    files = [("Answer file A-EPM", os.path.join(s._root, "config", "A-EPM_ftw.sh")),
             ("Answer file A-EPM-02", os.path.join(s._root, "config", "A-EPM-02_ftw.sh")),
             ("Licence A-EPM", tool(s, "LicenseFile")),
             ("Service contract", tool(s, "ContractFile")),
             ("Deployment Agent (newest in Tools)", deployment_agent(s))]

    for name, p in files:
        if os.path.isfile(p):
            report(name, True, f"{p} ({os.path.getsize(p) / 1048576:,.1f} MB)")
        else:
            report(name, False, f"not found: {p}")
    try:
        route, path = jumbo_route(s, int(s.JumboTake), s.JumboSource)
        report(f"Jumbo Take {s.JumboTake}", True,
               f"{s.JumboSource} -> local bundle {path}" if route == "local" else f"{s.JumboSource} -> CPUSE cloud download")
    except FileNotFoundError as e:
        report(f"Jumbo Take {s.JumboTake}", False, str(e))
    log.step("--- hosts ---")
    for name, ip in ((s.AEpmName, s.AEpmIp), (s.AEpm02Name, s.AEpm02Ip)):
        if not port_open(ip, int(os.environ.get('CCES_SSH_PORT', 22))):
            log.warn(f"{name} - {ip} not answering on tcp/22 (VM off?)")
            continue
        try:
            g = connect(s, ip)
            v = g.clish("show version all", 60, quiet=True).output
            ver = (re.search(r"Product version\s+(.+)", v) or [None, "?"])[1]
            take = cpuse.installed_take(g)
            ftw = "DONE" if g.shell == "bash" and ops.ftw_done(g) else ("unknown (clish)" if g.shell != "bash" else "PENDING")
            report(name, True, f"{ip} login OK, shell={g.shell}, {ver}, Jumbo take {take or 'none'}, wizard {ftw}")
            g.close()
        except Exception as e:
            report(name, False, f"{ip} SSH login failed: {e}")
    log.info("")
    (log.ok if ok else log.error)("Pre-flight checks passed." if ok else "Some checks failed - see above.")
    return ok


# ---------------------------------------------------------------- A-EPM ftw --
def ftw(s, dry_run=False, skip_license=False, skip_contract=False, skip_agent=False,
        apply_clish=False, keep_bash=False, **_):
    log.step(f"CCES R81.20 - building {s.AEpmName} at {s.AEpmIp}")
    answer_path = os.path.join(s._root, "config", "A-EPM_ftw.sh")
    answer = open(answer_path, encoding="utf-8").read()
    g = connect(s, s.AEpmIp)
    try:
        if not g.init_shell_access():
            raise RuntimeError("Could not get shell access on the target.")
        if ops.ftw_done(g):
            log.warn("The First Time Wizard has already been run on this machine.")
        else:
            st = ops.run_ftw(g, answer, "/home/admin/A-EPM_ftw.sh", dry_run)
            if dry_run:
                log.ok("Dry run finished - the answer file is valid.")
                return True
            time.sleep(45)
            want = (re.search(r'(?m)^\s*hostname="?([^"\r\n]+)"?', answer) or [None, ""])[1].strip()
            if not ops.wait_ftw_complete(g, 75, want):
                raise RuntimeError("The First Time Wizard did not complete - see /var/log/cces_ftw.log on the host.")
            if not g.init_shell_access():
                raise RuntimeError("Lost shell access after the reboot.")
            if not ops.ftw_done(g):
                log.block(g.bash("tail -n 40 /var/log/cces_ftw.log 2>/dev/null", 120, True).output, "ERROR")
                raise RuntimeError("The First Time Wizard does not look finished.")
            log.ok("First Time Wizard completed.")
            if not ops.wait_management_ready(g):
                log.warn("Management processes did not all come up - continuing; check cpwd_admin list.")
        if not skip_license and os.path.isfile(tool(s, "LicenseFile")):
            ops.install_license(g, tool(s, "LicenseFile"))
        else:
            log.warn("Skipping the licence step.")
        if not skip_contract and os.path.isfile(tool(s, "ContractFile")):
            ops.install_contract(g, tool(s, "ContractFile"))
        else:
            log.warn("Skipping the service contract step.")
        if not skip_agent and os.path.isfile(deployment_agent(s)):
            cpuse.install_deployment_agent(g, deployment_agent(s))
        else:
            log.warn("Skipping the Deployment Agent step.")
        if apply_clish:
            p = os.path.join(s._root, "config", "A-EPM_config.sh")
            log.warn("Applying config/A-EPM_config.sh (this also sets the admin and GRUB passwords).")
            g.write_text("/home/admin/A-EPM_config.sh", open(p, encoding="utf-8").read())
            g.bash("clish -s -f /home/admin/A-EPM_config.sh", 600)
        finish(g, s, keep_bash)
        log.ok(f"{s.AEpmName} is built. Next: Endpoint configuration (Task 2A-2), then the Jumbo.")
        return True
    finally:
        g.close()


# ------------------------------------------------------------- endpoint 2A-2 --
def endpoint(s, skip_nat=False, keep_bash=False, **_):
    log.step(f"CCES R81.20 - configuring the {s.AEpmObjectName} management object (Task 2A-2)")
    g = connect(s, s.AEpmIp)
    try:
        if not g.init_shell_access():
            raise RuntimeError("Could not get shell access on the target.")
        if not ops.ftw_done(g):
            raise RuntimeError("The First Time Wizard has not been run on this machine - run the ftw stage first.")
        if not ops.wait_management_ready(g):
            raise RuntimeError("The management API is not ready.")
        ok = ops.set_endpoint_management(g, s, skip_nat)
        finish(g, s, keep_bash)
        return ok
    finally:
        g.close()


# ------------------------------------------------------------------ jumbo --
def jumbo(s, target="A-EPM", take=None, source=None, skip_license_check=False, keep_bash=False, **_):
    take = int(take or s.JumboTake)
    source, bundle = jumbo_route(s, take, source or s.JumboSource)
    ip = target_ip(s, target)
    log.step(f"Jumbo Take {take} on {target} ({ip}) - " + (f"local bundle {os.path.basename(bundle)}" if bundle else "CPUSE cloud download"))
    g = connect(s, ip)
    try:
        before = cpuse.installed_take(g)
        log.info(f"Jumbo take currently installed: {before or 'none'}")
        if before >= take:
            log.ok(f"Take {before} is already installed - nothing to do.")
            return True
        if not skip_license_check and target == "A-EPM" and g.init_shell_access():
            lic = g.bash("cplic print -x 2>/dev/null", 180, True).output
            if re.search(r"(?i)no licenses|eval", lic):
                log.warn("Only an evaluation licence (or none) - CPUSE may refuse the Jumbo. Run the ftw stage first.")
        # CPUSE refuses every download/verify/install until the agent is current - and cannot
        # be trusted to say so - so enforce the newest bundled build before any CPUSE action.
        if g.init_shell_access():
            cpuse.install_deployment_agent(g, deployment_agent(s))
        if source == "cloud":
            if not cpuse.download(g, take):
                return False
        else:
            if not g.init_shell_access():
                raise RuntimeError("Shell access is needed to copy the bundle.")
            need_mb = os.path.getsize(bundle) * 2 // 1048576      # the bundle plus room to unpack
            df = g.bash("df -kP /var/log | tail -1 | tr -s ' ' | cut -d' ' -f4", 60, True).output
            free_mb = int(df) // 1024 if df.strip().isdigit() else 0
            if free_mb:
                (log.info if free_mb >= need_mb else log.warn)(
                    f"Free space in /var/log: {free_mb:,} MB (need about {need_mb:,} MB)")
            remote = g.put_file(bundle, "/var/log")
            if not cpuse.import_local(g, remote, take):
                return False
        if not cpuse.install(g, take):
            return False
        if g.shell == "bash" or g.init_shell_access():
            ops.wait_management_ready(g)
        finish(g, s, keep_bash)
        return True
    finally:
        g.close()


# ------------------------------------------------------------------ full --
def full(s, **kw):
    log.step("Full A-EPM build: wizard, licence, contract, agent, Endpoint config, Jumbo. Allow up to two hours.")
    t0 = time.time()
    for name, fn in (("ftw", ftw), ("endpoint", endpoint), ("jumbo", jumbo)):
        log.step(f"===== stage: {name} =====")
        if not fn(s, **{k: v for k, v in kw.items() if k != "dry_run"}):
            log.error(f"Full build stopped at '{name}'. Fix the cause and re-run - finished stages are skipped.")
            return False
    log.ok(f"Full build finished in {(time.time() - t0) / 60:.0f} minutes.")
    return True


# ------------------------------------------------------------- secondary --
def secondary(s, dry_run=False, install_license=False, skip_agent=False, install_jumbo=False, keep_bash=False, **kw):
    log.step(f"CCES R81.20 - building {s.AEpm02Name} (secondary management) at {s.AEpm02Ip}")
    log.warn(f"The Secondary Security Management Server object must already exist in SmartConsole on {s.AEpmName}, "
             f"with the one-time password from lab-settings (SicKey).")
    if not port_open(s.AEpmIp):
        log.error(f"Primary {s.AEpmName} ({s.AEpmIp}) is not answering - SIC will fail.")
    answer = open(os.path.join(s._root, "config", "A-EPM-02_ftw.sh"), encoding="utf-8").read()
    answer, n = re.subn(r'(?m)^\s*ftw_sic_key=.*$', f'ftw_sic_key="{s.SicKey}"', answer)
    if not n:
        raise RuntimeError("No ftw_sic_key line in config/A-EPM-02_ftw.sh")
    g = connect(s, s.AEpm02Ip)
    try:
        if not g.init_shell_access():
            raise RuntimeError("Could not get shell access on the target.")
        if ops.ftw_done(g):
            log.warn("The wizard has already been run on A-EPM-02 - skipping to the agent step.")
        else:
            ops.run_ftw(g, answer, "/home/admin/A-EPM-02_ftw.sh", dry_run)
            if dry_run:
                log.ok("Dry run finished - the answer file is valid.")
                return True
            time.sleep(45)
            if not ops.wait_ftw_complete(g, 75, "A-EPM-02"):
                raise RuntimeError("The First Time Wizard did not complete.")
            if not g.init_shell_access() or not ops.ftw_done(g):
                raise RuntimeError("The wizard does not look finished.")
            log.ok("First Time Wizard completed on A-EPM-02.")
            ops.wait_management_ready(g)
            g.bash("cpca_client lscert 2>/dev/null | head -5; cp_conf sic state 2>/dev/null", 180)
        if install_license and os.path.isfile(tool(s, "License02File")):
            ops.install_license(g, tool(s, "License02File"))
        if not skip_agent and os.path.isfile(deployment_agent(s)):
            cpuse.install_deployment_agent(g, deployment_agent(s))
        if not install_jumbo:
            finish(g, s, keep_bash)
    finally:
        g.close()
    if install_jumbo:
        # A secondary management server takes the Jumbo without a licence.
        jumbo(s, target="A-EPM-02", skip_license_check=True, keep_bash=keep_bash)
    log.ok("A-EPM-02 done. In SmartConsole on the primary: check SIC, then synchronise Management HA.")
    return True


# -------------------------------------------------------- package list --
def packages(s, target="A-EPM", **_):
    """Read-only: CPUSE status, installed/downloaded packages, and the numbered install list."""
    g = connect(s, target_ip(s, target))
    try:
        log.block(g.clish("show installer status", 120, quiet=True).output)
        log.block(cpuse.packages(g))
        rows, _ = cpuse.numbered_list(g, "install")
        log.step("installer install <TAB>:")
        for r in rows:
            log.info(f"    {r['num']:>3}  {r['name']}  [{r['type']}]")
        return True
    finally:
        g.close()


STAGES = {"prereqs": prereqs, "dryrun": lambda s, **k: ftw(s, dry_run=True, **k), "ftw": ftw,
          "endpoint": endpoint, "jumbo": jumbo, "full": full, "secondary": secondary,
          "secondary-jumbo": lambda s, **k: secondary(s, install_jumbo=True, **k), "packages": packages}
