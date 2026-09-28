# Ticket QR seat navigation

This package can temporarily replace the auditorium poster with an animated
route to a guest's seats. The current seat map is for Palmyra Auditorium 9.

## Data flow

1. A USB QR scanner types the numeric order number and sends Enter.
2. The package service requests that order from the local collector.
3. The service verifies the returned `screen_id` matches this sign's Indy ID.
4. `seat_navigation.json` is written for the Lua renderer.
5. The poster is hidden, the route draws from the entrance, and the poster
   automatically returns after the configured display time.

The sign never stores INDY OAuth credentials. Those remain on the collector
machine. Only the local order lookup response is sent to the player.

## Sign setup

- When installing this ZIP as a separate package, copy the original sign's
  **Device Serial**, **Indy ID**, **Rotation**, **Blank**, logo, and debug
  settings. Installing as a new package does not inherit another package's
  configuration.
- Enable **Seat navigation** on the Auditorium 9 sign.
- Set **Order lookup URL** to the collector's LAN address, including the
  `{order}` placeholder. Example:

  `http://192.168.1.20:8765/api/order/{order}`

- Leave **Scanner device** set to `auto` when only one keyboard-style scanner
  is attached. If the player has multiple keyboards, enter the stable scanner
  path from `/dev/input/by-id/` ending in `-event-kbd`.
- Set **Seat map display time** (20 seconds by default).

The collector endpoint must return this shape:

```json
{
  "order_id": "38344447",
  "showings": [{
    "title": "Resident Evil",
    "auditorium": "9",
    "screen_id": 2077,
    "showtime_utc": "2026-09-27T23:00:00Z",
    "runtime_minutes": 104,
    "seats": ["G4", "G5"]
  }]
}
```

Orders for another auditorium, future dates, showings more than 30 minutes
away, expired showings, missing orders, and lookup errors show a prominent
"Please see a manager for help" message. No wall or routing guide rails are
shown to guests.
