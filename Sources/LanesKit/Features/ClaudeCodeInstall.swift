// Lanes — account lanes for Claude Code
// Copyright (C) 2026 rowansail
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What Claude Code looks like on this machine, and whether the app's central
/// assumption still holds.
///
/// This type exists because of the honest answer to "what is the biggest risk in this
/// project?" — the risk is that `CLAUDE_CONFIG_DIR` and the Keychain naming it implies
/// are undocumented, reverse-engineered behaviour. Anthropic never promised either,
/// and both could change in a release.
///
/// So rather than assume and fail silently, the app checks. If profiles claim to be
/// logged in but no Keychain item exists under the name the app derives — while the
/// unhashed default name *does* exist — then the derivation has stopped matching
/// reality, and saying so plainly with a version number attached is far more use to
/// somebody than a menu that quietly reports the wrong thing.
public struct ClaudeCodeInstall {

    /// How Claude Code was installed. The distinction is not academic: the Node
    /// wrapper and the native binary have behaved differently around the Keychain,
    /// including a version that created entries with a null data blob — present, and
    /// therefore "logged in" by any existence check, but empty.
    public enum Kind: Equatable {
        case native
        case script
        case unknown
        case notFound

        public var description: String {
            switch self {
            case .native:   return "native binary"
            case .script:   return "script or Node wrapper"
            case .unknown:  return "unrecognised"
            case .notFound: return "not found"
            }
        }
    }

    public var executable: URL?
    public var version: String?
    public var kind: Kind

    public var isInstalled: Bool { executable != nil }

    /// Where `claude` might be, in the order worth trying.
    ///
    /// Probed by path rather than by asking a shell. The app was launched by launchd
    /// and has no `PATH` worth speaking of, so `which claude` would answer about an
    /// environment nobody uses. Native install first, because that is what Anthropic's
    /// installer produces now and what behaves correctly with the Keychain.
    static func candidatePaths(in locations: Locations) -> [String] {
        [
            locations.home.appendingPathComponent(".local/bin/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            locations.home.appendingPathComponent(".bun/bin/claude").path,
            locations.home.appendingPathComponent(".volta/bin/claude").path,
        ]
    }

    public static func detect(in locations: Locations) -> ClaudeCodeInstall {
        let fm = FileManager.default

        guard let path = candidatePaths(in: locations)
            .first(where: { fm.isExecutableFile(atPath: $0) }) else {
            return ClaudeCodeInstall(executable: nil, version: nil, kind: .notFound)
        }

        let url = URL(fileURLWithPath: path)

        // `claude --version` prints something like "2.1.185 (Claude Code)". Take the
        // first token that looks like a version and no more: parsing the whole line
        // would break the moment they add a word to it.
        let output = Shell.run(path, ["--version"]).stdout
        let version = output
            .split(whereSeparator: { $0 == " " || $0 == "\n" })
            .first { $0.first?.isNumber == true }
            .map(String.init)

        return ClaudeCodeInstall(executable: url, version: version, kind: kind(of: url))
    }

    /// Mach-O or shebang, decided by the first four bytes.
    ///
    /// Cheaper and more reliable than running `file`: no subprocess, and it works even
    /// when the binary refuses to start.
    static func kind(of url: URL) -> Kind {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }

        guard let head = try? handle.read(upToCount: 4), head.count == 4 else {
            return .unknown
        }

        if head.starts(with: [0x23, 0x21] /* #! */) { return .script }

        // 0xfeedfacf is 64-bit Mach-O; 0xcafebabe is a universal ("fat") binary.
        let magic = head.withUnsafeBytes { $0.load(as: UInt32.self) }
        if magic == 0xfeed_facf || magic == 0xfeed_face
            || magic.byteSwapped == 0xcafe_babe || magic == 0xcafe_babe {
            return .native
        }
        return .unknown
    }
}

/// Does the Keychain still look the way the app thinks it does?
public enum KeychainConsistency {

    public enum Verdict: Equatable {
        /// No profile has ever logged in, so there is nothing to check yet.
        case nothingToCheck

        /// At least one profile's tokens are filed exactly where expected.
        case consistent

        /// Profiles say they are logged in, but nothing is filed under the derived
        /// names — and the unhashed default name is in use instead.
        ///
        /// Two very different causes, same symptom, and the message says so: either
        /// the shell hook is not actually reaching Claude Code (so it ran without
        /// `CLAUDE_CONFIG_DIR` and wrote to the default item), or Anthropic changed
        /// how the name is derived.
        case unexpectedLayout

        /// Logged in per their config, but no Keychain item found under either name.
        /// Most often a Keychain that has not been unlocked, so worth a softer word.
        case cannotTell
    }

    /// Compares what the profiles claim with what the Keychain actually holds.
    ///
    /// Only ever asks whether an item *exists*. No token is read, so this cannot
    /// trigger a Keychain access prompt and cannot leak a secret into a log.
    public static func check(profiles: [Profile]) -> Verdict {
        let claimingLogin = profiles.filter { $0.accountEmail != nil }
        guard !claimingLogin.isEmpty else { return .nothingToCheck }

        if claimingLogin.contains(where: { $0.hasCredentials }) { return .consistent }

        let defaultItemExists = Shell.run(
            "/usr/bin/security",
            ["find-generic-password", "-s", KeychainService.default]).succeeded

        return defaultItemExists ? .unexpectedLayout : .cannotTell
    }

    /// What to tell the user, or `nil` when there is nothing worth saying.
    public static func explanation(for verdict: Verdict) -> String? {
        switch verdict {
        case .nothingToCheck, .consistent:
            return nil

        case .unexpectedLayout:
            return """
            Your profiles have accounts in their config, but their tokens are not \
            filed under the names \(Branding.name) derives from the folder paths — and \
            the unhashed default item is in use instead.

            Two possible causes. Either the shell hook is not reaching Claude Code, so \
            it ran without \(Branding.configDirVariable) and logged in to the default \
            item; check that first, with `echo $\(Branding.configDirVariable)` in a new \
            terminal. Or Claude Code changed how it names Keychain items, in which case \
            profile isolation no longer works and this app cannot fix it — please open \
            an issue with your Claude Code version.
            """

        case .cannotTell:
            return """
            Your profiles have accounts in their config, but no Keychain item was found \
            for them. Usually this means the login Keychain is locked. Log in once and \
            check again.
            """
        }
    }
}
