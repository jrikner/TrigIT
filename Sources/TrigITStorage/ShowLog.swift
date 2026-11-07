import Foundation

/// The show log on disk: one plain-text file per day, named by its date
/// (`2026-11-07.log`), so what happened during a show can be read afterwards.
/// Files whose day is older than `retentionDays` are removed.
public struct ShowLog: Sendable {
    public let directory: URL
    public let retentionDays: Int
    public let calendar: Calendar

    public init(directory: URL, retentionDays: Int = 30, calendar: Calendar = .current) {
        self.directory = directory
        self.retentionDays = retentionDays
        self.calendar = calendar
    }

    /// The file for the day `date` falls on.
    public func fileURL(for date: Date) -> URL {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        let name = String(format: "%04d-%02d-%02d.log", day.year!, day.month!, day.day!)
        return directory.appendingPathComponent(name)
    }

    /// Appends one line, stamped with the time of day, to that day's file.
    public func append(_ text: String, at date: Date) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let time = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let stamp = String(format: "%02d:%02d:%02d.%03d", time.hour!, time.minute!, time.second!, time.nanosecond! / 1_000_000)
        let line = Data("\(stamp)  \(text)\n".utf8)
        let url = fileURL(for: date)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try line.write(to: url)
            return
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// Removes the log files for days more than `retentionDays` before `date`.
    /// Other files in the folder are left alone.
    public func removeOldFiles(now date: Date) {
        guard let cutoff = calendar.date(byAdding: .day, value: -retentionDays, to: calendar.startOfDay(for: date)) else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "log" {
            guard let day = day(of: url), day < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func day(of url: URL) -> Date? {
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
