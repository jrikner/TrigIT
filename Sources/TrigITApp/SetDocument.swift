import AppKit
import Foundation
import TrigITEngine
import TrigITStorage
import UniformTypeIdentifiers

/// The Set's file: open, new, save as, autosave, undo, recent Sets and
/// previous versions. One Set is open at a time.
extension ShowModel {
    static let applicationSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("TrigIT", isDirectory: true)
    }()

    /// Where new Sets go unless the person picks somewhere else.
    static var defaultSetsFolder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return documents.appendingPathComponent("TrigIT", isDirectory: true)
    }

    static let setFileType = UTType(filenameExtension: SetFile.fileExtension, conformingTo: .json) ?? .json
    private static let lastDocumentKey = "TrigIT.lastDocument"
    private static let quitCleanlyKey = "TrigIT.quitCleanly"
    private static let recentDocumentsKey = "TrigIT.recentDocuments"
    private static let maxRecentDocuments = 10
    /// Changes are written this long after the last edit (and at once on quit).
    private static let saveDelay = 0.3
    /// While editing, a previous version is kept at most this often.
    private static let versionInterval: TimeInterval = 120

    /// The open Set's name as the toolbar shows it.
    var setTitle: String {
        documentURL?.deletingPathExtension().lastPathComponent ?? "Not Saved"
    }

    // MARK: Opening

    /// At launch: after a crash or a forced quit (TrigIT may have died
    /// mid-show), reopen the last Set straight away; otherwise show the
    /// welcome screen.
    func openLastDocument() {
        recentDocuments = (UserDefaults.standard.stringArray(forKey: Self.recentDocumentsKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
        // The app delegate saves through this on quit, synchronously.
        ShowModel.current = self
        let quitCleanly = UserDefaults.standard.object(forKey: Self.quitCleanlyKey) as? Bool ?? true
        UserDefaults.standard.set(false, forKey: Self.quitCleanlyKey)
        if !quitCleanly, let path = UserDefaults.standard.string(forKey: Self.lastDocumentKey) {
            open(URL(fileURLWithPath: path))
        } else {
            showingWelcome = true
        }
    }

    /// Called on a normal quit, so the next launch shows the welcome screen.
    static func markQuitCleanly() {
        UserDefaults.standard.set(true, forKey: quitCleanlyKey)
    }

    func open(_ url: URL) {
        saveNow()
        do {
            let loaded = try SetFile.read(from: url)
            history.reset()
            replaceSet(loaded)
            documentURL = url
            documentProblem = nil
            lastVersionSaved = nil
            keepVersion() // the Set as opened, before any edit
            remember(url)
            showingWelcome = false
            openingSetName = url.deletingPathExtension().lastPathComponent
            record("Opened \(url.lastPathComponent)")
        } catch {
            // Never overwrite a file we couldn't read: start an unsaved empty Set.
            history.reset()
            replaceSet(ShowSet())
            documentURL = nil
            let reason = (error as? SetFile.ReadError)?.description ?? error.localizedDescription
            documentProblem = "Couldn't open \(url.lastPathComponent): \(reason) Open another Set, or create a new one."
            record(documentProblem!, isError: true)
            forget(url)
            openingSetName = nil
            showingWelcome = true
        }
    }

    func chooseAndOpen() {
        guard !isShowLocked else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.setFileType, .json]
        panel.message = "Open a TrigIT Set"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    // MARK: Creating and saving

    func chooseAndCreateNew() {
        guard !isShowLocked else { return }
        guard let url = askForLocation(title: "New Set", name: "New Set") else { return }
        var set = ShowSet(name: url.deletingPathExtension().lastPathComponent)
        // Bring the Destinations along: they usually stay the same between shows.
        set.destinations = self.set.destinations
        write(set, to: url, opening: true)
        if documentURL == url { showingNewSetSetup = true }
    }

    /// Creates and opens the example Set in the default folder.
    func openExample() {
        guard !isShowLocked else { return }
        create(Self.exampleSet, inFolder: Self.defaultSetsFolder)
    }

    /// Asks for a CSV file, creates a new Set named after it and imports its Songs.
    func chooseAndImportCSVAsNewSet() {
        guard !isShowLocked else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.message = "Choose a CSV file with the columns name, start, end (hh:mm:ss:ff)."
        guard panel.runModal() == .OK, let csv = panel.url,
              let text = (try? String(contentsOf: csv, encoding: .utf8)) ?? (try? String(contentsOf: csv, encoding: .isoLatin1))
        else { return }
        var set = ShowSet(name: csv.deletingPathExtension().lastPathComponent)
        let report = set.importSongs(csv: text)
        create(set, inFolder: Self.defaultSetsFolder)
        record("Imported \(report.imported.count) Song(s) from \(csv.lastPathComponent); skipped \(report.problems.count) row(s)",
               isError: !report.problems.isEmpty)
    }


    /// Saves the current Set to a new place and carries on there.
    func chooseAndSaveAs() {
        guard let url = askForLocation(title: "Save Set As", name: documentURL?.deletingPathExtension().lastPathComponent ?? set.name) else { return }
        write(set, to: url, opening: true)
    }

    func showInFinder() {
        guard let documentURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([documentURL])
    }

    private func create(_ set: ShowSet, inFolder folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent("\(set.name).\(SetFile.fileExtension)")
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(set.name) \(number).\(SetFile.fileExtension)")
            number += 1
        }
        write(set, to: url, opening: true)
    }

    private func write(_ set: ShowSet, to url: URL, opening: Bool) {
        do {
            try SetFile.write(set, to: url)
            if opening { open(url) }
        } catch {
            documentProblem = "Couldn't save \(url.lastPathComponent): \(error.localizedDescription)"
            record(documentProblem!, isError: true)
        }
    }

    private func askForLocation(title: String, name: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.allowedContentTypes = [Self.setFileType]
        panel.nameFieldStringValue = name
        try? FileManager.default.createDirectory(at: Self.defaultSetsFolder, withIntermediateDirectories: true)
        panel.directoryURL = documentURL?.deletingLastPathComponent() ?? Self.defaultSetsFolder
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: Autosave

    func scheduleSave() {
        pendingSave?.cancel()
        let save = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.saveNow() }
        }
        pendingSave = save
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: save)
    }

    /// Writes any unsaved change now.
    func saveNow() {
        guard let save = pendingSave else { return }
        save.cancel()
        pendingSave = nil
        guard let documentURL else { return }
        do {
            try SetFile.write(set, to: documentURL)
            if documentProblem?.hasPrefix("Couldn't save") == true { documentProblem = nil }
            if let last = lastVersionSaved, Date().timeIntervalSince(last) < Self.versionInterval { return }
            keepVersion()
        } catch {
            documentProblem = "Couldn't save \(documentURL.lastPathComponent): \(error.localizedDescription). Changes are kept in TrigIT until saving works again."
            record(documentProblem!, isError: true)
        }
    }

    // MARK: Undo

    func undo() {
        guard !isShowLocked, let previous = history.undo(from: set) else { return }
        replaceSet(previous)
        scheduleSave()
        record("Undo")
    }

    func redo() {
        guard !isShowLocked, let next = history.redo(from: set) else { return }
        replaceSet(next)
        scheduleSave()
        record("Redo")
    }

    // MARK: Previous versions

    var previousVersions: [SetVersion] {
        versionStore.versions(of: set.id)
    }

    /// Goes back to an earlier version. The current Set is kept as a version
    /// first, and the change can be undone.
    func restore(_ version: SetVersion) {
        guard !isShowLocked else { return }
        do {
            var restored = try SetFile.read(from: version.url)
            restored.id = set.id
            keepVersion()
            history.record(before: set, at: now)
            replaceSet(restored)
            scheduleSave()
            record("Restored the version from \(version.date.formatted(date: .abbreviated, time: .standard))")
        } catch {
            record("Couldn't restore that version: \(error)", isError: true)
        }
    }

    /// The newest version stays marked while TrigIT is Armed.
    func markCurrentVersionUsedInShow() {
        if let latest = previousVersions.first { versionStore.markUsedInShow(latest) }
    }

    private func keepVersion() {
        guard documentURL != nil else { return }
        do {
            let version = try versionStore.save(set, at: Date())
            if isArmed { versionStore.markUsedInShow(version) }
            lastVersionSaved = Date()
        } catch {
            record("Couldn't keep a previous version: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: Recent Sets

    private func remember(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: Self.lastDocumentKey)
        recentDocuments = Array(([url] + recentDocuments.filter { $0.path != url.path }).prefix(Self.maxRecentDocuments))
        UserDefaults.standard.set(recentDocuments.map(\.path), forKey: Self.recentDocumentsKey)
    }

    private func forget(_ url: URL) {
        recentDocuments.removeAll { $0.path == url.path }
        UserDefaults.standard.set(recentDocuments.map(\.path), forKey: Self.recentDocumentsKey)
        if UserDefaults.standard.string(forKey: Self.lastDocumentKey) == url.path {
            UserDefaults.standard.removeObject(forKey: Self.lastDocumentKey)
        }
    }
}
