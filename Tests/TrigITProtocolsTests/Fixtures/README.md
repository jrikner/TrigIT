# LTC reference recordings

Raw mono audio, unsigned 8-bit, 48 kHz, written by libltc 1.3.2 (an LTC implementation independent of TrigIT) at -18 dBFS with a 40 µs rise time. Each name gives the frame rate and the first frame's timecode.

| File | Frames | Crosses |
|---|---|---|
| `libltc-24fps-01-00-58-00.u8` | 72 | a minute (01:00:59:23 → 01:01:00:00) |
| `libltc-25fps-01-00-58-00.u8` | 75 | a minute |
| `libltc-2997df-00-00-58-00.u8` | 90 | a dropped minute (00:00:59:29 → 00:01:00:02) |
| `libltc-30fps-23-59-59-00.u8` | 60 | midnight (23:59:59:29 → 00:00:00:00) |

Generated with a small C program around `ltc_encoder_encode_frame`: create the encoder with `ltc_encoder_create(48000, fps, standard, 0)`, call `ltc_encoder_set_filter(e, 40)` and `ltc_encoder_set_volume(e, -18)`, set the start time, then encode and increment once per frame.
