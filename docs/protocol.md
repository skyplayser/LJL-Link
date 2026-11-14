# LJL Link protocol (sender protocol), version 1

Between **LJL Link** (on the DJ's Mac, from the club's USB stick) and **LJ Link** (on the booth computer).
The sender only reports deck data; nothing sent this way can control LJ Link, Serato or any device.

## Transport

- WebSocket `ws://<host>:<port>/sender`. `host`/`port` come from `club.json` on the stick, otherwise from Bonjour
  `_ljlink._tcp` (TXT `sender=1`, `senderpath=/sender`).
- Text frames, one JSON object per frame, field `type` names the message. UTF-8.
- At most 2 MB per frame. LJ Link closes the connection on a larger frame, unknown `type` is ignored.
- The sender opens the connection and never listens on a port.

## Handshake

1. Sender → `hello`
2. LJ Link → `welcome` or `reject` (then closes)
3. Only after `welcome` the sender sends deck messages. Deck messages before `welcome` are ignored.

```json
{"type":"hello","protocol":1,"key":"<club key from club.json>","name":"MacBook von Anna","software":"Serato DJ Pro 5.0.0","app":"0.3.0","names":false}
{"type":"welcome","protocol":1,"club":"Testclub","sender":"s1"}
{"type":"reject","reason":"key"}      // reason: key | protocol | full
```

- `key`: must equal LJ Link's current club key (constant-time compare). A missing or wrong key → `reject key`.
  (Pairing with a code for senders without a club stick comes later; v1 knows only the key.)
- `protocol`: LJ Link accepts 1. Higher → `reject protocol`.
- At most 4 senders at once → `reject full`.
- `name`: shown in LJ Link ("MacBook von Anna · Deck 1"). Max 64 characters, LJ Link cuts longer names.
- `names`: whether the DJ allows track titles. `false` → LJ Link shows "Titel vom DJ ausgeblendet" and ignores any `title`/`artist`.

## Deck messages (sender → LJ Link)

Decks are numbered 1-4 as in Serato. Every deck message carries `deck`; `id` is a random id per loaded file chosen by
the sender (never the path), so late waveform messages of an old track can be dropped.

```json
{"type":"load","deck":1,"id":"a81f","lengthMs":243533,"bpm":130.0,"key":"6A","title":"Scream & Shout","artist":"will.i.am, Britney Spears"}
{"type":"waveform","deck":1,"id":"a81f","kind":"overview","entries":400,"data":"<base64>"}
{"type":"waveform","deck":1,"id":"a81f","kind":"detail","fps":150,"entries":42798,"data":"<base64>"}
{"type":"position","deck":1,"id":"a81f","ms":61234,"playing":true,"source":"screen"}
{"type":"unload","deck":1}
{"type":"names","on":false}
{"type":"ping"}
{"type":"bye"}
```

- `load`: a new track on the deck. `title`, `artist`, `bpm`, `key` are optional; `title`/`artist` only if `names` is on.
  LJ Link clears the deck's waveform, cues and position.
- `waveform`: `data` is base64 of the raw bytes, 4 bytes per entry (0-255), the "threeband" style LJ Link already uses
  for CDJ-3000 waveforms. Ignored if `id` is not the deck's current track. `entries * 4` must equal the decoded length.
  - `detail` → `Deck.setDetail`, `detailStyle = "threeband"`: low, mid, high, 0 — separate heights, painted low, mid,
    high on top of each other (app.js `drawDetail`). The sender weights them 100 / 75 / 50 % at each band's loud level,
    so they nest like on a CDJ-3000 (blue outside, amber, white inside).
  - `overview` → `Deck.setWaveform`, `previewStyle = "threeband"`: **cumulative** heights low, low+mid, low+mid+high, 0,
    painted from the outermost to the innermost (app.js `drawOverview`), scaled so the loudest sum fills the height.
- `position`: playhead in ms from the track start, `playing`, `source` = `screen` (read from Serato's time display) or
  `estimate`. Optional; without it the deck has no playhead.
  - `speed` (optional): playing speed measured by the sender (1.0 = no pitch, e.g. 0.98 at −2 %), from a straight line
    through the last 5-8 s of readings. LJ Link runs the playhead on at this speed between two messages; without it at
    1.0. Needed because the sender reports only about 4-5 times a second.
  - `ms: null`: the sender cannot see this deck's time any more (e.g. Serato's 2-deck view hides decks 3/4; other
    windows on top of Serato do not matter, the capture sees the window itself), sent after 6 s without a readable
    field. LJ Link removes the playhead instead of running it on.
- `unload`: deck empty.
- `names`: DJ switched track titles on/off. `false` → LJ Link removes titles and artists of this sender's decks at once,
  also on tablets.
- `ping`: every 5 s. LJ Link treats a sender as gone after 15 s without any message and removes its decks.
- `bye`: the sender quits; LJ Link removes its decks at once.

## LJ Link → sender (besides welcome/reject)

```json
{"type":"pong"}
```

Answer to `ping`, so the sender can show "connected".

## Finding LJ Link (Bonjour)

LJ Link announces itself as `_ljlink._tcp` with TXT `sender=1`, `senderpath=/sender`. LJL Link tries the addresses
from club.json first, then every LJ Link it finds this way (the booth computer may have a new address since the stick
was prepared). A different club's LJ Link answers `reject key`; the next place is tried after 2 s (with a single place,
a wrong key is tried again after 60 s). Note: the key goes to every LJ Link that announces `sender=1` (open decision). macOS asks for "Local Network".

## Chat

The chat is not part of this protocol: every suite program joins the suite chat by itself (UDP multicast, no host),
see LJ Link `docs/suite-chat.md`.

## Club key and club.json

- LJ Link creates a random club key (128 bit, hex) on first use and stores it in its settings. "Neuer Schlüssel"
  replaces it; old sticks are rejected from then on.
- `club.json` on the stick:

```json
{"version":1,"club":"Testclub","hosts":["192.168.1.20","booth.local"],"port":8080,"key":"<hex>"}
```

## Versioning

Additive changes (new optional fields, new message types) keep `protocol: 1`. Anything else raises it.
