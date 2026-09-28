#!/usr/bin/env python3
"""Poll INDY orders, enrich them from the TMS feed, and store them in SQLite."""

from __future__ import annotations

import argparse
import gzip
import io
import json
import os
import sqlite3
import sys
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

BASE_URL = os.getenv("INDY_BASE_URL", "https://api-us.indy.systems").rstrip("/")
SITE_ID = int(os.getenv("INDY_SITE_ID", "352"))
DB_PATH = Path(os.getenv("INDY_DB_PATH", Path(__file__).with_name("palmyra_orders.sqlite3")))
POLL_SECONDS = int(os.getenv("INDY_POLL_SECONDS", "60"))
OVERLAP_MINUTES = int(os.getenv("INDY_OVERLAP_MINUTES", "5"))
INITIAL_LOOKBACK_MINUTES = int(os.getenv("INDY_INITIAL_LOOKBACK_MINUTES", "30"))
LOCAL_TIMEZONE = ZoneInfo(os.getenv("INDY_TIMEZONE", "America/New_York"))


def utc_now() -> datetime:
    return datetime.now(timezone.utc).replace(microsecond=0)


def parse_dt(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def http_json(url: str, *, method: str = "GET", body=None, headers=None):
    encoded = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(url, data=encoded, method=method, headers=headers or {})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.loads(response.read().decode("utf-8"))


class TokenProvider:
    def __init__(self, access_token: str | None = None):
        self.token = access_token or os.getenv("INDY_ACCESS_TOKEN")
        self.expires_at = float("inf") if self.token else 0.0

    def get(self) -> str:
        if self.token and time.time() < self.expires_at - 300:
            return self.token
        client_id = os.getenv("INDY_CLIENT_ID")
        client_secret = os.getenv("INDY_CLIENT_SECRET")
        if not client_id or not client_secret:
            raise RuntimeError(
                "Set INDY_CLIENT_ID and INDY_CLIENT_SECRET, or supply INDY_ACCESS_TOKEN."
            )
        result = http_json(
            BASE_URL + "/v1/oauth/token",
            method="POST",
            body={
                "grant_type": "client_credentials",
                "client_id": client_id,
                "client_secret": client_secret,
            },
            headers={"Content-Type": "application/json", "Accept": "application/json"},
        )
        self.token = result["access_token"]
        self.expires_at = time.time() + int(result.get("expires_in", 259200))
        return self.token


def connect_db() -> sqlite3.Connection:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(DB_PATH)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL")
    db.executescript(
        """
        CREATE TABLE IF NOT EXISTS showings (
            showing_id INTEGER PRIMARY KEY,
            site_id INTEGER NOT NULL,
            feature_id INTEGER,
            title TEXT,
            screen_id INTEGER,
            auditorium TEXT,
            showtime_utc TEXT,
            runtime_minutes INTEGER,
            rating TEXT,
            refreshed_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS orders (
            order_id INTEGER PRIMARY KEY,
            site_id INTEGER NOT NULL,
            transaction_time_utc TEXT,
            cinema_time_local TEXT,
            updated_at TEXT,
            raw_json TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS tickets (
            ticket_id INTEGER PRIMARY KEY,
            order_id INTEGER NOT NULL REFERENCES orders(order_id),
            showing_id INTEGER,
            seat_name TEXT,
            voided_at TEXT,
            updated_at TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_tickets_order ON tickets(order_id);
        CREATE INDEX IF NOT EXISTS idx_tickets_showing ON tickets(showing_id);
        CREATE INDEX IF NOT EXISTS idx_tickets_seat ON tickets(seat_name);

        CREATE TABLE IF NOT EXISTS sync_state (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """
    )
    return db


def refresh_showings(db: sqlite3.Connection) -> int:
    url = BASE_URL + "/tms/upcoming_showings.xml?" + urllib.parse.urlencode({"site_id": SITE_ID})
    with urllib.request.urlopen(url, timeout=60) as response:
        root = ET.fromstring(response.read())
    refreshed = utc_now().isoformat()
    count = 0
    for show in root.findall("show"):
        feature = show.find("feature")
        db.execute(
            """
            INSERT INTO showings (
                showing_id, site_id, feature_id, title, screen_id, auditorium,
                showtime_utc, runtime_minutes, rating, refreshed_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(showing_id) DO UPDATE SET
                feature_id=excluded.feature_id, title=excluded.title,
                screen_id=excluded.screen_id, auditorium=excluded.auditorium,
                showtime_utc=excluded.showtime_utc,
                runtime_minutes=excluded.runtime_minutes, rating=excluded.rating,
                refreshed_at=excluded.refreshed_at
            """,
            (
                int(show.get("extId")), SITE_ID,
                int(feature.get("extId")) if feature is not None and feature.get("extId") else None,
                feature.get("title") if feature is not None else None,
                int(show.get("screenId")) if show.get("screenId") else None,
                show.get("screenName"), show.get("time"),
                int(feature.get("runtime")) if feature is not None and feature.get("runtime") else None,
                feature.get("rating") if feature is not None else None,
                refreshed,
            ),
        )
        count += 1
    db.commit()
    return count


def prune_old_showings(db: sqlite3.Connection) -> tuple[int, int, int]:
    """Remove showings before today's local date and their stored order data."""
    today = datetime.now(LOCAL_TIMEZONE).date()
    old_ids = []
    for row in db.execute("SELECT showing_id, showtime_utc FROM showings"):
        if row["showtime_utc"] and parse_dt(row["showtime_utc"]).astimezone(LOCAL_TIMEZONE).date() < today:
            old_ids.append(row["showing_id"])
    if not old_ids:
        return 0, 0, 0
    placeholders = ",".join("?" for _ in old_ids)
    ticket_count = db.execute(
        f"SELECT COUNT(*) FROM tickets WHERE showing_id IN ({placeholders})", old_ids
    ).fetchone()[0]
    db.execute(f"DELETE FROM tickets WHERE showing_id IN ({placeholders})", old_ids)
    orphan_orders = db.execute(
        "SELECT COUNT(*) FROM orders WHERE NOT EXISTS "
        "(SELECT 1 FROM tickets WHERE tickets.order_id=orders.order_id)"
    ).fetchone()[0]
    db.execute(
        "DELETE FROM orders WHERE NOT EXISTS "
        "(SELECT 1 FROM tickets WHERE tickets.order_id=orders.order_id)"
    )
    db.execute(f"DELETE FROM showings WHERE showing_id IN ({placeholders})", old_ids)
    db.commit()
    return len(old_ids), ticket_count, orphan_orders


def decode_download(blob: bytes):
    if blob[:2] == b"PK":
        with zipfile.ZipFile(io.BytesIO(blob)) as archive:
            return [
                json.loads(archive.read(name).decode("utf-8-sig"))
                for name in archive.namelist() if not name.endswith("/")
            ]
    if blob[:2] == b"\x1f\x8b":
        blob = gzip.decompress(blob)
    return [json.loads(blob.decode("utf-8-sig"))]


def extract_orders(value):
    if isinstance(value, list):
        if not value or all(isinstance(item, dict) and "id" in item for item in value):
            return value
        output = []
        for item in value:
            output.extend(extract_orders(item))
        return output
    if isinstance(value, dict):
        for key in ("orders", "data", "results", "items", "records"):
            if key in value:
                result = extract_orders(value[key])
                if result:
                    return result
        if "id" in value:
            return [value]
    return []


def get_window(db: sqlite3.Connection) -> tuple[datetime, datetime]:
    end = utc_now()
    row = db.execute("SELECT value FROM sync_state WHERE key='last_success_utc'").fetchone()
    if row:
        start = parse_dt(row["value"]) - timedelta(minutes=OVERLAP_MINUTES)
    else:
        start = end - timedelta(minutes=INITIAL_LOOKBACK_MINUTES)
    return start, end


def fetch_orders(token: str, start: datetime, end: datetime):
    params = urllib.parse.urlencode({
        "site_ids": f"[{SITE_ID}]",
        "start_timestamp": start.strftime("%Y-%m-%d %H:%M:%S"),
        "end_timestamp": end.strftime("%Y-%m-%d %H:%M:%S"),
        "data_type": "orders",
        "filter": "updated",
    })
    url = BASE_URL + "/export_service?" + params
    headers = {"Authorization": "Bearer " + token, "Accept": "application/json"}
    result = None
    for attempt in range(30):
        result = http_json(url, headers=headers)
        if isinstance(result.get("data"), list) and result["data"]:
            break
        time.sleep(min(2 + attempt, 10))
    else:
        raise TimeoutError("INDY export was not ready after polling")

    orders = []
    for download_url in result["data"]:
        request = urllib.request.Request(download_url, headers={"Accept": "application/json"})
        with urllib.request.urlopen(request, timeout=120) as response:
            for payload in decode_download(response.read()):
                orders.extend(extract_orders(payload))
    return orders


def store_orders(db: sqlite3.Connection, orders) -> tuple[int, int]:
    order_count = ticket_count = 0
    for order in orders:
        order_id = order.get("id")
        if order_id is None:
            continue
        db.execute(
            """
            INSERT INTO orders (
                order_id, site_id, transaction_time_utc, cinema_time_local,
                updated_at, raw_json
            ) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(order_id) DO UPDATE SET
                transaction_time_utc=excluded.transaction_time_utc,
                cinema_time_local=excluded.cinema_time_local,
                updated_at=excluded.updated_at,
                raw_json=excluded.raw_json
            """,
            (
                int(order_id), int(order.get("site_id", SITE_ID)),
                order.get("transaction_timestamp"), order.get("cinema_date"),
                order.get("updated_at"), json.dumps(order, separators=(",", ":")),
            ),
        )
        order_count += 1
        for ticket in order.get("ticket_sales") or []:
            if ticket.get("id") is None:
                continue
            db.execute(
                """
                INSERT INTO tickets (
                    ticket_id, order_id, showing_id, seat_name, voided_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(ticket_id) DO UPDATE SET
                    order_id=excluded.order_id, showing_id=excluded.showing_id,
                    seat_name=excluded.seat_name, voided_at=excluded.voided_at,
                    updated_at=excluded.updated_at
                """,
                (
                    int(ticket["id"]), int(order_id), ticket.get("showing_id"),
                    ticket.get("seat_name"), ticket.get("voided_at"), ticket.get("updated_at"),
                ),
            )
            ticket_count += 1
    db.commit()
    return order_count, ticket_count


def sync_once(db: sqlite3.Connection, tokens: TokenProvider):
    showings = refresh_showings(db)
    removed_showings, removed_tickets, removed_orders = prune_old_showings(db)
    start, end = get_window(db)
    orders = fetch_orders(tokens.get(), start, end)
    order_count, ticket_count = store_orders(db, orders)
    db.execute(
        "INSERT INTO sync_state(key,value) VALUES('last_success_utc',?) "
        "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        (end.isoformat(),),
    )
    db.commit()
    print(
        f"{utc_now().isoformat()} synced {order_count} orders, {ticket_count} tickets; "
        f"cached {showings} showings; removed {removed_showings} expired showings, "
        f"{removed_tickets} tickets, {removed_orders} orders "
        f"({start.isoformat()} to {end.isoformat()})",
        flush=True,
    )


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
    s.showtime_utc
FROM tickets t
JOIN orders o ON o.order_id = t.order_id
LEFT JOIN showings s ON s.showing_id = t.showing_id
"""


def print_rows(rows):
    print(json.dumps([dict(row) for row in rows], indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("once", "run", "recent", "order", "showing"))
    parser.add_argument("value", nargs="?", help="Order ID, showing ID, or recent row count")
    parser.add_argument("--access-token-stdin", action="store_true", help="Read a bearer token from stdin")
    args = parser.parse_args()
    db = connect_db()

    if args.command in ("once", "run"):
        supplied_token = sys.stdin.readline().strip() if args.access_token_stdin else None
        tokens = TokenProvider(supplied_token)
        if args.command == "once":
            sync_once(db, tokens)
            return
        while True:
            started = time.monotonic()
            try:
                sync_once(db, tokens)
            except Exception as exc:
                print(f"{utc_now().isoformat()} sync failed: {exc}", file=sys.stderr, flush=True)
            time.sleep(max(1, POLL_SECONDS - (time.monotonic() - started)))

    elif args.command == "order":
        if not args.value:
            parser.error("order requires an order ID")
        print_rows(db.execute(LOOKUP_SQL + " WHERE o.order_id=? ORDER BY t.ticket_id", (args.value,)))
    elif args.command == "showing":
        if not args.value:
            parser.error("showing requires a showing ID")
        print_rows(db.execute(LOOKUP_SQL + " WHERE t.showing_id=? ORDER BY t.seat_name", (args.value,)))
    else:
        limit = int(args.value or 50)
        print_rows(db.execute(LOOKUP_SQL + " ORDER BY o.transaction_time_utc DESC, t.ticket_id LIMIT ?", (limit,)))


if __name__ == "__main__":
    main()
