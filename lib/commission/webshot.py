#!/usr/bin/python3 -I
"""Take the web screenshots of a commissioning run with headless Chromium.

usage: webshot.py HOST OUTDIR FIRST < SHOTS

SHOTS has one line per screenshot, the `shot` lines of contract.py tsv:

    shot  NAME  SCHEME  PORT  PATH  AFTER  USER_FIELD  USER  PASS_FIELD  SECRET
          SUBMIT  WAIT

HOST is the address of the machine (an IPv6 address without brackets is
put in brackets). Each page is opened at SCHEME://HOST:PORT/PATH in a
window of 1280x800 and written to OUTDIR/web-NN-NAME.png, NN counted from
FIRST, WAIT seconds after it has loaded. A shot with a login fills USER_FIELD and PASS_FIELD (CSS selectors),
clicks SUBMIT, and writes a second screenshot, web-NN-NAME-after.png, of
AFTER (or of the page the login went to). The password is the value of the
environment variable KC_SECRET_SECRET: it goes to the browser over the
DevTools socket only, and never to a file, an argument or stdout.

stdout gets one line per screenshot written, for the guide:

    NN  LABEL  FILE  ANSWER

Environment: KC_CHROMIUM, the browser (chromium, chromium-browser or
google-chrome on the PATH); KC_WEB_PROXY, a proxy for the browser, such
as socks5://127.0.0.1:1080 (an ssh -D tunnel through the PVE host);
KC_WEB_WAIT, the seconds a page may take to load (30).

Exit 0 when every page was written, 1 when one was not (the reason goes to
stderr and the others are still taken), 2 for a usage error or no browser.

Only the standard library is used: the DevTools protocol is spoken over a
small WebSocket client of its own.
"""

import base64
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

WIDTH, HEIGHT = 1280, 800


class Socket:
    """A client WebSocket: text frames out, text frames in, no extensions"""

    def __init__(self, url, timeout):
        parts = urllib.parse.urlsplit(url)
        self.sock = socket.create_connection((parts.hostname, parts.port),
                                             timeout=timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        request = ("GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\n"
                   "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
                   "Sec-WebSocket-Version: 13\r\n\r\n"
                   % (parts.path, parts.hostname, parts.port, key))
        self.sock.sendall(request.encode())
        head = b""
        while b"\r\n\r\n" not in head:
            data = self.sock.recv(1)
            if not data:
                raise OSError("the browser closed the DevTools socket")
            head += data
        if b" 101 " not in head.split(b"\r\n", 1)[0]:
            raise OSError("the browser refused the DevTools socket")

    def send(self, text):
        data = text.encode()
        mask = os.urandom(4)
        size = len(data)
        if size < 126:
            head = struct.pack("!BB", 0x81, 0x80 | size)
        elif size < 65536:
            head = struct.pack("!BBH", 0x81, 0x80 | 126, size)
        else:
            head = struct.pack("!BBQ", 0x81, 0x80 | 127, size)
        body = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        self.sock.sendall(head + mask + body)

    def exact(self, size):
        data = b""
        while len(data) < size:
            more = self.sock.recv(size - len(data))
            if not more:
                raise OSError("the browser closed the DevTools socket")
            data += more
        return data

    def receive(self):
        message = b""
        while True:
            first, second = self.exact(2)
            size = second & 0x7F
            if size == 126:
                size = struct.unpack("!H", self.exact(2))[0]
            elif size == 127:
                size = struct.unpack("!Q", self.exact(8))[0]
            payload = self.exact(size)
            message += payload
            if first & 0x80:
                return message.decode()


class Browser:
    """One headless Chromium with one page, driven over DevTools"""

    def __init__(self, binary, proxy, wait):
        self.wait = wait
        self.profile = tempfile.mkdtemp(prefix="kc-chromium-")
        args = [binary, "--headless=new", "--disable-gpu", "--no-first-run",
                "--no-default-browser-check", "--ignore-certificate-errors",
                "--hide-scrollbars", "--window-size=%d,%d" % (WIDTH, HEIGHT),
                "--remote-debugging-port=0",
                "--user-data-dir=" + self.profile]
        if proxy:
            args.append("--proxy-server=" + proxy)
        args.append("about:blank")
        self.process = subprocess.Popen(args, stdout=subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL)
        self.next_id = 0
        self.ws = Socket(self.page_socket(), wait)
        self.call("Page.enable")
        self.call("Emulation.setDeviceMetricsOverride", width=WIDTH,
                  height=HEIGHT, deviceScaleFactor=1, mobile=False)

    def page_socket(self):
        port_file = os.path.join(self.profile, "DevToolsActivePort")
        deadline = time.time() + self.wait
        while time.time() < deadline:
            if os.path.exists(port_file):
                with open(port_file, encoding="ascii") as handle:
                    port = handle.readline().strip()
                if port:
                    break
            time.sleep(0.2)
        else:
            raise OSError("the browser opened no DevTools port")
        # no proxy of the environment: the DevTools port is on this host
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        while time.time() < deadline:
            try:
                with opener.open("http://127.0.0.1:%s/json/list" % port,
                                 timeout=5) as answer:
                    pages = [p for p in json.load(answer) if p.get("type") == "page"]
            except (OSError, ValueError):
                pages = []
            if pages:
                return pages[0]["webSocketDebuggerUrl"]
            time.sleep(0.2)
        raise OSError("the browser has no page on its DevTools port")

    def call(self, method, **params):
        self.next_id += 1
        mine = self.next_id
        self.ws.send(json.dumps({"id": mine, "method": method, "params": params}))
        while True:
            message = json.loads(self.ws.receive())
            if message.get("id") == mine:
                if "error" in message:
                    raise OSError("%s: %s" % (method, message["error"].get("message")))
                return message.get("result", {})

    def evaluate(self, expression):
        result = self.call("Runtime.evaluate", expression=expression,
                           returnByValue=True)
        return result.get("result", {}).get("value")

    def settle(self):
        """Wait until the page has loaded and stayed still for a second"""
        deadline = time.time() + self.wait
        while time.time() < deadline:
            if self.evaluate("document.readyState") == "complete":
                break
            time.sleep(0.5)
        time.sleep(1.5)

    def open(self, url):
        result = self.call("Page.navigate", url=url)
        if result.get("errorText"):
            raise OSError("%s: %s" % (url, result["errorText"]))
        self.settle()

    def login(self, user_field, user, pass_field, password, submit):
        fill = ("(function(s, v){var e=document.querySelector(s); if(!e) return false;"
                " e.focus(); e.value=v; e.dispatchEvent(new Event('input',{bubbles:true}));"
                " e.dispatchEvent(new Event('change',{bubbles:true})); return true;})")
        for selector, value in ((user_field, user), (pass_field, password)):
            if not self.evaluate("%s(%s, %s)" % (fill, json.dumps(selector),
                                                 json.dumps(value))):
                raise OSError("no field %s on the page" % selector)
        if not self.evaluate("(function(s){var e=document.querySelector(s);"
                             " if(!e) return false; e.click(); return true;})(%s)"
                             % json.dumps(submit)):
            raise OSError("no button %s on the page" % submit)
        time.sleep(1)
        self.settle()

    def shot(self, path):
        data = self.call("Page.captureScreenshot", format="png")["data"]
        with open(path, "wb") as handle:
            handle.write(base64.b64decode(data))

    def close(self):
        self.process.kill()
        self.process.wait()
        shutil.rmtree(self.profile, ignore_errors=True)


def url_of(host, scheme, port, path):
    if ":" in host and not host.startswith("["):
        host = "[%s]" % host
    return "%s://%s:%s%s" % (scheme, host, port, path)


def take(browser, host, outdir, number, fields):
    """Take one shot (and its after-login shot); return the guide lines"""
    name, scheme, port, path, after, user_field, user, pass_field, secret, submit, wait = fields
    wait = int(wait or 0)
    lines = []
    first = "web-%02d-%s.png" % (number, name)
    browser.open(url_of(host, scheme, port, path))
    time.sleep(wait)
    browser.shot(os.path.join(outdir, first))
    if not user_field:
        lines.append("%02d\tweb-%s\t%s\topen %s" % (number, name, first, path))
        return lines
    lines.append("%02d\tweb-%s\t%s\tuser %s, the %s secret"
                 % (number, name, first, user, secret))
    password = os.environ.get("KC_SECRET_" + secret)
    if password is None:
        raise OSError("no value for secret %s" % secret)
    browser.login(user_field, user, pass_field, password, submit)
    if after:
        browser.open(url_of(host, scheme, port, after))
    second = "web-%02d-%s-after.png" % (number, name)
    time.sleep(wait)
    browser.shot(os.path.join(outdir, second))
    lines.append("%02d\tweb-%s-after\t%s\tafter the login: %s"
                 % (number, name, second, after or "the page the login opened"))
    return lines


def binary():
    for name in (os.environ.get("KC_CHROMIUM"), "chromium", "chromium-browser",
                 "google-chrome"):
        if name and shutil.which(name):
            return shutil.which(name)
    return None


def main(argv):
    if len(argv) != 4 or not argv[3].isdigit():
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    host, outdir, number = argv[1], argv[2], int(argv[3])
    found = binary()
    if not found:
        print("webshot: no chromium, chromium-browser or google-chrome", file=sys.stderr)
        return 2
    rows = [line.rstrip("\n").split("\t") for line in sys.stdin if line.startswith("shot\t")]
    os.makedirs(outdir, exist_ok=True)
    status = 0
    try:
        browser = Browser(found, os.environ.get("KC_WEB_PROXY", ""),
                          int(os.environ.get("KC_WEB_WAIT", "30")))
    except OSError as error:
        print("webshot: %s" % error, file=sys.stderr)
        return 1
    try:
        for row in rows:
            fields = (row[1:] + [""] * 11)[:11]
            try:
                for line in take(browser, host, outdir, number, fields):
                    print(line, flush=True)
            except (OSError, ValueError, KeyError, IndexError) as error:
                print("webshot: %s: %s" % (fields[0], error), file=sys.stderr)
                status = 1
            number += 1
    finally:
        browser.close()
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv))
