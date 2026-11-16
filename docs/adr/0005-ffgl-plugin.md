# The Resolume plugin is an FFGL effect that runs the Lua engine

The request: TrigIT inside Resolume as an FFGL plugin, so a show needs no second app. FFGL is a video-effect interface, but a plugin is ordinary native code in Resolume's process, so it can keep a thread and UDP sockets. We found no published FFGL plugin that fires cues from timecode; the tools that do this for Resolume (TimeCue, LTCue, ShowCockpit, Chataigne) are separate apps.

## Decisions

- **Run `ma3-plugin/src/engine.lua`, don't port the engine a third time.** The plugin embeds Lua 5.4 (about 250 KB) and loads the grandMA3 plugin's `engine`, `timecode` and `json` modules unchanged, so the Swift engine and its Lua port stay the only two to keep in step. Linking the Swift engine was the alternative: fine on a Mac, but on Windows it would put about 70 MB of Swift runtime DLLs beside the plugin, where Resolume's loader may not find them.
- **An effect, not a source.** A source runs only while its clip plays. An effect on the Composition is there for the whole show and passes the picture through.
- **The engine has its own thread.** Resolume calls the plugin once per frame; firing from there would be a frame late and would stop when the effect isn't drawn. The thread blocks on the Art-Net socket and fires the moment a packet arrives, as the Windows spike does (ADR 0002).
- **One engine per process.** Every copy of the effect shares it, so two copies never fire a Song twice.
- **Art-Net Timecode in and OSC out only, for now.** Both are plain UDP. LTC and MTC need an audio or MIDI device opened inside Resolume's process, and MIDI out likewise; they wait until the plugin is proven in Resolume.
- **Cues are typed into parameters.** FFGL gives a plugin sliders, toggles, text boxes and file choosers, no lists or windows, so the Mac app's Set editor can't be rebuilt there. Sixteen Cues, each a time and a Resolume column (or an OSC message), cover the common show with no file and no other app; `host.lua` turns them into a Set for the unchanged engine. A Set file is still read, for what Cues can't say.
- **Lua and the FFGL SDK are fetched at build time**, pinned to a commit, not copied into the repository.

## Not known yet

Nobody has loaded the plugin into Resolume. Unchecked: that Resolume keeps a Composition effect initialised for the whole session; that the `.trigit` file parameter shows a file chooser; that text parameters are comfortable for typing Cue times; whether Resolume's own Art-Net input and the plugin both receive unicast packets on port 6454; fire latency on a real show machine.
