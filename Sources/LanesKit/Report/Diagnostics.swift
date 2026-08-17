// Lanes — account lanes for Claude Code
// Copyright (C) 2026 rowansail
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Builds a readable report on the state of the setup.
///
/// This exists because the mechanism has several parts that can each drift
/// independently of the others — the environment variable, the state file, the symlink,
/// the hook, someone's `.zshrc`, a project pin — and a person staring at a menu bar
/// cannot see any of them. One button that shows all of it at once is the cheapest
/// possible way to make sure nobody ever has to guess again.
///
/// Everything here is read-only, and it is the first thing to paste into a bug report.
public enum Diagnostics {

    /// The three answers in this report that cost a subprocess to find out.
    ///
    /// Split out so they can be gathered off the main thread while the report window is
    /// already on screen saying so. Everything else in the report is a file read or a
    /// value the store already holds, and together they take no measurable time; these
    /// three run `claude --version`, `security` once per profile, and `ps` once per
    /// editor helper process. On a Mac with a cold node and a few editors open that is
    /// comfortably over a second — during which the old code had the menu closed, no
    /// window, and nothing to suggest the click had registered.
    ///
    /// A plain value type with no reference to the store, precisely so it is safe to
    /// build on a background queue. `ProfileStore` is main-thread-only by design and
    /// stays that way.
    public struct Probe {
        public let install: ClaudeCodeInstall
        public let keychain: KeychainConsistency.Verdict
        public let editorHosts: [EditorEnvironment.Host]

        /// Takes values, not the store. The caller reads `profiles` and `locations` on
        /// the main thread and hands the results over.
        public static func run(profiles: [Profile], locations: Locations) -> Probe {
            Probe(install: ClaudeCodeInstall.detect(in: locations),
                  keychain: KeychainConsistency.check(profiles: profiles),
                  editorHosts: EditorEnvironment.extensionHosts())
        }
    }

    /// - Parameter probe: the slow answers, if they have already been gathered. Passing
    ///   `nil` computes them inline, which is what the tests do and what any future
    ///   caller that does not care about blocking can keep doing.
    public static func report(store: ProfileStore, probe: Probe? = nil) -> String {
        var out: [String] = []
        let fm = FileManager.default
        let locations = store.locations
        let setup = store.setupStatus

        func section(_ title: String) {
            out.append("")
            out.append(title)
            out.append(String(repeating: "─", count: title.count))
        }
        func line(_ label: String, _ value: String) {
            out.append(label.padding(toLength: 15, withPad: " ", startingAt: 0) + value)
        }
        func note(_ text: String) {
            out.append(String(repeating: " ", count: 15) + text)
        }

        out.append("\(Branding.name) \(Branding.version) — \(Branding.tagline)")
        out.append("Not affiliated with Anthropic. Claude is a trademark of Anthropic, PBC.")

        // ── Installation ──────────────────────────────────────────────────────
        // Deliberately first: on a machine that is not set up, this is the only thing
        // worth knowing, and the rest of this report describes a layout that does not
        // exist yet.
        section("Installation")

        switch setup.kind {
        case .ready:
            line("status", "ready for use ✓")
        case .neverInstalled:
            line("status", "never set up on this Mac")
            note("Use 'Set Up \(Branding.name)…' in the menu.")
        case .legacy:
            line("status", "SET UP UNDER THE PREVIOUS NAME")
            note("Use 'Repair Setup…' in the menu.")
        case .broken:
            line("status", "SET UP BEFORE, BUT SOMETHING CHANGED")
            note("Use 'Repair Setup…' in the menu.")
        }

        out.append("")

        switch setup.claudeDir {
        case .missing:
            line("~/.claude", "does not exist")
        case .realDirectory:
            line("~/.claude", "a regular folder")
            note("This is a normal Claude Code install. While it stays")
            note("this way the app cannot switch anything.")
        case .symlink(let target, let exists):
            line("~/.claude", "-> \(locations.abbreviate(target))\(exists ? "  ✓" : "")")
            if !exists {
                note("⚠ that target does not exist — broken symlink")
            }
        case .somethingElse:
            line("~/.claude", "neither a folder nor a symlink")
            note("Unexpected, so the app stays away from it.")
        }

        line("profiles", "\(setup.profileCount)")
        line("state file", setup.stateSlug ?? "(empty — never switched via the app)")
        if let slug = setup.stateSlug, !setup.stateSlugResolves {
            note("⚠ ~/\(Branding.profilePrefix)\(slug) does not exist")
        }
        note(locations.abbreviate(locations.stateFile.path))
        line("login shell", setup.loginShell.isEmpty ? "unknown" : setup.loginShell)
        if !setup.shellIsSupported && !setup.loginShell.isEmpty {
            note("⚠ no hook for this shell. Supported: "
                 + ShellFlavor.allCases.map(\.displayName).joined(separator: ", "))
        }

        if setup.kind == .broken || setup.kind == .legacy, !setup.problems.isEmpty {
            out.append("")
            out.append("Problems found:")
            for problem in setup.problems {
                out.append("  • \(problem.summary)")
                out.append("    \(problem.detail)")
            }
        }

        // ── Claude Code ───────────────────────────────────────────────────────
        // The version matters because everything this app relies on is undocumented.
        // When it breaks, the first question anyone will ask is which version broke it.
        section("Claude Code")

        let install = probe?.install ?? store.claudeInstall
        if let executable = install.executable {
            line("binary", locations.abbreviate(executable.path))
            line("kind", install.kind.description)
            line("version", install.version ?? "could not be read")
        } else {
            line("binary", "NOT FOUND")
            note("Looked in: " + ClaudeCodeInstall.candidatePaths(in: locations)
                    .map { locations.abbreviate($0) }.joined(separator: ", "))
            note("The app still works — it only sets an environment")
            note("variable — but nothing will read it.")
        }

        out.append("")
        out.append("How switching works, and what is not promised:")
        out.append("\(Branding.configDirVariable) points Claude Code at a config folder, and")
        out.append("Claude Code files that folder's tokens in the login Keychain under")
        out.append("a name derived from a hash of the folder path. That gives real")
        out.append("isolation between accounts for free, and it means this app never")
        out.append("has to touch a credential.")
        out.append("")
        out.append("Neither the variable nor the hash is documented by Anthropic. Both")
        out.append("were established by observation and could change in any release.")
        out.append("The check below is what notices if they have.")

        let verdict = probe?.keychain ?? store.checkKeychainConsistency()
        out.append("")
        switch verdict {
        case .nothingToCheck:
            line("keychain", "nothing to check yet — no profile has logged in")
        case .consistent:
            line("keychain", "consistent with the expected layout ✓")
        case .unexpectedLayout:
            line("keychain", "⚠ NOT WHERE EXPECTED")
        case .cannotTell:
            line("keychain", "⚠ could not be confirmed")
        }
        if let explanation = KeychainConsistency.explanation(for: verdict) {
            out.append("")
            out.append(explanation)
        }

        // ── Profiles ──────────────────────────────────────────────────────────
        section("Profiles")

        if store.profiles.isEmpty {
            out.append("No ~/\(Branding.profilePrefix)* folders found.")
        }
        for profile in store.profiles {
            let mark = profile.slug == store.activeSlug ? "●" : "○"
            out.append("\(mark) \(profile.displayName)  "
                       + "(\(locations.abbreviate(profile.directory.path)))")
            out.append("    account      "
                       + (profile.accountEmail ?? "— no .claude.json / never logged in"))
            out.append("    keychain     "
                       + (profile.hasCredentials ? "present" : "MISSING — fresh login needed"))
            out.append("                 \(profile.keychainService)")
        }

        out.append("")
        out.append("Folder sizes are deliberately not shown: `du` on a profile of a few")
        out.append("hundred megabytes takes seconds, and this report is built on the main")
        out.append("thread — the menu bar would freeze. Run ./doctor.sh for those.")

        // ── Project pins ──────────────────────────────────────────────────────
        section("Project pins")

        out.append("A \(Branding.lockFileName) file in a project, holding a profile name,")
        out.append("pins that project. `claude` then uses that profile whatever is")
        out.append("globally active — deliberately, because an explicit per-project")
        out.append("statement should outrank a menu click from last Tuesday.")
        out.append("")

        // Deliberately not a list. This app is launched by launchd, so it has no current
        // directory and cannot answer "which pin applies to me"; and enumerating every
        // pin would mean scanning the whole home directory. There used to be a list here
        // of pins made through the menu, which read as "your pins" while omitting every
        // pin made with `lane lock` or committed by a colleague. A shell has a current
        // directory and answers both questions in a few lines, so it is sent the
        // question.
        out.append("Which pin applies where you are standing is a question for a shell:")
        out.append("")
        out.append("  \(Branding.command)          in the project — prints the pin, if any")
        out.append("  ./doctor.sh   walks up from the current directory the way the")
        out.append("                hook does, and flags a pin naming a profile this")
        out.append("                Mac does not have")
        out.append("")
        out.append("\(Branding.command) lock <name> pins the directory you are in;")
        out.append("\(Branding.command) unlock removes it. A pin is honoured by the shell")
        out.append("function, so it applies wherever a shell runs — and not in the")
        out.append("editor's own panel, which starts the CLI without one.")

        // ── Shell hooks ───────────────────────────────────────────────────────
        section("Shell hooks")

        for hook in setup.hooks {
            let isPrimary = hook.flavor == setup.primaryFlavor
            let status: String
            if hook.isCurrent {
                status = "installed ✓"
            } else if hook.isOutdated {
                status = "installed, revision \(hook.scriptRevision.map(String.init) ?? "?")"
                       + " (this version writes \(ShellHook.revision))"
            } else if hook.blockDamaged {
                status = "block present but incomplete"
            } else if hook.blockInstalled && !hook.scriptInstalled {
                status = "block present, hook file missing"
            } else if !hook.blockInstalled && hook.scriptInstalled {
                status = "hook file present but never sourced"
            } else if !hook.configFileExists {
                status = "not installed (~/\(hook.flavor.relativeConfigPath) does not exist)"
            } else {
                status = "not installed"
            }

            line(hook.flavor.displayName + (isPrimary ? " (yours)" : ""), status)
            note("~/\(hook.flavor.relativeConfigPath)")
            if hook.isInstalled {
                note(locations.abbreviate(locations.hookFile(for: hook.flavor).path))
                let backup = locations.backup(of: locations.shellConfigFile(for: hook.flavor))
                if fm.fileExists(atPath: backup.path) {
                    note("backup: " + locations.abbreviate(backup.path))
                }
            }
            if !hook.flavor.coversScripts {
                note("does not reach non-interactive shells")
            }
        }

        out.append("")
        out.append("The startup file gets a four-line block between markers; the hook")
        out.append("itself lives in ~/.config/\(Branding.slug)/. Upgrades rewrite that file")
        out.append("and leave your shell config alone. Only the block between these")
        out.append("markers is ever removed:")
        out.append("")
        out.append("    \(ManagedBlock.current.begin)")
        out.append("    \(ManagedBlock.current.end)")

        // ── Env var ───────────────────────────────────────────────────────────
        section(Branding.configDirVariable)

        let appValue = ProcessInfo.processInfo.environment[Branding.configDirVariable]
        out.append("in this app process: \(appValue ?? "(not set)")")
        out.append("")
        out.append("This says nothing about your terminals. The app was launched by")
        out.append("launchd and never saw a shell environment. What applies in a terminal")
        out.append("you can only see there:")
        out.append("")
        out.append("    echo $\(Branding.configDirVariable)")

        // ── Things that override the hook ─────────────────────────────────────
        section("Files that override the hook")

        if setup.conflicts.isEmpty {
            out.append("Nothing found. Clean ✓")
        } else {
            for conflict in setup.conflicts {
                out.append("~/\(conflict.fileName):\(conflict.line)")
                out.append("    \(conflict.text)")
            }
            out.append("")
            out.append("These files run after the hook, so an export there wins. And an")
            out.append("alias always beats a function in zsh, so old `alias claude-…`")
            out.append("lines make the \(Branding.command) command unreachable. Remove them.")
            out.append("")
            out.append("The app reports this and does not fix it. It was given permission")
            out.append("to manage one file; reaching into another because it happens to")
            out.append("be convenient is how a tool loses the right to be trusted with")
            out.append("the first one.")
        }

        // ── Editors ───────────────────────────────────────────────────────────
        // The one place where everything above stops being the whole story, so it gets
        // its own section rather than a footnote under the shell hook.
        section("Editors")

        out.append("Claude Code in VS Code — and in Cursor and the other forks — runs")
        out.append("the same CLI, so \(Branding.configDirVariable) decides its account")
        out.append("exactly as it does in a terminal. Two differences matter:")
        out.append("")
        out.append("• The extension host takes its environment from the editor's main")
        out.append("  process, which resolved it once when the editor launched.")
        out.append("  Switching profiles afterwards does not reach it, and")
        out.append("  'Developer: Reload Window' does NOT fix it — reloading spawns a")
        out.append("  fresh extension host, but a fresh child of an unchanged parent")
        out.append("  inherits the unchanged environment. Quit the editor entirely")
        out.append("  (every window, so the main process exits) and open it again.")
        out.append("• The extension starts the CLI directly, without a shell, so project")
        out.append("  pins are NOT honoured in its panel — the shell function is what")
        out.append("  reads \(Branding.lockFileName), and no shell runs. Setting")
        out.append("  \"claudeCode.useTerminal\": true makes it launch in the integrated")
        out.append("  terminal instead, where pins work like everywhere else.")
        out.append("")

        let hosts = probe?.editorHosts ?? EditorEnvironment.extensionHosts()
        if hosts.isEmpty {
            out.append("No editor window is open, or none could be inspected.")
        } else {
            for host in hosts {
                guard let configDir = host.configDir else {
                    out.append("⚠ \(host.editor)")
                    out.append("    \(Branding.configDirVariable) is not set in this window.")
                    out.append("    Claude Code there falls back to ~/.claude and to the")
                    out.append("    default Keychain item — a different account from every")
                    out.append("    profile. Quit the editor and start it again.")
                    continue
                }

                let slug = host.slug
                let matches = slug != nil && slug == store.activeSlug
                out.append("\(matches ? "●" : "⚠") \(host.editor)  "
                           + "→ \(slug ?? locations.abbreviate(configDir))")
                if let launchedIn = host.launchedIn {
                    out.append("    launched in  \(locations.abbreviate(launchedIn))")
                }
                if !matches {
                    out.append("    the menu bar says '\(store.activeSlug ?? "none")'.")
                    out.append("    Quit this editor completely and reopen it to bring")
                    out.append("    it along. Reloading the window is not enough.")
                }
            }
        }

        // Editor settings are a separate category: not a shell file, same effect.
        var editors: [String] = []
        for editor in ["Code", "Cursor", "Code - Insiders", "VSCodium", "Windsurf"] {
            let settings = locations.home.appendingPathComponent(
                "Library/Application Support/\(editor)/User/settings.json")
            guard let text = try? String(contentsOf: settings, encoding: .utf8) else { continue }
            if text.contains(Branding.configDirVariable) {
                editors.append("\(editor): settings.json sets \(Branding.configDirVariable)")
                editors.append("  → terminal.integrated.env.osx can go; the hook already")
                editors.append("    covers the integrated terminal.")
            }
        }
        if !editors.isEmpty {
            out.append("")
            out.append(editors.joined(separator: "\n"))
        }

        // ── Legacy ────────────────────────────────────────────────────────────
        // Shown when either the old *files* or the old *app* is still here. Those are
        // two separate leftovers: adopting the install rewrites the hook, and does
        // nothing whatsoever about a second application sitting in /Applications.
        let legacyApp = LegacyInstall.installedApp()

        if setup.legacy.isPresent || legacyApp != nil {
            section("Previous name")
            out.append("This app used to be called '\(Branding.legacySlug)'.")

            if setup.legacy.isPresent {
                out.append("")
                out.append("Traces of the old install: \(setup.legacy.description)")
                out.append("")
                out.append("Two hook blocks in one file both export "
                           + "\(Branding.configDirVariable),")
                out.append("and the later one wins — which is exactly the class of bug this")
                out.append("app exists to remove. Use 'Repair Setup…' in the menu.")
            }

            if let legacyApp {
                out.append("")
                line("old app", locations.abbreviate(legacyApp.url.path))
                note(legacyApp.isRunning ? "⚠ RUNNING RIGHT NOW" : "installed, not running")
                out.append("")
                out.append("The rename produced a second application; it did not replace")
                out.append("the first. While that one runs you have two menu bar items,")
                out.append("it keeps writing its own state file, and it repoints the")
                out.append("~/.claude symlink — so switching in one of them appears to do")
                out.append("nothing. Quit it, then drag it to the Trash. \(Branding.name)")
                out.append("will not remove another application for you.")
            }
        }

        // ── Desktop app ───────────────────────────────────────────────────────
        section("Claude desktop app")

        out.append("A DIFFERENT login from Claude Code. The desktop app is Electron and")
        out.append("keeps its session in cookies; \(Branding.configDirVariable) has no")
        out.append("effect on it whatsoever. So each profile gets its own")
        out.append("--user-data-dir, and you log in once per profile.")
        out.append("")

        if let appURL = store.desktopAppURL {
            line("Claude.app", appURL.path)
            out.append("")

            for profile in store.profiles {
                let mark = profile.slug == store.activeSlug ? "●" : "○"
                out.append("\(mark) \(profile.displayName)")
                if fm.fileExists(atPath: profile.desktopDataDir.path) {
                    out.append("    data dir     "
                               + locations.abbreviate(profile.desktopDataDir.path))
                    out.append("    session      "
                               + (profile.desktopHasSession ? "present" : "not logged in yet"))
                } else {
                    out.append("    data dir     not created yet")
                }
            }

            out.append("")
            out.append("The Dock icon starts Claude with the default directory")
            out.append("(~/Library/Application Support/Claude) — your original login, the")
            out.append("one you had before \(Branding.name), and not a profile. It keeps")
            out.append("working and is left alone. To get a profile you have to open the")
            out.append("app from the menu, or with `\(Branding.command) app`; there is no")
            out.append("way to make the Dock icon do it.")
        } else {
            line("Claude.app", "NOT FOUND on this Mac")
            note("The menu hides the button accordingly.")
        }

        // ── Footnote ──────────────────────────────────────────────────────────
        section("Remember")
        out.append("An already-running Claude Code session does not follow along. A")
        out.append("process is given its environment when it starts, and nothing can")
        out.append("change that from outside afterwards — not this app, not anything.")
        out.append("Switching therefore always applies to what you start next.")

        return out.joined(separator: "\n")
    }
}
