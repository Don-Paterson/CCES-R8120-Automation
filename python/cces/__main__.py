"""py -3 -m cces [stage] [options]      (no stage = menu)

Stages: prereqs, dryrun, ftw, endpoint, jumbo, full, secondary, secondary-jumbo, packages
"""
import argparse
import os
import subprocess
import sys
import traceback

from . import __version__, config, log
from .stages import STAGES

MENU = [
    ("1", "prereqs",         "Pre-flight checks (read-only)"),
    ("2", "dryrun",          "A-EPM  - validate the answer file only"),
    (None, None, None),
    ("3", "ftw",             "A-EPM  - wizard, licence, contract, CPUSE agent   (Task 2A-1)"),
    ("4", "endpoint",        "A-EPM  - Endpoint + SmartEvent + NAT, install db  (Task 2A-2)"),
    ("5", "jumbo",           "A-EPM  - install the Jumbo (Take from settings)   (Task 2A-3)"),
    ("6", "full",            "A-EPM  - FULL BUILD: 3 + 4 + 5, no SmartConsole needed"),
    (None, None, None),
    ("7", "secondary",       "A-EPM-02 - build secondary management server"),
    ("8", "secondary-jumbo", "A-EPM-02 - build and install the Jumbo"),
    (None, None, None),
    ("P", "packages",        "Show CPUSE packages and the numbered list on a host (read-only)"),
]


def run_stage(s, name, **kw):
    log.start(s.LogPath, f"cces-{name}")
    log.dim(f"cces {__version__} - stage '{name}' - settings {s._path}")
    try:
        ok = STAGES[name](s, **kw)
    except KeyboardInterrupt:
        log.warn("Stopped by Ctrl+C.")
        return False
    except Exception as e:
        log.error(f"Stage '{name}' failed: {e}")
        log.block(traceback.format_exc(), "DIM")
        log.info("Re-running is safe - finished work is detected and skipped.")
        return False
    return bool(ok)


def menu(s):
    while True:
        print(f"\n  CCES R81.20 lab automation (Python {__version__})")
        print(f"  Jumbo: Take {s.JumboTake} from {s.JumboSource}\n")
        for key, _, text in MENU:
            print(f"   {key}   {text}" if key else "")
        print("\n   S   Edit lab settings    F   Open the folder    Q   Quit\n")
        c = input("  Choose: ").strip().upper()
        if c == "Q":
            return
        if c == "S":
            subprocess.call(["notepad.exe", s._path])
            s = config.load(s._path)
            continue
        if c == "F":
            os.startfile(s._root) if hasattr(os, "startfile") else None
            continue
        pick = [n for k, n, _ in MENU if k == c]
        if not pick:
            print("  Not an option.")
            continue
        kw = {}
        if pick[0] == "packages":
            kw["target"] = input("  Host [A-EPM / A-EPM-02 / A-SMS / IP] (A-EPM): ").strip() or "A-EPM"
        run_stage(s, pick[0], **kw)
        input("\n  Press Enter for the menu")


def main(argv=None):
    ap = argparse.ArgumentParser(prog="cces", description="CCES R81.20 lab automation")
    ap.add_argument("stage", nargs="?", choices=sorted(STAGES), help="omit for the menu")
    ap.add_argument("--settings", help="path to lab-settings.psd1")
    ap.add_argument("--target", default="A-EPM", help="jumbo/packages: A-EPM, A-EPM-02, A-SMS or an IP")
    ap.add_argument("--take", type=int, help="jumbo: override JumboTake")
    ap.add_argument("--source", choices=["auto", "cloud", "local"], help="jumbo: override JumboSource")
    ap.add_argument("--skip-license", action="store_true")
    ap.add_argument("--skip-contract", action="store_true")
    ap.add_argument("--skip-agent", action="store_true")
    ap.add_argument("--skip-nat", action="store_true")
    ap.add_argument("--skip-license-check", action="store_true")
    ap.add_argument("--install-license", action="store_true", help="secondary: install License02File")
    ap.add_argument("--apply-clish", action="store_true", help="ftw: also apply config/A-EPM_config.sh")
    ap.add_argument("--keep-bash", action="store_true", help="leave admin's shell as /bin/bash")
    a = ap.parse_args(argv)

    s = config.load(a.settings)
    if not a.stage:
        menu(s)
        return 0
    kw = {k: v for k, v in vars(a).items() if k not in ("stage", "settings") and v not in (None, False)}
    return 0 if run_stage(s, a.stage, **kw) else 1


if __name__ == "__main__":
    sys.exit(main())
