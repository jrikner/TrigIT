// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import TrigITEngine

// The Windows UI (issue #1, ADR 0004): a page in the browser, served by the
// app on 127.0.0.1. The page only reads; timecode and firing never wait on it.

extension SpikeSession {
    /// What the page shows, polled as JSON.
    public struct Status: Encodable, Equatable {
        public struct SongRow: Encodable, Equatable {
            public var name: String
            public var start: String?
            public var end: String?
            public var current: Bool
        }

        public struct FireRow: Encodable, Equatable {
            public var at: Double
            public var timecode: String
            public var song: String
            public var ended: Bool
            public var framesLate: Int?
            public var failed: Bool
        }

        public var set: String
        public var playhead: String?
        public var frameRate: String?
        public var following: String
        public var alert: String?
        public var stopped: Bool
        public var songs: [SongRow]
        /// Newest first.
        public var recentFires: [FireRow]
        public var fired: Int
        public var missed: Int
        public var doubleFires: Int
        public var failedSends: Int
    }

    public func status() -> Status {
        let current = engine.currentSongID
        let alertText: String? = switch engine.alert {
        case .primaryLostRunningOnBackup: "Primary timecode lost, following the Backup"
        case .allTimecodeLost: "All timecode lost"
        case nil: nil
        }
        return Status(
            set: engine.set.name,
            playhead: engine.playhead.map { "\($0)" },
            frameRate: engine.frameRate.map { "\($0.rawValue) fps" },
            following: engine.liveSource.rawValue,
            alert: alertText,
            stopped: engine.isStopped,
            songs: engine.set.songs.map {
                .init(name: $0.name, start: $0.hasSpan ? "\($0.start)" : nil, end: $0.hasSpan ? "\($0.end)" : nil,
                      current: $0.id == current)
            },
            recentFires: fires.suffix(20).reversed().map {
                .init(at: $0.time - startedAt, timecode: "\($0.timecode)", song: $0.songName, ended: $0.ended,
                      framesLate: $0.framesLate, failed: $0.failures > 0)
            },
            fired: fires.filter { !$0.ended }.count,
            missed: missedFires,
            doubleFires: doubleFires,
            failedSends: failedSends)
    }
}

/// Answers one HTTP/1.1 request. The caller owns the socket: it reads the
/// request, writes the response and closes the connection.
public enum WebUI {
    /// `status` is called only for /status, so the caller's lock is held only then.
    public static func respond(to request: [UInt8], status: () -> SpikeSession.Status) -> [UInt8] {
        let firstLine = String(decoding: request.prefix { $0 != 13 && $0 != 10 }, as: UTF8.self)
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            return response(405, "text/plain", Array("Only GET".utf8))
        }
        switch parts[1].split(separator: "?").first ?? "" {
        case "/":
            return response(200, "text/html; charset=utf-8", Array(page.utf8))
        case "/status":
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let body = (try? encoder.encode(status())) ?? Data("{}".utf8)
            return response(200, "application/json", Array(body))
        default:
            return response(404, "text/plain", Array("Not found".utf8))
        }
    }

    static func response(_ code: Int, _ type: String, _ body: [UInt8]) -> [UInt8] {
        let reason = [200: "OK", 404: "Not Found", 405: "Method Not Allowed"][code] ?? ""
        let head = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        return Array(head.utf8) + body
    }

    // ponytail: polls /status 10 times a second; switch to Server-Sent Events if that ever shows up in a profile.
    static let page = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>TrigIT</title>
    <style>
      :root { color-scheme: light dark; --bg: #111; --fg: #eee; --dim: #888; --line: #2a2a2a; --accent: #2fbf71; --warn: #e5a50a; --bad: #e5484d; }
      @media (prefers-color-scheme: light) { :root { --bg: #fafafa; --fg: #111; --dim: #666; --line: #ddd; } }
      * { box-sizing: border-box; }
      body { margin: 0; font: 15px/1.4 system-ui, "Segoe UI", sans-serif; background: var(--bg); color: var(--fg); }
      header { display: flex; align-items: baseline; gap: 1rem; padding: 1rem 1.5rem; border-bottom: 1px solid var(--line); }
      header h1 { font-size: 1rem; margin: 0; }
      header .set { color: var(--dim); }
      header .source { margin-left: auto; color: var(--dim); }
      #alert { display: none; padding: .75rem 1.5rem; background: var(--bad); color: #fff; font-weight: 600; }
      main { display: grid; grid-template-columns: minmax(0, 2fr) minmax(0, 3fr); gap: 1.5rem; padding: 1.5rem; }
      @media (max-width: 800px) { main { grid-template-columns: 1fr; } }
      #playhead { font: 600 clamp(2.5rem, 8vw, 5rem)/1 ui-monospace, Consolas, monospace; font-variant-numeric: tabular-nums; }
      #playhead.waiting { color: var(--dim); }
      #rate { color: var(--dim); margin-top: .25rem; }
      #counts { display: flex; gap: 1.5rem; margin-top: 1.5rem; }
      #counts div { color: var(--dim); font-size: .85rem; }
      #counts b { display: block; color: var(--fg); font-size: 1.4rem; font-variant-numeric: tabular-nums; }
      #counts b.bad { color: var(--bad); }
      h2 { font-size: .8rem; text-transform: uppercase; letter-spacing: .06em; color: var(--dim); margin: 0 0 .5rem; }
      table { width: 100%; border-collapse: collapse; }
      td { padding: .4rem .5rem; border-bottom: 1px solid var(--line); font-variant-numeric: tabular-nums; }
      td.tc { font-family: ui-monospace, Consolas, monospace; color: var(--dim); white-space: nowrap; }
      tr.current td { background: color-mix(in srgb, var(--accent) 18%, transparent); }
      tr.current td:first-child { box-shadow: inset 3px 0 var(--accent); }
      .late { color: var(--warn); } .failed { color: var(--bad); }
      section + section { margin-top: 1.5rem; }
      #offline { display: none; color: var(--bad); }
    </style>
    </head>
    <body>
    <header><h1>TrigIT</h1><span class="set" id="set"></span><span id="offline">Not connected to TrigIT</span><span class="source" id="source"></span></header>
    <div id="alert" role="alert"></div>
    <main>
      <div>
        <div id="playhead" class="waiting">--:--:--:--</div>
        <div id="rate">No timecode yet</div>
        <div id="counts">
          <div><b id="fired">0</b>fired</div>
          <div><b id="missed">0</b>missed</div>
          <div><b id="double">0</b>double</div>
          <div><b id="failed">0</b>failed sends</div>
        </div>
      </div>
      <div>
        <section><h2>Songs</h2><table><tbody id="songs"></tbody></table></section>
        <section><h2>Recent fires</h2><table><tbody id="fires"></tbody></table></section>
      </div>
    </main>
    <script>
    const $ = id => document.getElementById(id);
    const esc = s => String(s).replace(/[&<>"]/g, c => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;"}[c]));
    let last = "";
    function render(s) {
      $("set").textContent = s.set;
      $("source").textContent = "Following " + s.following;
      $("playhead").textContent = s.playhead || "--:--:--:--";
      $("playhead").classList.toggle("waiting", !s.playhead || s.stopped);
      $("rate").textContent = s.stopped ? "Stopped" : (s.frameRate || "No timecode yet");
      $("alert").style.display = s.alert ? "block" : "none";
      $("alert").textContent = s.alert || "";
      for (const [id, n] of [["fired", s.fired], ["missed", s.missed], ["double", s.doubleFires], ["failed", s.failedSends]]) {
        $(id).textContent = n;
        $(id).classList.toggle("bad", id !== "fired" && n > 0);
      }
      const songs = JSON.stringify(s.songs);
      if (songs !== last) {
        last = songs;
        $("songs").innerHTML = s.songs.map(r => `<tr class="${r.current ? "current" : ""}"><td>${esc(r.name)}</td><td class="tc">${r.start ? esc(r.start) + " – " + esc(r.end) : ""}</td></tr>`).join("");
      }
      $("fires").innerHTML = s.recentFires.length ? s.recentFires.map(f => {
        const note = f.failed ? `<span class="failed">send failed</span>` : f.framesLate > 0 ? `<span class="late">${f.framesLate} frames late</span>` : "";
        return `<tr><td class="tc">${esc(f.timecode)}</td><td>${f.ended ? "ended" : "fired"} ${esc(f.song)}</td><td>${note}</td></tr>`;
      }).join("") : `<tr><td class="tc">None yet</td></tr>`;
    }
    async function poll() {
      try {
        const r = await fetch("/status", {cache: "no-store"});
        render(await r.json());
        $("offline").style.display = "none";
      } catch {
        $("offline").style.display = "inline";
      }
      setTimeout(poll, 100);
    }
    poll();
    </script>
    </body>
    </html>
    """#
}
