#!/usr/bin/python3 -I
"""The PVE host side of a VM pass of keel-commission: the screen of the VM
as text, a command in the guest, and a screenshot. Nothing here uses
`qm guest exec`: the QEMU guest agent of a Keel image refuses it (common
PR 87, decision 0099), and keel-commission tests the image as it is
published.

usage: vmhost.py screen VMID     print the text on the screen of the VM
       vmhost.py exec VMID       the first line of stdin is the root
                                 password; run the rest of stdin in the
                                 guest as root, over SSH, with bash --norc
                                 and the PATH of a login; its stdout and
                                 stderr come back, and its exit status is
                                 the exit status of vmhost.py
       vmhost.py shot VMID PNG   write the screen of the VM to PNG

keel-commission copies this file, screentext.py and ppm2png.py to
/tmp/kcVMID on the PVE host when it makes the VM, and runs
them there with the python3 of the host. Only text and PNG files cross the
link.

The screen is the picture of qm monitor screendump, read as text by
screentext.py. Every answer goes in as keys (qm monitor sendkey), as an
operator types it.

A guest command goes over SSH from the PVE host, as root with the root
password the first boot set (PermitRootLogin yes in the image). The
address comes from `qm agent VMID network-get-interfaces`, which the
allow-list of the agent keeps: the IPv6 addresses first, then the
IPv4 ones; of two or more, the first that answers on port 22 is used,
and it is kept in /tmp/kcVMID/address. The password goes to ssh through
SSH_ASKPASS, never on a command line. ssh tries the password once:
fail2ban of the image bans an address after 3 failed logins.

Exit 1 when the screen cannot be read or the guest cannot be reached, 124
when the command did not end in its time, 2 for a usage error.
"""

import ipaddress
import json
import os
import socket
import stat
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ppm2png  # noqa: E402
import screentext  # noqa: E402

PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
TIMEOUT = int(os.environ.get("KC_GUEST_TIMEOUT", "900"))
SSH_PORT = 22
PROBE_TIMEOUT = 5
ASKPASS = "#!/bin/sh\nprintf '%s\\n' \"$KC_SSH_SECRET\"\n"


def screendump(vmid, ppm):
    """Write the screen of VMID to PPM; True when the file is there"""
    if os.path.exists(ppm):
        os.remove(ppm)
    subprocess.run(["qm", "monitor", vmid],
                   input=("screendump %s\n" % ppm).encode(),
                   capture_output=True, check=False)
    return os.path.exists(ppm)


def screen(vmid):
    ppm = os.path.join(HERE, "screen.ppm")
    if not screendump(vmid, ppm):
        print("vmhost: no screendump of %s" % vmid, file=sys.stderr)
        return 1
    status = screentext.main(["screentext", ppm])
    os.remove(ppm)
    return status


def addresses(vmid):
    """The addresses of the guest as the agent gives them: the
    IPv6 ones first, then the IPv4 ones; [] when the agent gives none"""
    done = subprocess.run(["qm", "agent", vmid, "network-get-interfaces"],
                          capture_output=True, check=False)
    try:
        interfaces = json.loads(done.stdout or b"null")
    except ValueError:
        return []
    found = []
    for interface in interfaces if isinstance(interfaces, list) else []:
        for entry in interface.get("ip-addresses") or []:
            try:
                addr = ipaddress.ip_address(entry.get("ip-address", ""))
            except ValueError:
                continue
            if not (addr.is_loopback or addr.is_link_local
                    or addr.is_multicast or addr.is_unspecified):
                found.append(addr)
    found.sort(key=lambda addr: -addr.version)
    return [str(addr) for addr in found]


def reaches(addr):
    try:
        socket.create_connection((addr, SSH_PORT), PROBE_TIMEOUT).close()
    except OSError:
        return False
    return True


def address(vmid):
    """The address of the guest for SSH: the one kept from the last
    command while the agent still gives it, else the first that answers on
    port 22, else the first; None when the agent gives none"""
    found = addresses(vmid)
    if not found:
        return None
    kept = os.path.join(HERE, "address")
    if os.path.exists(kept):
        with open(kept, encoding="ascii") as handle:
            addr = handle.read().strip()
        if addr in found:
            return addr
    # with one address there is nothing to choose: ssh says when it fails
    chosen = found[0]
    if len(found) > 1:
        chosen = next((addr for addr in found if reaches(addr)), None)
        if chosen is None:
            return found[0]
    with open(kept, "w", encoding="ascii") as handle:
        handle.write(chosen + "\n")
    return chosen


def ssh_command(addr):
    return ["ssh", "-T", "-p", str(SSH_PORT),
            "-o", "PreferredAuthentications=password",
            "-o", "PubkeyAuthentication=no",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=" + os.path.join(HERE, "known_hosts"),
            "-o", "ConnectTimeout=10",
            "root@" + addr,
            "env PATH=%s bash --norc -s" % PATH]


def askpass():
    """The askpass program of ssh: it prints KC_SSH_SECRET"""
    path = os.path.join(HERE, "askpass")
    if os.path.lexists(path):
        os.remove(path)
    # owner only: read and run; O_EXCL, so no file that was there is used
    with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                      stat.S_IRWXU), "w", encoding="ascii") as handle:
        handle.write(ASKPASS)
    return path


def run(vmid):
    data = sys.stdin.buffer.read()
    secret, _, script = data.partition(b"\n")
    if not secret:
        print("vmhost: no root password on stdin", file=sys.stderr)
        return 2
    addr = address(vmid)
    if addr is None:
        print("vmhost: the guest agent of %s gives no address" % vmid,
              file=sys.stderr)
        return 1
    env = dict(os.environ, KC_SSH_SECRET=secret.decode(),
               SSH_ASKPASS=askpass(), SSH_ASKPASS_REQUIRE="force")
    env.setdefault("DISPLAY", ":0")
    try:
        done = subprocess.run(ssh_command(addr), input=script, env=env,
                              capture_output=True, timeout=TIMEOUT,
                              check=False)
    except subprocess.TimeoutExpired:
        return 124
    sys.stdout.buffer.write(done.stdout)
    sys.stderr.buffer.write(done.stderr)
    if done.returncode == 255:
        print("vmhost: ssh to %s failed" % addr, file=sys.stderr)
        return 1
    return done.returncode


def shot(vmid, png):
    ppm = png[:-4] + ".ppm" if png.endswith(".png") else png + ".ppm"
    screendump(vmid, ppm)
    status = ppm2png.main(["ppm2png", ppm, png])
    if os.path.exists(ppm):
        os.remove(ppm)
    return status


def main(argv):
    if argv[1:2] == ["screen"] and len(argv) == 3:
        return screen(argv[2])
    if argv[1:2] == ["exec"] and len(argv) == 3:
        return run(argv[2])
    if argv[1:2] == ["shot"] and len(argv) == 4:
        return shot(argv[2], argv[3])
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
