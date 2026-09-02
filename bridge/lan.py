"""Finding a Roon core when the broadcast answer never arrives.

Omarchy enables ufw with `default deny incoming` on every install. Roon's
discovery works by broadcasting a SOOD query and reading the reply, and pyroon
sends that query from an unbound socket, so the reply lands on a random
ephemeral port. An inbound UDP packet to a random port is exactly what
`default deny incoming` drops.

The usual advice, `ufw allow 9003/udp`, opens the *destination* port and so
cannot match a reply addressed to port 47606. Only a source-port rule works.
That makes this the default state of the distribution the plugin targets: a
user with the core on another machine sees "No Roon core found" and no hint
why.

Outbound TCP is permitted by conntrack on the same firewall, so a direct
connection to the core's API port works when discovery does not. This sweeps
for one, and is deliberately narrow: only after discovery has already failed,
only subnets this machine is directly attached to, one pass, short timeouts.

Stdlib only.
"""

from __future__ import annotations

import concurrent.futures
import ipaddress
import shutil
import socket
import subprocess

ROON_API_PORT = 9330
SOOD_PORT = 9003

# A /24 is 254 hosts. Larger prefixes are not swept: a /16 is 65,000 connections
# and that is a port scan, not a fallback.
MAX_HOSTS = 512
CONNECT_TIMEOUT = 0.35
WORKERS = 128


def connected_subnets() -> list[str]:
    """IPv4 networks this machine is directly attached to, as CIDR strings.

    Read from `ip -o -4 addr`, so it reflects real interfaces rather than a
    guess derived from one address. Loopback and anything larger than MAX_HOSTS
    is dropped.
    """
    if not shutil.which("ip"):
        return []
    try:
        out = subprocess.run(["ip", "-o", "-4", "addr", "show", "scope", "global"],
                             capture_output=True, text=True, timeout=4).stdout
    except (OSError, subprocess.SubprocessError):
        return []

    nets = []
    for line in out.splitlines():
        parts = line.split()
        for token in parts:
            if "/" not in token:
                continue
            try:
                net = ipaddress.ip_network(token, strict=False)
            except ValueError:
                continue
            if net.version != 4 or net.is_loopback or net.num_addresses > MAX_HOSTS:
                continue
            cidr = str(net)
            if cidr not in nets:
                nets.append(cidr)
            break
    return nets


def _reachable(host: str, port: int, timeout: float) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def find_cores(port: int = ROON_API_PORT, subnets=None, timeout=CONNECT_TIMEOUT,
               workers: int = WORKERS, limit: int = 4) -> list[str]:
    """Hosts on a directly-attached subnet with the Roon API port open.

    An open 9330 is a candidate, not a confirmation: the caller still has to
    connect and pair, which is the real check. Stops early once `limit`
    candidates are found, because a home network has one core.
    """
    targets = []
    for cidr in (subnets if subnets is not None else connected_subnets()):
        try:
            net = ipaddress.ip_network(cidr, strict=False)
        except ValueError:
            continue
        # The size guard has to live here as well as in connected_subnets, or a
        # caller passing a prefix directly enumerates sixteen million hosts. A
        # /8 is not a fallback, it is a port scan, and it hangs.
        if net.version != 4 or net.num_addresses > MAX_HOSTS:
            continue
        for host in net.hosts():
            targets.append(str(host))
    if not targets:
        return []

    found = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(_reachable, h, port, timeout): h for h in targets}
        for future in concurrent.futures.as_completed(futures):
            try:
                if future.result():
                    found.append(futures[future])
                    if len(found) >= limit:
                        break
            except Exception:  # noqa: BLE001
                continue
        for future in futures:
            future.cancel()
    return sorted(found)


def firewall_hint() -> str:
    """Why discovery probably failed, when ufw is the reason.

    Deliberately says "likely" rather than proving it: confirming the drop means
    reading the kernel log, which needs privileges the plugin does not have and
    should not ask for.
    """
    if not shutil.which("ufw"):
        return ""
    try:
        state = subprocess.run(["systemctl", "is-active", "ufw"],
                               capture_output=True, text=True, timeout=4).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""
    if state != "active":
        return ""

    subnets = connected_subnets()
    where = subnets[0] if subnets else "192.168.1.0/24"
    return ("ufw is active. Roon answers discovery on a random port, so "
            "'ufw allow %d/udp' does not match the reply. Allow it by source "
            "port instead: sudo ufw allow proto udp from %s port %d"
            % (SOOD_PORT, where, SOOD_PORT))
