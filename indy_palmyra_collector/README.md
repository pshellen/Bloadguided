# INDY Palmyra Order Collector

This Python service polls INDY every minute, downloads updated Palmyra orders,
joins each ticket's `showing_id` to the TMS schedule, and stores the result in a
local SQLite database.

It uses only Python's standard library; no packages need to be installed.

## Configuration

Set the permanent OAuth client credentials in the service environment:

```bash
export INDY_CLIENT_ID='...'
export INDY_CLIENT_SECRET='...'
```

Do not put the secret directly in this source folder. The app requests a new
three-day bearer token automatically and refreshes it before expiry.

Optional settings:

```bash
export INDY_SITE_ID=352
export INDY_POLL_SECONDS=60
export INDY_OVERLAP_MINUTES=5
export INDY_INITIAL_LOOKBACK_MINUTES=30
export INDY_DB_PATH=/path/to/palmyra_orders.sqlite3
export INDY_TIMEZONE=America/New_York
```

## Run

Run one synchronization:

```bash
python3 collector.py once
```

Run continuously every minute:

```bash
python3 collector.py run
```

The collector overlaps each request by five minutes and upserts records by
INDY order and ticket IDs, so repeated records do not create duplicates.

At each synchronization it deletes showings dated before the current Palmyra
calendar date. Associated tickets and orders that no longer contain any current
or future tickets are deleted too. For example, on September 27 all September
26 showing records are removed while later advance-sale showings remain.

## Lookups

Show the 50 most recent stored tickets:

```bash
python3 collector.py recent
```

Look up one order:

```bash
python3 collector.py order 38344509
```

Look up all locally stored tickets for one showing:

```bash
python3 collector.py showing 3915360
```

Lookup results contain the order ID, ticket ID, seat, showing ID, movie title,
auditorium, screen ID, showtime, and purchase time.

## Guest lookup demo

Start the local web app after the database has been populated:

```bash
python3 web_app.py
```

Then open `http://127.0.0.1:8765`. Enter an order number and press Enter. The
field is compatible with keyboard-style barcode scanners, although the scanned
barcode will need to be mapped to an INDY order or ticket identifier before a
production scanner rollout. The guest map intentionally does not display the
physical wall used by the routing model.

If the showing is more than 30 minutes away, the guest screen displays a clear
future-showing warning. Showings on another calendar date are labeled “This
ticket is not for today” and show the scheduled date and time.

After the scheduled showtime plus the TMS-provided movie runtime has passed,
the screen displays “This showing has ended” with the start and estimated end
times. Both future and ended warnings direct the guest to see a manager for
help.

Highlighted paths animate from the entrance toward the assigned seats and then
remain visible. The animation is disabled when the device requests reduced
motion. Internal trunk, branch, wall, and routing guides are not shown to
guests.

After a successful lookup, the page automatically scrolls the result and seat
map into view. The full map is constrained to the available viewport height so
it does not render below the visible guest screen.

## Storage

The default database is `palmyra_orders.sqlite3` beside the script. SQLite WAL
mode is enabled so another local application can read it while collection is
running.

The database keeps the raw order JSON for troubleshooting, but applications
should normally read the normalized `orders`, `tickets`, and `showings` tables.
