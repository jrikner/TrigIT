# TrigIT

## Agent skills

### Issue tracker

Issues are tracked in GitHub Issues on `jrikner/TrigIT`, via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `GLOSSARY.md` and `docs/adr/` at the repo root, created lazily. See `docs/agents/domain.md`.

## Development

- Swift package:
  - `TrigITProtocols`: pure encoders/decoders (OSC, LTC, MIDI bytes, MTC, Art-Net Timecode, MIDI notes, MSC, ArtDmx, sACN, DMX pulse mixing), tested against reference bytes from each protocol's specification and, where available, an independent implementation (libltc for LTC; the Python sacn and stupidArtnet libraries for sACN and ArtDmx).
  - `TrigITEngine`: the pure Show Engine, no I/O. Emits `.send` events; the app does the sending.
  - `TrigITApp`: SwiftUI and the hardware/network adapters, macOS only, declared only when building on macOS.
- Test: `swift test`. Run the app on a Mac: `swift run TrigIT`.
- Test the engine through its public inputs (timecode readings, Set updates) and outputs (`EngineEvent`s), never its internal state.
- The Set is `ShowSet` in code because `Set` clashes with the Swift standard library.
