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
One piece of music in the Set, with its Start Actions and optional Stop Actions, and at least one way to be triggered: a span of timecode (start to end time), a Start Note, a Stop Note, or any combination. Timecode outside every span belongs to no Song.
_Avoid_: Track (clashes with Ableton's tracks), cue, scene

**Action**:
One outgoing message a Song sends: an OSC message, a MIDI message, or an Art-Net/sACN pulse.
_Avoid_: Command, output, trigger

**Start Actions**:
The Actions a Song sends on Entering.
_Avoid_: On-enter, cue

**Stop Actions**:
The optional Actions a Song sends on Ending, used for example for a DJ pull-up that must tell other gear the set has stopped. Usually empty.
_Avoid_: Exit actions, release, off-cue

**Destination**:
A named device that Actions are sent to, such as "Resolume" or "MA3", holding its network address and/or MIDI port. Each Action names one Destination.
_Avoid_: Endpoint, target, output, device

**Start Note**:
An optional incoming MIDI note (channel and note number) that makes a Song Enter without timecode, for example a DJ pull-up triggered from Ableton.
_Avoid_: Trigger note, MIDI cue

**Stop Note**:
An optional incoming MIDI note that makes its Song End if it is current. A Song with only a Stop Note sends its Stop Actions every time the note arrives.
_Avoid_: Release note, off note

**Entering**:
A Song becoming the current Song: the Playhead arriving inside its span from outside it (by playing in or by a Jump landing anywhere inside it), or its Start Note arriving while it is not current.
_Avoid_: Hitting, reaching

**Ending**:
The current Song finishing: a Stop while it is current, the Playhead playing on past its end time, or its Stop Note arriving. A Jump out of a Song is not Ending. A Song Ends at most once per Entering.
_Avoid_: Exiting, leaving, release

**Firing**:
A Song sending all its Start Actions, once, on Entering. Moving or jumping within the same Song does not fire it again; leaving it, or a Stop, re-arms it.
_Avoid_: Triggering, executing

**Armed**:
The app-wide state in which Firing sends Actions. When disarmed, the app still follows timecode but sends nothing.
_Avoid_: Live, enabled, active

**Show Lock**:
A switch that makes the Set read-only during a show, while arming and manual firing still work.
_Avoid_: Lock mode, edit lock, safe mode
