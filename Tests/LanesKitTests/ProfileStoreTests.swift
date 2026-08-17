// Lanes — account lanes for Claude Code
// Copyright (C) 2026 rowansail
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import LanesKit

/// The store decides what the menu bar says and what a switch actually does to the
/// disk. Both are things a screenshot would only appear to confirm.
final class ProfileStoreTests: XCTestCase {

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

    // MARK: - What the menu bar says

    func testProfilesAreDiscoveredWithoutAnyRegistry() throws {
        try home.makeProfile("work")
        try home.makeProfile("acme")
        try home.makeProfile("personal")

        let store = makeStore()

        // Sorted by slug, which is the order the menu draws and therefore the order
        // the landing page's reconstruction has to use.
        XCTAssertEqual(store.profiles.map(\.slug), ["acme", "personal", "work"])
        XCTAssertEqual(store.profiles.map(\.displayName), ["Acme", "Personal", "Work"])
    }

    /// On a machine set up before this app existed there is no state file, only the
    /// symlink. The menu bar has to read the truth from that rather than show
    /// "No profile" on a machine that is in fact perfectly set up.
    func testActiveProfileFallsBackToTheSymlinkWhenThereIsNoStateFile() throws {
        let work = try home.makeProfile("work")
        try Symlink.repoint(home.locations.claudeLink, to: work.directory, home: home.root)

        let store = makeStore()

        XCTAssertNil(AtomicFile.readTrimmed(home.locations.stateFile),
                     "precondition: no state file")
        XCTAssertEqual(store.activeSlug, "work")
        XCTAssertEqual(store.activeProfile?.displayName, "Work")
    }

    /// And with neither, there is genuinely no active profile — the menu bar says so
    /// rather than guessing.
    func testNothingIsActiveOnAFreshMachine() {
        let store = makeStore()
        XCTAssertNil(store.activeSlug)
        XCTAssertNil(store.activeProfile)
    }

    // MARK: - Switching

    func testActivatingWritesTheStateFileAndRepointsTheSymlink() throws {
        try home.makeProfile("work")
        let personal = try home.makeProfile("personal")
        let store = makeStore()

        store.activate(personal)

        XCTAssertEqual(store.activeSlug, "personal")
        XCTAssertEqual(home.read(".config/\(Branding.slug)/active")?
                        .trimmingCharacters(in: .whitespacesAndNewlines), "personal")
        XCTAssertEqual(home.symlinkTarget(".claude"), personal.directory.path)
        XCTAssertNil(store.lastError)

        // The state file holds one word about which client you are working for. It is
        // not a secret, but it is not everybody's business either.
        XCTAssertEqual(home.mode(".config/\(Branding.slug)/active"), AtomicFile.fileMode)
    }

    /// The ordering invariant, and the reason `activate` does the fallible step first.
    ///
    /// If `~/.claude` is a real folder the symlink swap must fail — and the state file
    /// must **not** have moved. Written the other way round, shells would pick up the
    /// new profile while the symlink still pointed at the old one, which is exactly
    /// the mismatch this app exists to remove.
    func testAFailedSwitchChangesNothingAtAll() throws {
        let work = try home.makeProfile("work")
        let personal = try home.makeProfile("personal")
        try Setup.writeState("work", at: home.locations)
        try Symlink.repoint(home.locations.claudeLink, to: work.directory, home: home.root)

        // Someone reinstalled Claude Code, and ~/.claude is a real folder again.
        try FileManager.default.removeItem(at: home.locations.claudeLink)
        try home.makeRealClaudeDirectory()

        let store = makeStore()
        store.activate(personal)

        XCTAssertNotNil(store.lastError, "a refused switch has to be reported")
        XCTAssertEqual(home.read(".config/\(Branding.slug)/active")?
                        .trimmingCharacters(in: .whitespacesAndNewlines), "work",
                       "the state file moved even though the switch failed")
        XCTAssertTrue(home.exists(".claude/history.jsonl"),
                      "the real folder must be left completely alone")
    }

    // MARK: - Setup status

    func testAFreshMachineIsNeverInstalledRatherThanBroken() {
        let store = makeStore()
        XCTAssertEqual(store.setupStatus.kind, .neverInstalled)
        XCTAssertTrue(store.setupStatus.problems.isEmpty,
                      "a first-time user must not be greeted with a list of faults")
    }

    func testAMachineWithProfilesAndAHookIsReady() throws {
        try home.makeProfile("work")
        try Setup.activate(slug: "work", at: home.locations)
        try ShellHook.install(.zsh, at: home.locations)

        let status = home.status(profiles: ["work"], loginShell: "/bin/zsh")

        XCTAssertEqual(status.kind, .ready, "problems: \(status.problems.map(\.summary))")
        XCTAssertTrue(status.hookInstalled)
        XCTAssertTrue(status.hookIsCurrent)
    }

    /// A `.zshrc` the app will never edit must not summon the wizard on every launch.
    ///
    /// This is the exact shape of a real complaint: an otherwise healthy machine whose
    /// only fault was two old `alias claude-…` lines opened the setup wizard at every
    /// single launch, showing a page whose only advice was "fix this yourself". Because
    /// the app deliberately never touches that file, the condition could not clear, so
    /// the wizard could not stop. It is still a problem — it still shows in the menu and
    /// the report — it just no longer summons anything.
    func testAConflictTheAppWillNotFixDoesNotSummonTheWizard() throws {
        try home.makeProfile("work")
        try Setup.activate(slug: "work", at: home.locations)
        try ShellHook.install(.zsh, at: home.locations)
        try home.write("""
        alias claude-work="export CLAUDE_CONFIG_DIR=~/.claude-work"
        """, to: ".zshrc")

        let status = home.status(profiles: ["work"], loginShell: "/bin/zsh")

        XCTAssertEqual(status.kind, .broken, "the conflict is still a fault")
        XCTAssertEqual(status.problems.map(\.id), ["shell-conflicts"])
        XCTAssertFalse(status.hasRepairableProblems,
                       "nothing here is the wizard's to fix, so it must not be opened")
    }

    /// The other half: a fault the wizard *can* fix still opens it.
    func testARepairableProblemStillSummonsTheWizard() throws {
        try home.makeProfile("work")
        try Setup.writeState("gone", at: home.locations)

        let status = home.status(profiles: ["work"], loginShell: "/bin/zsh")

        XCTAssertEqual(status.kind, .broken)
        XCTAssertTrue(status.hasRepairableProblems,
                      "problems: \(status.problems.map(\.id))")
    }

    /// A deleted profile folder that the state file still names: every new shell falls
    /// back to no profile at all, so it has to be reported rather than shrugged off.
    func testADanglingActiveProfileIsAProblem() throws {
        try home.makeProfile("work")
        try Setup.writeState("gone", at: home.locations)

        let status = home.status(profiles: ["work"], loginShell: "/bin/zsh")

        XCTAssertEqual(status.kind, .broken)
        XCTAssertTrue(status.problems.contains { $0.id == "state-dangling" },
                      status.problems.map(\.id).description)
    }
}
