# Testing the TrigIT Windows spike

Thanks for testing! This is not the Windows app yet. It is a small program in a
command window that listens to timecode, fires a Set's OSC messages at the right
moments, and measures how well Windows keeps time while doing it. What we learn
decides how the real Windows app gets built ([issue #60](https://github.com/jrikner/TrigIT/issues/60)).

It takes about 20 minutes. You need a Windows 10 or 11 PC and at least one of:

- **Art-Net Timecode** from something on the network: a lighting console (grandMA, ETC Eos, ChamSys, Avolites), Resolume, Ableton with an Art-Net plug-in, or a timecode generator app.
- **LTC** (audio timecode) on an audio input: from a playback rig, a timecode generator, or simply an LTC audio file played from a phone or another computer into your line-in or audio interface.

## 1. Download

1. Open [the CI workflow runs](https://github.com/jrikner/TrigIT/actions/workflows/ci.yml) and click the newest run with a green tick, on `main`.
2. Scroll down to **Artifacts** and click **TrigIT-Windows** to download a zip. You must be signed in to GitHub; while the repository is private, you must also have accepted your invitation to it. A download is kept for 90 days, so use a recent run.
3. Right-click the zip, choose **Extract All…**, and extract it to a folder, for example `C:\TrigIT-Windows`.

The folder holds `TrigITWindows.exe`, the Swift runtime files it needs (the `.dll` files: keep them next to the `.exe`), an example Set `windows-spike-example.trigit`, and this guide.

## 2. Open a command window in that folder

Open the folder in File Explorer, click the address bar, type `cmd` and press Enter. A black command window opens in the folder. Check the program starts:

```
TrigITWindows.exe --help
```

- If Windows says **VCRUNTIME140.dll was not found**, install the [Microsoft Visual C++ Redistributable (x64)](https://aka.ms/vs/17/release/vc_redist.x64.exe) and try again.
- If SmartScreen says **Windows protected your PC** when you run it, click **More info**, then **Run anyway**. The program is not signed yet.

## 3. Tell it where to send OSC

The example Set has three Songs: Song 1 starts at **00:00:10:00**, Song 2 at **00:01:00:00** and Song 3 at **00:02:00:00**. Each sends one OSC message, `/trigit/song` with the Song's number, to `127.0.0.1` port `9000` (this PC).

That is fine as it is: the timing is measured whether or not anything listens. To see the messages arrive somewhere, open `windows-spike-example.trigit` in Notepad and change `"host"` and `"port"` near the top to the computer and port of something that receives OSC (Resolume, Protokol, TouchOSC…). If you have a TrigIT Set from the Mac, you can use that instead.

## 4. Test with Art-Net Timecode

1. Start your Art-Net Timecode sender, pointing at this PC or broadcasting on the network, at any frame rate.
2. In the command window:

   ```
   TrigITWindows.exe windows-spike-example.trigit --source artnet
   ```

3. When Windows Firewall asks, **allow access** on the network you are using (private networks are enough for most show networks). Without it, no timecode arrives.
4. Play timecode across the Songs' start times: for example from 00:00:05:00 for 2½ minutes. Also try stopping and starting, and jumping around. The window prints a line for each Song that fires, and a status line every 5 seconds.
   Your browser also opens TrigIT's page at <http://127.0.0.1:7319/>: the playhead, the current Song and the recent fires. Keep it open during the test and note anything that looks wrong or lags.
5. Press **Ctrl+C**. The program writes `TrigIT-timing-report-<date>-<time>.txt` in the folder and tells you its name.

If nothing arrives: check the sender sends Art-Net *Timecode* (not only DMX), that both are on the same network, and that the firewall allowed it. Another program on this PC holding UDP port 6454 can also block it; close it, or try `--artnet-port`.

## 5. Test with LTC

1. List the audio inputs:

   ```
   TrigITWindows.exe --list-devices
   ```

2. Connect LTC to an input and start it with part of that input's name, and the channel the LTC is on (1 is left or the first input):

   ```
   TrigITWindows.exe windows-spike-example.trigit --source ltc --ltc-device "Focusrite" --ltc-channel 1
   ```

   Leave out `--ltc-device` to use the Windows default recording device. If the input stays silent or the program reports an error ending in `0x80070005`, turn on **Settings > Privacy & security > Microphone > Let desktop apps access your microphone**: Windows treats every audio input as a microphone.
3. Play LTC across the Songs as in step 4, then press **Ctrl+C**.

The status line shows the input's level. "LTC input silent" means no sound arrives: check the cable, the channel, and Windows' **Sound settings > Input** volume. Aim for a peak between about -20 and -3 dBFS.

## 6. Both at once (if you can)

If you have Art-Net Timecode and LTC running together, the first `--source` is followed and the second takes over when the first stops:

```
TrigITWindows.exe windows-spike-example.trigit --source artnet --source ltc --ltc-device "Focusrite"
```

Unplug or stop the first one mid-way to see the take-over.

## 7. Send the reports

Add a comment on [issue #60](https://github.com/jrikner/TrigIT/issues/60) and drag each report `.txt` file into it. Please also write a few lines:

- the PC (make and model, or CPU), Windows version, and the audio interface;
- what sent the timecode, and at which frame rate;
- anything odd you saw or heard: messages that came late, twice, or not at all.

## Options

| Option | Meaning |
|---|---|
| `--source artnet` or `--source ltc` | The timecode to follow. Give it twice for a main and a backup source. Default: `artnet`. |
| `--ltc-device <name>` | Part of the audio input's name, from `--list-devices`. Default: the Windows default recording device. |
| `--ltc-channel <n>` | The input channel carrying LTC, from 1. Default: 1. |
| `--artnet-port <port>` | The UDP port for Art-Net. Default: 6454. |
| `--report <file>` | Where to write the report. |
| `--duration <seconds>` | Stop by itself after this long, instead of waiting for Ctrl+C. |
| `--ui-port <port>` | The port of the browser page at `http://127.0.0.1:<port>/`; `0` turns the page off. Default: 7319. |
| `--no-browser` | Serve the page but don't open the browser. |

The zip also has `ci-smoke-report.txt`: the report from GitHub's own test run on a cloud Windows machine, for comparison.

## What the report means

- **Songs fired**: how many Songs fired. *Late* means a Song fired on a later frame than its start time while timecode played normally (frames went missing); *double* means a Song fired twice without anything that should re-fire it; *missed* means a Song became current without firing. All three should be 0.
- **Frame arrival jitter**: how far apart frames arrived compared with a perfect frame interval, in milliseconds. Lower is better; for LTC it includes the audio buffer size.
- **Send latency**: from the moment timecode reached the program to the moment the OSC message left it. Should be well under a millisecond.
- **Clock ticks**: how evenly Windows wakes the program up every 10 ms. This is the timer the real app would rely on.
