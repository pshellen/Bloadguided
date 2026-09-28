#!/usr/bin/env python3
"""Local preview server for the Indy Sign package layout."""
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError
import json
import os

PORT = 8765
ROOT = os.path.dirname(os.path.abspath(__file__))
GRAPHQL = "https://api-us.indy.systems/graphql"


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def do_GET(self):
        if self.path.startswith("/api/screen/"):
            screen_id = self.path.split("/api/screen/", 1)[1].split("?", 1)[0]
            self.proxy_screen(screen_id)
            return
        return super().do_GET()

    def proxy_screen(self, screen_id):
        query = (
            '{ screen(id: "%s") { name todaysShowings { time current past '
            "movie { name posterImage animatedPosterVideo rating ratingReason "
            "showingStatus duration } showingBadges { id title displayName } } } }"
        ) % screen_id
        body = json.dumps({"query": query}).encode("utf-8")
        req = Request(
            GRAPHQL,
            data=body,
            headers={
                "Content-Type": "application/json",
                "Accept": "application/graphql-response+json",
                "User-Agent": "indy-sign-preview/1.0",
            },
            method="POST",
        )
        try:
            with urlopen(req, timeout=10) as resp:
                data = resp.read()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)
        except (URLError, HTTPError, TimeoutError) as err:
            payload = json.dumps({"error": {"message": str(err)}}).encode("utf-8")
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(payload)

    def log_message(self, fmt, *args):
        print("[%s] %s" % (self.log_date_time_string(), fmt % args))


if __name__ == "__main__":
    os.chdir(ROOT)
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print("Preview: http://127.0.0.1:%d/preview.html" % PORT)
    server.serve_forever()
