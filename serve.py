#!/usr/bin/env python3
"""Local dev server for the TacoCrafts page.

Usage:  python serve.py [port]   (default 8000)
Then open http://localhost:8000 in a browser.
Run convert.py first so data.json exists.
"""
import http.server
import os
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
HOST = "localhost"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8000


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=ROOT, **k)

    def end_headers(self):
        # no-store so an in-game re-scan is visible on refresh without cache pain
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


def main():
    if not os.path.exists(os.path.join(ROOT, "data.json")):
        print("data.json not found. Run:  python convert.py   (after the addon has saved once)")
    print(f"Serving TacoCrafts at http://{HOST}:{PORT}  (Ctrl+C to stop)")
    http.server.HTTPServer((HOST, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
