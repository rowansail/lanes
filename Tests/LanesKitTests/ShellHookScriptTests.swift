// Lanes — account lanes for Claude Code
// Copyright (C) 2026 rowansail
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import LanesKit

/// The hook scripts are the one part of this project that is not Swift, is not
/// compiled, and runs in every shell the user opens. A typo in them is not a crash in
/// an app somebody can quit — it is an error printed at every prompt, on a machine
/// where the tool that caused it is now hard to trust.
///
/// So they get three kinds of test:
///
/// 1. **Branding.** The scripts hardcode `lanes`, `.claude-`, `.lanes` and so on
///    because shell text with Swift interpolation in it is unreadable. That trade is
///    only safe if something checks the hardcoded copies still match `Branding` — this
///    is that something, and `ShellHookScripts.swift` says so in its header.
/// 2. **Syntax.** Each script is parsed by the real shell (`zsh -n`, `bash -n`,
///    `fish --no-execute`). Nothing is executed; this catches an unbalanced quote.
/// 3. **Behaviour.** zsh and bash actually run, against a temporary home directory
///    with a fake `claude` on `PATH`, and the output is compared to what the README
///    and the landing page claim the command prints.
///
/// A shell that is not installed skips its own tests rather than failing: fish is not
/// on a stock Mac, and a missing fish says nothing about this code.
final class ShellHookScriptTests: XCTestCase {

    // MARK: - Branding

    func testEveryScriptStillSpellsTheBrandingConstants() {
        for flavor in ShellFlavor.allCases {
            let script = ShellHook.script(for: flavor)
            let what = flavor.displayName

            XCTAssertTrue(script.contains(".config/\(Branding.slug)/active"),
                          "\(what): state file path does not match Branding.slug")
            XCTAssertTrue(script.contains("$HOME/\(Branding.profilePrefix)"),
                          "\(what): profile folders do not match Branding.profilePrefix")
            XCTAssertTrue(script.contains(Branding.configDirVariable),
                          "\(what): does not export \(Branding.configDirVariable)")
            XCTAssertTrue(script.contains(Branding.lockFileName),
                          "\(what): pin file does not match Branding.lockFileName")
            XCTAssertTrue(script.contains(Branding.name),
                          "\(what): header does not name the product")
        }
    }

    /// The command is `lane`, singular, and the environment variables the scripts read
    /// are namespaced with the uppercased slug. Both are spelled out in the hook and
    /// both would silently stop working after a rename.
    func testEveryScriptDefinesTheCommandAndItsEscapeHatches() {
        let uppercased = Branding.slug.uppercased()

        for flavor in ShellFlavor.allCases {
            let script = ShellHook.script(for: flavor)
            let definition = flavor == .fish
                ? "function \(Branding.command)"
                : "\(Branding.command)() {"

            XCTAssertTrue(script.contains(definition),
                          "\(flavor.displayName): does not define \(Branding.command)()")
            XCTAssertTrue(script.contains("\(uppercased)_STATE"),
                          "\(flavor.displayName): state override variable is not "
                          + "\(uppercased)_STATE")
            XCTAssertTrue(script.contains("\(uppercased)_NO_LOCK"),
                          "\(flavor.displayName): pin bypass is not \(uppercased)_NO_LOCK")
        }
    }

    /// The revision comment is how the app notices an out-of-date hook. If a script
    /// changes and this is not bumped, everybody keeps running the old one and the app
    /// reports the install as current.
    func testRevisionCommentMatchesTheDeclaredRevision() {
        for flavor in ShellFlavor.allCases {
            XCTAssertEqual(ShellHook.parseRevision(ShellHook.script(for: flavor)),
                           ShellHook.revision,
                           "\(flavor.displayName): revision comment is out of step")
        }
    }

    // MARK: - Syntax

    func testZshScriptParses() throws {
        try assertParses(.zsh, tool: "/bin/zsh", arguments: ["-n"])
    }

    func testBashScriptParses() throws {
        try assertParses(.bash, tool: "/bin/bash", arguments: ["-n"])
    }

    func testFishScriptParses() throws {
        guard let fish = Self.find("fish") else {
            throw XCTSkip("fish is not installed on this machine")
        }
        try assertParses(.fish, tool: fish, arguments: ["--no-execute"])
    }

    private func assertParses(_ flavor: ShellFlavor,
                              tool: String,
                              arguments: [String],
                              file: StaticString = #filePath,
                              line: UInt = #line) throws {
        let home = try TestHome()
        let script = try write(flavor, in: home)

        let result = Self.run(tool, arguments + [script.path], home: home.root)
        XCTAssertEqual(result.exitCode, 0,
                       "\(flavor.displayName) rejected its own hook:\n\(result.stderr)",
                       file: file, line: line)
    }

    // MARK: - Behaviour: switching

    func testZshSwitchingWritesTheStateFileAndReportsAnAbbreviatedPath() throws {
        try assertSwitchingWorks(.zsh, tool: "/bin/zsh", interactive: ["-f", "-i", "-c"])
    }

    func testBashSwitchingWritesTheStateFileAndReportsAnAbbreviatedPath() throws {
        try assertSwitchingWorks(
            .bash, tool: "/bin/bash", interactive: ["--noprofile", "--norc", "-i", "-c"])
    }

    func testFishSwitchingWritesTheStateFileAndReportsAnAbbreviatedPath() throws {
        guard let fish = Self.find("fish") else {
            throw XCTSkip("fish is not installed on this machine")
        }
        try assertSwitchingWorks(.fish, tool: fish, interactive: ["--no-config", "-i", "-c"])
    }

    /// The path in `now: work  ->  ~/.claude-work` is abbreviated on purpose: it is the
    /// line quoted in the README and on the landing page, and it should read the same
    /// for every user rather than carrying whoever's home directory produced it.
    private func assertSwitchingWorks(_ flavor: ShellFlavor,
                                      tool: String,
                                      interactive: [String],
                                      file: StaticString = #filePath,
                                      line: UInt = #line) throws {
        let home = try TestHome()
        try home.makeProfile("work")
        try home.makeProfile("personal")
        let script = try write(flavor, in: home)

        let result = Self.run(
            tool,
            interactive + ["\(source(script, in: flavor)); lane work; lane"],
            home: home.root)

        XCTAssertTrue(result.stdout.contains("now: work  ->  ~/.claude-work"),
                      "\(flavor.displayName): unexpected switch output:\n\(result.stdout)",
                      file: file, line: line)
        XCTAssertTrue(result.stdout.contains("config dir : ~/.claude-work"),
                      "\(flavor.displayName): config dir was not abbreviated:\n"
                      + result.stdout, file: file, line: line)
        XCTAssertTrue(result.stdout.contains("active     : work"),
                      "\(flavor.displayName): active profile not reported:\n\(result.stdout)",
                      file: file, line: line)
        XCTAssertTrue(result.stdout.contains("  * work"),
                      "\(flavor.displayName): active profile not marked:\n\(result.stdout)",
                      file: file, line: line)
        XCTAssertTrue(result.stdout.contains("    personal"),
                      "\(flavor.displayName): other profiles not listed:\n\(result.stdout)",
                      file: file, line: line)

        // The state file is the source of truth the app reads back, so the shell and
        // the menu bar agreeing depends on exactly this.
        XCTAssertEqual(home.read(".config/\(Branding.slug)/active")?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       "work", file: file, line: line)
        XCTAssertEqual(home.symlinkTarget(".claude"),
                       home.locations.profileDirectory(for: "work").path,
                       file: file, line: line)
    }

    func testZshRefusesAProfileThatDoesNotExist() throws {
        let home = try TestHome()
        try home.makeProfile("work")
        let script = try write(.zsh, in: home)

        let result = Self.run("/bin/zsh", ["-f", "-i", "-c",
                                           ". '\(script.path)'; lane nope"],
                              home: home.root)

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("no profile 'nope'"), result.stderr)
        XCTAssertTrue(result.stderr.contains("~/.claude-nope"), result.stderr)
    }

    // MARK: - Behaviour: pins

    /// The pin is the app's strongest claim — "a pinned project always uses its own
    /// profile, whatever is active" — and it is implemented entirely in these scripts.
    /// This runs a fake `claude` and checks which account it was actually handed.
    func testZshPinOverridesTheActiveProfile() throws {
        try assertPinWins(.zsh, tool: "/bin/zsh", arguments: ["-f", "-c"])
    }

    func testBashPinOverridesTheActiveProfile() throws {
        try assertPinWins(.bash, tool: "/bin/bash", arguments: ["--noprofile", "--norc", "-c"])
    }

    func testFishPinOverridesTheActiveProfile() throws {
        guard let fish = Self.find("fish") else {
            throw XCTSkip("fish is not installed on this machine")
        }
        try assertPinWins(.fish, tool: fish, arguments: ["--no-config", "-c"])
    }

    private func assertPinWins(_ flavor: ShellFlavor,
                               tool: String,
                               arguments: [String],
                               file: StaticString = #filePath,
                               line: UInt = #line) throws {
        let home = try TestHome()
        try home.makeProfile("work")
        try home.makeProfile("acme")
        try Setup.writeState("work", at: home.locations)

        let project = home.root.appendingPathComponent("clients/acme")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try ProjectLocks.write(slug: "acme", in: project)

        let script = try write(flavor, in: home)
        let bin = try fakeClaude(in: home)

        let result = Self.run(
            tool,
            arguments + ["\(source(script, in: flavor)); cd '\(project.path)'; claude"],
            home: home.root,
            extraPath: bin.path)

        // The pin wins over the state file, which says "work".
        XCTAssertTrue(result.stdout.contains(
            "config=\(home.locations.profileDirectory(for: "acme").path)"),
            "\(flavor.displayName): the pin did not reach claude:\n\(result.stdout)",
            file: file, line: line)

        // And it says so, with the project path abbreviated the same way the app does.
        XCTAssertTrue(result.stderr.contains(
            "lanes: ~/clients/acme is pinned to 'acme' — using it for this command."),
            "\(flavor.displayName): unexpected notice:\n\(result.stderr)",
            file: file, line: line)
    }

    /// A pin naming a profile this machine does not have — the committed-by-a-colleague
    /// case. It must warn and carry on, never silently use the wrong account.
    func testZshPinNamingAMissingProfileWarnsAndContinues() throws {
        let home = try TestHome()
        try home.makeProfile("work")
        try Setup.writeState("work", at: home.locations)

        let project = home.root.appendingPathComponent("clients/other")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try ProjectLocks.write(slug: "nobody", in: project)

        let script = try write(.zsh, in: home)
        let bin = try fakeClaude(in: home)

        let result = Self.run(
            "/bin/zsh",
            ["-f", "-c", ". '\(script.path)'; cd '\(project.path)'; claude"],
            home: home.root,
            extraPath: bin.path)

        XCTAssertTrue(result.stderr.contains("names profile 'nobody', which does not exist"),
                      result.stderr)
        XCTAssertTrue(result.stderr.contains("continuing with the active profile"),
                      result.stderr)
        XCTAssertEqual(result.exitCode, 0, "claude should still have run")
    }

    /// `LANES_NO_LOCK=1` is documented in the script as the way out. If it stops working
    /// there is no way to run one command against a different account in a pinned repo.
    func testZshPinCanBeBypassed() throws {
        let home = try TestHome()
        try home.makeProfile("acme")
        let project = home.root.appendingPathComponent("clients/acme")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try ProjectLocks.write(slug: "acme", in: project)

        let script = try write(.zsh, in: home)
        let bin = try fakeClaude(in: home)

        let result = Self.run(
            "/bin/zsh",
            ["-f", "-c",
             ". '\(script.path)'; cd '\(project.path)'; \(Branding.slug.uppercased())_NO_LOCK=1 claude"],
            home: home.root,
            extraPath: bin.path)

        XCTAssertTrue(result.stdout.contains("config=none"),
                      "the pin was applied despite the bypass:\n\(result.stdout)")
        XCTAssertFalse(result.stderr.contains("is pinned to"), result.stderr)
    }

    /// `lane lock` / `lane unlock` and the pin line in `lane`'s listing. These strings
    /// are quoted verbatim in the README and on the landing page, so they are worth
    /// holding still.
    func testZshLockAndUnlockReportWhatTheyDid() throws {
        let home = try TestHome()
        try home.makeProfile("acme")
        let project = home.root.appendingPathComponent("clients/acme")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let script = try write(.zsh, in: home)
        let result = Self.run(
            "/bin/zsh",
            ["-f", "-i", "-c",
             ". '\(script.path)'; cd '\(project.path)'; lane lock acme; lane; lane unlock"],
            home: home.root)

        XCTAssertTrue(result.stdout.contains("pinned ~/clients/acme to 'acme'"),
                      result.stdout + result.stderr)
        XCTAssertTrue(result.stdout.contains(
            "Commit .lanes to share the pin, or add it to .git/info/exclude to keep it yours."),
            result.stdout)
        XCTAssertTrue(result.stdout.contains("pinned     : acme  (~/clients/acme/.lanes)"),
                      result.stdout)
        XCTAssertTrue(result.stdout.contains("removed .lanes from ~/clients/acme"),
                      result.stdout)

        // The pin file itself is 0644 — it is meant to be committed, and there is
        // nothing private in a profile name.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: project.appendingPathComponent(Branding.lockFileName).path),
            "unlock should have removed the file")
    }

    /// fish has no `VAR=value command` prefix, so its bypass has to be a real
    /// variable — and its `lane lock` builds the message from `(pwd)` rather than
    /// `$PWD`. Both are places where "the bash version works" proves nothing.
    func testFishLockUnlockAndBypass() throws {
        guard let fish = Self.find("fish") else {
            throw XCTSkip("fish is not installed on this machine")
        }

        let home = try TestHome()
        try home.makeProfile("acme")
        let project = home.root.appendingPathComponent("clients/acme")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let script = try write(.fish, in: home)
        let bin = try fakeClaude(in: home)

        let locking = Self.run(
            fish,
            ["--no-config", "-i", "-c",
             "\(source(script, in: .fish)); cd '\(project.path)'; "
             + "lane lock acme; lane; lane unlock"],
            home: home.root,
            extraPath: bin.path)

        XCTAssertTrue(locking.stdout.contains("pinned ~/clients/acme to 'acme'"),
                      locking.stdout + locking.stderr)
        XCTAssertTrue(locking.stdout.contains("pinned     : acme  (~/clients/acme/.lanes)"),
                      locking.stdout)
        XCTAssertTrue(locking.stdout.contains("removed .lanes from ~/clients/acme"),
                      locking.stdout)

        // And the bypass, with the pin back in place.
        try ProjectLocks.write(slug: "acme", in: project)
        let bypassed = Self.run(
            fish,
            ["--no-config", "-c",
             "\(source(script, in: .fish)); cd '\(project.path)'; "
             + "set -gx \(Branding.slug.uppercased())_NO_LOCK 1; claude"],
            home: home.root,
            extraPath: bin.path)

        XCTAssertTrue(bypassed.stdout.contains("config=none"),
                      "the pin was applied despite the bypass:\n\(bypassed.stdout)")
        XCTAssertFalse(bypassed.stderr.contains("is pinned to"), bypassed.stderr)
    }

    /// The hook has to be inert on a machine with no state file and no pins: this is
    /// what every shell start looks like before the user has switched anything.
    func testZshHookIsInertWithoutAnyState() throws {
        let home = try TestHome()
        let script = try write(.zsh, in: home)
        let bin = try fakeClaude(in: home)

        let result = Self.run("/bin/zsh", ["-f", "-c", ". '\(script.path)'; claude"],
                              home: home.root, extraPath: bin.path)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("config=none"), result.stdout)
        XCTAssertEqual(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines), "",
                       "the hook should say nothing when there is nothing to say")
    }

    // MARK: - Fixtures

    private func write(_ flavor: ShellFlavor, in home: TestHome) throws -> URL {
        let url = home.root.appendingPathComponent("hook-\(flavor.rawValue)")
        try ShellHook.script(for: flavor).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// How this shell reads a file of definitions. fish dropped `.` as a synonym for
    /// `source` in version 4, which is exactly the kind of difference that makes
    /// "the script parses" and "the script works" two separate claims.
    private func source(_ script: URL, in flavor: ShellFlavor) -> String {
        flavor == .fish ? "source '\(script.path)'" : ". '\(script.path)'"
    }

    /// A stand-in for Claude Code that reports the account it was handed. The real one
    /// is not installed on a CI runner, and this test is about what the shell passes it.
    private func fakeClaude(in home: TestHome) throws -> URL {
        let bin = home.root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        let claude = bin.appendingPathComponent("claude")
        try """
        #!/bin/sh
        printf 'config=%s\\n' "${CLAUDE_CONFIG_DIR:-none}"
        """.write(to: claude, atomically: true, encoding: .utf8)
        chmod(claude.path, 0o755)
        return bin
    }

    // MARK: - Running a shell

    private struct Output {
        var stdout: String
        var stderr: String
        var exitCode: Int32
    }

    /// Runs a tool with a controlled environment.
    ///
    /// `HOME` is the temporary directory, which is what makes these tests safe: every
    /// path the hook touches is derived from it, so nothing here can reach the
    /// developer's own `~/.claude`.
    private static func run(_ tool: String,
                            _ arguments: [String],
                            home: URL,
                            extraPath: String? = nil) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = home

        var path = "/usr/bin:/bin:/usr/sbin:/sbin"
        if let extraPath { path = extraPath + ":" + path }
        process.environment = [
            "HOME": home.path,
            "PATH": path,
            // Keep the shell out of the terminal's business: these run without a tty.
            "TERM": "dumb",
        ]

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do { try process.run() } catch {
            return Output(stdout: "", stderr: "could not run \(tool): \(error)", exitCode: -1)
        }

        // Read before waiting: a pipe buffer that fills up deadlocks the child.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Output(stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self),
                      exitCode: process.terminationStatus)
    }

    private static func find(_ tool: String) -> String? {
        ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/", "/bin/"]
            .map { $0 + tool }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
