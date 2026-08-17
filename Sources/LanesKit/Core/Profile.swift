// Lanes — account lanes for Claude Code
// Copyright (C) 2026 rowansail
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CryptoKit

/// How Claude Code names the Keychain item for a given config directory.
///
/// This is the single most important — and least stable — fact the app relies on, so
/// it lives in its own type with its own tests rather than buried in a computed
/// property.
///
/// **None of this is documented by Anthropic.** `CLAUDE_CONFIG_DIR` is not in the
/// published environment-variable list, and the hash derivation below was
/// reverse-engineered from the Claude Code binary by others and confirmed by
/// observation. It can change in any release. What saves the app from that being a
/// disaster is that it only ever *reads* whether an item exists, to answer "is this
/// profile logged in?" — a wrong answer there is a cosmetic bug in a report, not lost
/// credentials. See ``ClaudeCodeInstall`` for the check that notices when the
/// derivation has stopped matching reality.
public enum KeychainService {

    /// A plain install with no `CLAUDE_CONFIG_DIR` set. Note the absence of a hash.
    ///
    /// This asymmetry is the reason converting an existing install forces one fresh
    /// login: the tokens are filed under this fixed name, and after the move Claude
    /// Code looks under a hashed one. The app could not carry them over even if it
    /// wanted to, and it does not want to.
    public static let `default` = Branding.keychainPrefix

    /// `Claude Code-credentials-<first 8 hex of sha256(path)>`.
    ///
    /// The path is hashed exactly as given — no symlink resolution, no trailing-slash
    /// normalisation. Which is also why renaming a profile folder loses its login:
    /// same tokens, different filing name.
    public static func forConfigDirectory(_ path: String) -> String {
        Branding.keychainPrefix + "-" + shortHash(of: path)
    }

    /// The first eight hex characters of the SHA-256 of a string.
    public static func shortHash(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .prefix(4)                                  // 4 bytes → 8 hex characters
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// One Claude account on this machine: the folder `~/.claude-<slug>`.
///
/// The app does not keep a registry of profiles. Any directory in the home folder
/// whose name starts with `.claude-` *is* a profile — create `~/.claude-clientx`
/// tomorrow and it appears in the menu with no code change and nothing to configure.
/// Discovery instead of configuration means there is no second source of truth to
/// drift out of step with the disk.
public struct Profile: Identifiable, Hashable, Sendable {

    /// "work", "personal", "original", …
    public let slug: String

    /// `/Users/someone/.claude-work`
    public let directory: URL

    public var id: String { slug }

    public init(slug: String, directory: URL) {
        self.slug = slug
        self.directory = directory
    }

    /// "work" → "Work", "client-acme" → "Client Acme"
    public var displayName: String {
        slug.split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    /// SF Symbol per profile, with a neutral fallback.
    ///
    /// `original` and its synonyms get a distinct one: that folder is the install the
    /// user already had, and an icon reading as "the one from before" helps them
    /// recognise it in a menu they only glance at.
    public var symbolName: String {
        switch slug {
        case "work":                            return "briefcase.fill"
        case "personal":                        return "house.fill"
        case "original", "existing", "previous": return "clock.arrow.circlepath"
        default:                                return "person.crop.circle.fill"
        }
    }

    // MARK: - What lives inside

    /// This profile's config file.
    ///
    /// This path only applies *because* `CLAUDE_CONFIG_DIR` is set. With that variable
    /// unset, Claude Code reads `~/.claude.json` from the home folder instead. That
    /// asymmetry is exactly why the app switches with the environment variable and
    /// not with the symlink.
    public var configFile: URL {
        directory.appendingPathComponent(".claude.json")
    }

    /// Which account this profile is logged into, from `.claude.json`.
    /// `nil` means never logged in, or the file is not there.
    ///
    /// Reads only the `oauthAccount` metadata block. That file holds an email, an
    /// account UUID and a billing type — no tokens. Those are in the Keychain, and
    /// this app never opens it.
    public var accountEmail: String? {
        guard let data = try? Data(contentsOf: configFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any]
        else { return nil }

        return (account["emailAddress"] as? String)
            ?? (account["email"] as? String)
            ?? (account["accountUuid"] as? String).map { "account " + String($0.prefix(8)) }
    }

    /// The Keychain service that would hold this profile's tokens.
    public var keychainService: String {
        KeychainService.forConfigDirectory(directory.path)
    }

    /// Is there a Keychain item for this profile?
    ///
    /// `security find-generic-password` *without* `-w` asks for metadata only and
    /// never decrypts the item. That is the whole reason this does not raise a "do you
    /// want to allow access to your Keychain?" dialog — with `-w` it would, on every
    /// call, and the app would be asking for the one thing it promises not to read.
    public var hasCredentials: Bool {
        Shell.run("/usr/bin/security",
                  ["find-generic-password", "-s", keychainService]).exitCode == 0
    }

    // MARK: - The desktop app

    /// This profile's Electron data directory for the Claude desktop app.
    ///
    /// The desktop app is a completely separate login. `CLAUDE_CONFIG_DIR` does
    /// nothing there: it is Electron and keeps its session in cookies under
    /// `~/Library/Application Support/Claude`, encrypted with a Keychain key called
    /// "Claude Safe Storage". The only lever for putting that session elsewhere is
    /// `--user-data-dir`.
    ///
    /// That the encryption key is per *app* and not per account is precisely why this
    /// works — two cookie databases decrypt with the same key. Had it been derived per
    /// account this would have been a dead end.
    ///
    /// Deliberately *inside* the profile folder rather than beside it as
    /// `~/.claude-desktop-<slug>`: discovery filters on the `.claude-` prefix, so a
    /// sibling like that would appear in the menu as a bogus profile called
    /// "Desktop Work".
    public var desktopDataDir: URL {
        directory.appendingPathComponent("desktop")
    }

    /// Has this profile's desktop app ever logged in?
    ///
    /// Checks only that the file exists and never reads it. Cookies is an encrypted
    /// SQLite database whose contents mean nothing without the Keychain key, and this
    /// is called on the main thread.
    public var desktopHasSession: Bool {
        FileManager.default.fileExists(
            atPath: desktopDataDir.appendingPathComponent("Cookies").path)
    }

    // MARK: - Discovery

    /// Every profile in a home directory, sorted by name.
    public static func discover(in locations: Locations) -> [Profile] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: locations.home.path) else {
            return []
        }

        return names
            .filter { $0.hasPrefix(Branding.profilePrefix) }
            .compactMap { name -> Profile? in
                let url = locations.home.appendingPathComponent(name)

                // Real directories only. This filters out stray files and also
                // `~/.claude.pre-symlink-backup`, which starts with ".claude." — a
                // dot — rather than ".claude-" with a hyphen.
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { return nil }

                let slug = String(name.dropFirst(Branding.profilePrefix.count))
                guard !slug.isEmpty else { return nil }

                return Profile(slug: slug, directory: url)
            }
            .sorted { $0.slug < $1.slug }
    }

    // MARK: - Names

    /// Why this name will not do, or `nil` if it is fine.
    ///
    /// The name becomes a directory name and then travels through the shell hook into
    /// a path, so a space or a slash here is actively harmful rather than merely
    /// untidy — and a name that needs quoting in shell would break the hook for every
    /// shell the user opens, not just this one command.
    public static func validate(_ raw: String,
                                against others: [String] = [],
                                in locations: Locations) -> String? {
        let slug = raw.trimmingCharacters(in: .whitespaces)

        if slug.isEmpty { return "Enter a name." }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        if slug.rangeOfCharacter(from: allowed.inverted) != nil {
            return "Lowercase letters, digits and hyphens only."
        }
        if slug.hasPrefix("-") || slug.hasSuffix("-") {
            return "Cannot start or end with a hyphen."
        }
        // `lane lock` and friends are matched before a profile name, so a profile
        // called "lock" would be unreachable from the command line.
        if ["app", "lock", "unlock", "list", "help"].contains(slug) {
            return "'\(slug)' is a \(Branding.command) subcommand — pick another name."
        }
        if others.map({ $0.trimmingCharacters(in: .whitespaces) }).contains(slug) {
            return "This name is already used above."
        }
        if FileManager.default.fileExists(
            atPath: locations.profileDirectory(for: slug).path) {
            return "~/\(Branding.profilePrefix)\(slug) already exists."
        }
        return nil
    }
}
