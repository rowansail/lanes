// Lanes — account lanes for Claude Code
// Copyright (C) 2026 rowansail
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A region of somebody else's config file that this app is allowed to manage.
///
/// The contract, and the reason this is a type rather than three loose functions:
///
///  - Everything between the markers belongs to the app and may be rewritten or
///    removed at will.
///  - Everything outside them belongs to the user and is never touched, not even
///    reformatted. An earlier version of this code collapsed consecutive blank lines
///    across the whole file while "cleaning up" — which is rewriting someone's shell
///    config under the guise of removing four lines.
///  - Installing is always strip-then-append, never append. That makes it idempotent:
///    running setup twice leaves one block, not two fighting over the same variable.
///
/// `#` starts a comment in zsh, bash and fish alike, so one marker format covers
/// every shell the app supports.
public struct ManagedBlock: Equatable, Sendable {

    public let begin: String
    public let end: String

    public init(slug: String) {
        self.begin = "# >>> \(slug) >>>"
        self.end = "# <<< \(slug) <<<"
    }

    /// The block this version writes.
    public static let current = ManagedBlock(slug: Branding.slug)

    /// The block the previous name of this app wrote. Detection only — see
    /// ``LegacyInstall``.
    public static let legacy = ManagedBlock(slug: Branding.legacySlug)

    // MARK: - Reading

    /// Is our block in this text?
    ///
    /// Requires *both* markers. A file with only a begin marker is half-edited, and
    /// treating that as installed would mean reporting a working hook for a file that
    /// cannot possibly work.
    public func isPresent(in text: String) -> Bool {
        contains(begin, in: text) && contains(end, in: text)
    }

    /// A begin marker with no end marker: someone edited the file by hand and did
    /// not finish, or an editor truncated it. Worth reporting separately, because
    /// the fix is different — reinstalling replaces it, whereas a missing block
    /// needs installing.
    public func isDamaged(in text: String) -> Bool {
        contains(begin, in: text) && !contains(end, in: text)
    }

    /// What is currently between the markers, without the markers themselves.
    /// `nil` when there is no complete block.
    ///
    /// Used to tell an up-to-date install from one written by an older version,
    /// which otherwise looks identical from the outside.
    public func body(in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let first = index(of: begin, in: lines),
              let last = index(of: end, in: lines, from: first),
              last > first
        else { return nil }

        return lines[(first + 1)..<last].joined(separator: "\n")
    }

    // MARK: - Writing

    /// Removes every block, markers included, and leaves the rest of the file alone.
    ///
    /// Every block, not just the first: a bug in an old version or a hand-pasted
    /// duplicate can leave two, and removing one of them would silently leave the
    /// other in place.
    public func strip(from text: String) -> String {
        var lines = text.components(separatedBy: "\n")

        while let first = index(of: begin, in: lines) {
            // No end marker means the file is half-edited. Removing from the begin
            // marker to the end of the file is the only safe reading: everything
            // after a begin marker was, by the contract above, written by us.
            let last = index(of: end, in: lines, from: first) ?? (lines.count - 1)
            lines.removeSubrange(first...last)

            // The seam. Removing a block that had a blank line on each side leaves
            // two blanks where the user wrote one. Drop exactly one, and only in
            // that exact case.
            if first > 0, first < lines.count,
               isBlank(lines[first - 1]), isBlank(lines[first]) {
                lines.remove(at: first)
            }
        }

        while let last = lines.last, isBlank(last) { lines.removeLast() }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// The text with our block containing `body`, replacing any block already there.
    ///
    /// Appends at the end deliberately. For the environment variable that is also
    /// the correct place: a later `export` in the same file would win, so being last
    /// is the strongest position available in a file we do not control.
    public func installing(_ body: String, into text: String) -> String {
        var result = strip(from: text)

        if !result.isEmpty {
            // One blank line between their content and ours. Readable, and it makes
            // the seam logic in `strip` symmetrical.
            result += "\n"
        }

        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return result + begin + "\n" + trimmed + "\n" + end + "\n"
    }

    // MARK: - Line matching

    /// Markers are matched on the trimmed line, so indentation does not defeat
    /// removal — but they must be the *whole* line. Matching a substring would mean
    /// a comment mentioning the marker (in documentation, say, or in this repo's own
    /// README pasted into a config) silently becomes a block boundary.
    private func contains(_ marker: String, in text: String) -> Bool {
        index(of: marker, in: text.components(separatedBy: "\n")) != nil
    }

    private func index(of marker: String, in lines: [String], from: Int = 0) -> Int? {
        guard from < lines.count else { return nil }
        return lines[from...].firstIndex {
            $0.trimmingCharacters(in: .whitespaces) == marker
        }
    }

    private func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
