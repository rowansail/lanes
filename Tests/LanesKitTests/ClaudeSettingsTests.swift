// Lanes — account lanes for Claude Code
// Copyright (C) 2026 rowansail
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import LanesKit

/// The file being written here belongs to Claude Code, not to Lanes, and the user has
/// their model, their permission list and possibly their hooks in it. So the property
/// worth most of these tests is not "the key is set" — it is "everything else survived,
/// and where it might not have, nothing was written at all".
final class ClaudeSettingsTests: XCTestCase {

    private var home: TestHome!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        home = try TestHome()
        suiteName = "lanes-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        home = nil
    }

    private func makeStore() -> ProfileStore {
        ProfileStore(locations: home.locations, defaults: defaults)
    }

    private func settings(of profile: Profile) -> String? {
        try? String(contentsOf: ClaudeSettings.settingsFile(for: profile), encoding: .utf8)
    }

    // MARK: - Reading

    func testAFreshProfileDoesNotSkipTheWarning() throws {
        let profile = try home.makeProfile("work")
        XCTAssertFalse(ClaudeSettings.skipsBypassWarning(profile))
    }

    func testReadingASettingsFileThatSetsTheKey() throws {
        let profile = try home.makeProfile("work")
        try #"{"skipDangerousModePermissionPrompt": true}"#
            .write(to: ClaudeSettings.settingsFile(for: profile),
                   atomically: true, encoding: .utf8)

        XCTAssertTrue(ClaudeSettings.skipsBypassWarning(profile))
    }

    /// `false` and absent mean the same thing to Claude Code, and both have to read as
    /// "you will see the dialog".
    func testAnExplicitFalseIsNotSkipping() throws {
        let profile = try home.makeProfile("work")
        try #"{"skipDangerousModePermissionPrompt": false}"#
            .write(to: ClaudeSettings.settingsFile(for: profile),
                   atomically: true, encoding: .utf8)

        XCTAssertFalse(ClaudeSettings.skipsBypassWarning(profile))
    }

    /// A file somebody has broken is a file that will show the dialog again, so "no" is
    /// the true answer rather than a fallback.
    func testUnparseableSettingsReadAsNotSkipping() throws {
        let profile = try home.makeProfile("work")
        try "{ this is not json"
            .write(to: ClaudeSettings.settingsFile(for: profile),
                   atomically: true, encoding: .utf8)

        XCTAssertFalse(ClaudeSettings.skipsBypassWarning(profile))
    }

    // MARK: - Writing

    func testWritingIntoAProfileWithNoSettingsFileYet() throws {
        let profile = try home.makeProfile("work")
        try ClaudeSettings.setSkipsBypassWarning(true, for: profile)

        XCTAssertTrue(ClaudeSettings.skipsBypassWarning(profile))
        XCTAssertEqual(settings(of: profile)?.hasSuffix("\n"), true)
    }

    /// The one that matters. Everything else in that file is the user's.
    func testWritingKeepsEverySettingAlreadyThere() throws {
        let profile = try home.makeProfile("work")
        let original = """
            {
              "model": "opus",
              "permissions": { "allow": ["Bash(git status)"] },
              "env": { "FOO": "bar" }
            }
            """
        try original.write(to: ClaudeSettings.settingsFile(for: profile),
                           atomically: true, encoding: .utf8)

        try ClaudeSettings.setSkipsBypassWarning(true, for: profile)

        let data = try XCTUnwrap(settings(of: profile)?.data(using: .utf8))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["model"] as? String, "opus")
        XCTAssertEqual(object["skipDangerousModePermissionPrompt"] as? Bool, true)

        let permissions = try XCTUnwrap(object["permissions"] as? [String: Any])
        XCTAssertEqual(permissions["allow"] as? [String], ["Bash(git status)"])

        let env = try XCTUnwrap(object["env"] as? [String: String])
        XCTAssertEqual(env["FOO"], "bar")
    }

    /// Switching it off takes the key out rather than writing `false`, so a file the app
    /// does not own does not accumulate residue from a setting somebody tried once.
    func testTurningItOffRemovesTheKeyEntirely() throws {
        let profile = try home.makeProfile("work")
        try ClaudeSettings.setSkipsBypassWarning(true, for: profile)
        try ClaudeSettings.setSkipsBypassWarning(false, for: profile)

        XCTAssertFalse(ClaudeSettings.skipsBypassWarning(profile))
        XCTAssertEqual(settings(of: profile)?.contains("skipDangerousModePermissionPrompt"),
                       false)
    }

    func testTurningItOffKeepsTheOtherSettings() throws {
        let profile = try home.makeProfile("work")
        try #"{"model": "opus", "skipDangerousModePermissionPrompt": true}"#
            .write(to: ClaudeSettings.settingsFile(for: profile),
                   atomically: true, encoding: .utf8)

        try ClaudeSettings.setSkipsBypassWarning(false, for: profile)

        let data = try XCTUnwrap(settings(of: profile)?.data(using: .utf8))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "opus")
        XCTAssertNil(object["skipDangerousModePermissionPrompt"])
    }

    func testWritingTwiceIsIdempotent() throws {
        let profile = try home.makeProfile("work")
        try ClaudeSettings.setSkipsBypassWarning(true, for: profile)
        let first = settings(of: profile)
        try ClaudeSettings.setSkipsBypassWarning(true, for: profile)

        XCTAssertEqual(settings(of: profile), first)
    }

    /// Turning it off on a profile that never had it must not conjure a settings file
    /// into a lane that has none.
    func testTurningItOffOnAProfileWithoutASettingsFileWritesNothing() throws {
        let profile = try home.makeProfile("work")
        try ClaudeSettings.setSkipsBypassWarning(false, for: profile)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ClaudeSettings.settingsFile(for: profile).path))
    }

    func testAnEmptySettingsFileIsTreatedAsNoSettings() throws {
        let profile = try home.makeProfile("work")
        try "".write(to: ClaudeSettings.settingsFile(for: profile),
                     atomically: true, encoding: .utf8)

        try ClaudeSettings.setSkipsBypassWarning(true, for: profile)
        XCTAssertTrue(ClaudeSettings.skipsBypassWarning(profile))
    }

    /// Claude Code accepts comments and trailing commas; JSONSerialization does not.
    /// Rewriting from a parse that dropped them would silently delete something the user
    /// typed, so a file that does not parse strictly is refused untouched.
    func testACommentedSettingsFileIsRefusedAndLeftByteForByte() throws {
        let profile = try home.makeProfile("work")
        let original = """
            {
              // the model I actually want
              "model": "opus"
            }
            """
        try original.write(to: ClaudeSettings.settingsFile(for: profile),
                           atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ClaudeSettings.setSkipsBypassWarning(true, for: profile))
        XCTAssertEqual(settings(of: profile), original)
    }

    func testASettingsFileHoldingAnArrayIsRefused() throws {
        let profile = try home.makeProfile("work")
        try "[1, 2, 3]".write(to: ClaudeSettings.settingsFile(for: profile),
                              atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ClaudeSettings.setSkipsBypassWarning(true, for: profile))
        XCTAssertEqual(settings(of: profile), "[1, 2, 3]")
    }

    // MARK: - Through the store

    func testTheStoreReportsSkippingOnlyWhenEveryLaneHasIt() throws {
        let work = try home.makeProfile("work")
        _ = try home.makeProfile("personal")

        let store = makeStore()
        XCTAssertFalse(store.skipsBypassWarning)

        try ClaudeSettings.setSkipsBypassWarning(true, for: work)
        store.refresh()

        // One lane out of two. The lane still missing it is exactly the one that will
        // interrupt you, so this is not "on".
        XCTAssertFalse(store.skipsBypassWarning)
    }

    func testTheStoreWritesEveryLaneAtOnce() throws {
        let work = try home.makeProfile("work")
        let personal = try home.makeProfile("personal")

        let store = makeStore()
        store.setSkipsBypassWarning(true)

        XCTAssertTrue(store.skipsBypassWarning)
        XCTAssertTrue(ClaudeSettings.skipsBypassWarning(work))
        XCTAssertTrue(ClaudeSettings.skipsBypassWarning(personal))
        XCTAssertNil(store.lastError)
    }

    /// One hand-edited file must not stop the others from being written, and must not
    /// pass silently either — otherwise the menu shows the setting as off with no
    /// indication of which lane is holding out.
    func testOneUnwritableLaneIsReportedAndTheRestAreStillWritten() throws {
        let work = try home.makeProfile("work")
        let broken = try home.makeProfile("broken")
        try "{ // comment\n }".write(to: ClaudeSettings.settingsFile(for: broken),
                                     atomically: true, encoding: .utf8)

        let store = makeStore()
        store.setSkipsBypassWarning(true)

        XCTAssertTrue(ClaudeSettings.skipsBypassWarning(work))
        XCTAssertFalse(store.skipsBypassWarning)
        XCTAssertEqual(store.lastError?.contains("broken"), true)
    }

    func testAMachineWithNoLanesIsNotSkipping() throws {
        let store = makeStore()
        XCTAssertFalse(store.skipsBypassWarning)
    }
}
