"""CPUSE (Deployment Agent / installer) operations, driven the way that actually works.

Lessons that shaped this (all proven on A-SMS, 24-25 Sep 2026):
  * the numbered package list exists only in an interactive session, and appears on Tab;
    Enter on a bare 'installer install' just says "CLINFR0349 Incomplete command";
  * after the number, CPUSE asks
        "Do you want to continue? ([y]es / [n]o / [s]uppress reboot)"
    and nothing happens until it is answered - the reason every non-interactive attempt
    (clish -c, clish -f, keystrokes fed blind) said "installing" and then did nothing;
  * a cloud-downloaded package is listed by a display name WITH SPACES, which breaks any
    'installer install <name>' on a command line - numbers avoid that entirely;
  * "Result: ... installed successfully. Additional Info: ... error ..." is SUCCESS: the
    note (e.g. SFWR80CMP inspect files, sk116455) is about a side package.
"""
import re
import time

from . import log
from .clish import CONFIRM, PROMPT_AT, parse_numbered
from .gaia import port_open, wait_ssh

# CPUSE messages that end an operation without a "Result:" line.
REFUSAL = re.compile(r"(?i)(operation cancel+ed[^\n]*|before you continue with cpuse actions[^\n]*"
                     r"|update to the latest deployment agent[^\n]*|not enough (free )?(disk )?space[^\n]*)")

AGENT_REFUSAL = re.compile(r"(?i)latest deployment agent")

# Reboot timing (seconds) - module-level so tests can shorten them.
REBOOT_DOWN_WAIT = 600
POST_REBOOT_SETTLE = 60
RECHECK_EVERY = 60


def take_pattern(take):
    """Matches Take N in either a display name or a file name - never Take N0 / N1..."""
    return re.compile(rf"(?i)jumbo.*(\btake\s*{take}\b|_T{take}[._])")


def packages(g, which=""):
    """'show installer packages [installed|downloaded|imported|available-for-download]'"""
    return g.clish(f"show installer packages {which}".strip(), timeout=300, quiet=True).output


def installed_take(g):
    """Highest R81.20 main Jumbo take in the installed list (0 if none)."""
    takes = [int(t) for t in re.findall(r"(?i)Jumbo Hotfix Accumulator.*?Take\s*(\d+)", packages(g, "installed"))]
    return max(takes) if takes else 0


def has_take(text, take):
    return take_pattern(take).search(text) is not None


def numbered_list(g, verb="install"):
    """The Tab-completion table for 'installer <verb> '. Installs nothing."""
    sh = g.interactive()
    try:
        sh.send(f"installer {verb} \t")
        out = sh.read_until_prompt(90, quiet_after=2.0)
        sh.send("\x15\r")                      # Ctrl+U: clear the half-typed line
        sh.read_until_prompt(10)
        return parse_numbered(out), out
    finally:
        sh.close()


def run_numbered(g, verb, pattern, timeout_min=90, confirm="y"):
    """installer <verb> <Tab> -> pick the one row matching pattern -> number + Enter ->
    answer the confirmation when shown -> narrate until 'Result:' and the prompt return,
    or the session drops (a reboot). Returns (status, result_text)
    status: 'ok' | 'failed' | 'refused' | 'session-lost' | 'timeout' | 'not-found' | 'ambiguous'"""
    rx = re.compile(pattern, re.I) if isinstance(pattern, str) else pattern
    sh = g.interactive()
    try:
        sh.lock_override()
        sh.send(f"installer {verb} \t")
        listing = sh.read_until_prompt(90, quiet_after=2.0)
        rows = parse_numbered(listing)
        for r in rows:
            log.info(f"    {r['num']:>3}  {r['name']}  [{r['type']}]")
        pick = [r for r in rows if rx.search(r["name"])]
        if len(pick) != 1:
            sh.send("\x15\r")
            if not pick:
                log.error(f"Nothing in the 'installer {verb}' list matches /{rx.pattern}/.")
                return "not-found", listing
            log.error(f"{len(pick)} rows match /{rx.pattern}/ - refusing to guess.")
            return "ambiguous", listing
        pick = pick[0]
        log.step(f"installer {verb} {pick['num']}  ({pick['name']})")
        sh.send(f"{pick['num']}\r")              # on the same half-typed line, as at the keyboard

        t0, deadline = time.time(), time.time() + timeout_min * 60
        tail, answered, last_shown, last_line = "", 0, 0.0, ""
        while time.time() < deadline:
            try:
                chunk = sh.recv()
            except (EOFError, OSError) as e:
                log.warn(f"Session ended ({e}) - the host is probably rebooting.")
                return "session-lost", tail
            if chunk:
                tail = (tail + chunk)[-8000:]
                for l in chunk.splitlines():
                    l = l.rstrip()
                    if not l.strip():
                        continue
                    # CPUSE redraws its progress line every second - log changes, and a
                    # heartbeat once a minute, rather than 1,500 identical lines.
                    if l != last_line or time.time() - last_shown > 60:
                        log.info("   | " + l)
                        last_line, last_shown = l, time.time()
                refusal = REFUSAL.search(tail)
                if refusal:
                    log.error(f"CPUSE refused: {refusal.group(0).strip()}")
                    return "refused", refusal.group(0).strip()
                if CONFIRM.search(tail.rstrip()) and answered < 3:
                    log.warn(f">>> CPUSE is asking for confirmation - answering '{confirm}'.")
                    sh.send(confirm + "\r")
                    answered += 1
                    tail = ""
                continue
            m = re.search(r"(?i)result:([^\n]*)", tail)
            lines = [l for l in tail.split("\n") if l.strip()]
            if m and lines and PROMPT_AT.match(lines[-1]):
                res = m.group(1).strip()
                if re.search(r"(?i)successfully|was installed|was downloaded|was imported", res):
                    note = re.search(r"(?i)additional info:(.*)", res)
                    if note:
                        log.warn(f"CPUSE note (not a failure): {note.group(1).strip()}")
                    return "ok", res
                return "failed", res
        return "timeout", tail
    finally:
        sh.close()


def download(g, take, timeout_min=30):
    txt = packages(g)
    for line in txt.splitlines():
        if take_pattern(take).search(line) and re.search(r"(?i)downloaded|imported|installed|installing", line):
            log.ok(f"Take {take} is already on the box: {line.strip()}")
            return True
    log.step(f"Downloading Jumbo Take {take} from the Check Point cloud...")
    t0 = time.time()
    status, res = run_numbered(g, "download", take_pattern(take), timeout_min)
    if status == "ok":
        log.ok(f"Downloaded in {(time.time() - t0) / 60:.1f} min: {res}")
        return True
    log.error(f"Download did not complete ({status}): {res[-400:]}")
    return False


def import_local(g, remote_path, take, timeout_min=45):
    """Import a tar we copied up. Returns when it appears in the imported list."""
    if has_take(packages(g, "imported"), take):
        log.ok(f"Take {take} is already imported.")
        return True
    log.step(f"Importing {remote_path} into CPUSE...")
    g.clish(f"installer import local {remote_path} not-interactive", timeout=3600)
    t0 = time.time()
    while time.time() - t0 < timeout_min * 60:
        time.sleep(30)
        if has_take(packages(g, "imported"), take):
            log.ok(f"Imported after {(time.time() - t0) / 60:.1f} min.")
            return True
        log.info(f"Still importing - {int((time.time() - t0) / 60)}m...")
    log.error("The package never appeared in the imported list.")
    return False


AGENT_WAIT_MIN = 20
AGENT_POLL = 30


def wait_agent_self_update(g, wait_min=None):
    """CPUSE refused because the agent is not the latest. Nudge it (check-for-updates +
    agent update) and poll the build until it goes up. True if it did."""
    wait_min = AGENT_WAIT_MIN if wait_min is None else wait_min
    before = da_build(g)
    log.warn(f"CPUSE wants a newer Deployment Agent than {before} - waiting up to {wait_min} min "
             "for it to update itself (it does this in the background).")
    for c in ("installer check-for-updates not-interactive", "installer agent update not-interactive"):
        try:
            r = g.clish(c, timeout=900, quiet=True)
            if re.search(r"CLINFR0771|CLINFR0519|config lock", r.output, re.I):
                g.clish_locked(c, 900, save=False)
        except Exception as e:
            log.dim(f"{c}: {e}")
    t0 = time.time()
    last = 0
    while time.time() - t0 < wait_min * 60:
        try:
            now = da_build(g)
        except Exception:
            now = 0                       # the agent restarts while it updates
        if now > before:
            log.ok(f"Deployment Agent updated itself: {before} -> {now}. Trying the install again.")
            time.sleep(AGENT_POLL)        # let the new agent settle
            return True
        if time.time() - last > 120:
            log.info(f"    agent still {now or '?'} ({int((time.time() - t0) / 60)}m)...")
            last = time.time()
        time.sleep(AGENT_POLL)
    log.error(f"The Deployment Agent stayed at {before} for {wait_min} min. Update it in the Gaia Portal "
              "(Upgrades (CPUSE) > Status and Actions > Install DA) and re-run the jumbo stage.")
    return False


def install(g, take, timeout_min=90):
    """Install Jumbo `take` from the numbered list, follow the reboot, confirm."""
    if installed_take(g) >= take:
        log.ok(f"Take {installed_take(g)} is already installed - nothing to do.")
        return True
    t0 = time.time()
    status, res = run_numbered(g, "install", take_pattern(take), timeout_min)
    if status == "refused" and AGENT_REFUSAL.search(res or ""):
        # Seen on A-EPM 25 Sep (fresh lab): 'installer agent update' said 2806 was up to date,
        # the install was refused, and the agent then updated itself to 2808 in the background
        # a few minutes later. So wait for that, then try once more.
        if wait_agent_self_update(g):
            status, res = run_numbered(g, "install", take_pattern(take), timeout_min)
    if status in ("failed", "refused", "not-found", "ambiguous", "timeout"):
        log.error(f"Install did not go through ({status}): {res[-400:]}")
        return False
    log.ok("CPUSE finished the install - the host reboots now." if status == "ok"
           else "Session dropped mid-install - watching for the reboot.")

    # Follow the reboot: wait for it to go down (it may already be), then come back.
    host = g.host
    down_by = time.time() + REBOOT_DOWN_WAIT
    while time.time() < down_by and port_open(host, g.port):
        time.sleep(10)
    if not wait_ssh(host, 2400, "Waiting for the host after the reboot", g.port):
        log.error("The host did not come back after the reboot.")
        return False
    time.sleep(POST_REBOOT_SETTLE)
    deadline = t0 + timeout_min * 60 + 2400
    while time.time() < deadline:
        try:
            g.reconnect(600)
            now = installed_take(g)
            if now >= take:
                log.ok(f"Take {now} is INSTALLED - {(time.time() - t0) / 60:.0f} min from pressing Enter.")
                return True
            log.info(f"Host is back; installed take reads {now} - checking again shortly.")
        except Exception as e:
            log.info(f"Host up but not answering yet ({e.__class__.__name__}).")
        time.sleep(RECHECK_EVERY)
    log.error(f"Take {take} never showed as installed.")
    return False


def da_build(g):
    """Installed Deployment Agent build, as CPUSE and the Gaia Portal show it
    ('show installer status' -> 'Build number: 2806 (...)'). The registry value
    (cpprod_util DeploymentAgent BuildNumber) is only a fallback: straight after an agent
    install it has been seen to read 771 for a 2337/2806 agent."""
    for _ in range(3):
        try:
            b, _txt = da_status(g)
            if b >= 1000:
                return b
        except Exception:
            pass
        time.sleep(10)                    # the agent restarts after an install
    r = g.bash('cpprod_util CPPROD_GetValue "DeploymentAgent" "BuildNumber" 1 2>/dev/null', 180, True)
    m = re.search(r"(?m)^\s*(\d{4,6})\s*$", r.output)
    return int(m.group(1)) if m else 0


def da_status(g):
    """(build, verdict text) from 'show installer status'. Seen formats:
         Build number:       2808 (update status: Latest build is already installed)
         Build number:       2255 (agent build is up to date)"""
    st = g.clish("show installer status", timeout=180, quiet=True).output
    m = re.search(r"(?i)build number:\s*(\d+)\s*\(([^)]*)\)", st)
    return (int(m.group(1)), m.group(2).strip()) if m else (0, "")


def update_deployment_agent_online(g, wait_min=5):
    """installer agent update. CPUSE's own 'up to date' is only as good as its last cloud
    check - on 25 Sep it called 2255 up to date while refusing Jumbo work - so this is an
    extra step on top of the bundled minimum, never the only one."""
    before = da_build(g)
    r = g.clish("installer agent update not-interactive", timeout=900, quiet=True)
    if re.search(r"CLINFR0771|CLINFR0519|config lock", r.output, re.I):
        out = g.clish_locked("installer agent update not-interactive", 900, save=False)
        r = type(r)(out, 0)
    log.block(r.output)
    if re.search(r"(?i)up to date|already installed", r.output):
        log.info(f"CPUSE says the agent ({before}) is up to date.")
        return before
    t0 = time.time()
    while time.time() - t0 < wait_min * 60:
        time.sleep(30)
        try:
            now = da_build(g)
        except Exception:
            continue                      # the agent restarts during the update
        if now > before:
            log.ok(f"Deployment Agent updated online: {before} -> {now}.")
            return now
    return da_build(g)


def install_deployment_agent(g, local_path):
    """Make the agent at least the newest bundled build, then try the online update on top.
    CPUSE cancels every verify/install ('update to the latest Deployment Agent version') on
    an old agent, and cannot be trusted to know it is old."""
    import os
    want = 0
    m = re.search(r"DeploymentAgent[_-]0*(\d+)", os.path.basename(local_path or ""))
    if m:
        want = int(m.group(1))
    cur = da_build(g)
    log.info(f"Deployment Agent: installed build {cur}, newest bundled build {want or '?'}.")
    if want and cur < want:
        install_deployment_agent_bundled(g, local_path)
    try:
        update_deployment_agent_online(g)
    except Exception as e:
        log.warn(f"Online agent update failed ({e}).")
    final = da_build(g)
    if want and final < want:
        log.warn(f"Agent is still {final}, below the bundled {want} - CPUSE may cancel Jumbo actions.")
        return False
    log.ok(f"Deployment Agent build {final}.")
    return True


def install_deployment_agent_bundled(g, local_path):
    import os
    want = 0
    m = re.search(r"DeploymentAgent[_-]0*(\d+)", os.path.basename(local_path))
    if m:
        want = int(m.group(1))
    cur = da_build(g)
    log.info(f"Deployment Agent: installed build {cur}, bundled package build {want}.")
    if cur and want and cur >= want:
        log.ok("The installed Deployment Agent is the same or newer - nothing to do.")
        return True
    remote = g.put_file(local_path, "/var/log")
    log.step("Installing the Deployment Agent package...")
    g.bash(f"printf 'y\\ny\\n' | clish -c \"installer agent install {remote}\"", 1800)
    after = 0
    for _ in range(3):
        time.sleep(30)
        after = da_build(g)
        if not want or after >= want:
            break
        log.info(f"Agent reports build {after} - waiting for it to finish restarting...")
    if want and after < want:
        log.warn(f"Expected build {want} but the agent reports {after} - check /var/log/CPda.")
        return False
    log.ok(f"Deployment Agent build is now {after}.")
    return True
