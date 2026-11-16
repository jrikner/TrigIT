# TrigIT for Resolume (FFGL plugin, preview)

TrigIT's Show Engine as an FFGL effect. It runs inside Resolume, so there is no second app to start and nothing to draw: it follows Art-Net Timecode and, when the timecode enters a Song, sends that Song's OSC Actions. The firing rules are the Mac app's ([Firing rules](../README.md#firing-rules)), because it runs the same engine as the [grandMA3 plugin](../ma3-plugin/README.md).

**Not yet tested in Resolume.** The engine, the Art-Net Timecode reading and the OSC it sends are tested over a real network socket on macOS, Windows and Linux (`test/core_test.cpp`). The plugin shell around them is built by CI but nobody has loaded it into Resolume yet. Try it on a rehearsal machine first, and report what you see in an issue.

## What it does and doesn't

| | Mac app | This plugin |
|---|---|---|
| Timecode in | LTC, MTC, Art-Net Timecode, backup source | Art-Net Timecode |
| Actions out | OSC, MIDI note, MSC, Art-Net and sACN pulses | OSC |
| Start and Stop Notes | yes | no |
| Making cues | the Set editor | 16 Cues typed into the effect's parameters, or a Set file made elsewhere |

A Set with other Actions still loads; they are skipped, and Resolume's log says how many.

## Install

1. Get the plugin. Until a release carries it, CI builds it: run the **CI** workflow on GitHub (Actions > CI > Run workflow) and download `TrigIT-FFGL-macOS` or `TrigIT-FFGL-Windows` from the run. Or build it, below.
2. Copy `TrigIT.bundle` (Mac) or `TrigIT.dll` (Windows) to Resolume's extra effects folder: `Documents/Resolume Arena/Extra Effects`.
3. On a Mac, a downloaded plugin is quarantined. Clear it once in Terminal: `xattr -dr com.apple.quarantine ~/Documents/Resolume\ Arena/Extra\ Effects/TrigIT.bundle`
4. Restart Resolume. **TrigIT** is in the Effects list.

## Use

1. Drag **TrigIT** onto the **Composition**, not a clip or layer, so it runs for the whole show. The picture passes through unchanged.
2. Switch on OSC input in Resolume's Preferences (port 7000), then give the plugin its cues, one of two ways:
   - **Cues**, typed in Resolume, no file needed. For each, **Cue n time** is a timecode such as `01:00:00:00` and **Cue n column** is the Resolume column to launch. When the timecode reaches a Cue's time, or jumps to anywhere between it and the next Cue, its column launches. Instead of a column number you can type any OSC address and its arguments, such as `/composition/layers/2/clear 1`. Two Cues with the same time both fire. **Cue OSC port** is Resolume's OSC input port.
   - **Set**: a `.trigit` file from the Mac app or the grandMA3 plugin, for Songs with end times, Stop Actions and other Destinations. To reach Resolume itself, the Set's Destination is `127.0.0.1`, port 7000. The file is used only while every Cue is empty.
3. Send Art-Net Timecode to this computer, UDP port 6454. Broadcast is safest: if Resolume or another program also listens for Art-Net on this computer, a packet sent to the computer's own address may reach only one of them.
4. Switch **Show timecode** on. The Playhead is drawn over the output: dashes until timecode arrives, grey while disarmed, green while Armed, red on a timecode alert. Switch it off for the show.
5. Switch **Armed** on. Songs fire only while Armed.

Resolume saves the settings with the composition. What fired, and anything that could not be sent, is written to Resolume's log, each line starting `TrigIT:`.

The plugin loads the Set when you choose it and when the composition opens. After changing the file, choose it again.

Use the effect once. More copies share one engine, so nothing fires twice, but they also share the Set, the Cues and Armed: the last one changed wins.

## Build

Needs CMake 3.20 and a C++17 compiler (Xcode, or Visual Studio 2022). The build fetches Lua 5.4.8 and the FFGL SDK from GitHub.

```
cd ffgl-plugin
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release
ctest --test-dir build -C Release --output-on-failure
```

The plugin is `build/TrigIT.bundle` or `build/Release/TrigIT.dll`. On Linux only the engine core and its test build: FFGL has no Linux host.

## How it is made

- `core/` is the engine with its own thread and sockets, no OpenGL: it embeds Lua and runs `ma3-plugin/src/engine.lua`, `timecode.lua` and `json.lua` unchanged, plus `src/host.lua` (Art-Net Timecode in, OSC out). A timecode packet wakes the thread and fires at once; a 10 ms tick only detects Stops and lost timecode.
- `plugin/` is the FFGL effect: its parameters, a pass-through shader and the timecode overlay.
- Why this shape: [ADR 0005](../docs/adr/0005-ffgl-plugin.md).
