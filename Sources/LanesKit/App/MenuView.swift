// Lanes — account lanes for Claude Code
// Copyright (C) 2026 rowansail
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit

/// The contents of the dropdown menu.
///
/// Two things to know about `MenuBarExtra` in the `.menu` style:
///
/// 1. You write ordinary SwiftUI, but AppKit renders it as a real `NSMenu`. Reliably
///    works: Button, Toggle (drawn automatically as a checkmark), Text (a grey,
///    non-clickable line), Divider, ForEach, Menu (a submenu). Does *not*: your own
///    layout with HStack/VStack, colours, images beside text, or a text field. If you
///    need those, `.window` is the style — which is exactly why the setup wizard is a
///    real window rather than a menu.
///
/// 2. A ViewBuilder takes at most ten separate children. That is why this menu is cut
///    into sections: not for tidiness, but because it otherwise does not compile.
///    Worth knowing before adding a line.
struct MenuView: View {

    @ObservedObject var store: ProfileStore
    @ObservedObject var keepAwake: KeepAwake

    var body: some View {
        header
        Divider()
        profileSection
        Divider()
        actionSection
        Divider()
        setupSection
        Divider()
        settingsSection
    }

    // MARK: - Sections

    /// The active profile, and the two caveats that come with it.
    ///
    /// Neither line is filler.
    ///
    /// "Switching does not affect what is already running" is the single thing every
    /// user of this app has to learn, it cannot be engineered away, and a menu that
    /// states it every time is cheaper than a menu that lets people rediscover it.
    ///
    /// The third line exists because a profile is a whole `CLAUDE_CONFIG_DIR`, not a
    /// login. `projects/` (every session transcript, and the `memory/` folder inside
    /// each), `history.jsonl`, `plans/`, `settings.json`, `skills/`, `plugins/` and the
    /// MCP servers in `.claude.json` all live inside the folder being switched. So
    /// `claude --resume` in one profile cannot see the other's conversations, and a
    /// hook or permission set up in one is absent in the other. People read "switch
    /// account" and expect their history to follow them; it does not, and finding that
    /// out mid-task is the second-worst surprise this app can hand somebody.
    @ViewBuilder
    private var header: some View {
        if let error = store.lastError {
            Text("⚠ \(error)")
        }

        if let active = store.activeProfile {
            Text("Active: \(active.displayName)"
                 + (active.accountEmail.map { "  —  \($0)" } ?? ""))
            Text("Applies to terminals and apps you open next")
            Text("History, memory, settings and MCP servers are per profile")
        } else {
            Text("No profile active")
        }
    }

    @ViewBuilder
    private var profileSection: some View {
        // A heading, because without it the rows below are three words with a tick
        // beside one of them and no statement of what they are.
        Text("Switch to")

        // Toggle and not Button, because a Toggle in an NSMenu is drawn automatically as
        // a checkmark — exactly the right semantics here: one of a group is on.
        ForEach(store.profiles) { profile in
            Toggle(isOn: binding(for: profile)) {
                Text(label(for: profile))
            }
        }

        if store.profiles.isEmpty {
            Text("No ~/\(Branding.profilePrefix)* folders found")
        }

        // Adding a lane belongs beside the lanes, not under setup. Setup is a thing you
        // do once; this is part of using the switcher.
        //
        // A button and a dialog rather than a submenu of names the app picked. An NSMenu
        // cannot hold a text field, but that is a reason to open something that can — not
        // a reason to decide on somebody's behalf that their accounts are called work,
        // personal and "client".
        Button("New Profile…") {
            store.createProfileAskingForName()
        }
    }

    /// Things you do with the active profile.
    ///
    /// `Check Setup…` used to live here and has moved down to sit beside `Setup…`,
    /// where anybody looking for it will look. What is left is one shape: act on the
    /// lane you are in.
    @ViewBuilder
    private var actionSection: some View {
        if let active = store.activeProfile, store.desktopAppURL != nil {
            // The desktop app is a separate login (Electron cookies) and ignores
            // CLAUDE_CONFIG_DIR entirely. This opens it with this profile's data
            // directory, so work and personal can sit side by side. Hidden when
            // Claude.app is not installed.
            Button("Open Claude App (\(active.displayName))") {
                store.openDesktopApp(for: active)
            }
            // Phrased as an instruction rather than a fact, because the fact alone
            // ("the Dock opens your original account") tells you what goes wrong
            // without telling you what to do instead. The mistake is made right here:
            // the Dock icon is one gesture away, it opens perfectly, and nothing about
            // it suggests you have just landed in a different account.
            Text("Only open from here — the Dock icon opens your original account")
        }

        // Keep awake sits here rather than under the settings: it is something you *do*
        // for the task you are about to start, not something you configure once.
        keepAwakeMenu
    }

    /// Setting up and undoing it. Two doors, and deliberately only two.
    ///
    /// This used to be seven entries — a status line, a wizard, the report, two
    /// warnings, a submenu of profile names and a Maintenance submenu holding four more
    /// actions, one of which moved your entire Claude history to the Trash. Every one of
    /// them was individually defensible and the result was a menu nobody could read.
    ///
    /// Everything that was in Maintenance now lives inside one of the two wizards, where
    /// it can be explained before it happens instead of being a verb on a menu row:
    /// hook installation and repair belong to Set Up, restoring and removing belong to
    /// Uninstall. The rename from the app's previous name is no longer a menu state at
    /// all — it is a repair like any other, and the wizard's plan still carries it.
    @ViewBuilder
    private var setupSection: some View {
        let status = store.setupStatus

        // One entry point rather than a button per action. The wizard shows what it
        // found and what it intends to do before doing any of it, and neither of those
        // fits in an NSMenu — a text field for the profile name certainly does not.
        switch status.kind {
        case .neverInstalled:
            Text("Not set up on this Mac yet")
            Button("Set Up \(Branding.name)…") {
                SetupWizardWindow.shared.show(store: store, mode: .install)
            }

        // A legacy install is a machine that needs work, which is what "repair" means.
        // Giving it its own wording made people think it was a different kind of thing
        // requiring a different kind of decision; it is not, and the wizard has said so
        // in full on its first page all along.
        case .legacy, .broken:
            Text("⚠ \(status.problems.count) problem(s) with the current setup")
            Button("Repair Setup…") {
                SetupWizardWindow.shared.show(store: store, mode: .install)
            }

        case .ready:
            // Not "Setup…", which sat one line above "Check Setup…" and made two
            // different things look like the same thing said twice.
            Button("Setup Assistant…") {
                SetupWizardWindow.shared.show(store: store, mode: .install)
            }
        }

        // showReport and not show(title:text:): building the report costs a second of
        // subprocesses, and it opens the window first and fills it in after.
        Button("Check Setup…") {
            ReportWindow.shared.showReport(
                store: store,
                title: "\(Branding.name) — Setup")
        }

        // Shown even on a machine with nothing installed, where it opens on a page that
        // says there is nothing to undo. An uninstaller you can only find once you are
        // already set up is one people go looking for in the Trash instead.
        Button("Uninstall \(Branding.name)…") {
            SetupWizardWindow.shared.show(store: store, mode: .uninstall)
        }

        // Somebody deliberately using a shell with no hook needs to *know*, rather than
        // wonder why switching appears to do nothing.
        if !status.shellIsSupported && !status.loginShell.isEmpty {
            Text("Note: your login shell is \(status.shellName), which has no hook")
        }
    }

    // `Pin a Project…` used to sit here: a folder picker, and a list of the pins the
    // app had created. Both halves were weaker than the command they duplicated.
    // `lane lock` runs in the directory you are already standing in, where a picker
    // makes you go and find it — and the list was only ever pins made *through the
    // menu*, so the ones made with `lane lock`, or committed by a colleague, silently
    // did not appear. A list of your pins that omits most of your pins is worse than
    // no list.
    //
    // The pin itself is untouched and is still the strongest thing this app does. It
    // lives entirely in the shell hook, which is the only place that can honour it.
    // `lane`, `lane lock` and `lane unlock` cover it, and `./doctor.sh` answers "which
    // pin applies here" properly, because a shell has a current directory and an app
    // launched by launchd does not.

    @ViewBuilder
    private var settingsSection: some View {
        Toggle(isOn: Binding(
            get: { store.launchAtLogin },
            set: { store.setLaunchAtLogin($0) }
        )) {
            Text("Launch at Login")
        }

        Toggle(isOn: Binding(
            get: { store.checksSetupAutomatically },
            set: { store.setChecksSetupAutomatically($0) }
        )) {
            Text("Check Setup Automatically")
        }

        Text("\(Branding.name) \(Branding.version)")

        Button("Quit") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    // MARK: - Keep awake

    /// Keep awake, with the duration options and the display choice.
    ///
    /// Toggles rather than Buttons for the durations, so the active choice gets a
    /// checkmark — same reason as for the profiles. Checking one turns it on; unchecking
    /// turns it off.
    @ViewBuilder
    private var keepAwakeMenu: some View {
        Menu(keepAwake.mode.isOn ? "Keep Awake ✓" : "Keep Awake") {
            if let status = keepAwake.statusLine {
                Text(status)
            }

            Toggle(isOn: Binding(
                get: { !keepAwake.mode.isOn },
                set: { if $0 { keepAwake.stop() } })) {
                Text("Off")
            }

            Divider()

            ForEach(KeepAwakeDuration.allCases) { option in
                Toggle(isOn: Binding(
                    get: { matches(option) },
                    set: { if $0 { keepAwake.start(option.mode) } })) {
                    Text(option.label)
                }
            }

            Divider()

            Toggle(isOn: Binding(
                get: { keepAwake.keepDisplayOn },
                set: { keepAwake.setKeepDisplayOn($0) })) {
                Text("Keep Display On Too")
            }
        }
    }

    /// Does this duration option match the current mode?
    ///
    /// For a timed session this cannot be exact: `.until(date)` no longer knows whether
    /// you picked one hour or two. So while a timer runs no duration gets a checkmark —
    /// the remaining time is at the top of the menu anyway.
    private func matches(_ option: KeepAwakeDuration) -> Bool {
        switch (option, keepAwake.mode) {
        case (.indefinite, .indefinite):          return true
        case (.whileClaude, .whileClaudeRunning): return true
        default:                                  return false
        }
    }

    // MARK: - Helpers

    /// A radio-like binding: switching on activates, switching off does nothing. You
    /// cannot pick "no profile" — there is always exactly one active.
    private func binding(for profile: Profile) -> Binding<Bool> {
        Binding(
            get: { profile.slug == store.activeSlug },
            set: { isOn in
                if isOn { store.activate(profile) }
            }
        )
    }

    private func label(for profile: Profile) -> String {
        var text = profile.displayName
        if let email = profile.accountEmail {
            text += "  —  \(email)"
        } else {
            text += "  —  not logged in"
        }
        return text
    }
}
