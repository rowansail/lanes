// Lanes — account lanes for Claude Code
// Copyright (C) 2026 rowansail
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A shell the app knows how to hook into.
public enum ShellFlavor: String, CaseIterable, Identifiable, Sendable {
    case zsh
    case bash
    case fish

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .zsh:  return "zsh"
        case .bash: return "bash"
        case .fish: return "fish"
        }
    }

    /// The startup file that gets the four-line loader block.
    ///
    /// The choices differ per shell and are not arbitrary:
    ///
    /// - **zsh → `.zshenv`.** The only zsh startup file read for *every* invocation,
    ///   including non-interactive ones. `claude -p …` from a script, a git hook or a
    ///   launchd job would otherwise run against whichever account is the default.
    ///   `.zprofile` is the more usual advice, and for `PATH` it is the right advice —
    ///   but this variable has to reach shells that no human ever sees.
    /// - **bash → `.bash_profile`.** macOS Terminal runs login shells, so this is the
    ///   file that actually gets read. Non-interactive bash reads neither this nor
    ///   `.bashrc`; it reads `$BASH_ENV`, which is not ours to set.
    /// - **fish → `config.fish`.** fish has one config file and reads it for every
    ///   shell, so there is nothing to choose.
    public var relativeConfigPath: String {
        switch self {
        case .zsh:  return ".zshenv"
        case .bash: return ".bash_profile"
        case .fish: return ".config/fish/config.fish"
        }
    }

    /// The managed file this shell's loader block sources.
    public var hookFileName: String {
        switch self {
        case .zsh:  return "hook.zsh"
        case .bash: return "hook.bash"
        case .fish: return "hook.fish"
        }
    }

    /// Does the hook reach non-interactive shells in this flavour?
    ///
    /// Only zsh. Worth surfacing rather than hiding, because it decides whether
    /// `claude` invoked from a script picks up the right account, and someone
    /// scripting against bash needs to know they have to export the variable
    /// themselves.
    public var coversScripts: Bool { self == .zsh }

    /// The login shell of the current user, if the app supports it.
    ///
    /// Read from the passwd database rather than `$SHELL`: the app is launched by
    /// launchd and never saw a shell environment, so `$SHELL` is absent or stale.
    public static func matching(loginShell path: String) -> ShellFlavor? {
        let name = (path as NSString).lastPathComponent
        return ShellFlavor.allCases.first { $0.rawValue == name }
    }
}

/// The shell side of the app: what gets written where, and what it does.
///
/// The layout is deliberately two files per shell rather than one:
///
/// 1. A four-line **loader block** in the user's startup file, between markers. It
///    sources the second file and does nothing else.
/// 2. The **hook script** itself, in `~/.config/lanes/`, which the app owns outright.
///
/// The reason is that the app then almost never has to edit the startup file again.
/// Every upgrade rewrites a file in its own directory; the block in `.zshenv` is
/// written once and is stable forever. Editing someone's shell config is the riskiest
/// thing this app does, so doing it exactly once is worth an extra file.
///
/// It also makes "reinstall the hook" a plain file write instead of a parse-and-splice
/// of a file that may have changed underneath us.
public enum ShellHook {

    /// Bumped whenever a hook script changes.
    ///
    /// Written into the script as a comment and parsed back out, which is what lets
    /// the app notice "your hook is from an older version" — otherwise an outdated
    /// hook and a current one are indistinguishable from the outside, and someone
    /// keeps hitting a bug that was fixed months ago.
    public static let revision = 2

    private static let revisionMarker = "lanes-hook-revision:"

    // MARK: - The loader block

    /// The body of the managed block in the startup file.
    ///
    /// Guarded on readability so that deleting `~/.config/lanes` cannot break the
    /// user's shell — a missing hook degrades to "no profile switching", never to an
    /// error on every prompt.
    public static func loaderBlock(for flavor: ShellFlavor, at locations: Locations) -> String {
        // $HOME rather than the absolute path: the block survives the home directory
        // moving — a restored backup, a renamed account — and it keeps the username
        // out of a file people paste into bug reports.
        let path = locations.hookFile(for: flavor).path
        let home = locations.home.path
        let target = path.hasPrefix(home + "/")
            ? "$HOME/" + path.dropFirst(home.count + 1)
            : path

        let preamble = """
        # \(Branding.name) — \(Branding.tagline)
        # Managed block. The hook itself lives in \(target);
        # edit that, or delete these lines to switch it off.
        """

        // Guarded on readability, so deleting the hook file cannot break the user's
        // shell. A missing hook degrades to "no profile switching", never to an
        // error on every prompt.
        switch flavor {
        case .zsh, .bash:
            return preamble + "\n[ -r \"\(target)\" ] && . \"\(target)\""
        case .fish:
            return preamble + "\ntest -r \"\(target)\"; and source \"\(target)\""
        }
    }

    // MARK: - Installing

    /// Writes the hook script and puts the loader block in the startup file.
    ///
    /// Order matters: script first. If the block landed first and then the script
    /// write failed, every new shell would source a file that is not there — harmless
    /// thanks to the readability guard, but it would report a working install that
    /// does nothing.
    public static func install(_ flavor: ShellFlavor, at locations: Locations) throws {
        try AtomicFile.write(script(for: flavor), to: locations.hookFile(for: flavor))

        let config = locations.shellConfigFile(for: flavor)
        try backUpOnce(config, at: locations)

        let existing = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
        let updated = ManagedBlock.current.installing(
            loaderBlock(for: flavor, at: locations), into: existing)

        try writePreservingMode(updated, to: config)
    }

    /// Takes the loader block out and deletes the hook script.
    ///
    /// Only ever removes our own block. Anything the user wrote around it — including
    /// their own `export CLAUDE_CONFIG_DIR`, which is theirs to keep — stays.
    public static func remove(_ flavor: ShellFlavor, at locations: Locations) throws {
        let config = locations.shellConfigFile(for: flavor)
        if let existing = try? String(contentsOf: config, encoding: .utf8),
           ManagedBlock.current.isPresent(in: existing)
            || ManagedBlock.current.isDamaged(in: existing) {
            try writePreservingMode(ManagedBlock.current.strip(from: existing), to: config)
        }

        try? FileManager.default.removeItem(at: locations.hookFile(for: flavor))
    }

    // MARK: - State

    public struct State: Equatable, Sendable {
        public var flavor: ShellFlavor

        /// Does the startup file have our loader block?
        public var blockInstalled: Bool

        /// A begin marker with no end marker — a half-edited file.
        public var blockDamaged: Bool

        /// Does the hook script exist?
        public var scriptInstalled: Bool

        /// The revision found in the script, if it could be read.
        public var scriptRevision: Int?

        /// Is the startup file present at all? A shell someone does not use has no
        /// config file, and that is not a fault.
        public var configFileExists: Bool

        /// Fully working: block in place, script present, script current.
        public var isCurrent: Bool {
            blockInstalled && scriptInstalled && scriptRevision == ShellHook.revision
        }

        /// Installed but out of date — reinstalling fixes it.
        public var isOutdated: Bool {
            blockInstalled && scriptInstalled && scriptRevision != ShellHook.revision
        }

        /// Installed at all, in any state.
        public var isInstalled: Bool { blockInstalled || scriptInstalled }
    }

    public static func state(of flavor: ShellFlavor, at locations: Locations) -> State {
        let fm = FileManager.default
        let config = locations.shellConfigFile(for: flavor)
        let configText = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
        let scriptURL = locations.hookFile(for: flavor)
        let scriptText = try? String(contentsOf: scriptURL, encoding: .utf8)

        return State(
            flavor: flavor,
            blockInstalled: ManagedBlock.current.isPresent(in: configText),
            blockDamaged: ManagedBlock.current.isDamaged(in: configText),
            scriptInstalled: fm.fileExists(atPath: scriptURL.path),
            scriptRevision: scriptText.flatMap(parseRevision),
            configFileExists: fm.fileExists(atPath: config.path))
    }

    /// Reads `# lanes-hook-revision: N` out of a script.
    public static func parseRevision(_ script: String) -> Int? {
        for line in script.components(separatedBy: "\n") {
            guard let range = line.range(of: revisionMarker) else { continue }
            let tail = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return Int(tail)
        }
        return nil
    }

    // MARK: - Writing someone else's file

    /// Backs up a startup file the first time we touch it, and only then.
    ///
    /// Once, not every time: a backup that is overwritten on each run is not a
    /// backup, it is a copy of the current state. The one worth keeping is the file
    /// as it was before this app had ever seen it.
    private static func backUpOnce(_ config: URL, at locations: Locations) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: config.path) else { return }

        let backup = locations.backup(of: config)
        guard !fm.fileExists(atPath: backup.path) else { return }
        try fm.copyItem(at: config, to: backup)
    }

    /// Atomic write that keeps the file's existing permissions.
    ///
    /// `AtomicFile.write` forces `0600`, which is right for our own state but wrong
    /// here: a `.zshenv` is commonly `0644`, and silently tightening a file the user
    /// owns is a surprise they did not ask for. So this writes atomically and then
    /// restores whatever mode was there before.
    private static func writePreservingMode(_ text: String, to url: URL) throws {
        let fm = FileManager.default
        let previousMode = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions]
            as? NSNumber

        try AtomicFile.write(text, to: url)

        if let previousMode {
            chmod(url.path, mode_t(previousMode.uint16Value))
        } else {
            // A file we just created. 0644 is what a shell config normally is, and
            // it contains nothing private.
            chmod(url.path, 0o644)
        }
    }
}
