"""SSH transport to a Gaia host: exec, SFTP, shell handling - the Python replacement for
lib/CPLab.Ssh.ps1's transport and 'gaia shell handling' regions.

Gaia's admin user normally lands in Clish, so the exec channel runs Clish commands, and
SFTP/SCP do not work. config_system, cplic and friends need a real shell, so - exactly as
the PowerShell library did - we set the Expert password from its hash, switch admin's shell
to /bin/bash (admin is UID 0, so that is non-interactive root), and put it back at the end.
"""
import base64
import os
import re
import socket
import time

import paramiko

from . import log
from .clish import ClishShell, EXPERT_PROMPT, PASSWORD_PROMPT, clean


def port_open(host, port=22, timeout=4):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def wait_ssh(host, timeout=600, activity="Waiting for SSH", port=22):
    t0 = time.time()
    last = 0
    while time.time() - t0 < timeout:
        if port_open(host, port):
            return True
        if time.time() - last > 60:
            log.info(f"{activity} on {host} ({int((time.time() - t0) / 60)}m)...")
            last = time.time()
        time.sleep(10)
    return False


def wait_reboot(host, down_timeout=600, up_timeout=2400):
    t0 = time.time()
    while time.time() - t0 < down_timeout and port_open(host):
        time.sleep(10)
    log.info(f"{host} is down - rebooting.")
    return wait_ssh(host, up_timeout, "Waiting for the host to come back")


class Result:
    def __init__(self, out, rc):
        self.output, self.rc = out, rc

    @property
    def ok(self):
        return self.rc == 0

    def __contains__(self, s):
        return s in self.output


class Gaia:
    def __init__(self, host, user, password, expert_password=None, expert_hash=None, port=None):
        self.host, self.user, self.password = host, user, password
        self.port = int(port or os.environ.get("CCES_SSH_PORT", 22))     # env override is for tests
        self.expert_password, self.expert_hash = expert_password, expert_hash
        self.client = None
        self.shell = "unknown"

    # ------------------------------------------------------------ connection --
    def connect(self, timeout=60, tries=3):
        if not wait_ssh(self.host, timeout, "Connecting", self.port):
            raise ConnectionError(f"Cannot reach {self.host} on tcp/22.")
        err = None
        for i in range(tries):
            try:
                c = paramiko.SSHClient()
                c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
                c.connect(self.host, port=self.port, username=self.user, password=self.password, timeout=30,
                          banner_timeout=60, auth_timeout=60, look_for_keys=False, allow_agent=False)
                c.get_transport().set_keepalive(20)
                self.client = c
                self.shell = self._detect_shell()
                log.ok(f"Connected to {self.host} as {self.user} (shell: {self.shell}).")
                return self
            except paramiko.AuthenticationException:
                raise
            except Exception as e:
                err = e
                time.sleep(10 * (i + 1))
        raise ConnectionError(f"SSH to {self.host} failed: {err}")

    def reconnect(self, timeout=600):
        self.close()
        time.sleep(3)
        return self.connect(timeout)

    def close(self):
        if self.client:
            try:
                self.client.close()
            except Exception:
                pass
        self.client = None

    def _detect_shell(self):
        r = self.exec("id -u", 30, quiet=True)
        return "bash" if re.search(r"(?m)^\s*\d+\s*$", r.output) else "clish"

    # ------------------------------------------------------------------ exec --
    def exec(self, command, timeout=300, quiet=False, tries=3):
        """Run one command on the exec channel, exactly as given."""
        if not quiet:
            log.info(f"ssh {self.host}: {command if len(command) < 160 else command[:157] + '...'}")
        for i in range(tries):
            try:
                chan = self.client.get_transport().open_session(timeout=30)
                chan.settimeout(timeout)
                chan.set_combine_stderr(True)      # stderr interleaved, and can never block stdout
                chan.exec_command(command)
                buf = []
                while True:
                    data = chan.recv(65536)
                    if not data:
                        break
                    buf.append(data)
                rc = chan.recv_exit_status()
                chan.close()
                out = clean(b"".join(buf).decode("utf-8", "replace")).strip()
                if not quiet:
                    log.block(out)
                return Result(out, rc)
            except (paramiko.SSHException, socket.error, EOFError, AttributeError) as e:
                if i == tries - 1:
                    raise
                time.sleep(3 * (i + 1))
                try:
                    self.reconnect(120)
                except Exception:
                    pass

    def clish(self, command, save=False, timeout=600, quiet=False):
        """A Gaia Clish command, whichever shell admin is in."""
        if self.shell == "bash":
            esc = command.replace('"', '\\"')
            return self.exec(f'clish {"-s " if save else ""}-c "{esc}"', timeout, quiet)
        r = self.exec(command, timeout, quiet)
        if save:
            self.exec("save config", 60, True)
        return r

    def clish_locked(self, command, timeout=600, save=True):
        """A Clish command that needs the config lock, in ONE interactive session:
        lock database override -> command -> save config. The lock is per session, so a
        separate exec-channel command after an override would still be refused
        (CLINFR0771 'Config lock is owned by admin')."""
        sh = self.interactive()
        try:
            sh.lock_override()
            out = sh.run(command, timeout)
            if save:
                sh.run("save config", 60)
            return out
        finally:
            sh.close()

    def bash(self, command, timeout=600, quiet=False):
        """A shell (Expert-equivalent) command. Switches admin's shell first if needed."""
        if self.shell != "bash" and not self.ensure_bash():
            raise RuntimeError(f"No shell access on {self.host}.")
        return self.exec(command, timeout, quiet)

    def interactive(self, echo=False):
        return ClishShell(self.client, echo)

    # ---------------------------------------------------------- shell access --
    def set_expert_password(self):
        if self.expert_hash:
            r = self.clish(f"set expert-password-hash {self.expert_hash}", save=True, quiet=True)
            if not re.search(r"(?i)invalid|failed|error", r.output):
                log.ok("Expert password set from hash.")
                return True
            log.warn(f"set expert-password-hash was not accepted: {r.output}")
        if self.expert_password:
            sh = self.interactive()
            try:
                sh.send("set expert-password\r")
                for _ in range(2):
                    if PASSWORD_PROMPT.search(sh.read_until(PASSWORD_PROMPT, 20).rstrip()):
                        sh.send(self.expert_password + "\r")
                sh.read_until_prompt(20)
                sh.run("save config", 30)
                log.ok("Expert password set interactively.")
                return True
            finally:
                sh.close()
        return False

    def ensure_bash(self):
        """Switch admin's shell to /bin/bash (non-interactive root, and SFTP works)."""
        if self.shell == "bash":
            return True
        log.step(f"Switching {self.user} shell to /bin/bash on {self.host}...")
        r = self.exec(f"set user {self.user} shell /bin/bash", 60, True)
        if re.search(r"(?i)lock|read[- ]only|not have (the )?permission|config.*denied", r.output):
            # The config lock is per session, so override and change in ONE interactive session.
            log.warn("The Clish config database is locked by another session - taking the lock.")
            sh = self.interactive()
            try:
                sh.lock_override()
                sh.run(f"set user {self.user} shell /bin/bash", 30)
                sh.run("save config", 30)
            finally:
                sh.close()
        else:
            self.exec("save config", 60, True)
        self.reconnect()
        if self.shell == "bash":
            log.ok("Shell is now /bin/bash.")
            return True
        if self.expert_password:
            return self._bash_via_expert()
        log.error("Could not switch the admin shell to /bin/bash.")
        return False

    def _bash_via_expert(self):
        """Last resort before the wizard, where Clish is restricted: do it from Expert mode."""
        log.warn("Clish refused the shell change - trying via Expert mode.")
        sh = self.interactive()
        try:
            sh.send("expert\r")
            if PASSWORD_PROMPT.search(sh.read_until(PASSWORD_PROMPT, 20).rstrip()):
                sh.send(self.expert_password + "\r")
            if not EXPERT_PROMPT.search(sh.read_until(EXPERT_PROMPT, 20).rstrip()):
                log.error("Did not get an Expert prompt.")
                return False
            sh.send(f"sed -i '/^{self.user}:/ s|:/etc/cli.sh$|:/bin/bash|' /etc/passwd\r")
            sh.read_until(EXPERT_PROMPT, 20)
        finally:
            sh.close()
        self.reconnect()
        if self.shell == "bash":
            log.ok("Shell access established through Expert mode.")
            return True
        return False

    def init_shell_access(self):
        if self.shell == "bash":
            return True
        if self.expert_hash or self.expert_password:
            self.set_expert_password()
        return self.ensure_bash()

    def restore_clish(self):
        log.step(f"Restoring {self.user} shell to Gaia Clish on {self.host}...")
        r = self.bash(f'clish -s -c "set user {self.user} shell /etc/cli.sh"', 60, True)
        if re.search(r"CLINFR0771|CLINFR0519|lock", r.output):
            self.clish_locked(f"set user {self.user} shell /etc/cli.sh", 60)
        self.shell = "clish"

    # --------------------------------------------------------------- files --
    def write_text(self, remote_path, content, mode="600"):
        """Create a text file without SFTP (base64 over the exec channel, LF endings)."""
        data = content.replace("\r\n", "\n").encode("utf-8")
        b64 = base64.b64encode(data).decode()
        r = self.bash(f"mkdir -p $(dirname {remote_path}); echo '{b64}' | base64 -d > {remote_path} "
                      f"&& chmod {mode} {remote_path} && wc -c < {remote_path}", 120, True)
        if not r.ok:
            raise RuntimeError(f"Failed to write {remote_path}: {r.output}")
        log.ok(f"Wrote {remote_path} ({len(data)} bytes).")

    def put_file(self, local_path, remote_dir="/var/log", skip_same_size=True):
        """SFTP a file up, with progress. Needs the bash shell (SFTP does not work under Clish)."""
        if not os.path.isfile(local_path):
            raise FileNotFoundError(local_path)
        self.bash("true", 30, True)
        name = os.path.basename(local_path)
        size = os.path.getsize(local_path)
        remote = f"{remote_dir}/{name}"
        if skip_same_size:
            r = self.exec(f"stat -c %s {remote} 2>/dev/null || echo 0", 60, True)
            if re.sub(r"\D", "", r.output) == str(size):
                log.ok(f"{name} already on {self.host} with the same size - skipping the copy.")
                return remote
        log.step(f"Copying {name} ({size / 1048576:,.0f} MB) to {self.host}:{remote_dir} ...")
        t0 = time.time()
        state = {"next": 10}

        def progress(done, total):
            pct = int(done * 100 / total) if total else 100
            if pct >= state["next"]:
                log.info(f"    {pct}%  ({done / 1048576:,.0f} MB, {time.time() - t0:,.0f}s)")
                state["next"] += 10

        sftp = self.client.open_sftp()
        try:
            sftp.put(local_path, remote, callback=progress)
        finally:
            sftp.close()
        got = re.sub(r"\D", "", self.exec(f"stat -c %s {remote}", 60, True).output)
        if got != str(size):
            raise RuntimeError(f"Copy of {name} looks wrong: local {size} bytes, remote {got}.")
        log.ok(f"Copied {name} in {time.time() - t0:,.0f}s.")
        return remote
