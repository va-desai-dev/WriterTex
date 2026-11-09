//
//  FileWatcher.swift
//  WriterTex
//
//  The watching half of Writerly's LinkedLibraryWatcher, without the sandbox
//  bookmark and persistence parts (TypeNBash is not sandboxed, and the IDE —
//  not this code — decides which .bib is active).
//
//  The awkward detail is that almost nothing rewrites a file in place. Zotero,
//  BibDesk, JabRef and most editors write a temporary file and rename it over
//  the target. A kqueue watch is attached to the *inode*, not the path — so the
//  moment the rename lands, the watch is holding a descriptor for a file that no
//  longer has a name, and it never fires again. Handling that is most of this
//  file.
//

import Foundation

final class FileWatcher {
    let url: URL
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: Task<Void, Never>?
    private var active = false

    init(url: URL, onChange: @escaping @MainActor () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    func start() {
        guard !active else { return }
        active = true
        attach()
    }

    func stop() {
        active = false
        detach()
    }

    private func attach() {
        // O_EVTONLY asks for a descriptor purely for event delivery: it does not
        // count as a reference that would keep the file open.
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // Not there yet — a Zotero auto-export that has not run, say.
            retryLater()
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.source else { return }
                let flags = source.data
                if flags.contains(.rename) || flags.contains(.delete) || flags.contains(.revoke) {
                    // The path now names a different inode: the atomic-replace
                    // case, and the common one, not the exception.
                    self.reattach()
                } else {
                    self.schedule()
                }
            }
        }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    private func detach() {
        pending?.cancel()
        pending = nil
        source?.cancel()          // the cancel handler closes the descriptor
        source = nil
    }

    /// A short delay lets the writer finish; without it the new file is
    /// occasionally still being renamed.
    private func reattach() {
        detach()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard self.active, self.source == nil else { return }
            self.attach()
            self.schedule(delay: .zero)
        }
    }

    private func retryLater() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard self.active, self.source == nil else { return }
            self.attach()
            if self.source != nil { self.schedule(delay: .zero) }
        }
    }

    /// Coalesces bursts. A single save can produce several write events, and
    /// reacting to each one would read a half-written file.
    private func schedule(delay: Duration = .milliseconds(400)) {
        pending?.cancel()
        pending = Task { @MainActor in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, self.active else { return }
            self.onChange()
        }
    }
}
