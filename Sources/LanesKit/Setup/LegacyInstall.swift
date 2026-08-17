// Lanes — account lanes for Claude Code
// Copyright (C) 2026 rowansail
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AppKit

/// An install left behind by the previous name of this app.
///
/// The app used to be called something that led with a trademark it does not own, so it
/// was renamed. That is cheap for the code and not cheap for the user: their `.zshenv`
/// has a block with the old markers, and `~/.config/<old name>/active` holds the
/// profile they were using. Ignoring both would leave two hook blocks exporting
/// `CLAUDE_CONFIG_DIR` from the same file, with the later one silently winning — the
/// exact class of "why is it using the wrong account" bug this app exists to eliminate.
///
/// So it is detected, described, and offered as something to adopt. Detection is
/// read-only; nothing here changes anything until ``adopt(_:at:)`` is called from the
/// wizard, with the plan on screen first.
public enum LegacyInstall {

    public struct Findings: Equatable, Sendable {

        /// Startup files still carrying a block with the old markers.
        public var blockFiles: [URL] = []

        /// The profile the old install had active, if its state file is readable.
        public var stateSlug: String?

        /// The old state directory, if it exists.
        public var stateDirectory: URL?

        public var isPresent: Bool {
            !blockFiles.isEmpty || stateDirectory != nil
        }

        /// Whether adopting would change which profile is active.
        ///
        /// Only true when the old install knew something the new one does not. If the
        /// current state file already names a profile, that one wins — a rename is not
        /// a reason to move somebody to a different account behind their back.
        public var carriesState: Bool { stateSlug != nil }

        public var description: String {
            var parts: [String] = []
            if !blockFiles.isEmpty {
                let names = blockFiles.map(\.lastPathComponent).joined(separator: ", ")
                parts.append("\(names) still has a block with the old "
                             + "'\(Branding.legacySlug)' markers")
            }
            if let stateSlug {
                parts.append("the old state file says '\(stateSlug)' was active")
            } else if stateDirectory != nil {
                parts.append("the old state directory is still there")
            }
            return parts.joined(separator: "; ") + "."
        }
    }

    /// The previous version's application bundle, and whether it is running now.
    ///
    /// Deliberately not part of ``Findings``, for two reasons. It is not found by
    /// looking at the home directory like everything else here — it asks Launch
    /// Services, which no test with a temporary `Locations` can influence. And it is
    /// not something the wizard can fix: an app cannot uninstall another app, and one
    /// that tried would deserve every bit of the suspicion that followed.
    ///
    /// Reporting it still matters. Renaming produced a *second* bundle; the old one
    /// keeps its own menu bar item, keeps writing `~/.config/claude-switcher/active`,
    /// and keeps repointing the `~/.claude` symlink. Somebody looking at two menu bar
    /// items wondering why switching in one of them does nothing deserves a straight
    /// answer.
    public static func installedApp() -> (url: URL, isRunning: Bool)? {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: Branding.legacyBundleIdentifier) else { return nil }

        let running = !NSRunningApplication.runningApplications(
            withBundleIdentifier: Branding.legacyBundleIdentifier).isEmpty

        return (url, running)
    }

    public static func detect(in locations: Locations) -> Findings {
        var findings = Findings()
        let fm = FileManager.default

        // Every startup file the old version could plausibly have written to, not just
        // the one it preferred: someone may have moved the block by hand.
        let candidates = ShellFlavor.allCases.map { locations.shellConfigFile(for: $0) }
            + Setup.conflictSources(in: locations)

        var seen = Set<String>()
        for file in candidates where !seen.contains(file.path) {
            seen.insert(file.path)
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            if ManagedBlock.legacy.isPresent(in: text)
                || ManagedBlock.legacy.isDamaged(in: text) {
                findings.blockFiles.append(file)
            }
        }

        if fm.fileExists(atPath: locations.legacyStateDirectory.path) {
            findings.stateDirectory = locations.legacyStateDirectory
        }
        findings.stateSlug = AtomicFile.readTrimmed(locations.legacyStateFile)

        return findings
    }

    /// Takes over from the old install: keep the profile it had active, remove its
    /// block, install the current hook, and put the old state directory in the Trash.
    ///
    /// Order is deliberate. State is carried over *first*, so that if anything later
    /// fails the user has not lost track of which profile they were on. The old block
    /// goes before the new hook is installed, so there is never a moment with two
    /// blocks in one file.
    public static func adopt(_ findings: Findings,
                             at locations: Locations,
                             installing flavor: ShellFlavor? = nil) throws {
        // 1. Carry over which profile was active — but never overwrite a newer answer.
        if let slug = findings.stateSlug,
           AtomicFile.readTrimmed(locations.stateFile) == nil,
           FileManager.default.fileExists(
                atPath: locations.profileDirectory(for: slug).path) {
            try Setup.writeState(slug, at: locations)
        }

        // 2. Remove the old block from every file that has one. Back the file up first
        //    if this app has never touched it, because from the user's point of view
        //    this is the first time a differently-named app has edited their config.
        for file in findings.blockFiles {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }

            let backup = locations.backup(of: file)
            if !FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.copyItem(at: file, to: backup)
            }

            try AtomicFile.write(ManagedBlock.legacy.strip(from: text), to: file)
            chmod(file.path, 0o644)
        }

        // 3. The current hook, for the shell they actually use.
        if let flavor {
            try ShellHook.install(flavor, at: locations)
        } else {
            try Setup.installHook(at: locations)
        }

        // 4. The old state directory. To the Trash rather than deleted — it is only a
        //    slug in a text file, but it is the last record of the old install and
        //    deleting things outright is a habit worth not having.
        if let directory = findings.stateDirectory,
           FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.trashItem(at: directory, resultingItemURL: nil)
        }
    }
}
