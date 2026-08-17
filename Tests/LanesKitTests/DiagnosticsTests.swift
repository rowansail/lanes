// Lanes — account lanes for Claude Code
// Copyright (C) 2026 rowansail
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import LanesKit

/// The report is the app's answer to "something is wrong and I cannot see why", and
/// it is the first thing anybody pastes into a bug report. It is also one long
/// string built from a dozen sources, which is exactly the shape of thing that
/// quietly loses a section.
///
/// These tests build it against a temporary home directory rather than the real one,
/// so the machine running them cannot change the result — with one exception noted
/// below.
final class DiagnosticsTests: XCTestCase {

    private var home: TestHome!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        home = try TestHome()

        // A throwaway defaults suite: ProfileStore remembers project pins and the
        // auto-check setting there, and a test has no business writing to the
        // developer's own preferences.
        suiteName = "lanes-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        home = nil
    }

    private func report(profiles: [String] = [],
                        pinning: (directory: URL, slug: String)? = nil,
                        withHook: Bool = false) throws -> String {
        for slug in profiles {
            try home.makeProfile(slug, loggedInAs: "\(slug)@example.com")
        }
        if let pinning {
            try FileManager.default.createDirectory(at: pinning.directory,
                                                    withIntermediateDirectories: true)
            try ProjectLocks.write(slug: pinning.slug, in: pinning.directory)
        }
        if withHook {
            try ShellHook.install(.zsh, at: home.locations)
        }

        let store = ProfileStore(locations: home.locations, defaults: defaults)
        store.refresh()
        return Diagnostics.report(store: store)
    }

    /// Every section heading, on a machine that is fully set up. A missing section is
    /// invisible in a 200-line report until somebody needs the part that is gone.
    func testReportContainsEverySection() throws {
        try Setup.writeState("work", at: home.locations)
        let text = try report(profiles: ["work", "personal"], withHook: true)

        for heading in ["Installation", "Claude Code", "Profiles", "Project pins",
                        "Shell hooks", Branding.configDirVariable,
                        "Files that override the hook", "Editors",
                        "Claude desktop app", "Remember"] {
            XCTAssertTrue(text.contains("\n\(heading)\n"),
                          "the '\(heading)' section is missing from the report")
        }

        // The header names the product and disclaims the trademark, which is a
        // requirement rather than a nicety — see Branding.disclaimer.
        XCTAssertTrue(text.hasPrefix("\(Branding.name) \(Branding.version)"), text)
        XCTAssertTrue(text.contains("Not affiliated with Anthropic"))
    }

    func testReportNamesEveryProfileAndItsKeychainItem() throws {
        try Setup.writeState("work", at: home.locations)
        let text = try report(profiles: ["work", "personal"])

        XCTAssertTrue(text.contains("Work"), text)
        XCTAssertTrue(text.contains("Personal"), text)
        XCTAssertTrue(text.contains("work@example.com"), text)

        // The derived Keychain name is printed so a bug report can be checked against
        // `security` by hand. It is the least stable fact in the project.
        let expected = KeychainService.forConfigDirectory(
            home.locations.profileDirectory(for: "work").path)
        XCTAssertTrue(text.contains(expected), "the derived Keychain name is missing")
    }

    /// A machine that has never been set up must read as a welcome, not as a fault:
    /// the report is shown to first-time users straight from the menu.
    func testFreshMachineReportsNotSetUpRatherThanBroken() throws {
        let text = try report()

        XCTAssertTrue(text.contains("never set up on this Mac"), text)
        XCTAssertTrue(text.contains("Set Up \(Branding.name)…"), text)
        XCTAssertFalse(text.contains("SET UP BEFORE, BUT SOMETHING CHANGED"), text)
    }

    /// The pin section points at the shell rather than listing pins, and the wording
    /// that does so is the assertion.
    ///
    /// There used to be two tests here covering a list of pins in the report. They were
    /// green against a list only the app's own menu could fill, so a pin made with
    /// `lane lock` — the documented way — was never in it. The app has no current
    /// directory (launchd starts it) and enumerating every pin would mean scanning the
    /// home directory, so the question is now sent to the shell, which can answer it.
    /// `ShellHookScriptTests` covers the hook actually honouring a pin, and
    /// `doctor.sh` walks up from `$PWD` the way the hook does.
    func testReportSendsPinQuestionsToTheShell() throws {
        try Setup.writeState("acme", at: home.locations)
        let text = try report(profiles: ["acme"])

        XCTAssertTrue(text.contains("./doctor.sh"), text)
        XCTAssertTrue(text.contains("\(Branding.command) lock <name>"), text)
    }

    /// A line in `.zshrc` that overrides the hook is the single most common cause of
    /// "I keep ending up in the same account", so the report has to name file *and*
    /// line — that is what makes it actionable.
    func testReportNamesTheFileAndLineThatOverridesTheHook() throws {
        try home.write("""
        # a comment mentioning CLAUDE_CONFIG_DIR does not count
        export PATH=/usr/bin

        export CLAUDE_CONFIG_DIR=~/.claude-personal
        """, to: ".zshrc")

        let text = try report(profiles: ["work"], withHook: true)

        XCTAssertTrue(text.contains("~/.zshrc:4"), text)
        XCTAssertTrue(text.contains("export CLAUDE_CONFIG_DIR=~/.claude-personal"), text)
        XCTAssertFalse(text.contains("Nothing found. Clean ✓"), text)
    }

    /// The hook section prints the markers it manages, because "which lines are
    /// yours" is a fair question to ask of something that edited your shell config.
    func testReportShowsTheManagedMarkersAndHookRevision() throws {
        try Setup.writeState("work", at: home.locations)
        let text = try report(profiles: ["work"], withHook: true)

        XCTAssertTrue(text.contains(ManagedBlock.current.begin), text)
        XCTAssertTrue(text.contains(ManagedBlock.current.end), text)
        XCTAssertTrue(text.contains("zsh"), text)
        XCTAssertTrue(text.contains("installed ✓"), text)
    }

    /// Building the report must never be the thing that breaks. It runs `security`,
    /// `ps` and reads several files, and it is called from a menu on the main thread.
    func testReportIsSafeOnAnEmptyHomeDirectory() throws {
        let text = try report()
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.contains("An already-running Claude Code session does not"),
                      text)
    }
}
