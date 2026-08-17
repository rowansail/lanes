// Lanes — account lanes for Claude Code
// Copyright (C) 2026 rowansail
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Every name and path the app writes, in one place.
///
/// This file exists because the app used to be called something else, and renaming
/// it meant hunting the old string through markers in `~/.zshenv`, a directory under
/// `~/.config`, a backup suffix, a bundle identifier and a dozen strings of user
/// visible prose. Once was enough.
///
/// The rule: nothing outside this file spells the product name in a string that ends
/// up on disk. Prose in the UI may of course say "Lanes"; a *path* may not.
public enum Branding {

    /// What the app is called to a human.
    public static let name = "Lanes"

    /// One-line description. Kept here because it appears in the About text, the
    /// README and the Homebrew cask, and those drifting apart looks sloppy.
    public static let tagline = "Account lanes for Claude Code"

    /// Lowercase, filesystem-safe form. Used for `~/.config/<slug>`, the marker
    /// comments in shell config, and the backup suffix.
    public static let slug = "lanes"

    public static let bundleIdentifier = "nl.rowansail.lanes"

    /// Semantic version. `build.sh` reads this line to fill in the Info.plist, so this
    /// is the one place a release is numbered — there is no second copy to forget.
    public static let version = "1.0.0"

    /// Where to report a bug. Printed in the diagnostics report, because the single
    /// most useful thing a user can do when the undocumented behaviour this app relies
    /// on changes is tell somebody, with a version number attached.
    public static let repositoryURL = "https://github.com/rowansail/lanes"

    /// Required wherever the app names itself alongside Claude.
    ///
    /// Not decoration and not excessive caution. `CLAUDE` is a registered trademark of
    /// Anthropic, PBC, and their published trademark guidelines are permission-based
    /// with no explicit fair-use carve-out. This app is deliberately named so that
    /// "Claude" is a descriptor rather than the product name, uses none of Anthropic's
    /// logos or wordmark styling, and says plainly that it is unaffiliated.
    public static let disclaimer = """
        Not affiliated with, endorsed by, or sponsored by Anthropic. \
        Claude is a trademark of Anthropic, PBC.
        """

    /// The shell command the hook defines. Singular on purpose: you type
    /// `lane work`, not `lanes work`.
    public static let command = "lane"

    /// The project lock file, dropped in a project directory to pin it to one
    /// profile. A dotfile so it stays out of the way, and named after the product so
    /// that finding it in a repo tells you what put it there.
    public static let lockFileName = ".lanes"

    /// What this app used to be called.
    ///
    /// Kept because an install made by the old version left a marker block in
    /// `~/.zshenv` and a state directory under `~/.config`, and silently ignoring
    /// those would leave two hooks fighting over `CLAUDE_CONFIG_DIR`. See
    /// ``LegacyInstall``.
    public static let legacySlug = "claude-switcher"

    /// The bundle identifier the previous version shipped with.
    ///
    /// Renaming the app did not uninstall the old one: it is a separate bundle with a
    /// separate identifier, so a machine can quite happily run both at once — two menu
    /// bar items, two state files, and one of them silently wrong. The app cannot
    /// delete another application, but it can say so, which is the whole reason this
    /// constant exists. See ``LegacyInstall/installedApp()``.
    public static let legacyBundleIdentifier = "nl.rowansail.claudeswitcher"

    // MARK: - Things owned by Claude Code, not by us

    /// The prefix that makes a folder in the home directory a profile.
    ///
    /// Deliberately *not* renamed along with the app. These folders are Claude
    /// Code's config directories — the app only points `CLAUDE_CONFIG_DIR` at them.
    /// Naming them after this app would suggest it owns your history, which it very
    /// much does not.
    public static let profilePrefix = ".claude-"

    /// The one environment variable that actually switches anything.
    public static let configDirVariable = "CLAUDE_CONFIG_DIR"

    /// Keychain service name for a config directory, and for a default install.
    ///
    /// Both are Claude Code's, not ours, and neither is documented — see
    /// ``ClaudeCodeInstall`` for what that means for reliability. The app never reads
    /// or writes these items; it only asks whether they exist.
    public static let keychainPrefix = "Claude Code-credentials"
}
