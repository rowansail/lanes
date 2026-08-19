// Lanes — account lanes for Claude Code
// Copyright (C) 2026 rowansail
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One key in a profile's `settings.json`.
///
/// This is the only place in the app that writes inside a profile folder, and it exists
/// for a reason that is entirely a consequence of what Lanes does. A profile *is* a
/// config directory, Claude Code keeps its settings per config directory, and a few of
/// those settings record "yes, I have read this warning". Split one install into four
/// lanes and you get asked four times — once per lane, and again for every lane you make
/// afterwards. Nothing is broken; there is simply no shared place for the answer to live.
///
/// The scope is deliberately one key. This is not a settings editor: everything else in
/// that file is the user's, and an app that switches directories has no business having
/// opinions about the model or the permission list.
public enum ClaudeSettings {

    /// Claude Code's own name for the setting, spelled exactly as it appears in
    /// `settings.json`.
    ///
    /// Not ours to rename, and not covered by ``Branding``'s no-product-names-on-disk
    /// rule — that rule is about strings *we* choose.
    public static let bypassWarningKey = "skipDangerousModePermissionPrompt"

    /// The user-level settings file for a profile.
    ///
    /// `settings.json` and not `settings.local.json`: Claude Code reads the key from
    /// either, but the dialog this replaces writes to the user layer, and matching what
    /// the tool itself does means a lane set up through Lanes and a lane set up by
    /// clicking Accept end up with the same file.
    public static func settingsFile(for profile: Profile) -> URL {
        profile.directory.appendingPathComponent("settings.json")
    }

    public enum Failure: LocalizedError {
        case notJSON(path: String)
        case notAnObject(path: String)

        public var errorDescription: String? {
            switch self {
            case .notJSON(let path):
                return "\(path) is not plain JSON — comments or a trailing comma, "
                     + "perhaps. Left untouched; edit it by hand."
            case .notAnObject(let path):
                return "\(path) does not contain a JSON object. Left untouched."
            }
        }
    }

    // MARK: - Reading

    /// Whether this profile has already accepted the Bypass Permissions warning.
    ///
    /// Deliberately total: an unreadable or malformed file answers "no" rather than
    /// throwing. This is called to decide whether a menu item gets a checkmark, and a
    /// file somebody has broken is a file that will show the dialog again — so "no" is
    /// not a fallback here, it is the correct answer.
    public static func skipsBypassWarning(_ profile: Profile) -> Bool {
        guard let object = read(settingsFile(for: profile)) else { return false }
        return object[bypassWarningKey] as? Bool == true
    }

    // MARK: - Writing

    /// Sets or clears the key, leaving every other setting in the file alone.
    ///
    /// Switching it off *removes* the key rather than writing `false`. The two mean the
    /// same thing to Claude Code, and leaving a key behind in a file the app does not
    /// own is how a config file slowly fills up with the residue of tools that once
    /// touched it.
    public static func setSkipsBypassWarning(_ enabled: Bool,
                                             for profile: Profile) throws {
        let url = settingsFile(for: profile)
        var object = try readStrictly(url)

        if enabled {
            guard object[bypassWarningKey] as? Bool != true else { return }
            object[bypassWarningKey] = true
        } else {
            guard object[bypassWarningKey] != nil else { return }
            object.removeValue(forKey: bypassWarningKey)
        }

        // `.sortedKeys` because the alternative is a dictionary's arbitrary order, which
        // would reshuffle the whole file on every write and make a one-key change look
        // like a rewrite in anyone's diff. Sorted at least gets there once and stays.
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])

        guard let text = String(data: data, encoding: .utf8) else {
            throw Failure.notJSON(path: url.path)
        }
        try AtomicFile.write(text + "\n", to: url)
    }

    // MARK: - The file

    /// Best-effort read. `nil` for anything that is not a JSON object.
    private static func read(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The same read, but it refuses rather than guesses.
    ///
    /// The whole risk in this file is on the write path: `JSONSerialization` parses
    /// strict JSON, while Claude Code also accepts comments and trailing commas. Rewrite
    /// a commented file from a parse that silently dropped what it could not read and
    /// the comments are gone — so a file that does not parse is reported and not
    /// written, and the user keeps whatever they wrote in there.
    ///
    /// A missing or empty file is not a failure: that is a fresh lane, and the answer is
    /// an empty object.
    private static func readStrictly(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { return [:] }

        let text = String(data: data, encoding: .utf8) ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }

        guard let parsed = try? JSONSerialization.jsonObject(with: data) else {
            throw Failure.notJSON(path: url.path)
        }
        guard let object = parsed as? [String: Any] else {
            throw Failure.notAnObject(path: url.path)
        }
        return object
    }
}
