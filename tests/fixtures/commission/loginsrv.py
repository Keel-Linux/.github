"""A web application of one login form, for the webshot.py test.

usage: python3 loginsrv.py PORT

/ is the login form (fields #u and #p, button #go); a POST of admin and
s3cret sets a cookie and goes to /admin, which says Dashboard with the
cookie and denied, with 403, without it. /challenge is a page that goes to / after
two seconds, as the challenge of Anubis does once it is solved.
"""

import http.server
import sys
import urllib.parse

FORM = ('<h1>Login</h1><form method=post><input id=u name=u>'
        '<input id=p name=p type=password><button id=go>Go</button></form>')


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def page(self, body, code=200, extra=None):
        self.send_response(code)
        self.send_header("Content-Type", "text/html")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body.encode())

    def do_GET(self):
        if "HeadlessChrome" in (self.headers.get("User-Agent") or ""):
            # as Anubis does: a browser that names itself headless is denied
            self.page("<h1>Access Denied</h1>", 403)
        elif self.path.startswith("/challenge"):
            self.page("<p>Making sure you are not a bot</p>"
                      "<script>setTimeout(function(){location='/'}, 2000)</script>")
        elif self.path.startswith("/admin"):
            good = "kc=ok" in (self.headers.get("Cookie") or "")
            self.page("<h1>%s</h1>" % ("Dashboard" if good else "denied"), 200 if good else 403)
        else:
            self.page(FORM)

    def do_POST(self):
        size = int(self.headers["Content-Length"])
        form = urllib.parse.parse_qs(self.rfile.read(size).decode())
        good = form.get("u") == ["admin"] and form.get("p") == ["s3cret"]
        if self.path.startswith("/stay"):
            # a login that fails and shows its form again
            self.page(FORM)
            return
        self.page("", 302, {"Location": "/admin",
                            "Set-Cookie": "kc=%s; Path=/" % ("ok" if good else "no")})


http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
