# One grandMA3 plugin with two modes: Standalone and Bridge

The user's requirement, verbatim: "The plugin must be able to both be bridge but also fully functional on its own". There is one TrigIT plugin for grandMA3 (`ma3-plugin/`), not one per issue. You pick its mode in its panel, and changing mode needs no reinstall.

- **Standalone** (#47): TrigIT's Show Engine, ported to Lua, follows a timecode slot and sends the Set's Actions from the console while Armed.
- **Bridge** (#46): the plugin sends the timecode slot to the TrigIT Mac app, and the Mac app fires the Set as usual.

## Decisions

- **Shared parts.** Both modes use the same panel, the same timecode-slot reader (one loop polling `Root().TimecodeSlots[n].Time`, slot and frame rate chosen in the panel) and the same Set loading. In bridge mode the engine still runs, always disarmed, so the panel shows the Playhead and current Song the Mac app should be seeing. Arm, Fire Song and Stop Song do nothing there: the Mac app fires.
- **Bridge speaks Art-Net Timecode.** The Mac app already follows ArtTimeCode on UDP 6454 (`ArtNetTimecodeInput`). The plugin builds the 19-byte packet itself (`src/artnet.lua`, checked against the Swift reference bytes) and sends it with LuaSocket to the Mac's IP address or a broadcast address, once per new frame on the slot. No new Timecode Source, glossary term or engine input on the Mac. That answers #46's open question about an interpolating OSC source: it isn't needed.
- **Not MA's own Art-Net Timecode output.** MA3 has Art-Net Timecode entries with Mode Broadcast or Unicast. On onPC 2.5.1 they sent nothing in four setups: unicast and broadcast, with Art-Net Output on, and with the slot fed by Art-Net input or a running Timecode show. If they work on a console, they would be frame-accurate and need no plugin; check that on #43 before relying on the plugin's packets.
- **The settings live in the show.** The mode, the bridge address, the slot, the frame rate and the Set path are kept in the show's global variables.

## What we measured on onPC 2.5.1

- The slot's `Time` changes about 24 times a second with 25 fps Art-Net input, although the plugin loop runs at 57 Hz. So bridge mode sends about 20 frames a second. Most steps are one frame, about one in five is two frames, and once in a while a step goes 2–4 frames back when MA corrects its extrapolation. All of these are inside the Mac engine's Jump tolerance (5 frames), so none counts as a Jump.
- MA keeps the slot running for its afterroll (0.5 s by default) after timecode stops, so the Mac app sees timecode about 12 frames longer than the source sent it.
- The frame rate comes from the panel's Timecode setting, not from the input: the slot has no rate. If it is set wrong, the Mac app gets the wrong frames and the wrong rate.

## Consequences

- Bridge readings are not frame-accurate, so the Mac app fires up to about two frames later than it would from the source directly. Where the Mac can receive the timecode source itself, that is better than the bridge.
- LuaSocket loads on onPC for macOS. Consoles and Windows onPC are unchecked (#43). Without it, bridge mode shows an alert and sends nothing.
