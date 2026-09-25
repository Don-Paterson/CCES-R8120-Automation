"""Console + file logging in the same style as the PowerShell tools (timestamp, level)."""
import os
import sys
from datetime import datetime

COLOURS = {"STEP": "\033[96m", "OK": "\033[92m", "WARN": "\033[93m", "ERROR": "\033[91m", "INFO": "", "DIM": "\033[90m"}
RESET = "\033[0m"
_file = None
_colour = sys.stdout.isatty() and os.environ.get("NO_COLOR") is None
if _colour and os.name == "nt":
    os.system("")          # enables ANSI colours in the Windows console


def start(log_dir, name):
    global _file
    os.makedirs(log_dir, exist_ok=True)
    path = os.path.join(log_dir, f"{name}_{datetime.now():%Y%m%d-%H%M%S}.log")
    _file = open(path, "a", encoding="utf-8")
    log(f"Log file: {path}", "DIM")
    return path


def log(msg="", level="INFO"):
    stamp = f"{datetime.now():%H:%M:%S}"
    line = f"{stamp}  {msg}"
    if _colour and COLOURS.get(level):
        print(f"{COLOURS[level]}{line}{RESET}", flush=True)
    else:
        print(line, flush=True)
    if _file:
        _file.write(f"{datetime.now():%Y-%m-%d %H:%M:%S} {level:<5} {msg}\n")
        _file.flush()


def step(m): log(m, "STEP")
def ok(m): log(m, "OK")
def warn(m): log(m, "WARN")
def error(m): log(m, "ERROR")
def info(m): log(m, "INFO")
def dim(m): log(m, "DIM")


def block(text, level="INFO", prefix="    "):
    for l in (text or "").splitlines():
        if l.strip():
            log(prefix + l.rstrip(), level)
