#!/usr/bin/python3 -I
"""The PVE host side of a VM pass of keel-commission: the screen of tty1
read through the QEMU guest agent, a command in the guest, and a screenshot.

usage: qga.py screen VMID       print the text on tty1 of the guest
       qga.py exec VMID         run the script on stdin in the guest as root,
                                with bash --norc and the PATH of a login;
                                its stdout and stderr come back, and its exit
                                status is the exit status of qga.py
       qga.py shot VMID PNG     write the screen of the VM to PNG

keel-commission copies this file and ppm2png.py to /tmp/kcVMID on the PVE
host when it makes the VM, and runs them there with the python3 of the
host: `qm guest exec` answers in JSON, and only the text crosses the link.

The screen is read from /dev/vcs1, the text of tty1 as the kernel keeps
it: the agent reads it, and only reads. Every answer goes in as keys
(qm monitor sendkey), as an operator types it.

Exit 1 when the agent does not answer, 124 when the command did not end
in its time, 2 for a usage error.
"""

import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ppm2png  # noqa: E402

PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SCREEN = ('c=$(stty -F /dev/tty1 size | cut -d" " -f2); '
          'fold -w "${c:-80}" /dev/vcs1')
TIMEOUT = os.environ.get("KC_GUEST_TIMEOUT", "900")


def agent(vmid, args, stdin=None):
    """The answer of `qm guest exec`, or None when the agent gave none"""
    command = ["qm", "guest", "exec", vmid] + args
    try:
        done = subprocess.run(command, input=stdin, capture_output=True,
                              check=False)
        answer = json.loads(done.stdout or b"null")
    except (OSError, ValueError):
        return None
    return answer if isinstance(answer, dict) else None


def screen(vmid):
    answer = agent(vmid, ["--timeout", "20", "--", "sh", "-c", SCREEN])
    if not answer or answer.get("exitcode") != 0:
        return 1
    text = answer.get("out-data", "")
    sys.stdout.write("".join(c if c.isprintable() or c == "\n" else " " for c in text))
    return 0


def run(vmid):
    answer = agent(vmid, ["--pass-stdin", "1", "--timeout", TIMEOUT, "--",
                          "env", "PATH=" + PATH, "bash", "--norc", "-s"],
                   sys.stdin.buffer.read())
    if not answer:
        print("qga: the guest agent of %s does not answer" % vmid, file=sys.stderr)
        return 1
    sys.stdout.write(answer.get("out-data", ""))
    sys.stderr.write(answer.get("err-data", ""))
    if not answer.get("exited"):
        return 124
    return int(answer.get("exitcode", 1))


def shot(vmid, png):
    ppm = png[:-4] + ".ppm" if png.endswith(".png") else png + ".ppm"
    subprocess.run(["qm", "monitor", vmid], input=("screendump %s\n" % ppm).encode(),
                   capture_output=True, check=False)
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
