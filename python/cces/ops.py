"""Check Point operations: First Time Wizard, management readiness, licence, contract,
and the Endpoint management object (Lab 2A Task 2A-2) through mgmt_cli.
Ported from lib/CPLab.Ssh.ps1 with the same checks and the same lessons in the comments."""
import os
import re
import time

from . import log
from .gaia import port_open, wait_ssh


# ------------------------------------------------------------------ wizard --
def ftw_done(g):
    return "FTW_DONE" in g.bash("test -f /etc/.wizard_accepted && echo FTW_DONE || echo FTW_PENDING", 60, True).output


def run_ftw(g, answer_text, remote_path, dry_run_only=False):
    """Write the answer file, validate with --dry-run, then launch config_system detached."""
    if ftw_done(g):
        log.warn(f"{g.host} has already completed the First Time Wizard - skipping.")
        return "already-done"
    g.write_text(remote_path, answer_text)
    log.step("Validating the answer file (config_system --dry-run)...")
    dry = g.bash(f"config_system -f {remote_path} --dry-run", 300)
    if re.search(r"ERROR|Invalid|not a valid|failed", dry.output):
        raise RuntimeError(f"config_system --dry-run rejected the answer file:\n{dry.output}")
    log.ok("Answer file validated.")
    if dry_run_only:
        return "dry-run"
    log.step("Running the First Time Wizard - several minutes, then a reboot.")
    r = g.bash(f"rm -f /var/log/cces_ftw.log; nohup config_system -f {remote_path} > /var/log/cces_ftw.log 2>&1 & echo LAUNCHED:$!", 60, True)
    m = re.search(r"LAUNCHED:(\d+)", r.output)
    if m:
        log.ok(f"config_system started as pid {m.group(1)}.")
    time.sleep(20)
    # [c] keeps pgrep from matching the probe's own command line.
    alive = g.bash('pgrep -f "[c]onfig_system -f" >/dev/null 2>&1 && echo ALIVE || echo DEAD; echo ---; tail -20 /var/log/cces_ftw.log 2>/dev/null', 90, True)
    if "DEAD" in alive.output and not ftw_done(g):
        log.block(alive.output, "ERROR")
        raise RuntimeError("The First Time Wizard did not start. See /var/log/cces_ftw.log on the host.")
    return "started"


def wait_ftw_complete(g, timeout_min=75, expected_hostname=""):
    """Watch the work, not the clock: host down = reboot; process gone + marker = done."""
    t0 = time.time()
    seen_host = False
    log.step(f"Watching the wizard on {g.host} - up to {timeout_min} min, reboot included.")
    while time.time() - t0 < timeout_min * 60:
        mins = int((time.time() - t0) / 60)
        if not port_open(g.host, g.port):
            log.ok(f"Host went down after {mins}m - the wizard is rebooting it.")
            if not wait_ssh(g.host, 2400, "Waiting for the host to come back", g.port):
                log.error("The host did not come back.")
                return False
            time.sleep(20)
            try:
                g.reconnect()
            except Exception as e:
                log.warn(f"Reconnect after reboot failed: {e}")
            return True
        try:
            p = g.bash('pgrep -f "[c]onfig_system -f" >/dev/null 2>&1 && echo WIZARD_RUNNING || echo WIZARD_GONE; '
                       'test -f /etc/.wizard_accepted && echo MARKER_PRESENT || echo MARKER_ABSENT; echo "HOSTNAME=$(hostname)"', 90, True)
            hn = (re.search(r"HOSTNAME=(\S+)", p.output) or [None, ""])[1]
            if expected_hostname and hn == expected_hostname and not seen_host:
                log.ok(f"Hostname is now '{hn}' - the wizard is making progress.")
                seen_host = True
            if "WIZARD_RUNNING" in p.output:
                log.info(f"Wizard still running ({mins}m){f' [hostname: {hn}]' if hn else ''}...")
            elif "MARKER_PRESENT" in p.output:
                log.ok(f"Wizard finished after {mins}m without needing a reboot.")
                return True
            else:
                log.error("config_system is no longer running and the wizard marker is absent - it failed.")
                log.block(g.bash("tail -n 30 /var/log/cces_ftw.log 2>/dev/null", 120, True).output, "ERROR")
                return False
        except Exception:
            log.info(f"Probe failed ({mins}m) - most likely the reboot starting. Retrying...")
            try:
                g.reconnect(120)
            except Exception:
                pass
        time.sleep(30)
    log.error(f"Gave up after {timeout_min} minutes. Check on the host: pgrep -f config_system")
    return False


def wait_management_ready(g, timeout_s=2400, poll_s=30):
    """Watchdog up is not the same as usable: read 'api status' for the real verdict."""
    log.step(f"Waiting for management services on {g.host} (up to {timeout_s // 60} min)...")
    t0 = time.time()
    while time.time() - t0 < timeout_s:
        try:
            r = g.bash('cpwd_admin list 2>/dev/null | egrep "CPM|FWM|CPD" || echo NOT_READY', 120, True)
            lines = [l for l in r.output.splitlines() if re.match(r"^\s*(CPM|FWM|CPD)\b", l)]
            up = [l for l in lines if re.search(r"\bE\b", l)]
            if lines and len(up) >= len(lines):
                a = g.bash("api status 2>&1 | egrep -i 'readiness|Overall API Status|during initialization|may not be run|^\\s*(API|CPM|FWM)\\s'", 300, True).output
                if re.search(r"(?i)may not be run before First-Time-Wizard", a):
                    log.info("Wizard has not finished yet - waiting.")
                elif re.search(r"(?i)API readiness test SUCCESSFUL", a):
                    log.ok("Management API is up and ready.")
                    return True
                elif re.search(r"(?i)during initialization|^\s*CPM\s+Starting", a, re.M):
                    log.info("CPM is still initialising (normal for a few minutes after the wizard)...")
                elif re.search(r"(?i)readiness test FAILED|API Server Is Not Running", a):
                    log.info("Management API is not up yet...")
                else:
                    log.warn("Could not read api status - going by the watchdog.")
                    return True
            else:
                log.info(f"Not ready yet ({len(up)}/{len(lines)} processes up)...")
        except Exception as e:
            log.warn(f"Poll failed ({e.__class__.__name__}) - reconnecting...")
            try:
                g.reconnect(300)
            except Exception:
                pass
        time.sleep(poll_s)
    log.error("Timed out waiting for management services.")
    return False


# ------------------------------------------------------ licence / contract --
def install_license(g, local_path):
    remote = g.put_file(local_path, "/var/log", skip_same_size=False)
    log.step(f"Installing the licence (cplic put -l {remote})...")
    r = g.bash(f"cplic put -l '{remote}'", 300)
    if re.search(r"Usage|failed|Failed|error occurred", r.output):
        log.warn("cplic put -l did not work - trying line by line.")
        with open(local_path, encoding="utf-8", errors="replace") as f:
            for line in f:
                t = line.strip()
                if not t or t.startswith("#"):
                    continue
                t = re.sub(r"^cplic\s+(put|putlic)\s+", "", t)
                t = re.sub(r"^LICENSE\s+", "", t)
                g.bash(f"cplic put {t}", 300)
    chk = g.bash("cplic print -x", 120)
    if re.search(r"(?i)no licenses|0 licenses", chk.output):
        log.error("No licences are showing - check the .lic file matches this IP.")
        return False
    log.ok("Licence installed.")
    return True


def install_contract(g, local_path):
    """cplic contract put -o installs the contract ON THE BOX. SmartUpdate's 'License and
    Contract Repository' is a separate management-side view and may still say
    'No contracts' - see docs/manual-steps.md."""
    remote = g.put_file(local_path, "/var/log", skip_same_size=False)
    log.step(f"Installing the service contract (cplic contract put -o {remote})...")
    r = g.bash(f"cplic contract put -o '{remote}'", 300)
    if re.search(r"(?i)error|failed|usage", r.output):
        log.warn("The service contract did not install cleanly - add it in SmartConsole if CPUSE complains.")
        return False
    log.ok("Service contract installed on the box.")
    return True


# ------------------------------------------------- Endpoint object (2A-2) --
ENDPOINT_SCRIPT = r'''#!/bin/bash
# Generated by CCES-R8120-Automation - configures the Endpoint management object.
SID=/tmp/cces_mgmt_sid.txt
rm -f "$SID"
say()  { echo "CCES_INFO:$1"; }
fail() { echo "CCES_FAIL:$1"; [ -f "$SID" ] && mgmt_cli -s "$SID" logout >/dev/null 2>&1; exit 1; }
blade() { grep -o "\"$1\" : [a-z]*" "$2" | head -1 | awk '{print $3}'; }
natip() { grep -A5 '"nat-settings"' "$1" | grep -o '"ipv4-address" : "[^"]*"' | head -1 | cut -d'"' -f4; }

mgmt_cli -r true login > "$SID" 2>/tmp/cces_login.err || { cat /tmp/cces_login.err; fail login; }
say "logged in"
mgmt_cli -s "$SID" show checkpoint-host name "__OBJ__" --format json > /tmp/cces_before.json 2>&1 || fail show-before
grep -q '"name" *: *"__OBJ__"' /tmp/cces_before.json || { head -5 /tmp/cces_before.json; fail object-not-found; }
for k in endpoint-policy smart-event-server smart-event-correlation logging-and-status; do
    say "before  $k = $(blade $k /tmp/cces_before.json)"
done
say "before  nat ipv4 = $(natip /tmp/cces_before.json)"
mgmt_cli -s "$SID" set checkpoint-host name "__OBJ__" \
    __SETARGS__ \
    --format json > /tmp/cces_set.json 2>&1 || { head -20 /tmp/cces_set.json; fail set-checkpoint-host; }
say "set accepted"
mgmt_cli -s "$SID" publish --format json > /tmp/cces_pub.json 2>&1 || { head -20 /tmp/cces_pub.json; fail publish; }
CH=$(grep -o '"numberOfPublishedChanges" : [0-9]*' /tmp/cces_pub.json | head -1 | awk '{print $3}')
say "published $CH change(s)"
[ "$CH" = "0" ] && echo "CCES_NO_CHANGES"
mgmt_cli -s "$SID" install-database targets "__OBJ__" --format json > /tmp/cces_db.json 2>&1
TASK=$(sed -n 's/.*"task-id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /tmp/cces_db.json | head -1)
if [ -n "$TASK" ]; then
    say "install-database task $TASK"
    for i in $(seq 1 __POLLS__); do
        mgmt_cli -s "$SID" show-task task-id "$TASK" --format json > /tmp/cces_task.json 2>/dev/null
        if grep -qi '"status"[[:space:]]*:[[:space:]]*"succeeded"' /tmp/cces_task.json; then echo "CCES_TASK_OK"; break; fi
        if grep -qi '"status"[[:space:]]*:[[:space:]]*"failed"' /tmp/cces_task.json; then
            echo "CCES_TASK_FAILED"; grep -o '"comments" : "[^"]*"' /tmp/cces_task.json | head -3; break
        fi
        sleep 10
    done
else
    say "no task id returned - install-database may have run synchronously"
    grep -qi '"status" *: *"succeeded"' /tmp/cces_db.json && echo "CCES_TASK_OK"
fi
mgmt_cli -s "$SID" show checkpoint-host name "__OBJ__" --format json > /tmp/cces_after.json 2>&1
for k in endpoint-policy smart-event-server smart-event-correlation logging-and-status; do
    say "after   $k = $(blade $k /tmp/cces_after.json)"
done
say "after   nat ipv4 = $(natip /tmp/cces_after.json)"
mgmt_cli -s "$SID" logout >/dev/null 2>&1
echo "CCES_DONE"
'''


def set_endpoint_management(g, s, skip_nat=False, task_timeout_min=20):
    """Lab 2A Task 2A-2 in one mgmt_cli session (a bare 'mgmt_cli -r true' per command would
    log out and discard the change before publish)."""
    b = lambda v: "true" if v else "false"
    args = [f"management-blades.endpoint-policy {b(s.EnableEndpointPolicy)}",
            f"management-blades.smart-event-server {b(s.EnableSmartEventServer)}",
            f"management-blades.smart-event-correlation {b(s.EnableSmartEventCorrelation)}",
            f"management-blades.logging-and-status {b(s.EnableLoggingAndStatus)}"]
    if not skip_nat and s.AEpmNatIp:
        args += ["nat-settings.auto-rule true", "nat-settings.method static",
                 f"nat-settings.ipv4-address {s.AEpmNatIp}", "nat-settings.install-on All"]
    script = (ENDPOINT_SCRIPT.replace("__OBJ__", s.AEpmObjectName)
              .replace("__SETARGS__", " \\\n    ".join(args))
              .replace("__POLLS__", str(task_timeout_min * 6)))
    log.step(f"Configuring the {s.AEpmObjectName} management object through the API...")
    g.write_text("/home/admin/cces_endpoint_cfg.sh", script)
    r = g.bash("bash /home/admin/cces_endpoint_cfg.sh 2>&1", 60 * (task_timeout_min + 10), True)
    for l in r.output.splitlines():
        m = re.match(r"^CCES_INFO:(.*)$", l)
        if m:
            log.info("    " + m.group(1))
    m = re.search(r"CCES_FAIL:(\S+)", r.output)
    if m:
        log.error(f"The API step failed at: {m.group(1)}")
        return False
    if "CCES_TASK_FAILED" in r.output:
        log.error("install-database reported a failed task.")
        return False
    if "CCES_DONE" not in r.output:
        log.error("The API script did not run to completion.")
        return False
    if "CCES_NO_CHANGES" in r.output:
        log.warn("Publish had nothing to commit - the object was already in the wanted state.")
    if re.search(r"after\s+endpoint-policy = true", r.output):
        log.ok("Endpoint Policy Management is enabled on the object.")
    else:
        log.warn("Could not confirm Endpoint Policy Management - check the object in SmartConsole.")
    if "CCES_TASK_OK" in r.output:
        log.ok("Database installed.")
    return True
