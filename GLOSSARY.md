# TrigIT

A macOS app that follows incoming show timecode and fires output messages to other show devices when the timecode reaches programmed points.

## Language

### Timecode

**Timecode Source**:
One incoming timecode stream of a given kind: LTC, MTC or Art-Net Timecode.
_Avoid_: Input, clock

**Primary Source**:
The Timecode Source the app follows while it is healthy.

**Backup Source**:
An optional Timecode Source the app follows automatically while the Primary Source is lost.
_Avoid_: Fallback, secondary

**Playhead**:
The current timecode position the app is following, taken from the live Timecode Source.
_Avoid_: Current time, position

**Jump**:
A discontinuity in the Playhead: timecode arriving at a position that is not the natural next frame (skipping forward, backward, or starting mid-show).
_Avoid_: Seek, scrub, locate

### Cues

**Cue**:
A single point in timecode with the messages to send when the Playhead reaches it.
_Avoid_: Trigger, event, marker

**Firing**:
A Cue sending its messages. A Cue fires when the Playhead passes its time in normal playback, or when a Jump lands after it and before the next Cue.
_Avoid_: Triggering, executing
