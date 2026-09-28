#!/usr/bin/env python3
"""Small guest-facing order lookup demo for the local INDY database."""

from __future__ import annotations

import argparse
import json
import sqlite3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse

ROOT = Path(__file__).resolve().parent
DB_PATH = ROOT / "palmyra_orders.sqlite3"
INDEX_PATH = ROOT / "web" / "index.html"

LOOKUP_SQL = """
SELECT
    o.order_id,
    o.cinema_time_local AS purchased_at,
    t.ticket_id,
    t.seat_name,
    t.showing_id,
    s.title,
    s.auditorium,
    s.screen_id,
    s.showtime_utc,
    s.runtime_minutes
FROM tickets t
JOIN orders o ON o.order_id = t.order_id
LEFT JOIN showings s ON s.showing_id = t.showing_id
WHERE o.order_id = ? AND t.voided_at IS NULL
ORDER BY t.showing_id, t.seat_name
"""


def lookup_order(order_id: str):
    db = sqlite3.connect(DB_PATH)
    db.row_factory = sqlite3.Row
    try:
        rows = [dict(row) for row in db.execute(LOOKUP_SQL, (order_id,))]
    finally:
        db.close()
    if not rows:
        return None
    groups = {}
    for row in rows:
        key = row["showing_id"]
        group = groups.setdefault(key, {
            "order_id": row["order_id"],
            "purchased_at": row["purchased_at"],
            "showing_id": row["showing_id"],
            "title": row["title"],
            "auditorium": row["auditorium"],
            "screen_id": row["screen_id"],
            "showtime_utc": row["showtime_utc"],
            "runtime_minutes": row["runtime_minutes"],
            "seats": [],
        })
        if row["seat_name"]:
            group["seats"].append(row["seat_name"])
    return {"order_id": rows[0]["order_id"], "showings": list(groups.values())}


class Handler(BaseHTTPRequestHandler):
    def send_bytes(self, status, body, content_type):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/":
            self.send_bytes(200, INDEX_PATH.read_bytes(), "text/html; charset=utf-8")
            return
        if path == "/api/health":
            body = json.dumps({"ok": DB_PATH.exists()}).encode()
            self.send_bytes(200, body, "application/json")
            return
        if path.startswith("/api/order/"):
            order_id = unquote(path[len("/api/order/"):]).strip()
            if not order_id.isdigit():
                self.send_bytes(400, b'{"error":"Enter a numeric order number."}', "application/json")
                return
            result = lookup_order(order_id)
            if result is None:
                self.send_bytes(404, b'{"error":"Order not found in the local cache."}', "application/json")
                return
            self.send_bytes(200, json.dumps(result).encode(), "application/json")
            return
        self.send_bytes(404, b"Not found", "text/plain; charset=utf-8")

    def log_message(self, format, *args):
        print("lookup:", format % args)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    if not DB_PATH.exists():
        raise SystemExit(f"Database not found: {DB_PATH}. Run collector.py once first.")
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"Guest lookup demo: http://{args.host}:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
