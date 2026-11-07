# TrigIT

A lightweight macOS app that follows show timecode (LTC, MTC, Art-Net Timecode) and fires OSC, MIDI, Art-Net and sACN messages when the timecode enters a Song. See `GLOSSARY.md` for the vocabulary and issue #1 for the spec.

## Run the app (macOS 13+)

```sh
swift run TrigIT
```

Or open `Package.swift` in Xcode and run the `TrigIT` scheme.

## Running a show

TrigIT starts Armed, with the last Set and the last Timecode Sources, so it can be relaunched mid-show and carry on. The first timecode it hears inside a Song counts as Entering: that Song's Start Actions go out once more, on purpose, to bring the devices back in sync. The Simulator never plays after a launch, and while Armed it only drives the show after you confirm it.

Everything in the fire log is also written to a daily file in `~/Library/Logs/TrigIT/` (`2026-11-07.log`); files older than 30 days are removed.

To have TrigIT relaunched within seconds if it crashes or is killed, build the app and install the launch agent:

```sh
scripts/build-app.sh                       # build/TrigIT.app, ad-hoc signed
cp -R build/TrigIT.app /Applications/
scripts/install-launch-agent.sh            # or: scripts/install-launch-agent.sh --uninstall
```

The agent also starts TrigIT at login. Quitting with ⌘Q leaves it quit. To sign and notarize for other Macs, see `docs/release.md`.

## Run the tests

```sh
swift test
```

The Show Engine (`Sources/TrigITEngine`) and the protocol codecs (`Sources/TrigITProtocols`) are pure Swift with no platform dependencies, so their tests also run on Linux. The SwiftUI app (`Sources/TrigITApp`) only builds on macOS.

## LTC input

Pick "LTC: device, channel" as the Timecode Source on the show screen. macOS asks for audio input (microphone) permission the first time; when run with `swift run`, the permission belongs to Terminal (or whichever app launched it).

## MTC input

Pick "MTC: source" as the Timecode Source. Every Core MIDI source is listed: physical ports, network MIDI sessions (set up in Audio MIDI Setup → MIDI Network Setup) and IAC buses (enable "Device is online" for the IAC Driver in Audio MIDI Setup to run on the same Mac as Ableton).

## Art-Net Timecode input

Pick "Art-Net Timecode: interface" as the Timecode Source. TrigIT listens on UDP port 6454 and shares it with other Art-Net software on the same Mac. Choosing an interface means packets arriving on any other interface are ignored.

## Editing a Set

- **Capture:** select a Song, play timecode to the right moment, and press "Set start" or "Set end".
- **Overlaps:** every timecode position belongs to at most one Song. An edit that would overlap another Song is refused, and both Songs are highlighted.
- **Import CSV:** one Song per row: name, start, end (hh:mm:ss:ff). Commas, semicolons or tabs, an optional header row, and quoted names all work. Invalid or overlapping rows are listed by line number and skipped.
- **Show Lock:** the lock button in the top bar makes the Set read-only. Arming and the Simulator keep working.

## Firing rules

- **Entering** a Song (playing into it, or a Jump landing inside it) sends its Start Actions once.
- **Stop:** no timecode for longer than the Set's Stop time (default 2 s, set above the Song list). Shorter gaps are Dropouts: logged, never re-firing.
- **Ending:** a Stop while inside a Song, or playing on past its end, sends its Stop Actions once. A Jump out of a Song sends nothing. After a Stop, timecode resuming inside the same Song fires it again.
- **Manual:** ▶ on a Song sends its Start Actions; ■ sends its Stop Actions. Both work while disarmed and under Show Lock.

## MIDI output

Give a Destination a MIDI output (Destinations tab): a physical port, a network MIDI session or an IAC bus. Its Actions can then be MIDI notes (Note On, then Note Off 100 ms later, released at once on disarm or quit) or MIDI Show Control GO/STOP/RESUME with a cue and list. One Destination can have both a network address for OSC and a MIDI output.

## Art-Net and sACN pulses

Give a Destination a DMX output (Destinations tab): Art-Net to its address (a node, or a broadcast address such as 2.255.255.255), sACN multicast, or sACN unicast to its address, through its chosen network interface. Pulse Actions set one channel (default 255) for a time (default 0.5 s), then 0. Every universe a pulse Action uses is streamed 30 times a second from launch until quit, with zeros at rest, so receivers such as the grandMA3's DMX remote inputs never see the source disappear.

## Set files

A Set is one readable JSON file (`.trigit`), saved automatically a moment after every change and on quit; there is no Save command. TrigIT reopens the last Set at launch (the first launch creates an example in Documents/TrigIT). File → New Set, Open Set, Open Recent, Save As, Show in Finder. Edit → Undo/Redo covers every change to the Set. File → Previous Versions lists versions kept when the Set was opened and every two minutes of editing (the last 100, in Application Support/TrigIT/Versions) and restores any of them. A file that can't be opened is never overwritten: TrigIT says why and starts an unsaved empty Set.
