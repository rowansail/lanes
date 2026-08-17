// Lanes — account lanes for Claude Code
// Copyright (C) 2026 rowansail
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Darwin

/// Writing a small text file so that no reader ever sees it half-written, and no
/// other user on the machine ever sees it at all.
///
/// Both halves matter here for concrete reasons:
///
/// **Atomicity.** The state file is read by a shell hook that runs on every single
/// `zsh` invocation. A plain overwrite has a window in which the file is truncated,
/// and a shell starting inside that window exports an empty `CLAUDE_CONFIG_DIR` — so
/// Claude Code silently falls back to the default account. Write-then-rename removes
/// the window: `rename(2)` swaps the directory entry in one step, so a reader sees
/// either the whole old file or the whole new one.
///
/// **Permissions.** `Data.write(options: .atomic)` also does write-then-rename, but
/// it creates its temporary file with the process umask, typically `0644`. That is a
/// brief moment where anyone with an account on the Mac can read it. Nothing secret
/// lives in these files — the app never handles tokens — but "which client am I
/// working for" is not something to hand out either, and doing it right costs twenty
/// lines.
public enum AtomicFile {

    /// Owner read/write only.
    public static let fileMode: mode_t = 0o600

    /// Owner read/write/execute only. A directory needs `x` to be entered at all.
    public static let directoryMode: mode_t = 0o700

    public enum Failure: LocalizedError {
        case posix(call: String, path: String, code: Int32)

        public var errorDescription: String? {
            switch self {
            case .posix(let call, let path, let code):
                return "\(call) on \(path) failed: "
                     + "\(String(cString: strerror(code))) (errno \(code))"
            }
        }
    }

    /// Creates a directory, and every missing parent, with `0700`.
    ///
    /// Note that `withIntermediateDirectories` applies the attributes to the
    /// intermediate directories too — so `~/.config` gets created `0700` as well if
    /// it did not exist. That is stricter than the `0755` most tools leave behind,
    /// and stricter is the right direction to be wrong in.
    public static func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: directoryMode)])
    }

    /// Writes `text` to `url`, atomically, `0600`, creating the parent directory.
    public static func write(_ text: String, to url: URL) throws {
        try createDirectory(url.deletingLastPathComponent())

        // A unique sibling, so two writers can never pick the same temporary name.
        // Same directory is a hard requirement: rename() cannot cross a filesystem
        // boundary, and /tmp may well be a different one.
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")

        // O_EXCL so we never write into a file someone else made, and mode 0600 at
        // creation time rather than a chmod afterwards — there is no window.
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, fileMode)
        guard descriptor >= 0 else {
            throw Failure.posix(call: "open()", path: temporary.path, code: errno)
        }

        let bytes = Array(text.utf8)
        var written = 0
        while written < bytes.count {
            let result = bytes[written...].withUnsafeBufferPointer {
                Darwin.write(descriptor, $0.baseAddress, $0.count)
            }
            // A short write is legal and not an error; only -1 is.
            guard result > 0 else {
                let saved = errno
                close(descriptor)
                unlink(temporary.path)
                throw Failure.posix(call: "write()", path: temporary.path, code: saved)
            }
            written += result
        }

        // fsync before rename. Without it the rename can reach disk before the
        // contents do, and a power cut leaves a correctly named empty file — which
        // is exactly the failure the atomic write was meant to prevent.
        if fsync(descriptor) != 0 {
            let saved = errno
            close(descriptor)
            unlink(temporary.path)
            throw Failure.posix(call: "fsync()", path: temporary.path, code: saved)
        }
        close(descriptor)

        guard rename(temporary.path, url.path) == 0 else {
            let saved = errno
            unlink(temporary.path)
            throw Failure.posix(call: "rename()", path: url.path, code: saved)
        }
    }

    /// Reads a small text file, trimmed. `nil` for missing, unreadable or empty.
    ///
    /// Empty collapses to `nil` on purpose: an empty state file and a missing one
    /// mean the same thing to every caller, and letting `""` through produces a
    /// profile named "" and a path of `~/.claude-`.
    public static func readTrimmed(_ url: URL) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Tightens permissions on a file that already exists, ignoring the case where
    /// it does not. Used to repair state written by an older version, which used
    /// `Data.write` and therefore left `0644` behind.
    public static func tighten(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        chmod(url.path, fileMode)
    }
}
