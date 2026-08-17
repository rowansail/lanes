// Lanes — account lanes for Claude Code
// Copyright (C) 2026 rowansail
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Darwin

/// Notices when one small file changes, without polling for it.
///
/// The app used to check the state file every two seconds. That worked, but it meant
/// waking the CPU 30 times a minute forever to read four bytes that almost never
/// change — and it still made switching from a terminal feel laggy, because the menu
/// bar could be two seconds behind. A vnode event source fixes both: nothing happens
/// until the file actually changes, and then it happens immediately.
///
/// Two subtleties make this more than a one-liner:
///
/// **Atomic writes destroy the thing you are watching.** A vnode source is attached to
/// an open file descriptor, which refers to an *inode*, not a path. Write-then-rename —
/// which both this app and the shell hook do deliberately, so no reader ever sees a
/// truncated file — puts a brand-new inode at the path and leaves the old one
/// orphaned. The descriptor stays valid and stays silent forever. So `.delete` and
/// `.rename` are not "the file went away", they are "re-open the path".
///
/// **The file may not exist yet.** Before first setup there is no state file, and
/// there is nothing to attach to. Watching the containing directory as well covers
/// that: a directory changes when an entry is created, removed or renamed inside it,
/// which is exactly the set of events a path-based watcher needs and an inode-based one
/// cannot see.
///
/// `DispatchSource` rather than FSEvents on purpose. FSEvents is built for whole
/// directory trees, comes with a latency window and its own daemon; for one file it is
/// heavier for no benefit.
public final class FileWatcher {

    private let url: URL
    private let onChange: () -> Void
    private let queue: DispatchQueue

    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?

    /// Coalesces bursts. An editor saving a file, or a rename immediately followed by
    /// a directory event, can easily produce three events for one logical change; the
    /// callback should fire once.
    private var pending: DispatchWorkItem?
    private let debounce: DispatchTimeInterval = .milliseconds(80)

    public init(url: URL, queue: DispatchQueue = .main, onChange: @escaping () -> Void) {
        self.url = url
        self.queue = queue
        self.onChange = onChange
        watchDirectory()
        watchFile()
    }

    deinit {
        pending?.cancel()
        fileSource?.cancel()
        directorySource?.cancel()
    }

    public func stop() {
        pending?.cancel()
        pending = nil
        fileSource?.cancel()
        fileSource = nil
        directorySource?.cancel()
        directorySource = nil
    }

    // MARK: - Arming

    private func watchFile() {
        fileSource?.cancel()
        fileSource = nil

        // O_EVTONLY: open purely to receive events. It does not count as a reference
        // that would keep a volume busy, so watching a file on an external disk does
        // not stop the user ejecting it.
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }   // not there yet; the directory covers us

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .link, .revoke],
            queue: queue)

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let data = self.fileSource?.data ?? []

            // The path may now point at a different inode. Re-attach before telling
            // anyone, so the next change is not missed while the callback runs.
            if !data.intersection([.delete, .rename, .revoke]).isEmpty {
                self.watchFile()
            }
            self.notify()
        }

        // Closing the descriptor belongs in the cancel handler and nowhere else: that
        // is the one place GCD guarantees no event handler is still using it.
        source.setCancelHandler { close(descriptor) }

        fileSource = source
        source.resume()
    }

    private func watchDirectory() {
        let directory = url.deletingLastPathComponent()

        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: queue)

        source.setEventHandler { [weak self] in
            guard let self else { return }

            // Something in the directory changed. If that something was our file
            // being created or replaced, the current file watch is stale or absent.
            self.watchFile()
            self.notify()
        }
        source.setCancelHandler { close(descriptor) }

        directorySource = source
        source.resume()
    }

    private func notify() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
