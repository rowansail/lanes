// Lanes — account lanes for Claude Code
// Copyright (C) 2026 rowansail
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import LanesKit

/// Parsing `ps eww` output, which is the one part of the editor check that can be
/// tested without an editor running.
///
/// It is worth testing rather than eyeballing because the format is genuinely
/// ambiguous: `ps` joins the environment with single spaces and quotes nothing, so a
/// value containing a space cannot be distinguished from the start of the next
/// variable by any parser. The tests below pin down what the chosen heuristic does in
/// the cases that occur — including the one where it is wrong, so that anybody
/// changing it later can see the trade-off rather than rediscover it.
final class EditorEnvironmentTests: XCTestCase {

    /// A realistic line: leading padding, the command, then the environment.
    private let sample = """
          PID   TT  STAT      TIME COMMAND
        11882   ??  Ss     0:12.34 /Applications/Visual Studio Code.app/Contents/MacOS/Code \
    PATH=/usr/bin:/bin SHELL=/bin/zsh CLAUDE_CONFIG_DIR=/Users/rowan/.claude-work \
    VSCODE_CWD=/Users/rowan/projects VSCODE_PID=3420
    """

    func testReadsAVariableFromTheMiddleOfTheEnvironment() {
        XCTAssertEqual(EditorEnvironment.value(of: "CLAUDE_CONFIG_DIR", in: sample),
                       "/Users/rowan/.claude-work")
        XCTAssertEqual(EditorEnvironment.value(of: "SHELL", in: sample), "/bin/zsh")
    }

    func testReadsTheLastVariableOnTheLine() {
        XCTAssertEqual(EditorEnvironment.value(of: "VSCODE_PID", in: sample), "3420")
    }

    func testAbsentVariableIsNil() {
        XCTAssertNil(EditorEnvironment.value(of: "CLAUDE_CODE_SSE_PORT", in: sample))
    }

    /// A variable whose *name* merely ends with the one we asked for must not match:
    /// searching for `CONFIG_DIR` should not find `CLAUDE_CONFIG_DIR`.
    func testDoesNotMatchASuffixOfAnotherVariableName() {
        XCTAssertNil(EditorEnvironment.value(of: "CONFIG_DIR", in: sample))
    }

    /// The case the heuristic gets right: a home directory with a space in it. The
    /// scan keeps consuming words until one looks like `NAME=`, so the whole path
    /// survives.
    func testKeepsAValueThatContainsSpaces() {
        let output = "… PATH=/bin CLAUDE_CONFIG_DIR=/Users/jan de vries/.claude-work "
                   + "VSCODE_PID=1"
        XCTAssertEqual(EditorEnvironment.value(of: "CLAUDE_CONFIG_DIR", in: output),
                       "/Users/jan de vries/.claude-work")
    }

    /// And the case it gets wrong, recorded deliberately. A path containing a word
    /// shaped like an assignment ends the value early. Nothing can fix this from `ps`
    /// output alone, and the consequence is a wrong line in a diagnostic report rather
    /// than a wrong account, so it is left as it is.
    func testTruncatesAValueContainingSomethingShapedLikeAnAssignment() {
        let output = " CLAUDE_CONFIG_DIR=/Users/x/a=b/.claude-work VSCODE_PID=1"
        XCTAssertEqual(EditorEnvironment.value(of: "CLAUDE_CONFIG_DIR", in: output),
                       "/Users/x/a=b/.claude-work")

        let broken = " CLAUDE_CONFIG_DIR=/Users/x/dir A=b/.claude-work VSCODE_PID=1"
        XCTAssertEqual(EditorEnvironment.value(of: "CLAUDE_CONFIG_DIR", in: broken),
                       "/Users/x/dir")
    }

    // MARK: - Identifying the editor

    func testTakesTheOuterBundleNameNotTheHelper() {
        let path = "/Applications/Visual Studio Code.app/Contents/Frameworks/"
                 + "Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"
        XCTAssertEqual(EditorEnvironment.editorName(inPath: path), "Visual Studio Code")
    }

    func testFindsAnEditorInstalledOutsideApplications() {
        let path = "/Users/rowan/Applications/Cursor.app/Contents/Frameworks/"
                 + "Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)"
        XCTAssertEqual(EditorEnvironment.editorName(inPath: path), "Cursor")
    }

    /// Any other Electron app has helpers with the same name. Only the editors we
    /// know how to talk about are reported.
    func testIgnoresAnUnrelatedElectronApp() {
        let path = "/Applications/Slack.app/Contents/Frameworks/"
                 + "Slack Helper (Plugin).app/Contents/MacOS/Slack Helper (Plugin)"
        XCTAssertNil(EditorEnvironment.editorName(inPath: path))
    }

    // MARK: - The real thing

    /// A smoke test, not an assertion about this machine: whether an editor is open
    /// during a test run is nobody's business. It only checks that shelling out to
    /// `ps` and parsing whatever comes back cannot crash or hang, and that anything
    /// reported is internally consistent.
    func testInspectingRunningEditorsIsSafe() {
        for host in EditorEnvironment.extensionHosts() {
            XCTAssertTrue(EditorEnvironment.knownEditors.contains(host.editor))
            if let slug = host.slug {
                XCTAssertFalse(slug.isEmpty)
                XCTAssertEqual(host.configDir?.hasSuffix(Branding.profilePrefix + slug),
                               true)
            }
        }
    }
}
