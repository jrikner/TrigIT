import Foundation
import TrigITEngine

/// One automatically kept earlier version of a Set.
public struct SetVersion: Hashable, Sendable {
    public var url: URL
    public var date: Date
    /// Whether TrigIT was Armed while this was the current version.
    public var usedInShow: Bool = false
}

/// Keeps earlier versions of Sets in a folder of its own (normally in
/// Application Support), one subfolder per Set ID, so they follow a Set that
/// is renamed or moved and never clutter the folder the Set lives in.
public struct SetVersionStore: Sendable {
    public let directory: URL
    /// Versions kept per Set; the oldest go first.
    public let limit: Int

    public init(directory: URL, limit: Int = 100) {
        self.directory = directory
        self.limit = limit
    }

    /// Saves a copy of the Set as it is at `date`, then removes the oldest
    /// versions beyond the limit.
    @discardableResult
    public func save(_ set: ShowSet, at date: Date) throws -> SetVersion {
        let folder = folder(for: set.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let url = folder.appendingPathComponent("\(milliseconds).\(SetFile.fileExtension)")
        try SetFile.write(set, to: url)
        for old in versions(of: set.id).dropFirst(limit) {
            try? FileManager.default.removeItem(at: old.url)
            try? FileManager.default.removeItem(at: old.url.deletingPathExtension().appendingPathExtension("used"))
        }
        return SetVersion(url: url, date: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
    }

    /// The Set's kept versions, newest first.
    public func versions(of id: SetID) -> [SetVersion] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder(for: id), includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url -> SetVersion? in
            guard url.pathExtension == SetFile.fileExtension,
                  let milliseconds = Int64(url.deletingPathExtension().lastPathComponent) else { return nil }
            let used = FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("used").path)
            return SetVersion(url: url, date: Date(timeIntervalSince1970: Double(milliseconds) / 1000), usedInShow: used)
        }
        .sorted { $0.date > $1.date }
    }

    /// Marks a version as having been current while TrigIT was Armed, with an
    /// empty file next to it.
    public func markUsedInShow(_ version: SetVersion) {
        FileManager.default.createFile(atPath: version.url.deletingPathExtension().appendingPathExtension("used").path, contents: nil)
    }

    private func folder(for id: SetID) -> URL {
        directory.appendingPathComponent(String(id.rawValue), isDirectory: true)
    }
}
