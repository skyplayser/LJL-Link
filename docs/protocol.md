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
{"type":"reject","reason":"key"}      // reason: key | protocol | full | denied | timeout
```

- `key`: optional since LJL Link 0.4. If present and equal to LJ Link's current club key (constant-time compare) →
  `welcome`. Without a valid key see *Approval without club.json* below; an LJ Link without that feature answers
  `reject key`.
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
a wrong key is tried again after 60 s). Note: the key goes to every LJ Link that announces `sender=1` (accepted: internal technical network). macOS asks for "Local Network".

## Approval without club.json (LJL Link 0.4, LJ Link 1.7.13)

Without `club.json` LJL Link has no club key. It finds LJ Link by Bonjour and asks to be let in; the LJ allows it once
with a click in LJ Link, and from then on LJ Link knows this Mac.

**Bonjour TXT (new, additive):** `pair=1` (this LJ Link can approve senders), `booth=<id>` (16 hex, random per LJ Link
install, stored in its settings; replaced together with the club key on "New key").

**hello (new, optional field):**

```json
{"type":"hello","protocol":1,"device":"<32 hex>","name":"MacBook von Anna","software":"Serato DJ Pro 5.0.0","app":"0.4.0","names":false}
```

- `device`: a pseudonym of this Mac **for this one LJ Link**: the first 32 hex digits of
  HMAC-SHA256(key = the Mac's hardware UUID, message = `"ljl-pair:" + booth`). Nothing is stored on the DJ's Mac, the
  hardware UUID never leaves it, and two LJ Links get different values (one booth cannot pose as this Mac at another).
  Only sent to an LJ Link that announces `pair=1` and `booth`. With a `key` from club.json it may be sent too.

**LJ Link decides in this order:**

1. `protocol` wrong → `reject protocol`.
2. `key` valid → `welcome` (as before).
   Neither `key` nor `device` (LJL Link 0.3 with an old stick) → always `reject key`, also when LJ Link is full.
3. `device` in the list of approved Macs → `welcome` (name and last seen updated).
4. Already 4 senders → `reject full`.
5. `device` present, not approved:
   - refused in the last 10 minutes → `reject denied` (no nagging);
   - more than 2 requests already waiting → `reject full`;
   - otherwise → `{"type":"pending"}` and LJ Link shows the request: *"MacBook von Anna" (192.168.1.34) wants to send
     Serato decks – Allow / Deny*. Only on the booth computer itself or a device with control rights, never on a
     tablet without them (like the club key).
     - **Allow** → the Mac goes into the list (pseudonym, name, first and last seen) and the same connection gets
       `welcome`. Deck messages follow as usual.
     - **Deny** → `reject denied`, closed; refused for 10 minutes.
     - No answer within 120 s → `reject timeout`, closed. The request disappears.
     - The sender disconnects while waiting → the request disappears.

While waiting the sender sends `ping` every 5 s and LJ Link answers `pong`; the 15-s silence rule applies as usual.
Deck messages before `welcome` are still ignored.

**Approved Macs in LJ Link:** a list in the settings next to the club key (name, last seen, *Remove*). *Remove*
disconnects that Mac at once. *New key* empties the list and gives LJ Link a new `booth` id, so every approval and every
old stick becomes invalid in one step. At most 32 entries; the oldest unused one makes room.

**LJL Link:** tries the addresses from club.json first (with the key), then every LJ Link found by Bonjour. With
`pending` it shows "Waiting for approval in the booth" and waits up to 130 s, then tries the next place. `denied` →
next try at this place after 60 s. `reject key` from an LJ Link without `pair=1` and no club.json → "LJ Link in the
booth is too old for approval without club.json".

Known limit (same as with the key): the network is not encrypted. Someone in the same network who reads the traffic can
copy the pseudonym of an approved Mac. The suite relies on the club's internal technical network.

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
