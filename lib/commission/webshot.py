#!/usr/bin/python3 -I
"""Take the web screenshots of a commissioning run with headless Chromium.

usage: webshot.py HOST OUTDIR FIRST < SHOTS

SHOTS has one line per screenshot, the `shot` lines of contract.py tsv:

    shot  NAME  SCHEME  PORT  PATH  AFTER  USER_FIELD  USER  PASS_FIELD  SECRET
          SUBMIT  WAIT  TEXT

HOST is the address of the machine (an IPv6 address without brackets is
put in brackets). Each page is opened at SCHEME://HOST:PORT/PATH in a
window of 1280x800 and written to OUTDIR/web-NN-NAME.png, NN counted from
FIRST, WAIT seconds after it has loaded. A shot with a login waits until
the page shows USER_FIELD (at most KC_WEB_WAIT seconds; a field that is in
the page but hidden does not count, and the login is then not tried), fills
USER_FIELD and PASS_FIELD (CSS selectors),
clicks SUBMIT, and writes a second screenshot, web-NN-NAME-after.png, of
AFTER (or of the page the login went to). That page must answer with an
HTTP status below 400 and must not show PASS_FIELD again. When TEXT is
not empty, the last page (the shot's, or the after-login one) must show it,
and its shot is taken once it shows it (at most KC_WEB_WAIT seconds). Every
stylesheet link of a page shot, of the page's own origin, must have rules
that the browser can read, and no stylesheet request may answer 400 or more.
The password is the value of the
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

# The user agent of a desktop Chrome. Headless Chromium names itself
# HeadlessChrome, and Anubis, in front of a cloud node, denies that name
# (BR1 and BR2, 2026-11-06): the operator's browser is what the gallery
# shows, so the shots ask as one.
USER_AGENT = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko)"
              " Chrome/140.0.0.0 Safari/537.36")
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
                "--user-agent=" + USER_AGENT,
                "--user-data-dir=" + self.profile]
        if proxy:
            args.append("--proxy-server=" + proxy)
        args.append("about:blank")
        self.process = subprocess.Popen(args, stdout=subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL)
        self.next_id = 0
        # the answers to the stylesheet requests of the page: a stylesheet
        # that did not load is said with what the browser got for it
        self.sheets = {}
        self.ws = Socket(self.page_socket(), wait)
        self.call("Page.enable")
        self.call("Network.enable")
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
            self.note(message)
            if message.get("id") == mine:
                if "error" in message:
                    raise OSError("%s: %s" % (method, message["error"].get("message")))
                return message.get("result", {})

    def note(self, message):
        """Keep the events of the stylesheet requests of the page"""
        event, params = message.get("method"), message.get("params", {})
        if event == "Network.responseReceived" and params.get("type") == "Stylesheet":
            response = params.get("response", {})
            self.sheets[response.get("url")] = {
                "id": params.get("requestId"), "status": response.get("status"),
                "type": response.get("mimeType")}
        elif event == "Network.loadingFailed" and params.get("type") == "Stylesheet":
            for sheet in self.sheets.values():
                if sheet.get("id") == params.get("requestId"):
                    sheet["error"] = params.get("errorText")
                    return
            self.sheets[params.get("requestId")] = {
                "id": params.get("requestId"), "error": params.get("errorText")}

    def answer(self, url):
        """What the browser got for the stylesheet URL: the status, the type
        and the first bytes, or the error of the request"""
        sheet = self.sheets.get(url)
        if sheet is None:
            return "no answer"
        if sheet.get("status") is None:
            return "failed: %s" % sheet.get("error")
        start = ""
        try:
            body = self.call("Network.getResponseBody", requestId=sheet["id"])
            data = body.get("body", "")
            if body.get("base64Encoded"):
                data = base64.b64decode(data).decode("utf-8", "replace")
            start = " ".join(data[:80].split())
        except OSError:
            start = "(no body)"
        text = "status %s, %s, starts %s" % (sheet["status"], sheet.get("type"), start)
        if sheet.get("error"):
            text += ", failed: %s" % sheet["error"]
        return text

    def not_css(self):
        """The stylesheets of the page that the server answered with a type
        other than text/css: Chromium keeps a sheet of 0 rules for them that
        it can read, as for an empty CSS file (Anubis's challenge, replica,
        BR2, 2026-11-07)"""
        return [url for url, sheet in self.sheets.items()
                if sheet.get("status") is not None
                and (sheet.get("type") or "").split(";")[0].strip() != "text/css"]

    def evaluate(self, expression):
        result = self.call("Runtime.evaluate", expression=expression,
                           returnByValue=True)
        return result.get("result", {}).get("value")

    def settle(self):
        """Wait until the page has loaded, then until it asks for nothing
        more: the count of its requests stays the same for two seconds.
        Webmin's dashboard comes by requests after the document has loaded,
        and the after-login shot of a loaded host showed the menu and no
        dashboard (BR1 and BR2, 2026-11-06)."""
        deadline = time.time() + self.wait
        while time.time() < deadline:
            if self.evaluate("document.readyState") == "complete":
                break
            time.sleep(0.5)
        last, still = None, 0
        while time.time() < deadline and still < 2:
            count = self.evaluate("performance.getEntriesByType('resource').length")
            still = still + 1 if count == last else 0
            last = count
            if still < 2:
                time.sleep(1)
        time.sleep(0.5)

    def open(self, url):
        self.sheets = {}
        result = self.call("Page.navigate", url=url)
        if result.get("errorText"):
            raise OSError("%s: %s" % (url, result["errorText"]))
        self.settle()

    def wait_for(self, selector):
        """Wait up to the browser's wait until the page shows SELECTOR. A
        cloud node puts Anubis in front: its challenge page comes first, and
        the login form only once the browser has solved it (BR1 and BR2,
        2026-11-06). The login page of Odoo 18 has its form in the page but
        hidden, and blocks the click of its button, until its lazy script
        has loaded: on a first view with a slow standby the form was filled
        and clicked before the page showed it, and no login was made (odoo
        cloud_simple, release A3, 2026-11-10). An element that has no box
        on the page (display: none, on it or around it) does not count.
        True when it came."""
        deadline = time.time() + self.wait
        probe = ("(function(s){var e=document.querySelector(s);"
                 " return !!(e && e.getClientRects().length);})(%s)"
                 % json.dumps(selector))
        while time.time() < deadline:
            if self.evaluate(probe):
                return True
            time.sleep(0.5)
        return False

    def wait_text(self, text):
        """Wait up to the browser's wait until the page shows TEXT. Webmin's
        dashboard on a VM of BR2 came after the page had stayed still, and
        the after-login shot showed the menu only (2026-11-06). True when
        it came."""
        deadline = time.time() + self.wait
        probe = "document.body.innerText.includes(%s)" % json.dumps(text)
        while time.time() < deadline:
            if self.evaluate(probe):
                return True
            time.sleep(0.5)
        return False

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

    def status(self):
        """The HTTP status of the page's document, 0 when it is not known"""
        return int(self.evaluate(
            "(performance.getEntriesByType('navigation')[0] || {}).responseStatus || 0") or 0)

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
    (name, scheme, port, path, after, user_field, user, pass_field, secret, submit, wait,
     text) = fields
    wait = int(wait or 0)
    lines = []
    first = "web-%02d-%s.png" % (number, name)
    browser.open(url_of(host, scheme, port, path))
    shown = True
    if user_field:
        shown = browser.wait_for(user_field)
    elif text:
        browser.wait_text(text)
    time.sleep(wait)
    browser.shot(os.path.join(outdir, first))
    if not shown:
        # the shot is the evidence: a login on a form that the page does not
        # show does nothing, and the failure would name the page after it
        raise OSError("the field %s did not show in %d s, so the login was not tried"
                      % (user_field, browser.wait))
    styled(browser, path)
    if not user_field:
        lines.append("%02d\tweb-%s\t%s\topen %s" % (number, name, first, path))
        shows(browser, path, text)
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
    if text:
        browser.wait_text(text)
    time.sleep(wait)
    browser.shot(os.path.join(outdir, second))
    styled(browser, after or "the page the login opened")
    lines.append("%02d\tweb-%s-after\t%s\tafter the login: %s"
                 % (number, name, second, after or "the page the login opened"))
    # the shot is written, as evidence, before the page is judged: a login
    # that Coraza refused was a 403 page, and the run passed with it (BR1
    # and BR2, 2026-11-06)
    status = browser.status()
    if status >= 400:
        raise OSError("after the login: %s answered HTTP %d"
                      % (after or "the page the login opened", status))
    if browser.evaluate("document.querySelector(%s) !== null" % json.dumps(pass_field)):
        raise OSError("after the login: the password field %s is still on the page"
                      % pass_field)
    shows(browser, after or "the page the login opened", text)
    return lines


# the stylesheet links of the page that did not load, and the stylesheet
# requests that answered 400 or more, as "URL" or "URL STATUS". Chromium
# keeps a sheet for a link that got an error or a page that is not CSS
# (a 404 page, or Anubis's challenge), but its rules cannot be read: a
# link of the page's own origin whose rules cannot be read did not load. An
# empty CSS file has 0 rules and loaded. The rules of a link of another
# origin cannot be read at all: only its status counts, and it is 0 when
# that origin does not allow timing.
UNSTYLED = """(function () {
  var bad = [];
  document.querySelectorAll('link[rel~="stylesheet"]').forEach(function (l) {
    var rules = -1;
    try {
      if (new URL(l.href, location.href).origin !== location.origin) { return; }
      rules = l.sheet ? l.sheet.cssRules.length : -1;
    } catch (e) { rules = -1; }
    if (rules < 0) { bad.push(l.href); }
  });
  performance.getEntriesByType('resource').forEach(function (e) {
    if (e.initiatorType === 'link' && e.responseStatus >= 400) {
      bad.push(e.name + ' ' + e.responseStatus);
    }
  });
  return bad;
})()"""


def styled(browser, where):
    """Raise when a stylesheet of the page did not load. The login page of a
    cloud advanced replica was shot with no style, and the run counted it
    (wordpress, BR2, 2026-11-07). The shot is written before: it is the
    evidence of the failure."""
    bad = browser.evaluate(UNSTYLED) or []
    bad = bad + [url for url in browser.not_css() if url not in bad]
    if bad:
        said = ["%s (%s)" % (item, browser.answer(str(item).split(" ")[0]))
                for item in bad]
        raise OSError("%s has a stylesheet that did not load: %s"
                      % (where, ", ".join(said)))


def shows(browser, where, text):
    """Raise when TEXT is not empty and the page does not show it"""
    if text and not browser.evaluate("document.body.innerText.includes(%s)"
                                     % json.dumps(text)):
        raise OSError("%s does not show %r" % (where, text))


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
            fields = (row[1:] + [""] * 12)[:12]
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
