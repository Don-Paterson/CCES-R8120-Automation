"""Prompt-driven interactive session on a Gaia host (paramiko invoke_shell).

This is the piece that finally made CPUSE installs work: never type ahead - wait for the
prompt, then send the next thing, and answer a question only when it is on the screen.
"""
import re
import socket
import time

import paramiko

from . import log

ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[()][A-Za-z0-9]|\x08|\x07")
# Clish:  A-SMS>  /  A-SMS:0>   (possibly followed by a half-typed line after Tab)
# Expert: [Expert@A-EPM:0]#
PROMPT_AT = re.compile(r"^([\w.\-]+(:\S+)?>( |$)|\[Expert@[^\]]+\]#\s?)")
EXPERT_PROMPT = re.compile(r"\[Expert@[^\]]+\]#\s*$")
PASSWORD_PROMPT = re.compile(r"(?i)(enter )?(expert )?password:?\s*$")
CONFIRM = re.compile(
    r"(?i)(\[y\]es\s*/\s*\[n\]o[^\n]*"                  # ([y]es / [n]o / [s]uppress reboot)  - R81.20 CPUSE
    r"|\(y-yes,? else no\)|\[y/n\]|\(y/n\)|yes/no"
    r"|do you want to continue\?[^\n]*|are you sure[^\n]*)\s*:?\s*$")


def clean(text):
    return ANSI.sub("", text).replace("\r", "")


class ClishShell:
    def __init__(self, client, echo=False):
        self.ch = client.invoke_shell(term="vt100", width=250, height=200)
        self.ch.settimeout(0.5)
        self.echo = echo
        out = self.read_until_prompt(30)
        # If admin's shell is /bin/bash (we switch it for SFTP and config_system), the session
        # opens at [Expert@host:0]# - where 'lock database override' is "command not found"
        # and Tab lists files. Enter Clish first. (Seen on A-EPM, 25 Sep 2026.)
        lines = [l for l in out.split("\n") if l.strip()]
        if lines and EXPERT_PROMPT.search(lines[-1]):
            self.send("clish\r")
            self.read_until_prompt(30)
            self.entered_clish = True
        else:
            self.entered_clish = False

    # -- low level ------------------------------------------------------------
    def recv(self):
        try:
            data = self.ch.recv(65536)
        except socket.timeout:
            return ""
        if not data:
            raise EOFError("session closed")
        text = clean(data.decode("utf-8", "replace"))
        if self.echo:
            log.block(text, "DIM", "   | ")
        return text

    def send(self, text):
        self.ch.send(text)

    def close(self):
        try:
            self.ch.close()
        except Exception:
            pass

    # -- reading --------------------------------------------------------------
    def read_until(self, pattern, timeout=60, quiet_after=0.5):
        """Read until the tail of the output matches pattern (regex) and then goes quiet."""
        rx = re.compile(pattern) if isinstance(pattern, str) else pattern
        out, last, t0 = "", time.time(), time.time()
        while time.time() - t0 < timeout:
            chunk = self.recv()
            if chunk:
                out += chunk
                last = time.time()
                continue
            if rx.search(out.rstrip("\n")) and time.time() - last >= quiet_after:
                return out
        return out

    def read_until_prompt(self, timeout=60, quiet_after=1.0):
        out, last, t0 = "", time.time(), time.time()
        while time.time() - t0 < timeout:
            chunk = self.recv()
            if chunk:
                out += chunk
                last = time.time()
                continue
            lines = [l for l in out.split("\n") if l.strip()]
            if lines and PROMPT_AT.match(lines[-1]) and time.time() - last >= quiet_after:
                return out
        return out

    def run(self, command, timeout=120):
        """Type a command, wait for the prompt, return what came back (minus the echo)."""
        self.send(command + "\r")
        out = self.read_until_prompt(timeout)
        return "\n".join(l for l in out.split("\n") if l.strip() and l.strip() != command)

    def lock_override(self):
        out = self.run("lock database override", 30)
        # CLICMD0201 "Config lock is already turned on" = we hold it already: fine.
        return out


def parse_numbered(text):
    """Rows of the numbered table Clish prints on Tab after 'installer <verb> '."""
    row = re.compile(r"^\s*(\d+)\s+(.+?)\s{2,}(\S.*?)\s*$")
    rows = []
    for line in text.splitlines():
        if line.strip().startswith("**") or re.match(r"^\s*Num\b", line) or PROMPT_AT.match(line):
            continue
        m = row.match(line)
        if m:
            rows.append({"num": int(m.group(1)), "name": m.group(2).strip(), "type": m.group(3).strip()})
    return rows
