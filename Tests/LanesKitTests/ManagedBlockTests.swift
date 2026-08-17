// Lanes — account lanes for Claude Code
// Copyright (C) 2026 rowansail
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import LanesKit

/// Editing someone's shell config is the riskiest thing this app does.
///
/// A mistake here does not produce a wrong menu bar label — it produces a terminal
/// that does not start, on a machine the user needs for work, with no obvious
/// connection to the menu bar app they installed last week. So the contract in
/// ``ManagedBlock`` is worth pinning down precisely:
///
///  - everything between the markers belongs to the app;
///  - everything outside them is never touched, not even reformatted;
///  - installing is strip-then-append, so it is idempotent.
///
/// Each of those is a test below, plus the failure modes that motivated the code:
/// duplicate blocks, half-edited files, and markers quoted inside documentation.
final class ManagedBlockTests: XCTestCase {

    private let block = ManagedBlock(slug: "lanes")

    private let hook = "export CLAUDE_CONFIG_DIR=\"$HOME/.claude-work\""

    // MARK: - Installing

    func testInstallingIntoAnEmptyFileProducesJustTheBlock() {
        let result = block.installing(hook, into: "")

        XCTAssertEqual(result, """
            # >>> lanes >>>
            \(hook)
            # <<< lanes <<<

            """)
    }

    func testInstallingAppendsAfterExistingContent() {
        let existing = "export PATH=/usr/local/bin:$PATH\n"
        let result = block.installing(hook, into: existing)

        XCTAssertTrue(result.hasPrefix(existing),
                      "the user's own content must survive verbatim, at the top")
        XCTAssertTrue(block.isPresent(in: result))
    }

    /// Being last matters: a later `export` in the same file would win, so appending
    /// is the strongest position available in a file the app does not control.
    func testBlockIsAppendedAtTheEndNotPrepended() {
        let existing = "export EDITOR=vim\n"
        let result = block.installing(hook, into: existing)

        let lines = result.components(separatedBy: "\n")
        let beginIndex = lines.firstIndex(of: "# >>> lanes >>>")
        let userIndex = lines.firstIndex(of: "export EDITOR=vim")

        XCTAssertNotNil(beginIndex)
        XCTAssertNotNil(userIndex)
        XCTAssertLessThan(userIndex!, beginIndex!)
    }

    // MARK: - Idempotency

    /// The single most important property. Running setup twice must leave one block,
    /// not two exports of the same variable fighting each other.
    func testInstallingTwiceLeavesExactlyOneBlock() {
        let once = block.installing(hook, into: "export EDITOR=vim\n")
        let twice = block.installing(hook, into: once)

        XCTAssertEqual(twice, once)
        XCTAssertEqual(occurrences(of: "# >>> lanes >>>", in: twice), 1)
        XCTAssertEqual(occurrences(of: "# <<< lanes <<<", in: twice), 1)
    }

    func testReinstallingReplacesTheBodyRatherThanAccumulating() {
        let first = block.installing("export OLD=1", into: "")
        let second = block.installing("export NEW=2", into: first)

        XCTAssertEqual(block.body(in: second), "export NEW=2")
        XCTAssertFalse(second.contains("export OLD=1"))
        XCTAssertEqual(occurrences(of: "# >>> lanes >>>", in: second), 1)
    }

    // MARK: - Stripping

    func testStripLeavesUnrelatedContentByteForByte() {
        let user = """
            export PATH=/usr/local/bin:$PATH

            # my own comment
            alias ll='ls -la'
            """
        let installed = block.installing(hook, into: user + "\n")

        XCTAssertEqual(block.strip(from: installed), user + "\n")
    }

    /// An old bug collapsed consecutive blank lines across the whole file while
    /// "cleaning up" — rewriting someone's config under the guise of removing four
    /// lines. Interior blank runs must survive untouched.
    func testStripDoesNotReformatTheRestOfTheFile() {
        let user = "a\n\n\n\nb\n"
        let installed = block.installing(hook, into: user)

        XCTAssertEqual(block.strip(from: installed), user)
    }

    /// A bug in an old version, or a hand-pasted duplicate, can leave two blocks.
    /// Removing only the first would silently leave the second in place.
    func testStripRemovesEveryBlockNotJustTheFirst() {
        let doubled = """
            keep me
            # >>> lanes >>>
            export A=1
            # <<< lanes <<<
            middle
            # >>> lanes >>>
            export B=2
            # <<< lanes <<<
            """

        let result = block.strip(from: doubled)

        XCTAssertFalse(result.contains("lanes"))
        XCTAssertFalse(result.contains("export A=1"))
        XCTAssertFalse(result.contains("export B=2"))
        XCTAssertTrue(result.contains("keep me"))
        XCTAssertTrue(result.contains("middle"))
    }

    func testStripOnAFileWithNoBlockChangesNothingMeaningful() {
        let user = "export EDITOR=vim\n"
        XCTAssertEqual(block.strip(from: user), user)
    }

    // MARK: - Damaged files

    /// A begin marker with no end marker means someone edited by hand and stopped, or
    /// an editor truncated the file. Reporting that as "installed" would mean claiming
    /// a working hook for a file that cannot work.
    func testHalfEditedFileIsDamagedNotPresent() {
        let damaged = "export EDITOR=vim\n# >>> lanes >>>\nexport A=1\n"

        XCTAssertTrue(block.isDamaged(in: damaged))
        XCTAssertFalse(block.isPresent(in: damaged))
        XCTAssertNil(block.body(in: damaged))
    }

    /// Everything after an orphaned begin marker was, by contract, written by the app,
    /// so removing to end-of-file is the only safe reading.
    func testStripRepairsAHalfEditedFile() {
        let damaged = "keep me\n# >>> lanes >>>\nexport A=1\n"
        let result = block.strip(from: damaged)

        XCTAssertEqual(result, "keep me\n")
    }

    func testInstallingOverADamagedBlockRecovers() {
        let damaged = "keep me\n# >>> lanes >>>\nexport OLD=1\n"
        let result = block.installing(hook, into: damaged)

        XCTAssertTrue(block.isPresent(in: result))
        XCTAssertFalse(block.isDamaged(in: result))
        XCTAssertFalse(result.contains("export OLD=1"))
        XCTAssertTrue(result.contains("keep me"))
        XCTAssertEqual(occurrences(of: "# >>> lanes >>>", in: result), 1)
    }

    // MARK: - Marker matching

    /// Markers must be the whole line. If a substring counted, this project's own
    /// README pasted into a config would silently become a block boundary and the
    /// strip would eat the surrounding file.
    func testMarkerMentionedInsideAnotherLineIsNotABoundary() {
        let text = "echo 'this file uses # >>> lanes >>> as a marker'\n"

        XCTAssertFalse(block.isPresent(in: text))
        XCTAssertFalse(block.isDamaged(in: text))
        XCTAssertEqual(block.strip(from: text), text)
    }

    /// Indentation must not defeat removal — a marker the user has indented is still
    /// the app's marker, and leaving it behind would orphan the block forever.
    func testIndentedMarkersAreStillRecognised() {
        let indented = """
              # >>> lanes >>>
              export A=1
              # <<< lanes <<<
            """

        XCTAssertTrue(block.isPresent(in: indented))
        XCTAssertEqual(block.strip(from: indented), "")
    }

    // MARK: - Slug isolation

    /// The pre-rename block must not be mistaken for the current one; migration
    /// depends on telling them apart.
    func testADifferentSlugIsADifferentBlock() {
        let legacy = ManagedBlock(slug: "claude-switcher")
        let installed = legacy.installing(hook, into: "")

        XCTAssertTrue(legacy.isPresent(in: installed))
        XCTAssertFalse(block.isPresent(in: installed))
        XCTAssertEqual(block.strip(from: installed), installed)
    }

    func testCurrentAndLegacyBlocksUseTheExpectedSlugs() {
        XCTAssertEqual(ManagedBlock.current, ManagedBlock(slug: Branding.slug))
        XCTAssertEqual(ManagedBlock.legacy, ManagedBlock(slug: Branding.legacySlug))
        XCTAssertNotEqual(ManagedBlock.current, ManagedBlock.legacy)
    }

    // MARK: - Body

    func testBodyReturnsTheContentWithoutTheMarkers() {
        let installed = block.installing("line one\nline two", into: "")
        XCTAssertEqual(block.body(in: installed), "line one\nline two")
    }

    func testBodyIsNilWhenThereIsNoBlock() {
        XCTAssertNil(block.body(in: "export EDITOR=vim\n"))
    }

    /// Used to tell an up-to-date install from one written by an older version, which
    /// is otherwise indistinguishable from the outside.
    func testBodyDetectsAnOutdatedInstall() {
        let old = block.installing("export OLD=1", into: "")
        XCTAssertNotEqual(block.body(in: old), "export NEW=2")
    }

    // MARK: - Helpers

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces) == needle }
            .count
    }
}
