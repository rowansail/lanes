// Lanes — account lanes for Claude Code
// Copyright (C) 2026 rowansail
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import LanesKit

/// The most important tests in the project.
///
/// Everything the app claims about account isolation rests on one derivation: Claude Code
/// files a config directory's tokens under `Claude Code-credentials-<first 8 hex of
/// sha256(path)>`. That is undocumented, reverse-engineered behaviour, so the least the
/// app can do is pin its own understanding of it against independently computed vectors —
/// so that if the *app* ever drifts, that is caught here rather than by a user wondering
/// why a profile says it is not logged in.
///
/// The expected hashes below were produced with `shasum -a 256`, not with this code:
///
///     printf '/Users/test/.claude-work' | shasum -a 256 | cut -c1-8
final class KeychainServiceTests: XCTestCase {

    func testShortHashMatchesIndependentlyComputedVectors() {
        XCTAssertEqual(KeychainService.shortHash(of: "/Users/test/.claude-work"),
                       "03abf0ee")
        XCTAssertEqual(KeychainService.shortHash(of: "/Users/test/.claude-personal"),
                       "b7eb89f8")

        // The well-known SHA-256 of the empty string, as a check that the truncation is
        // taking the *first* four bytes and not the last.
        XCTAssertEqual(KeychainService.shortHash(of: ""), "e3b0c442")
    }

    func testShortHashIsEightHexCharacters() {
        let hash = KeychainService.shortHash(of: "/some/path")
        XCTAssertEqual(hash.count, 8)
        XCTAssertTrue(hash.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    func testServiceNameHasThePrefixAndTheHash() {
        XCTAssertEqual(KeychainService.forConfigDirectory("/Users/test/.claude-work"),
                       "Claude Code-credentials-03abf0ee")
    }

    /// A normal install with no `CLAUDE_CONFIG_DIR` uses a *fixed, unhashed* name.
    ///
    /// This asymmetry is the reason converting an existing install forces one fresh
    /// login, and the reason the app cannot carry credentials across even in principle.
    /// If this assertion ever has to change, the migration story changes with it.
    func testDefaultServiceIsUnhashed() {
        XCTAssertEqual(KeychainService.default, "Claude Code-credentials")
        XCTAssertFalse(KeychainService.default.contains("-credentials-"))
    }

    /// A trailing slash is a different path and therefore a different Keychain item.
    ///
    /// Not a bug to fix — it is what Claude Code does — but a trap worth having written
    /// down. Anything that builds these paths must build them consistently, which is why
    /// they all come from `Locations.profileDirectory(for:)`.
    func testTrailingSlashChangesTheDerivedName() {
        XCTAssertNotEqual(KeychainService.shortHash(of: "/Users/test/.claude-work"),
                          KeychainService.shortHash(of: "/Users/test/.claude-work/"))
    }

    /// `Locations` must not introduce a trailing slash, or every derived name would be
    /// wrong while looking entirely plausible.
    func testProfileDirectoryPathHasNoTrailingSlash() {
        let locations = Locations(home: URL(fileURLWithPath: "/Users/test"))
        XCTAssertEqual(locations.profileDirectory(for: "work").path,
                       "/Users/test/.claude-work")
    }

    func testProfileUsesTheDerivedName() {
        let locations = Locations(home: URL(fileURLWithPath: "/Users/test"))
        let profile = Profile(slug: "work",
                              directory: locations.profileDirectory(for: "work"))
        XCTAssertEqual(profile.keychainService, "Claude Code-credentials-03abf0ee")
    }
}
