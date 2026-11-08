# A Windows spike on the shared core, with Windows calls in a small C shim

ADR 0001 gave up Windows. Issue #60 reopens it as a second app on the shared core (`TrigITProtocols`, `TrigITEngine`, `TrigITStorage`), and before choosing a UI we built a console spike, `TrigITWindows`, to learn whether Windows keeps show timing. It follows Art-Net Timecode and LTC, drives the unchanged `ShowEngine` with a `.trigit` Set, sends the OSC Actions, and writes a timing report. It is a real target on main, declared only when building on Windows, built and smoke-run by CI's Windows job, which uploads it as the `TrigIT-Windows` artifact for testers (`docs/windows-spike.md`).

## Decisions

- **Split portable from Windows-only.** Argument parsing, the engine loop and the report statistics live in `TrigITSpike`, a Foundation-only library built and tested on every platform. The Windows target is only I/O glue, so most of the spike's logic is covered by `swift test` on the Mac and Linux.
- **Windows calls go through a C shim (`CWindowsIO`), not Swift's `WinSDK` overlay.** WASAPI is COM; calling vtables from Swift is clumsy, and which Windows headers the overlay imports (high-resolution timer flags, `mmdeviceapi.h`, macros such as `stdout`) is uncertain without a Windows machine to try on. In C, with `COBJMACROS`, it is the well-trodden way, and the header Swift imports has only `stdint.h` types. We define our own copies of the COM GUIDs and property key so nothing depends on which import libraries define them.
- **Timer: a periodic high-resolution waitable timer** (`CreateWaitableTimerExW` with `CREATE_WAITABLE_TIMER_HIGH_RESOLUTION`, Windows 10 1803+), plus `timeBeginPeriod(1)`, with a standard waitable timer as the fallback. The default timer granularity is about 15.6 ms; the clock tick must run every 10 ms. The timer is periodic so ticks don't drift by each tick's work.
- **Timecode does not wait for the timer.** Art-Net is received on its own thread with a blocking `recv`, and LTC on WASAPI's event-driven capture thread (registered with MMCSS as "Pro Audio"); each reading goes straight through the engine and out as OSC under one lock. Only Stop detection and lost-source alerts depend on the tick. So timer granularity costs nothing in fire latency; it only matters for MTC-style polling, which the spike doesn't do.
- **One clock: `QueryPerformanceCounter`.** WASAPI's capture timestamps (`u64QPCPosition`) are on the same clock, so an LTC frame's start time is exact, as on macOS. We don't use `ProcessInfo.systemUptime`, whose source on Windows we have not checked.
- **Winsock:** `SO_REUSEADDR` to share port 6454 with other Art-Net software (Windows has no `SO_REUSEPORT`, and its `SO_REUSEADDR` lets sockets share or take over a port), `SO_BROADCAST`, IPv4 only. There is no `IP_BOUND_IF`; binding to one interface would mean binding to its address. Not done in the spike.
- **Distribution:** the artifact is `TrigITWindows.exe` plus every DLL in the Swift runtime folder (Foundation, ICU, Dispatch and the Microsoft C++ runtime the toolchain ships), about 70 MB unzipped, mostly ICU. Unsigned, so SmartScreen warns.

## What we learned so far

From CI only (GitHub's `windows-latest`, a 2-core cloud VM, Swift 6.4.2): the spike builds in release, runs from its folder with no Swift toolchain on the PATH, receives Art-Net Timecode on localhost and fires the example Set on time. Its clock ticks came out at p50 10.03 ms, p99 10.56 ms, max 16.09 ms over 8 s; one OSC send took 0.39 ms from frame arrival. Other things noticed:

- An enum case named `INT16` clashes with the Windows typedef of the same name: name C identifiers defensively.
- Through a pipe, a Windows console app's stdout is fully buffered, so the spike flushes after each batch of lines.
- `ProcessInfo.operatingSystemVersionString` reported "Windows Server 2019 (build 26100)" on the CI VM; trust the build number, not the name.

LTC through WASAPI, and everything on real hardware with a real network and audio interface, has not run yet. A tester's reports on #60 decide the next step (the UI approach); update this ADR with them.
