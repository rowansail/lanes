// Lanes — account lanes for Claude Code
// Copyright (C) 2026 rowansail
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Runs a command-line tool and hands back its output.
///
/// Deliberately with no shell in between — no `/bin/sh -c`. That removes quoting from
/// the picture entirely: an argument containing a space, a quote or a semicolon is
/// just an argument, and there is no string for anything to be injected into. Every
/// call site here passes paths derived from a home directory, which is exactly the
/// kind of value that eventually contains a space.
public enum Shell {

    /// Named `Output` rather than `Result` on purpose: a nested type called `Result`
    /// shadows Swift's own within the file, and the resulting error messages are
    /// bewildering.
    public struct Output {
        public let exitCode: Int32
        public let stdout: String

        public var succeeded: Bool { exitCode == 0 }
    }

    @discardableResult
    public static func run(_ executable: String, _ arguments: [String]) -> Output {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return Output(exitCode: -1, stdout: "")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return Output(exitCode: -1, stdout: "")
        }

        // Read first, then wait. The other order deadlocks as soon as the output
        // exceeds the pipe buffer: the child blocks writing, we block in
        // waitUntilExit, and neither ever moves again.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Output(exitCode: process.terminationStatus,
                      stdout: String(data: data, encoding: .utf8) ?? "")
    }
}
