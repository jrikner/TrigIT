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

**Stop**:
Timecode ceasing from every Timecode Source for longer than a set time, as when Ableton's transport stops. Shorter gaps are Dropouts.
_Avoid_: Pause, halt

**Dropout**:
A brief loss of timecode that is not a Stop; it never re-arms a Song.
_Avoid_: Glitch, loss

**Simulator**:
A virtual Timecode Source inside the app for programming and testing a Set without real timecode.
_Avoid_: Test mode, generator

### Show

**Set**:
The show: an ordered list of Songs, each with its own span of timecode.
_Avoid_: Show file, playlist, cue list

**Song**:
One piece of music in the Set, owning a span of timecode from a start to an end time, and the Actions to send when that span is entered. Timecode between Songs belongs to no Song.
_Avoid_: Track (clashes with Ableton's tracks), cue, scene

**Action**:
One outgoing message a Song sends: an OSC message, a MIDI message, or an Art-Net/sACN pulse.
_Avoid_: Command, output, trigger

**Destination**:
A named device that Actions are sent to, such as "Resolume" or "MA3", holding its network address and/or MIDI port. Each Action names one Destination.
_Avoid_: Endpoint, target, output, device

**Entering**:
The Playhead arriving inside a Song's span from outside it, by playing into it or by a Jump landing anywhere inside it.
_Avoid_: Hitting, reaching

**Firing**:
A Song sending all its Actions, once, on Entering. Moving or jumping within the same Song does not fire it again; leaving it, or a Stop, re-arms it.
_Avoid_: Triggering, executing

**Armed**:
The app-wide state in which Firing sends Actions. When disarmed, the app still follows timecode but sends nothing.
_Avoid_: Live, enabled, active

**Show Lock**:
A switch that makes the Set read-only during a show, while arming and manual firing still work.
_Avoid_: Lock mode, edit lock, safe mode
