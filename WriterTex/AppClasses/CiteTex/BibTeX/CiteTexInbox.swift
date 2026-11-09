//
//  CiteTexInbox.swift
//  BibTeXKit — linked by BOTH the app and the CiteTex Safari extension.
//
//  The extension is sandboxed and cannot see the user's project, so it cannot
//  write to the active .bib directly. Instead it appends captures to a small
//  .bib inside the shared App Group container; the app drains that into
//  whichever .bib is active. This replaces Writerly's CitationStore, where the
//  App Group file *was* the library.
//
//  The inbox is itself BibTeX, so it is readable by eye and parsed by the same
//  code as everything else.
//

import Foundation

nonisolated struct CiteTexInbox: Sendable {
    /// Team-ID-prefixed App Group. macOS grants any process signed by team
    /// URGQW7YQ67 access to it with no provisioning profile, so the app and the
    /// extension must both sign as that team and both list this group in their
    /// entitlements. Keep this line and both entitlements files identical.
    static let defaultAppGroup = "URGQW7YQ67.group.VD.TypeNBash"

    static let filename = "citetex-inbox.bib"

    let fileURL: URL
    private var lockURL: URL { fileURL.appendingPathExtension("lock") }

    /// Nil when the App Group container is unavailable — almost always a
    /// signing-team or entitlements mismatch.
    init?(appGroup: String = CiteTexInbox.defaultAppGroup) {
        guard let dir = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        self.init(directory: dir)
    }

    init(directory: URL) {
        fileURL = directory.appendingPathComponent(Self.filename)
    }

    // MARK: - Extension side

    /// Appends captured records. Returns how many captures are now waiting.
    @discardableResult
    func append(_ citations: [Citation]) throws -> Int {
        guard !citations.isEmpty else { return try pendingCount() }
        return try withLock {
            var doc = try readUnlocked()
            // Within the inbox, a repeat capture of the same paper is a no-op.
            doc.append(citations)
            try doc.write(to: fileURL)
            return doc.entries.count
        }
    }

    // MARK: - App side

    /// Creates an empty inbox if there is none, so a file watcher can attach.
    func prepare() throws {
        try withLock {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try Data().write(to: fileURL, options: .atomic)
            }
        }
    }

    func pendingCount() throws -> Int {
        try withLock { try readUnlocked().entries.count }
    }

    /// Every waiting capture. Nothing is removed: call `discard(keys:)` once
    /// they are safely in a .bib.
    ///
    /// Two steps rather than one locked drain, because writing the .bib may be
    /// an async write over SSH — far too long to hold a lock the extension is
    /// waiting on, and a failed write must not lose what the user captured.
    func pending() throws -> [Citation] {
        try withLock { try readUnlocked().entries.map(\.citation) }
    }

    /// Removes the given captures. Anything captured since `pending()` stays:
    /// a new capture that reused a key was disambiguated on arrival, so it
    /// cannot be mistaken for one of these.
    func discard(keys: Set<String>) throws {
        guard !keys.isEmpty else { return }
        try withLock {
            var doc = try readUnlocked()
            let ids = Set(doc.entries.filter { keys.contains($0.key) }.map(\.id))
            guard doc.remove(ids: ids) > 0 else { return }
            try doc.write(to: fileURL)
        }
    }

    // MARK: - Plumbing

    private func readUnlocked() throws -> BibDocument {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return BibDocument(text: "")
        }
        return try BibDocument(contentsOf: fileURL)
    }

    /// Two processes touch this file, so it is guarded by an advisory lock on a
    /// sidecar file. (Locking the inbox itself would not work: the atomic writes
    /// above replace its inode, and the lock would go with the old one.)
    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileLocking) }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
