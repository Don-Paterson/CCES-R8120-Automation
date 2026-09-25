#!/usr/bin/env python3
"""
cpuse_install.py - install a CPUSE package (e.g. a Jumbo Hotfix Accumulator) on a Gaia
host by driving Clish exactly the way a person does at the keyboard.

Why this exists
    Non-interactive routes proved unreliable in this lab:
      * a package CPUSE downloaded from the cloud is listed by a display name with
        spaces, which 'installer install' splits when given on a command line;
      * the numbered package list only exists in an interactive session, and only
        appears when Tab is pressed (Enter just says "Incomplete command");
      * feeding keystrokes blind into a pty (plink -t < file) got CPUSE to say
        "installing ..." and then nothing happened.
    So this script opens a real interactive shell with paramiko, WAITS for each prompt,
    types 'installer install ', presses Tab, reads the numbered list, types the number
    on the same line and presses Enter - then stays attached and answers any y/n
    question when (and only when) it is actually asked.

Credentials
    The password is read from the environment variable CP_GAIA_PASSWORD (set by
    Invoke-CPUSEInstall.ps1 from config/lab-settings.psd1). It is never taken from the
    command line, so it does not appear in process listings or relay job scripts.

Exit codes
    0 installed (or already installed, or --list-only finished)
    2 bad arguments / cannot connect
    3 package not found in the numbered list
    4 install did not complete in time
    5 CPUSE reported a failure
"""
import argparse
import os
import re
import socket
import sys
import time
from datetime import datetime

try:
    import paramiko
except ImportError:
    print("paramiko is not installed - run:  py -3 -m pip install paramiko", flush=True)
    sys.exit(2)

ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[()][A-Za-z0-9]|\x08")
PROMPT_AT = re.compile(r"^[\w.\-]+(:\S+)?>( |$)")                      # A-SMS> ...  or  A-EPM:0>
CONFIRM = re.compile(
    r"(?i)(\[y\]es\s*/\s*\[n\]o[^\n]*"          # Do you want to continue? ([y]es / [n]o / [s]uppress reboot)  <- seen on R81.20 CPUSE
    r"|\(y-yes,? else no\)|\[y/n\]|\(y/n\)|yes/no"
    r"|do you want to continue\?[^\n]*|are you sure[^\n]*)\s*:?\s*$")
ROW = re.compile(r"^\s*(\d+)\s+(.+?)\s{2,}(\S.*?)\s*$")

LOG = None


def log(msg=""):
    line = f"{datetime.now():%H:%M:%S}  {msg}" if msg else ""
    print(line, flush=True)
    if LOG:
        LOG.write(line + "\n")
        LOG.flush()


def clean(text):
    return ANSI.sub("", text).replace("\r", "")


# --------------------------------------------------------------------- ssh --
def connect(host, user, password, timeout=30):
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(host, username=user, password=password, timeout=timeout,
              banner_timeout=timeout, auth_timeout=timeout, look_for_keys=False, allow_agent=False)
    c.get_transport().set_keepalive(20)
    return c


def run(client, cmd, timeout=180, tries=3):
    """One Clish command over an exec channel (admin's shell is Clish). Retries, because
    straight after a reboot SSH answers before Gaia is ready to run commands."""
    for i in range(tries):
        try:
            _, out, err = client.exec_command(cmd, timeout=timeout)
            text = out.read().decode("utf-8", "replace") + err.read().decode("utf-8", "replace")
            return clean(text).strip()
        except (paramiko.SSHException, socket.error, EOFError) as e:
            if i == tries - 1:
                raise
            time.sleep(3 * (i + 1))


class Shell:
    """An interactive Clish session that reads until it sees a prompt."""

    def __init__(self, client):
        self.ch = client.invoke_shell(term="vt100", width=250, height=200)
        self.ch.settimeout(0.5)
        self.buf = ""
        self.read_until_prompt(30)

    def _recv(self):
        try:
            data = self.ch.recv(65536)
        except socket.timeout:
            return ""
        if not data:
            raise EOFError("session closed")
        return clean(data.decode("utf-8", "replace"))

    def read_until_prompt(self, timeout=60, quiet_after=1.0):
        """Read until the last line starts with a Clish prompt (possibly followed by a
        half-typed command after Tab) and nothing more has arrived for quiet_after s."""
        out, last, t0 = "", time.time(), time.time()
        while time.time() - t0 < timeout:
            chunk = self._recv()
            if chunk:
                out += chunk
                last = time.time()
                continue
            lines = [l for l in out.split("\n") if l.strip()]
            if lines and PROMPT_AT.match(lines[-1]) and time.time() - last >= quiet_after:
                return out
        return out

    def send(self, text):
        self.ch.send(text)


def parse_numbered(text):
    rows = []
    for line in text.splitlines():
        if line.strip().startswith("**") or re.match(r"^\s*Num\b", line):
            continue
        m = ROW.match(line)
        if m:
            rows.append({"num": int(m.group(1)), "name": m.group(2).strip(), "type": m.group(3).strip()})
    return rows


def installed_list(client):
    return run(client, "show installer packages installed")


def has_take(text, take):
    return re.search(rf"(?i)\b(take\s*{take}\b|_T{take}[._])", text) is not None


# -------------------------------------------------------------------- main --
def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--host", required=True)
    ap.add_argument("--user", default="admin")
    ap.add_argument("--match", required=True, help="regex for the package display name, e.g. 'Take 170'")
    ap.add_argument("--take", type=int, default=0, help="expected Jumbo take, used to confirm success")
    ap.add_argument("--list-only", action="store_true", help="show what would be installed and stop")
    ap.add_argument("--timeout-min", type=int, default=90)
    ap.add_argument("--log", help="also write the transcript to this file")
    a = ap.parse_args()

    global LOG
    if a.log:
        os.makedirs(os.path.dirname(os.path.abspath(a.log)), exist_ok=True)
        LOG = open(a.log, "a", encoding="utf-8")

    pw = os.environ.get("CP_GAIA_PASSWORD")
    if not pw:
        log("CP_GAIA_PASSWORD is not set - run this through Invoke-CPUSEInstall.ps1.")
        return 2

    log(f"CPUSE install on {a.host}  package /{a.match}/  expected take {a.take or '-'}")
    try:
        client = connect(a.host, a.user, pw)
    except Exception as e:
        log(f"Cannot connect to {a.host}: {e}")
        return 2

    log("--- show installer status")
    for l in run(client, "show installer status").splitlines():
        log("   " + l)
    before = installed_list(client)
    log("--- installed packages")
    for l in before.splitlines():
        if l.strip() and not l.startswith("**"):
            log("   " + l)
    if a.take and has_take(before, a.take):
        log(f"Take {a.take} is already installed - nothing to do.")
        return 0

    sh = Shell(client)
    log("Interactive Clish session open.")

    # Config lock: harmless if nobody else holds it.
    sh.send("lock database override\r")
    for l in sh.read_until_prompt(30).splitlines():
        if l.strip() and "lock database override" not in l:
            log("   " + l.strip())

    # Keyboard sequence: type the command, press Tab - Clish prints the numbered list and
    # re-draws the prompt with the half-typed line still in place.
    sh.send("installer install \t")
    listing = sh.read_until_prompt(90, quiet_after=2.0)
    rows = parse_numbered(listing)
    log("--- installer install <TAB>")
    for r in rows:
        log(f"   {r['num']:>3}  {r['name']}  [{r['type']}]")
    if not rows:
        log("No numbered list came back. Raw output:")
        for l in listing.splitlines():
            log("   | " + l)
        sh.send("\x15\r")
        return 3

    pick = [r for r in rows if re.search(a.match, r["name"], re.I)]
    if len(pick) != 1:
        log(f"Expected exactly one match for /{a.match}/, found {len(pick)} - stopping, nothing installed.")
        sh.send("\x15\r")
        return 3
    pick = pick[0]
    log(f"Selected {pick['num']}: {pick['name']}")

    if a.list_only:
        log("--list-only: clearing the line and stopping. Nothing was installed.")
        sh.send("\x15\r")
        sh.read_until_prompt(10)
        return 0

    # Finish the half-typed line with the number, exactly as at the keyboard.
    log(f"Typing '{pick['num']}' + Enter on the half-typed 'installer install ' line.")
    sh.send(f"{pick['num']}\r")

    t0 = time.time()
    deadline = t0 + a.timeout_min * 60
    answered = 0
    failed = False
    ok_result = None
    tail = ""
    session_lost = False

    # Stay attached and narrate. Answer a y/n only when it is on screen.
    while time.time() < deadline:
        try:
            chunk = sh._recv()
        except (EOFError, OSError, paramiko.SSHException) as e:
            log(f"Session ended ({e}) - the host is probably rebooting.")
            session_lost = True
            break
        if not chunk:
            last = [l for l in tail.split("\n") if l.strip()]
            if last and PROMPT_AT.match(last[-1]) and "Result:" in tail:
                break                    # the command finished and returned to the prompt
            continue
        tail = (tail + chunk)[-4000:]
        for l in chunk.splitlines():
            if l.strip():
                log("   | " + l.rstrip())
        if CONFIRM.search(tail.rstrip()) and answered < 3:
            log(">>> CPUSE is asking for confirmation - answering 'y'.")
            sh.send("y\r")
            answered += 1
            tail = ""
        # "Result: ... installed successfully. Additional Info: ..." is SUCCESS - the Additional
        # Info can mention "error" (e.g. SFWR80CMP inspect files, sk116455) without the
        # package failing. Only a Result line WITHOUT "successfully" counts as a failure.
        mres = re.search(r"(?i)result:([^\n]*)", tail)
        if mres:
            res = mres.group(1)
            if re.search(r"(?i)installed successfully|was installed", res):
                ok_result = res.strip()
            elif re.search(r"(?i)fail|error|cannot|aborted", res):
                failed = True
        if re.search(r"(?i)installation failed|cannot be installed", tail):
            failed = True

    if failed:
        log("CPUSE reported a failure - see the transcript above.")
        return 5
    if ok_result:
        m = re.search(r"(?i)additional info:(.*)", ok_result)
        log("CPUSE: package installed successfully.")
        if m:
            log(f"NOTE from CPUSE (not a failure): {m.group(1).strip()}")

    # Follow the reboot and confirm the take.
    log("Watching for the install to complete (and the reboot).")
    down_seen = session_lost
    while time.time() < deadline:
        time.sleep(60)
        m = int((time.time() - t0) / 60)
        try:
            c2 = connect(a.host, a.user, pw, timeout=20)
        except Exception:
            if not down_seen:
                log(f"{m}m  SSH unavailable - rebooting.")
            down_seen = True
            continue
        try:
            try:
                inst = installed_list(c2)
            except Exception as e:
                log(f"{m}m  host is up but not answering commands yet ({e.__class__.__name__}).")
                continue
            if a.take and has_take(inst, a.take):
                log(f"{m}m  Take {a.take} is INSTALLED.")
                for l in inst.splitlines():
                    if l.strip() and not l.startswith("**"):
                        log("   " + l)
                log(f"Total time from pressing Enter: {m} minutes.")
                return 0
            st = run(c2, "show installer status all")
            prog = [l.strip() for l in st.splitlines() if re.search(r"(?i)install|%|progress", l)]
            log(f"{m}m  still installing{': ' + ' | '.join(prog[-2:]) if prog else ''}")
        finally:
            c2.close()

    log(f"Gave up after {a.timeout_min} minutes without seeing the take installed.")
    return 4


if __name__ == "__main__":
    try:
        sys.exit(main())
    finally:
        if LOG:
            LOG.close()
