#!/usr/bin/env python3
"""
check_system_status.py
Checks system readiness for running Podman / NetBox.
"""

import os
import shutil
import subprocess
import sys

# ── ANSI colors ───────────────────────────────────────────────────────────────
GREEN  = "\033[92m"
RED    = "\033[91m"
YELLOW = "\033[93m"
CYAN   = "\033[96m"
BOLD   = "\033[1m"
RESET  = "\033[0m"

OK   = f"{GREEN}[  OK  ]{RESET}"
FAIL = f"{RED}[ FAIL ]{RESET}"
WARN = f"{YELLOW}[ WARN ]{RESET}"
INFO = f"{CYAN}[ INFO ]{RESET}"

# ── helpers ───────────────────────────────────────────────────────────────────

def run(cmd: str) -> tuple[int, str, str]:
    """Run a shell command and return (returncode, stdout, stderr)."""
    result = subprocess.run(
        cmd, shell=True, capture_output=True, text=True
    )
    return result.returncode, result.stdout.strip(), result.stderr.strip()


def header(title: str) -> None:
    width = 60
    print(f"\n{BOLD}{CYAN}{'═' * width}{RESET}")
    print(f"{BOLD}{CYAN}  {title}{RESET}")
    print(f"{BOLD}{CYAN}{'═' * width}{RESET}")


def row(status: str, label: str, detail: str = "") -> None:
    detail_str = f"  {YELLOW}→ {detail}{RESET}" if detail else ""
    print(f"  {status}  {label}{detail_str}")


# ── checks ────────────────────────────────────────────────────────────────────

results: dict[str, bool] = {}


# 1. PODMAN ───────────────────────────────────────────────────────────────────
def check_podman() -> None:
    header("1 / Podman")
    path = shutil.which("podman")
    if path:
        rc, out, _ = run("podman --version")
        ver = out if rc == 0 else "?"
        row(OK, "Podman is installed", f"{ver}  ({path})")
        results["podman"] = True
    else:
        row(FAIL, "Podman is NOT installed")
        results["podman"] = False


# 2. CGROUP v2 ─────────────────────────────────────────────────────────────────
def check_cgroup() -> None:
    header("2 / cgroup v2")

    rc, out, _ = run("mount | grep '^cgroup' | awk '{print $1}' | uniq")
    cgroup_types = set(out.splitlines()) if out else set()

    v2_file = os.path.exists("/sys/fs/cgroup/cgroup.controllers")

    rc2, out2, _ = run("stat -fc %T /sys/fs/cgroup/")
    fstype = out2.strip()

    is_v2 = v2_file or fstype == "cgroup2fs" or "cgroup2" in cgroup_types

    if is_v2:
        row(OK, "cgroup v2 is active", f"fstype={fstype}")
        results["cgroup_v2"] = True
    elif "cgroup" in cgroup_types and not is_v2:
        row(FAIL, "cgroup v1 detected (v2 required)",
            "Enable cgroup v2: add 'systemd.unified_cgroup_hierarchy=1' to GRUB")
        results["cgroup_v2"] = False
    else:
        row(WARN, "Cannot determine cgroup version",
            f"fstype={fstype}, mount={cgroup_types or 'none'}")
        results["cgroup_v2"] = False


# 3. PORTS ────────────────────────────────────────────────────────────────────
PORTS_TO_CHECK = [
    (80,  "tcp", "HTTP"),
    (443, "tcp", "HTTPS"),
]

def port_listening(port: int, proto: str) -> tuple[bool, str]:
    if proto == "tcp":
        rc, out, _ = run(f"ss -tlnH sport = :{port} 2>/dev/null")
    else:
        rc, out, _ = run(f"ss -ulnH sport = :{port} 2>/dev/null")
    listening = bool(out.strip())

    rc_fw, out_fw, _ = run(
        f"firewall-cmd --query-port={port}/{proto} 2>/dev/null"
    )
    fw_open = (rc_fw == 0 and "yes" in out_fw)

    rc_ipt, out_ipt, _ = run(
        f"iptables -C INPUT -p {proto} --dport {port} -j ACCEPT 2>/dev/null"
    )
    ipt_open = (rc_ipt == 0)

    detail_parts = []
    if listening:
        detail_parts.append("listening")
    if fw_open:
        detail_parts.append("firewalld: open")
    elif ipt_open:
        detail_parts.append("iptables: open")
    else:
        detail_parts.append("no firewall rule found or firewall inactive")

    return listening, ", ".join(detail_parts)


def check_ports() -> None:
    header("3 / Network ports")
    for port, proto, label in PORTS_TO_CHECK:
        listening, detail = port_listening(port, proto)
        key = f"port_{port}_{proto}"
        if listening:
            row(OK, f"Port {port}/{proto.upper()}  ({label})", detail)
            results[key] = True
        else:
            row(WARN, f"Port {port}/{proto.upper()}  ({label}) – not listening", detail)
            results[key] = False


# 4. net.ipv4.ip_unprivileged_port_start ──────────────────────────────────────
def check_unprivileged_port() -> None:
    header("4 / Unprivileged port binding (sysctl)")
    rc, out, _ = run("sysctl -n net.ipv4.ip_unprivileged_port_start 2>/dev/null")
    if rc == 0 and out.isdigit():
        val = int(out)
        if val <= 80:
            row(OK,
                f"net.ipv4.ip_unprivileged_port_start = {val}",
                "Non-root processes can bind port 80 and above")
            results["unprivileged_port"] = True
        else:
            row(FAIL,
                f"net.ipv4.ip_unprivileged_port_start = {val}",
                "Set to <= 80:  sysctl -w net.ipv4.ip_unprivileged_port_start=80")
            results["unprivileged_port"] = False
    else:
        row(WARN, "Cannot read sysctl net.ipv4.ip_unprivileged_port_start")
        results["unprivileged_port"] = False


# ── SUMMARY ───────────────────────────────────────────────────────────────────

def summary() -> None:
    header("SUMMARY")
    total = len(results)
    passed = sum(1 for v in results.values() if v)

    checks_labels = {
        "podman":            "Podman installed",
        "cgroup_v2":         "cgroup v2",
        "port_80_tcp":       "Port 80/TCP",
        "port_443_tcp":      "Port 443/TCP",
        "unprivileged_port": "Unprivileged port binding (sysctl)",
    }

    for key, label in checks_labels.items():
        status = OK if results.get(key) else FAIL
        row(status, label)

    color = GREEN if passed == total else (YELLOW if passed >= total - 2 else RED)
    print(f"\n  {color}{BOLD}Result: {passed}/{total} checks passed{RESET}\n")

    if passed < total:
        print(f"  {YELLOW}Fix the issues above before starting the Podman / NetBox environment.{RESET}\n")
    else:
        print(f"  {GREEN}System is ready to go! 🎉{RESET}\n")


# ── MAIN ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    print(f"\n{BOLD}  check_system_status.py  --  Podman / NetBox environment diagnostics{RESET}")
    check_podman()
    check_cgroup()
    check_ports()
    check_unprivileged_port()
    summary()
    sys.exit(0 if all(results.values()) else 1)