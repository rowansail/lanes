// Lanes — account lanes for Claude Code
// Copyright (C) 2026 rowansail
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Every path the app touches, derived from one home directory.
///
/// The home directory is a stored property rather than a call to
/// `FileManager.default.homeDirectoryForCurrentUser` at each use site, and that is
/// the whole point of this type: a test can hand it a freshly created temporary
/// directory and then exercise migration, hook installation and cleanup for real —
/// actual renames, actual symlinks, actual file writes — without touching the
/// developer's own `~/.claude`.
///
/// Before this existed, the only way to test any of that was to read the code and
/// hope.
public struct Locations: Equatable, Sendable {

    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    /// The real home directory of the current user.
    public static var real: Locations {
        Locations(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    // MARK: - Ours

    /// `~/.config/lanes` — the only directory this app owns outright.
    public var stateDirectory: URL {
        home.appendingPathComponent(".config/\(Branding.slug)", isDirectory: true)
    }

    /// `~/.config/lanes/active` — one line, the slug of the active profile.
    ///
    /// This file is the source of truth. The menu bar renders it, the shell hook
    /// reads it, and the `lane` command writes it. Everything else is derived.
    public var stateFile: URL {
        stateDirectory.appendingPathComponent("active")
    }

    /// Where the previous version kept its state, for detection only.
    public var legacyStateDirectory: URL {
        home.appendingPathComponent(".config/\(Branding.legacySlug)", isDirectory: true)
    }

    public var legacyStateFile: URL {
        legacyStateDirectory.appendingPathComponent("active")
    }

    /// `~/.config/lanes/hook.zsh` — the shell hook itself.
    ///
    /// Deliberately not inlined into the user's `.zshenv`. The startup file gets a
    /// four-line block that sources this, so upgrades rewrite a file the app owns
    /// instead of splicing a file it does not. Editing someone's shell config is the
    /// riskiest thing this app does; doing it exactly once is worth an extra file.
    public func hookFile(for flavor: ShellFlavor) -> URL {
        stateDirectory.appendingPathComponent(flavor.hookFileName)
    }

    // MARK: - Claude Code's

    /// `~/.claude` — a symlink to the active profile, once set up.
    ///
    /// Worth being clear about: this link switches *nothing*. Claude Code finds its
    /// config through `CLAUDE_CONFIG_DIR`. The link exists so that tools which
    /// `readlink ~/.claude` — an older VS Code extension, a script someone wrote —
    /// do not report something different from the menu bar.
    public var claudeLink: URL {
        home.appendingPathComponent(".claude")
    }

    /// `~/.claude.json` — the config Claude Code uses when no profile is active.
    /// Lives beside `~/.claude`, not inside it, which is why migration has to copy
    /// it separately.
    public var looseClaudeConfig: URL {
        home.appendingPathComponent(".claude.json")
    }

    public func profileDirectory(for slug: String) -> URL {
        home.appendingPathComponent(Branding.profilePrefix + slug, isDirectory: true)
    }

    // MARK: - Shell config

    public func shellConfigFile(for flavor: ShellFlavor) -> URL {
        home.appendingPathComponent(flavor.relativeConfigPath)
    }

    /// Where a shell config file's backup goes, before the app first edits it.
    public func backup(of configFile: URL) -> URL {
        URL(fileURLWithPath: configFile.path + ".\(Branding.slug)-backup")
    }

    /// `~/.zshrc` — reported on, never written to. See ``Setup/conflicts(in:)``.
    public var zshrc: URL {
        home.appendingPathComponent(".zshrc")
    }

    /// Turns `/Users/someone/.claude-work` into `~/.claude-work` for display.
    public func abbreviate(_ path: String) -> String {
        guard path == home.path || path.hasPrefix(home.path + "/") else { return path }
        return "~" + path.dropFirst(home.path.count)
    }
}
