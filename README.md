<p align="center">
  <img src="docs/images/ljl-link-icon.png" width="120" alt="LJL Link logo">
</p>

<h1 align="center">LJL Link</h1>

<p align="center">
  Your Serato decks in the lighting booth.<br>
  From the club's USB stick to LJ Link – nothing to install.
</p>

<p align="center">
  <a href="https://skyplayser.github.io/LJL-Link/">Website</a> &nbsp;·&nbsp;
  <a href="https://github.com/skyplayser/LJL-Link/releases/latest">Download</a> &nbsp;·&nbsp;
  <a href="#quick-start">Quick start</a> &nbsp;·&nbsp;
  <a href="README.de.md">Deutsch</a> &nbsp;·&nbsp;
  <a href="https://skyplayser.github.io/LJ-Link/wiki-serato.html#ljl-link">Guide (LJ Link wiki)</a> &nbsp;·&nbsp;
  <a href="https://discord.gg/N6DMca4Bjk">Discord</a> &nbsp;·&nbsp;
  <a href="https://github.com/skyplayser/LJ-Link">LJ Link</a>
</p>

<p align="center">
  <img alt="Status: alpha" src="https://img.shields.io/badge/status-alpha-FFB020">
  <img alt="macOS 14+, free" src="https://img.shields.io/badge/macOS%2014%2B-free-3DDC84">
  <img alt="License: EPL-2.0" src="https://img.shields.io/badge/license-EPL--2.0-22C8F0">
</p>

LJL Link is a small Mac app for DJs who play **Serato DJ Pro**. It runs straight from the club's USB stick and sends the
lighting booth what is on your decks: which track is on which deck, its length, BPM and key, three-band waveforms and the
running position. In the booth, [LJ Link](https://github.com/skyplayser/LJ-Link) shows your decks next to every other player,
so lights and effects match drops and breaks.

Serato has no live interface for other programs. LJL Link follows along on your Mac instead – passively: it never controls
Serato and never touches controllers or MIDI.

> [!WARNING]
> **This is an alpha.** LJL Link has been tested locally, but not yet in a club. Try it before an important night, and tell
> us what you find: **Report a problem** in the app, or on [Discord](https://discord.gg/N6DMca4Bjk).

## What it does

- **Runs from the USB stick:** the club puts LJL Link on its stick. Plug it in, start the app – nothing is installed. At the end
  choose *Quit* (⌘Q) and unplug the stick; closing the window is not enough, LJL Link keeps sending from the menu bar.
- **Your decks in the booth:** which track is on which deck, with length, BPM and key.
- **Three-band waveforms:** lows, mids and highs apart, as an overview of the whole track and as a detail waveform. Built on
  your Mac from the loaded file; the audio itself never leaves it.
- **Running position:** read from the time display in Serato's window, so the waveform in LJ Link runs along with your track.
- **You decide about names:** at the start LJL Link asks whether track names may be sent, and you can switch it any time.
  Without your OK, titles, artists and file names do not leave your Mac.
- **Passive:** LJL Link only reads Serato's log, the loaded track (for waveform, BPM and key) and the time display.
- **Finds the booth:** the file `club.json` next to the app holds the booth address and the club key. If the booth computer has
  a new address, LJL Link finds LJ Link with Bonjour in the local network; the key decides.
- **Suite chat (alpha):** one chat room with every suite program in the network – LJ Link, VJ-Link, LJL Link – without a
  server. Enter your name and position. The **EMERGENCY** button opens a pop-up at the bottom right for everyone. Can be
  switched off; messages are never saved and never logged.
- **Simple for every DJ:** a welcome screen explains everything before the first question, the menu bar icon shows whether all
  is well, *Report a problem* is built in, and the app speaks **English and German** (after the Mac's language).

## What leaves your Mac

LJL Link sends only within the local network: to LJ Link in the club and, while it is on, to the suite chat. It has no account,
no cloud, no telemetry and opens no connection to the internet.

| Data | To LJ Link |
|---|---|
| Name of the Mac (from System Settings), LJL Link version | yes – LJ Link shows with it whose decks these are |
| Deck number, length, BPM, key | yes |
| Waveforms (three bands) | yes |
| Running position | yes, if *Screen Recording* is allowed – only the time, no picture |
| Title and artist | only if you allow it |
| File names, folders, the audio itself | never |
| Chat messages | to every suite program in the network while the chat is on |

Each loaded track gets a random id; the file path is never sent. The protocol is described in [docs/protocol.md](docs/protocol.md).

## Requirements

| What | State |
|---|---|
| Mac with macOS 14 or newer, Apple silicon or Intel (one universal app) | alpha; tested on one Apple silicon Mac with the current macOS, not yet on Intel or older macOS |
| Serato DJ Pro | alpha, tested locally, not yet in a club |
| [LJ Link](https://github.com/skyplayser/LJ-Link) in the lighting booth, with the input for LJL Link | alpha |
| Mac and booth in the same local network | required |
| *Prepare stick* in LJ Link (writes LJL Link and `club.json` onto the stick) | planned; until then `club.json` by hand |
| Windows, other DJ software | not supported |

## Install

Download LJL Link from the [latest release](https://github.com/skyplayser/LJL-Link/releases/latest) and put it on the USB stick
together with the club's `club.json` (see below).

The app is **ad-hoc signed, but not notarized by Apple yet**. So macOS blocks a copy downloaded from the internet once on the
first start (“LJL Link” Not Opened):

- Start LJL Link once and click *Done* at the warning. Open *System Settings → Privacy & Security*, scroll down, click
  **Open Anyway** next to LJL Link and confirm with your password or Touch ID, then *Open*.
- On macOS 14, right-click the app → *Open* → *Open* also works.
- Terminal alternative: `xattr -dr com.apple.quarantine "LJL Link.app"` (with the path to the app). This switches off macOS's
  download check for this app, so only use it for a copy from this GitHub page or the official website.

Once LJ Link prepares the stick (the function is still to come), the app carries no download flag and starts without the warning.

On the first start macOS asks two questions:

- **Local Network:** *Allow*. With it LJL Link finds LJ Link in the booth, and the chat works.
- **Screen Recording:** switch it on for LJL Link in System Settings. LJL Link only reads Serato's time display with it; nothing
  is recorded or sent except the time. Without it everything works, only without the running position.

## Quick start

1. **Stick from the club:** the lighting team puts LJL Link and `club.json` on a USB stick. The DJ's Mac has to be in the same
   network as LJ Link.
2. **Start:** plug in the stick, start LJL Link, allow *Local Network* and *Screen Recording* and answer the question about
   track names.
3. **Play:** load tracks in Serato as usual. Your decks appear in LJ Link. At the end choose *Quit* (⌘Q), then unplug the stick.

The full guide is in the LJ Link wiki: **[Serato DJ Pro](https://skyplayser.github.io/LJ-Link/wiki-serato.html#ljl-link)** and
[Use case: Serato on the DJ laptop](https://skyplayser.github.io/LJ-Link/wiki-case-serato.html). LJL Link has no wiki of its own.

### club.json

LJL Link looks for `club.json` next to the app. If there is none, you can choose the file in the app. LJ Link will write this file when it
prepares the stick; until that function is released, it is made by hand as the guide in the LJ Link wiki describes. The format:

```json
{
  "version": 1,
  "club": "<name shown to the DJ>",
  "hosts": ["<address of the booth computer>"],
  "port": <LJ Link's port>,
  "key": "<club key from LJ Link>"
}
```

The club key is not anyone's password. A new key in LJ Link makes every older `club.json` invalid; LJL Link then says the stick
has to be prepared again.

## Suite chat

LJL Link, [LJ Link](https://github.com/skyplayser/LJ-Link) and [VJ-Link](https://github.com/skyplayser/VJ-LINK) in the same
network share one chat room, without a server – so the DJ and the booth can write to each other instead of shouting across the
dance floor. Messages are kept only in memory, never written to a file, a log or a problem report. Anyone who starts a suite
program in the same network can read the chat, so do not write anything confidential. The chat is an alpha and can be switched
off in the app; it was tested on one Mac with LJ Link, LJL Link and VJ-Link, not yet between two computers and not in a club. Specification: [docs/suite-chat.md in LJ Link](https://github.com/skyplayser/LJ-Link/blob/main/docs/suite-chat.md).

## Problems?

Use **Report a problem** in the app: describe what happens and leave *Include diagnostic data* ticked. The diagnostic data holds
the versions of LJL Link, macOS and Serato, the connection to LJ Link, the state of the decks (length, position, waveform) and
the last log lines – no track titles, no artists, no file names, no club key – and you see it before sending. Send it by email
(your mail program opens a mail to fehlermelden@nextphilm.de), save it as a file or copy it.

## Build from source

LJL Link is a Swift package in `sender/` (macOS 14, Swift 5.9, the Command Line Tools are enough).

```sh
cd sender
swift run -c release selftest   # self test without XCTest
./build-app.sh                  # builds "LJL Link.app" (Apple silicon and Intel), ad-hoc signed, in .build/app
```

| Folder | What |
|---|---|
| `sender/Sources/SenderCore` | everything testable: Serato log, track tags, waveforms, time display, club config, protocol, suite chat |
| `sender/Sources/LJLLinkApp` | the app: welcome, track-name question, decks, chat, report, menu bar |
| `sender/Sources/ljlink-sender` | command line front end for development |
| `sender/Sources/selftest` | the self test |
| `docs/protocol.md` | the protocol between LJL Link and LJ Link |

## The suite

<a href="https://github.com/skyplayser/LJ-Link"><img src="https://raw.githubusercontent.com/skyplayser/LJ-Link/main/docs/images/logo.png" width="56" align="left" alt="LJ Link logo"></a>

**[LJ Link](https://github.com/skyplayser/LJ-Link)** shows the lighting jockey what the DJ plays: every deck, waveform, cue and
the BPM from Pioneer and Denon gear – and, with LJL Link, from Serato – and sends the tempo to grandMA, Daslight and more.
LJL Link needs it in the booth. Free for macOS and Windows.

<br clear="left">

<a href="https://github.com/skyplayser/VJ-LINK"><img src="https://raw.githubusercontent.com/skyplayser/VJ-LINK/main/docs/images/logo.png" width="56" align="left" alt="VJ-Link logo"></a>

**[VJ-Link](https://github.com/skyplayser/VJ-LINK)** plays live visuals run by the light desk, on screens, LED walls and
projectors, and takes tempo and track from LJ Link. Free for macOS and Windows.

<br clear="left">

## Credits and notices

Logo lettering: [Inter](https://github.com/rsms/inter) (SIL Open Font License 1.1, see [docs/Inter-OFL.txt](docs/Inter-OFL.txt)).
The PNGs contain no font software.

LJL Link is an independent project that works with Serato DJ Pro. It is not an official product of, and is not endorsed by, any
maker of DJ, lighting or music hardware or software – including Serato. All product names and trademarks mentioned in LJL Link
and its documentation belong to their respective owners and are used only to describe compatibility. Serato and Serato DJ Pro are
trademarks of Serato. LJL Link is not related to the LightJockey software by Martin.

LJL Link is free and comes without warranty. Software, network and devices can fail: the lighting team should always keep a
fallback ready, for example tap tempo on the desk.

## License

© 2026 Philipp Spruck / NEXTPHILM. LJL Link is distributed under the [Eclipse Public License 2.0](LICENSE), without any warranty.

<br>

<p align="center">
  <sub>Idea SKYPLAYSER/NEXTPHILM<br>
  Prompted with ❤️ made by Claude<br>
  <a href="https://skyplayser.github.io/LJL-Link/impressum.html">Legal notice (Impressum)</a> ·
  <a href="https://skyplayser.github.io/LJL-Link/datenschutz.html">Privacy</a></sub>
</p>
