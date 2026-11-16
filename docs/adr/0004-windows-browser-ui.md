# The Windows UI is a page in the browser, served by the app

The Windows version (issue #1, ADR 0002) needs a UI. We looked at WinUI 3 from Swift first: The Browser Company archived its ready-made Swift bindings for WinUI and the Windows App SDK in October 2025, and the last versions depend on local folders, so another package can't use them. What's left is generating our own bindings with `swift-winrt` (0.1.x, Windows-only, and per its own notes unable to project all of WinUI). With no Windows PC to try it on, that was too much risk for the UI.

So the Windows app serves its UI as a web page from the same process: the Show Engine, the timecode inputs and the senders stay in Swift, and a browser shows the page.

## Decisions

- **Loopback only.** The listener binds `127.0.0.1` with `SO_EXCLUSIVEADDRUSE`, so nobody on the show network can reach it and no Firewall prompt appears for it. Default port 7319, `--ui-port 0` turns it off.
- **The UI never sits on the timing path.** Timecode readings, firing and sends run on their own threads as before. The HTTP thread takes the session lock only to copy a status snapshot, which is microseconds. Closing the browser changes nothing about the show.
- **One HTTP thread, one request per connection** (`Connection: close`), with 2 s socket timeouts so a stalled client can't hold it. The page polls `/status` (JSON) 10 times a second. Server-Sent Events would cut requests, but polling is simpler and enough on loopback.
- **Request handling and the page are portable Swift** (`WebUI` in `TrigITSpike`), tested with `swift test` on every platform. The Windows target only accepts sockets (`CWindowsIO`) and opens the default browser (`ShellExecuteA`).
- **No new dependencies.** No web framework, no JavaScript build step; the page is one HTML string with inline CSS and script.

## What this first step covers

The page only reads: playhead, frame rate, followed source, timecode alerts, the Set's Songs with the current one highlighted, recent fires with late and failed marks, and the fired, missed, double and failed-send counts. Editing a Set, Arm and Disarm, and choosing sources still go through the `.trigit` file and the command line. They come next, once a real-PC test confirms the spike's timing.

## Later

Since the page doesn't depend on Windows, the Mac and Linux could serve it too. If a native window is wanted later, a WebView2 host or Tauri can wrap the same page.
