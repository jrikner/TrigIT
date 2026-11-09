# Contributing to TrigIT

Thanks for helping. Bug reports and feature ideas go in [Issues](https://github.com/jrikner/TrigIT/issues/new/choose); code goes in a pull request against `main`.

## Build and test

```sh
swift test          # every target this platform can build
swift run TrigIT    # the app, macOS 13+ only
```

The package has three parts:

- `TrigITProtocols`: pure encoders and decoders (OSC, LTC, MIDI, MTC, Art-Net, sACN, MSC, DMX).
- `TrigITEngine`: the Show Engine. No I/O; it emits `.send` events and the app does the sending.
- `TrigITApp`: SwiftUI and the hardware and network adapters. macOS only.

The protocols and the engine build and test on Linux too, and CI runs `swift test` on Linux and macOS for every PR. Keep them free of Apple-only frameworks.

## Words and decisions

- Use the vocabulary in [GLOSSARY.md](GLOSSARY.md): Set, Song, Destination, Start Actions and so on. The Set is `ShowSet` in code because `Set` clashes with the Swift standard library.
- Decisions that are hard to undo are written up in [docs/adr/](docs/adr/). Read the relevant ADR before changing something it covers, and add one when you make such a decision.

## Tests

- **Show Engine:** test it through its public inputs (timecode readings, Set updates) and its outputs (`EngineEvent`s), never its internal state.
- **Protocol codecs:** test against reference bytes from the protocol's specification, or against an independent implementation (libltc for LTC; the Python `sacn` and `stupidArtnet` libraries for sACN and ArtDmx). Say in the test where the bytes come from.
- If a change touches real timecode or real Destinations, say in the PR what you ran it against.

## Sign your commits (DCO)

Every commit must be signed off under the [Developer Certificate of Origin](https://developercertificate.org): a `Signed-off-by: Your Name <you@example.com>` line that says you have the right to submit the change under this project's license. `git commit -s` adds it. There is no CLA.

A CI check fails the PR if any of its commits lacks the line. To fix that, sign off the commits and force-push:

```sh
git rebase --signoff main
git push --force-with-lease
```

## License

TrigIT is licensed under the GNU General Public License, version 3 or later (`GPL-3.0-or-later`); see [LICENSE](LICENSE). By contributing you agree your changes are licensed the same way.

[NOTICE](NOTICE) adds one term under GPL §7(b): modified versions must keep the attribution "Originally created by Jonathan Rikner" in their README and in the app's About window. Don't remove it.
