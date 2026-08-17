// Lanes — account lanes for Claude Code
// Copyright (C) 2026 rowansail
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Which profile the Claude Code extension in VS Code (or Cursor, or any other fork)
/// is actually running in.
///
/// This type exists because the editor is the one place where the mechanism described
/// everywhere else in this app quietly does not apply, and until you can *see* that,
/// it looks like the app is lying to you.
///
/// The extension does not run `claude` through a shell. Its bundle spawns the binary
/// with `shell: false` and `env: {...process.env, ...}`, which has two consequences:
///
/// 1. **The profile is frozen when the editor launches** — not when the window opens.
///    The extension host is a child of the VS Code *main* process and inherits its
///    `process.env`, and that environment was resolved once, when the main process
///    started. Switch profiles afterwards and the menu bar, your terminals and the
///    editor's Claude panel disagree, with nothing on screen to say so.
/// 2. **Project pins do not apply there.** A `.lanes` file is honoured by the shell
///    function, and no shell runs. The panel uses the frozen profile whatever the
///    project says. That is the opposite of the guarantee the rest of this app makes,
///    so it is worth stating loudly rather than discovering.
///
/// Both are reported rather than fixed, because neither is fixable from outside: an
/// environment cannot be changed in a running process.
///
/// **`Developer: Reload Window` does not fix it, and this file used to say it did.**
/// Reloading does spawn a fresh extension host — you can watch the pid change — but a
/// fresh child of an unchanged parent inherits the unchanged environment. Observed
/// directly: a main process launched at 10:43 holding `.claude-work`, an extension host
/// spawned by a reload at 17:26, seven hours and one profile switch later, still holding
/// `.claude-work`. Nothing short of the main process exiting can change it, so the fix
/// is to quit the editor entirely — every window, so the main process goes — and reopen.
///
/// `"claudeCode.useTerminal": true` sidesteps both consequences at once, and is the
/// better advice for anyone who switches often: the integrated terminal is a real shell,
/// so it reads the state file per terminal and honours pins, with nothing to reload.
public enum EditorEnvironment {

    /// One extension host process, and the profile it is stuck with.
    public struct Host: Equatable {
        /// "Visual Studio Code", "Cursor" — derived from the bundle path.
        public let editor: String
        public let pid: Int32

        /// `CLAUDE_CONFIG_DIR` as this process actually has it. `nil` means the
        /// variable is absent, which is worse than a mismatch: Claude Code then falls
        /// back to `~/.claude` *and* to the unhashed default Keychain item.
        public let configDir: String?

        /// Where the editor was launched from. Only a hint at which window this is —
        /// it is the working directory at launch, not the folder currently open.
        public let launchedIn: String?

        /// The profile slug this host resolves to, if the path looks like a profile.
        public var slug: String? {
            guard let configDir else { return nil }
            let name = URL(fileURLWithPath: configDir).lastPathComponent
            guard name.hasPrefix(Branding.profilePrefix) else { return nil }
            return String(name.dropFirst(Branding.profilePrefix.count))
        }
    }

    /// Editors worth looking for. Matched on the bundle name in the process path, so a
    /// copy of VS Code that does not live in `/Applications` is found just the same.
    static let knownEditors = [
        "Visual Studio Code", "Visual Studio Code - Insiders",
        "Cursor", "VSCodium", "Windsurf", "Positron", "Trae",
    ]

    /// Every running extension host, newest process last.
    ///
    /// Returns an empty array when no editor is running, which is the common case and
    /// not worth distinguishing from "could not tell" — the report says what it found.
    public static func extensionHosts() -> [Host] {
        // -x and not -ax: only this user's processes. Another user's editor cannot be
        // inspected anyway, and asking would cost a subprocess per helper to find out.
        let listing = Shell.run("/bin/ps", ["-xo", "pid=,command="])
        guard listing.succeeded else { return [] }

        var hosts: [Host] = []

        for line in listing.stdout.split(separator: "\n") {
            let text = String(line).trimmingCharacters(in: .whitespaces)

            // Every Electron editor names its utility processes "<Name> Helper (Plugin)".
            // Cheap string test first: reading a process environment costs a subprocess
            // each, and a busy Mac has dozens of helpers.
            guard text.contains("Helper (Plugin)") else { continue }

            let parts = text.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            guard let editor = editorName(inPath: String(parts[1])) else { continue }

            // `ps eww` prints a process's environment. Allowed here only because the
            // editor runs as the same user; it fails silently for anything else, which
            // is exactly the behaviour wanted.
            let environment = Shell.run("/bin/ps", ["eww", "-p", String(pid)]).stdout

            // Several kinds of helper share that name, and the environment does not
            // separate them: a language server is a child of the extension host and
            // inherits every variable, this one included. So the test admits them all
            // and the dedupe below throws the duplicates away — which is the honest
            // shape of the question anyway: an inherited profile is the same profile.
            guard value(of: "VSCODE_CRASH_REPORTER_PROCESS_TYPE", in: environment)
                    == "extensionHost" else { continue }

            hosts.append(Host(
                editor: editor,
                pid: pid,
                configDir: value(of: Branding.configDirVariable, in: environment),
                launchedIn: value(of: "VSCODE_CWD", in: environment)))
        }

        // One row per editor per profile. Two rows for the same editor means two
        // instances on different profiles, which is worth seeing; twelve rows because
        // a TypeScript server is running is not.
        var seen: Set<String> = []
        return hosts.filter { seen.insert("\($0.editor)\u{0}\($0.configDir ?? "")").inserted }
    }

    /// The bundle name for a helper path, or `nil` when it is not an editor we know.
    ///
    /// `/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/…`
    /// has two `.app` components; the first one is the editor.
    static func editorName(inPath path: String) -> String? {
        for component in path.split(separator: "/") where component.hasSuffix(".app") {
            let name = String(component.dropLast(".app".count))
            return knownEditors.contains(name) ? name : nil
        }
        return nil
    }

    /// Pulls one variable out of `ps eww` output.
    ///
    /// `ps` separates the environment with single spaces and does not quote anything, so
    /// a value containing a space is ambiguous by construction — `/Users/my name/…` is
    /// indistinguishable from the end of one variable and the start of the next. The
    /// scan therefore keeps consuming words until one *looks* like `NAME=`, which is
    /// wrong only for a value whose own text contains something of that shape.
    static func value(of key: String, in output: String) -> String? {
        guard let start = output.range(of: " \(key)=")
                ?? output.range(of: "\n\(key)=") else { return nil }

        let rest = output[start.upperBound...]
        var words: [Substring] = []

        for word in rest.split(separator: " ", omittingEmptySubsequences: false) {
            // A newline ends the process's environment: the next line is another process.
            if let newline = word.firstIndex(of: "\n") {
                words.append(word[..<newline])
                break
            }
            if !words.isEmpty && looksLikeVariableName(word) { break }
            words.append(word)
        }

        let value = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// Does this word start a new `NAME=value` pair?
    private static func looksLikeVariableName(_ word: Substring) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals > word.startIndex
        else { return false }

        let name = word[..<equals]
        guard let first = name.first, first == "_" || first.isLetter else { return false }
        return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }
}
