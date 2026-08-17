// Lanes — account lanes for Claude Code
// Copyright (C) 2026 rowansail
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A project pinned to one profile by a `.lanes` file.
///
/// This is the app's answer to the failure it actually exists to prevent. Switching
/// from the menu bar is global and stateful, which means it is exactly as reliable as
/// your memory: you switch to personal for an evening, come back on Monday, open a
/// client's repo and Claude Code is happily using the wrong account. A pin removes
/// memory from the loop — the project itself says which account it belongs to, and the
/// shell hook honours that regardless of what is globally active.
///
/// The pin deliberately outranks the global setting. An explicit, per-project,
/// checked-in statement of intent should beat a menu click from last Tuesday.
public struct ProjectLock: Equatable, Hashable, Sendable {

    /// The directory holding the lock file — not necessarily the one you were in.
    public let directory: URL

    /// The profile this project belongs to.
    public let slug: String

    public init(directory: URL, slug: String) {
        self.directory = directory
        self.slug = slug
    }

    public var file: URL {
        directory.appendingPathComponent(Branding.lockFileName)
    }

    /// Is the profile named by this pin actually on this machine?
    ///
    /// A pin naming a profile that does not exist is worth reporting rather than
    /// silently ignoring: it usually means the file was committed by a colleague whose
    /// profile is called something else, and the fix is a conversation, not a retry.
    public func resolves(in locations: Locations) -> Bool {
        FileManager.default.fileExists(
            atPath: locations.profileDirectory(for: slug).path)
    }
}

public enum ProjectLocks {

    public enum Failure: LocalizedError {
        case noLockHere(URL)

        public var errorDescription: String? {
            switch self {
            case .noLockHere(let url):
                return "There is no \(Branding.lockFileName) in \(url.path)."
            }
        }
    }

    /// Walks up from `start` looking for a lock file, exactly as the shell hook does.
    ///
    /// Walking up rather than checking one directory is what makes the feature usable:
    /// you pin the repository root once, and it holds in every subdirectory you happen
    /// to be standing in. Stops before `/` — a lock file at the filesystem root would
    /// apply to every project on the machine, which is never what anyone meant.
    public static func find(from start: URL) -> ProjectLock? {
        var directory = start.standardizedFileURL

        while directory.path != "/" && !directory.path.isEmpty {
            let candidate = directory.appendingPathComponent(Branding.lockFileName)
            if let slug = AtomicFile.readTrimmed(candidate) {
                return ProjectLock(directory: directory, slug: slug)
            }

            let parent = directory.deletingLastPathComponent().standardizedFileURL
            // deletingLastPathComponent on "/" returns "/", so without this the loop
            // never ends on a path that somehow reaches the root.
            if parent == directory { break }
            directory = parent
        }

        return nil
    }

    /// Pins a directory to a profile.
    ///
    /// Written `0644`, not `0600` like the app's own state: a lock file is meant to be
    /// committed and read by colleagues, and there is nothing private in a profile
    /// name.
    public static func write(slug: String, in directory: URL) throws {
        let file = directory.appendingPathComponent(Branding.lockFileName)
        try AtomicFile.write(slug + "\n", to: file)
        chmod(file.path, 0o644)
    }

    public static func remove(in directory: URL) throws {
        let file = directory.appendingPathComponent(Branding.lockFileName)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw Failure.noLockHere(directory)
        }
        try FileManager.default.removeItem(at: file)
    }
}

// `ProjectLockRegistry` lived here: a UserDefaults list of the pins the app had made,
// so the menu could show them. It went with the menu entry that was its only writer.
//
// It is not worth reviving in another form. The app is launched by launchd and has no
// current directory, so "which pin applies to me" is a question it structurally cannot
// answer, and enumerating every pin on the disk would mean scanning the whole home
// directory. The shell can answer both in a few lines because it is standing in the
// directory — which is what `lane` and `doctor.sh` do.
