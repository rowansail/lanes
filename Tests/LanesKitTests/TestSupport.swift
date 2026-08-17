// Lanes — account lanes for Claude Code
// Copyright (C) 2026 rowansail
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import LanesKit

/// A throwaway home directory.
///
/// The whole point of `Locations` taking its home as a value is this class. Every test
/// that touches the filesystem gets a real directory, does real renames, writes real
/// symlinks and installs a real shell hook — and then throws the lot away. Nothing here
/// can reach the developer's own `~/.claude`, which is what makes it acceptable to test
/// the destructive paths at all.
final class TestHome {

    let root: URL

    /// `resolvingSymlinksInPath` matters on macOS: the temporary directory lives under
    /// `/var`, which is itself a symlink to `/private/var`. Without resolving it, a path
    /// the test writes and a path the code reports back differ by that prefix, and
    /// perfectly correct assertions fail for a reason that takes an hour to find.
    init(file: StaticString = #filePath, line: UInt = #line) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .resolvingSymlinksInPath()
            .appendingPathComponent("lanes-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    var locations: Locations { Locations(home: root) }

    // MARK: - Building a situation

    /// Creates a profile directory and returns it.
    @discardableResult
    func makeProfile(_ slug: String, loggedInAs email: String? = nil) throws -> Profile {
        let directory = locations.profileDirectory(for: slug)
        try FileManager.default.createDirectory(at: directory,
                                               withIntermediateDirectories: true)
        if let email {
            let json = #"{"oauthAccount":{"emailAddress":"\#(email)"}}"#
            try json.write(to: directory.appendingPathComponent(".claude.json"),
                           atomically: true, encoding: .utf8)
        }
        return Profile(slug: slug, directory: directory)
    }

    /// A real `~/.claude` directory, as a machine with a normal install has.
    func makeRealClaudeDirectory(containing name: String = "history.jsonl") throws {
        try FileManager.default.createDirectory(at: locations.claudeLink,
                                               withIntermediateDirectories: true)
        try "x".write(to: locations.claudeLink.appendingPathComponent(name),
                      atomically: true, encoding: .utf8)
    }

    func write(_ text: String, to relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Looking at the result

    func read(_ relativePath: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path)
    }

    func mode(_ relativePath: String) -> mode_t? {
        let path = root.appendingPathComponent(relativePath).path
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return info.st_mode & 0o777
    }

    /// The target of a symlink, or nil if the path is not one.
    func symlinkTarget(_ relativePath: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(
            atPath: root.appendingPathComponent(relativePath).path)
    }

    func status(profiles: [String] = [], loginShell: String = "/bin/zsh") -> Setup.Status {
        Setup.status(at: locations, profileSlugs: profiles, loginShell: loginShell)
    }
}
