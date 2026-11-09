# TrigIT for grandMA3

A grandMA3 plugin that imports a TrigIT Set (a `.trigit` file or a CSV) and builds a Timecode Show from it, so the console fires the Set's OSC and MIDI Actions at the right timecode by itself (map issue #30). MA's own timecode engine does the firing. The plugin only writes the show.

Tested on **grandMA3 onPC 2.5.1** (macOS), not yet on a console (spike #43). It is written for 2.5; older versions may refuse the plugin file.

## Install

1. Copy `dist/TrigIT.xml` and `dist/TrigIT.lua` into a folder of the MA3 library's plugins folder:
   - onPC: `~/MALightingTechnology/gma3_library/datapools/plugins/TrigIT/` (macOS), or the same path under your user folder on Windows.
   - Console: on a USB stick, `grandMA3/gma3_library/datapools/plugins/TrigIT/`.
2. In a Plugins pool window, edit an empty pool object, tap **Import**, and choose `TrigIT.xml`. Or type `Import Plugin <n> /Path "<that folder>" /File "TrigIT.xml"` on the command line.
3. Put your Set files in `gma3_library/trigit/`, or at the top of a USB stick, or in a `trigit` folder on it. Export the `.trigit` from the Mac app, or write a CSV (below).

## Use

Run the plugin (tap it, or type `Plugin <n>`). It asks, one dialog at a time:

1. **Which Set.** It lists every `.trigit` and `.csv` it finds in those folders.
2. **Frame rate, timecode slot, and numbers.** The frame rate is the incoming timecode's: the Set stores none, and it decides when Stop Actions fire. The Timecode and Sequence numbers must be free or from an earlier TrigIT import. It suggests free ones.
3. **An OSC line per OSC Destination.** It picks the line it made last time, or one with the same address, or offers to make a new line `TrigIT <Destination>` from the Set's IP and port (type them for a CSV Set). Choose **Leave out** to skip that Destination.
4. **A summary** with every warning (skipped Songs, Actions it can't send). The warnings also go to the System Monitor.

On **Import** it writes:

- **Sequence** `TrigIT <Set>`: one cue per moment, named after its Song (`Intro start`, `Intro stop`, `Intro note off`). Each cue's Command holds that moment's Actions, joined with `;`.
- **Timecode** `TrigIT <Set>`: one track playing that sequence, with a `Goto` event per cue at its time. It follows the chosen slot, and starts and stops by itself when timecode arrives and stops (Auto Start, Auto Stop).
- **OSC lines** in In & Out, when you asked for new ones: Send Command on, Send off. Without Send Command, MA3 refuses `SendOSC`. With Send on, MA3 would also send its own playback feedback to the device.

Importing again, with the same or another Set, replaces that Timecode and Sequence. The plugin finds them by their Note and never touches anything else. **Oops** undoes an import.

OSC needs an interface: if Menu > In & Out > OSC shows Interface "None", choose one there. The summary says so.

## What was checked on onPC 2.5.1

- `SendOSC` sends the same bytes as the Mac app for int, float and string arguments, UTF-8, `;` inside strings, and messages with no arguments (`"/address,"`). MA3 refuses a bare `"/address"`.
- The example Set, imported with Art-Net Timecode on slot 1, fires Resolume's `/composition/columns/1/connect 1` 25–58 ms after 01:00:00:00 arrives at 30 fps, over 4 runs, and a 4-cue Set fires each cue 52–59 ms after its frame at 25 fps. That is one to two frames, from MA3's own timecode handling.
- Importing a second Set replaces the first: one Timecode, one Sequence, and the same OSC line.
- Timecode events targeting a **macro** never ran in onPC 2.5.1, so the plugin targets a sequence and puts the commands in cue Commands.

## Differences from the Mac app

- **Jumps:** starting timecode in the middle of a Song doesn't fire its Start Actions. The Mac app does, because a Jump landing inside a Song Enters it. MA3 only fires events the playhead passes.
- **Stops:** MA3 runs on for its slot's afterroll (0.5 s by default) when timecode stops, so a Stop cue within that time still fires.
- **Not sent:** MIDI Show Control and DMX pulse Actions, Songs with only Start or Stop Notes, and OSC strings containing `,` or `"`. Each is listed as a warning.
- **MIDI** goes out of the console's MIDI output, whichever Destination it names. A note is held 0.1 s, as in the Mac app.
- **Drop-frame:** at 29.97 DF, times are counted in real seconds (frames × 1001/30000). This is not checked against MA3's own DF handling yet.

## Files

- `src/trigit_plan.lua`: `fromCSV(text, options)` and `fromTrigit(text, options)` turn a Set into a plan. Pure Lua, no MA calls.
- `src/ma3.lua`: turns a plan into the cues the plugin writes. Pure Lua.
- `src/commands.lua`: every MA3 command the plugin writes, formatted in one place.
- `src/json.lua`: a small JSON decoder for `.trigit` files.
- `adapter/TrigIT.lua`: the MA3 side: dialogs, OSC lines, the Sequence and the Timecode. The only file that calls MA.
- `build.lua`: bundles all of these into `dist/` (an MA3 plugin can't `require` files). Run `lua build.lua` after changing them, and commit `dist/`. CI fails if it is out of date.
- `spec/`: busted tests. `spec/fixtures/*.trigit` are written by the Swift tests (`Tests/TrigITStorageTests/MA3FixtureTests.swift`). After changing those Sets or the file format, run `TRIGIT_WRITE_FIXTURES=1 swift test --filter MA3FixtureTests`.

## Run the tests

```bash
cd ma3-plugin && busted && lua build.lua --check
```

You need Lua 5.4 (the MA3 runs 5.4.8) and `luarocks install busted`. The adapter has no unit tests: check it on onPC with the procedure below.

## Checking on onPC

1. Import the plugin (above) in a scratch show, and copy `spec/fixtures/example.trigit` to `gma3_library/trigit/`.
2. Set up Art-Net Timecode input: Menu > DMX Protocols > Art-Net: Enable Input, an interface, and in the Timecode tab an enabled input on slot 1.
3. Run the plugin, choose the example, 30 fps, slot 1, and a new OSC line to an address where something listens on port 7000. Check that the summary, the Sequence and the Timecode look as described above.
4. Send Art-Net Timecode from 00:59:58:00 to that machine from any Art-Net timecode generator, and check that `/composition/columns/1/connect 1` arrives at 01:00:00:00.
5. Import a changed Set and check that the Timecode and Sequence were replaced, not added.

## The plan

```lua
local plan = require("trigit_plan").fromTrigit(text, { frameRate = "25" })
-- or: local result, reason = ...; result is nil and reason says why when the file isn't a readable Set
{
  frameRate = "25",          -- "24", "25", "29.97 DF" or "30" (default "30"); a Set stores none
  destinations = { { name = "Resolume", kind = "osc", host = "127.0.0.1", port = 7000, midiPort = nil } },
  events = {
    { time = "01:00:00:00", song = "Intro", phase = "start",
      destination = { osc_line_for = "Resolume" },
      command = 'SendOSC $line "/composition/columns/1/connect,i,1"' },
    { time = "01:04:00:01", song = "Intro", phase = "stop",
      destination = { midi_for = "MA3" },
      command = 'SendMIDI "Note" 10/36 100',
      release = { after = 0.1, command = 'SendMIDI "Note" 10/36 0' } },
  },
  warnings = { 'Song "Pull-up": skipped: it has a Start Note and no timecode span, so it can\'t become timecode events' },
}
```

- `kind` lists the Destination's switched-on transports, joined with `+` (`osc+midi+dmx`). A CSV Set has no addresses, so `host`, `port` and `midiPort` are nil.
- Destinations stay symbolic. `ma3.cues` replaces `$line` with the Destination's OSC line.
- `release` is a second command to send `after` seconds later: the Note Off for a MIDI note.
- Events are in timecode order. Actions keep their Set order within one time.

## Rules (as in the Mac app and `GLOSSARY.md`)

- Each Song's **Start Actions** become events at its start time, in order.
- Its **Stop Actions** become events on the frame after its end time, at the plan's frame rate. The app Ends a Song when the Playhead plays on past its end time.
- A Song with no timecode span (only a Start Note or Stop Note) can't become timecode events. It is skipped with a warning.
- Songs whose spans overlap an earlier Song are refused, with `line N: overlaps "Name"` for CSV, as the app's CSV import says it. Spans include both ends.
- A Song whose times use frames the frame rate doesn't have, such as `:27` at 25 fps, gets a warning.
- Actions are left out with a warning when their Destination is missing, has that transport switched off, or is of a kind MA3 can't send yet (above).

## CSV format

This extends the CSV the Mac app imports (Set > Import Songs from CSV). One row per Song or per Action, with up to eight columns:

| # | Column | Meaning |
|---|--------|---------|
| 1 | name | The Song's name. Empty on a row that adds another Action to the Song above. |
| 2 | start | `hh:mm:ss:ff`. `;` or `.` before the frames also works. Frames 0–29. |
| 3 | end | `hh:mm:ss:ff`, not before start. Both ends are part of the Song. |
| 4 | destination | The Destination's name, such as `Resolume`. Each name used becomes a Destination. |
| 5 | kind | `osc`, `midi-note` or `dmx` (any case). The MA3 plugin doesn't send `dmx` yet. |
| 6 | address | `osc`: the OSC address (`/composition/columns/1/connect`). `midi-note`: the note `60` (channel 1) or `channel/note` (`10/36`, channels 1–16). `dmx`: `universe.channel` (`2.101`, channel 1–512). |
| 7 | args / value | `osc`: arguments as typed in the app's editor. Whole numbers are ints, numbers with a `.` or `e` are floats, anything else is a string, and `"two words"` keeps spaces. `midi-note`: velocity 1–127 (default 127). `dmx`: value 0–255 (default 255), held 0.5 s. |
| 8 | when | `start` (default) or `stop`: a Start Action or a Stop Action. |

- Separators: comma, semicolon or tab, whichever the first non-empty line uses most outside quotes.
- Quote a field to use the separator in it, and double a quote inside quotes (`"Intro, ""live"""`). Fields are trimmed.
- An optional header: a first row whose start and end are both not timecodes is skipped.
- Empty lines are skipped. Problems are reported with 1-based line numbers. Bad Song rows are skipped. A bad Action row loses only that Action.
- Columns 1–3 alone are exactly what the Mac app imports.

```csv
name,start,end,destination,kind,address,args,when
Intro,01:00:00:00,01:04:00:00,Resolume,osc,/composition/columns/1/connect,1
,,,Resolume,osc,/composition/layers/2/clear,"""fade out"" 0.5"
,,,Ableton,midi-note,10/36,100,stop
DJ Pull-up,02:00:00:00,02:01:30:00,Resolume,osc,/composition/columns/2/connect,1
```

The Mac app's importer reads columns 1–3 only. It reports a row with an empty name as "the name is empty", so it doesn't read the extra Action rows yet (#87).
