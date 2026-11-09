//
//  BibSelectionStore.swift
//  WriterTex
//
//  Remembers which .bib each project uses, keyed by the host's project UUID.
//
//  A file inside the project is stored relative to the root, so the choice
//  survives the folder moving and works for a remote root, whose paths mean
//  nothing on this Mac. A file outside it is stored as an absolute path.
//
//  Defaults to UserDefaults. A host with portable per-project settings (say,
//  a field in the project's manifest) can implement the protocol on that
//  instead, so the choice travels with the project.
//

import Foundation

@MainActor
protocol BibSelectionStoring: AnyObject {
    func bibURL(forProject id: UUID, root: URL) -> URL?
    func setBibURL(_ url: URL?, forProject id: UUID, root: URL)
}

nonisolated final class BibSelectionStore: BibSelectionStoring {
    private let defaults: UserDefaults
    private let prefix = "CiteTexKit.bib."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func bibURL(forProject id: UUID, root: URL) -> URL? {
        guard let stored = defaults.string(forKey: prefix + id.uuidString) else { return nil }
        return Self.resolve(stored, root: root)
    }

    func setBibURL(_ url: URL?, forProject id: UUID, root: URL) {
        let key = prefix + id.uuidString
        if let url {
            defaults.set(Self.relativePath(of: url, root: root), forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// `refs/main.bib` for a file under the root; `/abs/path.bib` otherwise.
    /// Plain path arithmetic, no symlink resolution: a remote path cannot be
    /// resolved on this machine.
    nonisolated static func relativePath(of url: URL, root: URL) -> String {
        let base = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    nonisolated static func resolve(_ stored: String, root: URL) -> URL {
        stored.hasPrefix("/")
            ? URL(fileURLWithPath: stored).standardizedFileURL
            : root.appendingPathComponent(stored).standardizedFileURL
    }
}
