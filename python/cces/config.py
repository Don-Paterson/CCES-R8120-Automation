"""Read config/lab-settings.psd1 - the single settings file shared with the PowerShell tools.

Only the subset of PowerShell data-file syntax that lab-settings.psd1 uses is supported:
    Key = 'single quoted'   Key = "double quoted"   Key = $true / $false   Key = 123
Comments (# ... and <# ... #>) are ignored.
"""
import os
import re

DEFAULTS = {
    "AEpmName": "A-EPM", "AEpmIp": "10.1.1.103",
    "AEpm02Name": "A-EPM-02", "AEpm02Ip": "10.1.1.104",
    "ASmsIp": "10.1.1.101",
    "GaiaUser": "admin",
    "MgmtAdminUser": "cpadmin",
    "AEpmObjectName": "A-EPM", "AEpmNatIp": "203.0.113.103",
    "EnableEndpointPolicy": True, "EnableSmartEventServer": False,
    "EnableSmartEventCorrelation": True, "EnableLoggingAndStatus": True,
    "ToolsPath": r"C:\Users\Admin\Desktop\Check Point Tools",
    "LicenseFile": r"Licenses\A-EPM.lic", "License02File": r"Licenses\A-EPM-02.lic",
    "ContractFile": r"Licenses\ServiceContract.xml",
    "DeploymentAgent": "DeploymentAgent_000002337_1.tgz",
    "JumboBundle": "Check_Point_R81_20_JUMBO_HF_MAIN_Bundle_T26_FULL.tar",
    "JumboTake": 170,            # which Jumbo the Jumbo stage installs
    "JumboSource": "Cloud",      # Cloud = CPUSE downloads it; Local = import JumboBundle from ToolsPath
    "LogPath": r"C:\CCES-Automation-Logs",
    "RestoreClishShell": True,
}

_LINE = re.compile(r"""^\s*([A-Za-z_]\w*)\s*=\s*(?:'((?:[^']|'')*)'|"((?:[^"`]|`.)*)"|(\$true|\$false)|(-?\d+))\s*$""", re.I)


def parse_psd1(text):
    text = re.sub(r"<#.*?#>", "", text, flags=re.S)
    out = {}
    for raw in text.splitlines():
        line = raw.split("#", 1)[0] if not re.search(r"""['"]""", raw) else raw
        m = _LINE.match(line.rstrip())
        if not m:
            # a trailing comment after a quoted value
            m = _LINE.match(re.sub(r"""(['"])\s*#.*$""", r"\1", raw).rstrip())
            if not m:
                continue
        key, sq, dq, b, n = m.groups()
        if sq is not None:
            val = sq.replace("''", "'")
        elif dq is not None:
            val = dq.replace("`\"", '"').replace("``", "`")
        elif b is not None:
            val = b.lower() == "$true"
        else:
            val = int(n)
        out[key] = val
    return out


class Settings(dict):
    """dict with defaults, plus attribute access: s.AEpmIp"""

    def __getattr__(self, k):
        try:
            return self[k]
        except KeyError:
            raise AttributeError(k)

    def path(self, *parts):
        return os.path.join(*parts)


def load(path=None):
    if not path:
        here = os.path.dirname(os.path.abspath(__file__))
        path = os.path.normpath(os.path.join(here, "..", "..", "config", "lab-settings.psd1"))
    s = Settings(DEFAULTS)
    with open(path, encoding="utf-8-sig") as f:
        s.update(parse_psd1(f.read()))
    s["_path"] = path
    s["_root"] = os.path.normpath(os.path.join(os.path.dirname(path), ".."))
    return s
