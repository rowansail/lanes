// Lanes — account lanes for Claude Code
// Copyright (C) 2026 rowansail
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit

/// Which direction the wizard is running in.
///
/// One window and one set of steps for both, rather than two wizards. Setting up and
/// taking apart ask the same five questions in the same order — what is on disk, what do
/// you want, here is the plan, here is what happened, here is what is left for you — and
/// the half of this file that answers them is worth writing once. Only the content of
/// each step differs, which is exactly what a mode is for.
enum SetupWizardMode {
    case install
    case uninstall

    var windowTitle: String {
        switch self {
        case .install:   return "\(Branding.name) Setup"
        case .uninstall: return "Uninstall \(Branding.name)"
        }
    }
}

/// The wizard window. Same pattern and the same reason as ``ReportWindow``: a SwiftUI
/// `Window` scene opens immediately at launch on macOS 13, which is wrong for an app
/// that should only exist in the menu bar until asked for.
final class SetupWizardWindow {

    static let shared = SetupWizardWindow()
    private var window: NSWindow?

    private init() {}

    /// Is the window on screen right now? Used by the automatic check so it never fights
    /// with a wizard the user already has open.
    var isVisible: Bool { window?.isVisible ?? false }

    func show(store: ProfileStore, mode: SetupWizardMode = .install) {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false)

            // Without this the app crashes as soon as you close the window and open it
            // again: AppKit releases a closed window by default.
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }

        // Set every time and not just on creation: one window serves both modes, so a
        // title fixed at creation would say "Setup" over the uninstaller.
        window?.title = mode.windowTitle

        // Rebuilt on every show, so reopening reflects the machine's current state
        // rather than whatever it found the last time.
        window?.contentView = NSHostingView(
            rootView: SetupWizardView(store: store, mode: mode) { [weak self] in
                self?.window?.close()
            })

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - One step in the plan

/// An action the wizard is going to perform.
///
/// The action is carried inside the item as a closure, which is deliberate: the review
/// step lists the titles of exactly this array, and running walks exactly this array. So
/// what the user is shown cannot diverge from what happens. A second list of "what I am
/// about to do" strings would inevitably drift from the first.
private struct PlanItem: Identifiable {
    let id = UUID()
    let title: String
    let detail: String

    /// Does this action require a fresh login? A flag rather than a string match on the
    /// title, which silently stops warning the moment anybody rewords it.
    let requiresRelogin: Bool
    let action: () throws -> Void

    var result: Result<Void, Error>?

    init(title: String,
         detail: String,
         requiresRelogin: Bool = false,
         action: @escaping () throws -> Void) {
        self.title = title
        self.detail = detail
        self.requiresRelogin = requiresRelogin
        self.action = action
    }
}

// MARK: - The wizard

/// What an uninstall should leave behind.
///
/// Two genuinely different intentions, and conflating them would be the one unforgivable
/// bug in this file. "I am done with the app" wants a working Claude Code afterwards.
/// "Get all of this off my Mac" does not. The first is reversible by running setup again;
/// the second moves entire conversation histories to the Trash.
private enum UninstallChoice: Hashable {
    /// Put one profile back at `~/.claude` as a normal folder. Everything else stays.
    case restore
    /// Trash the profile folders too.
    case removeEverything
}

private struct SetupWizardView: View {

    @ObservedObject var store: ProfileStore
    let mode: SetupWizardMode
    let onClose: () -> Void

    private enum Step: Int, CaseIterable {
        case diagnose, choose, review, run, done

        var title: String {
            switch self {
            case .diagnose: return "Findings"
            case .choose:   return "Choices"
            case .review:   return "Plan"
            case .run:      return "Apply"
            case .done:     return "Done"
            }
        }
    }

    @State private var step: Step = .diagnose
    @State private var primarySlug = ""
    @State private var secondSlug = ""
    @State private var wantSecondProfile = false
    @State private var wantHook = true
    @State private var plan: [PlanItem] = []

    /// Extra shells to hook, beyond the login shell.
    ///
    /// This was a Maintenance submenu of toggles that applied the moment you clicked
    /// one. It belongs here instead: hooking a second shell is a decision about how this
    /// Mac is set up, and it should go through the same show-the-plan-first path as
    /// every other such decision rather than silently editing a startup file on click.
    @State private var extraFlavors: Set<ShellFlavor> = []

    @State private var uninstallChoice: UninstallChoice = .restore
    @State private var restoreSlug: String = ""

    private var locations: Locations { store.locations }
    private var status: Setup.Status { store.setupStatus }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                content
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            footer
        }
        .frame(width: 640, height: 560)
        .onAppear(perform: prefillSlugs)
    }

    // MARK: - Step indicator

    private var header: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                let active = s == step
                let passed = s.rawValue < step.rawValue

                Text(s.title)
                    .font(.system(size: 11, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? .primary : (passed ? .secondary : .tertiary))

                if s != Step.allCases.last {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Content per step

    @ViewBuilder
    private var content: some View {
        switch (step, mode) {
        case (.diagnose, .install):   diagnoseStep
        case (.diagnose, .uninstall): uninstallDiagnoseStep
        case (.choose, .install):     chooseStep
        case (.choose, .uninstall):   uninstallChooseStep
        case (.review, _):            reviewStep
        case (.run, _):               runStep
        case (.done, .install):       doneStep
        case (.done, .uninstall):     uninstallDoneStep
        }
    }

    /// Step 1 — what we found, worded according to which situation this is.
    ///
    /// The cases get different tone on purpose. Telling somebody who has used this for
    /// months to "get started" would be worse than saying nothing; telling a first-time
    /// user that "something changed" would be nonsense.
    private var diagnoseStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(headline)
                .font(.title3.weight(.semibold))

            Text(subhead)
                .font(.callout)
                .foregroundStyle(.secondary)

            // What is actually on disk, regardless of which case we are in.
            VStack(alignment: .leading, spacing: 8) {
                switch status.claudeDir {
                case .symlink(let target, let exists):
                    row(exists, "~/.claude",
                        exists ? "symlink to \(locations.abbreviate(target))"
                               : "symlink to \(locations.abbreviate(target)) — missing")
                case .realDirectory:
                    row(false, "~/.claude", "a regular folder")
                case .missing:
                    row(false, "~/.claude", "does not exist")
                case .somethingElse:
                    row(false, "~/.claude", "neither a folder nor a symlink")
                }

                row(status.profileCount > 0, "Profiles",
                    status.profileCount == 0
                        ? "none"
                        : status.profileSlugs.joined(separator: ", "))

                if let hook = status.primaryHook {
                    row(hook.isCurrent, "Shell hook",
                        hookSummary(hook))
                } else {
                    row(false, "Shell hook", "no hook for \(status.shellName)")
                }

                row(status.shellIsSupported, "Login shell",
                    status.loginShell.isEmpty ? "unknown" : status.loginShell)
            }

            // The specific problems, only when there are any. On a fresh machine this
            // list is empty by design — nothing is broken, it simply is not set up.
            if status.kind == .broken || status.kind == .legacy {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(status.problems) { problem in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("• " + problem.summary)
                                .font(.callout.weight(.medium))
                            Text(problem.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 12)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }

            if status.needsMigration && status.profileCount == 0 {
                note("""
                You have used Claude Code before. This turns that existing install into \
                your first profile — settings and history are kept, nothing is deleted.
                """)
            }

            if status.kind == .ready {
                note("""
                Nothing to set up. Use the menu to switch profiles, or Maintenance to \
                restore or clean up.
                """)
            }
        }
    }

    private func hookSummary(_ hook: ShellHook.State) -> String {
        if hook.isCurrent { return "installed in ~/\(hook.flavor.relativeConfigPath)" }
        if hook.blockDamaged { return "block present but incomplete" }
        if hook.isOutdated {
            return "revision \(hook.scriptRevision.map(String.init) ?? "?"), "
                 + "this version writes \(ShellHook.revision)"
        }
        if hook.blockInstalled { return "block present, hook file missing" }
        return "missing — terminals will not follow"
    }

    private var headline: String {
        switch status.kind {
        case .ready:          return "Everything is in order"
        case .neverInstalled: return "Let's set this up"
        case .legacy:         return "Almost there — one rename to finish"
        case .broken:         return "Something has changed"
        }
    }

    private var subhead: String {
        switch status.kind {
        case .ready:
            return "No changes needed on this Mac."
        case .neverInstalled:
            return "\(Branding.name) has not been set up on this Mac yet. Here is what "
                 + "is currently on disk."
        case .legacy:
            return "This Mac was set up when the app was called "
                 + "'\(Branding.legacySlug)'. Your profiles are fine and stay exactly "
                 + "where they are — only the hook and the state file move to the new "
                 + "name."
        case .broken:
            return "This was set up before, but the layout it relies on no longer "
                 + "matches. Here is what is off, and what can be repaired."
        }
    }

    /// Step 2 — the only real choices.
    private var chooseStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            if needsPrimarySlug {
                VStack(alignment: .leading, spacing: 6) {
                    Text(status.needsMigration
                            ? "Name for your existing install"
                            : "Name for your first profile")
                        .font(.headline)

                    // Wording matters here: the user has to recognise this folder later
                    // as "the install I already had", which is why the suggestion is
                    // "original" rather than something neutral like "main".
                    Text(status.needsMigration
                            ? "Everything currently in ~/.claude moves to "
                              + "~/\(Branding.profilePrefix)\(displaySlug(primarySlug)) "
                              + "and keeps working."
                            : "A folder ~/\(Branding.profilePrefix)"
                              + "\(displaySlug(primarySlug)) will be created.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    TextField("original", text: $primarySlug)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)

                    if let problem = validate(primarySlug) {
                        Text(problem).font(.caption).foregroundStyle(.red)
                    }
                }
            }

            // With one profile there is nothing to switch between, so this belongs to a
            // first install rather than to "maybe later".
            if status.profileCount + (needsPrimarySlug ? 1 : 0) < 2 {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Create a second profile now", isOn: $wantSecondProfile)

                    Text("With only one profile there is nothing to switch between.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if wantSecondProfile {
                        TextField("work", text: $secondSlug)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)

                        if let problem = validate(secondSlug, against: [primarySlug]) {
                            Text(problem).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }

            if needsHook {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Install the shell hook", isOn: $wantHook)

                    Text(hookExplanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            otherShellsChoice
        }
    }

    /// Hooking a shell other than the login shell.
    ///
    /// A real need rather than a completionist one: plenty of people have zsh as their
    /// login shell and run fish interactively, and for them the login shell is not the
    /// shell they type `claude` into. Listed only when there is something to add, so a
    /// machine with one shell never sees it.
    @ViewBuilder
    private var otherShellsChoice: some View {
        let others = ShellFlavor.allCases.filter { $0 != status.primaryFlavor }
        let available = others.filter { flavor in
            !(status.hooks.first { $0.flavor == flavor }?.isCurrent ?? false)
        }

        if !available.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Other shells")
                    .font(.headline)

                Text("Only needed if you use one of these as well. The hook is the same "
                     + "one, in that shell's startup file.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                ForEach(available, id: \.self) { flavor in
                    Toggle(isOn: Binding(
                        get: { extraFlavors.contains(flavor) },
                        set: { on in
                            if on { extraFlavors.insert(flavor) }
                            else { extraFlavors.remove(flavor) }
                        }
                    )) {
                        Text("\(flavor.displayName)  —  ~/\(flavor.relativeConfigPath)")
                    }
                }
            }
        }
    }

    // MARK: - Uninstalling

    /// Step 1, uninstalling — what is here, and therefore what there is to undo.
    private var uninstallDiagnoseStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(status.hasEvidenceOfSetup
                    ? "Put this Mac back the way it was"
                    : "There is nothing to undo")
                .font(.title3.weight(.semibold))

            Text(status.hasEvidenceOfSetup
                    ? "Here is everything \(Branding.name) put on this Mac. The next "
                      + "page asks what should happen to it, and nothing is touched "
                      + "until you have seen the plan."
                    : "\(Branding.name) has not set anything up on this Mac, so there "
                      + "is nothing here to take apart. Deleting the app itself is "
                      + "enough.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if status.hasEvidenceOfSetup {
                VStack(alignment: .leading, spacing: 8) {
                    row(true, "Profiles",
                        status.profileCount == 0
                            ? "none"
                            : status.profileSlugs.joined(separator: ", "))

                    row(true, "~/.claude",
                        status.hasWorkingSymlink
                            ? "symlink to the active profile"
                            : "not a working symlink")

                    let installed = status.installedHooks.map { $0.flavor.displayName }
                    row(true, "Shell hooks",
                        installed.isEmpty ? "none" : installed.joined(separator: ", "))

                    row(true, "State", "~/.config/\(Branding.slug)")
                }

                // Stated unconditionally, and without a count. The app cannot know how
                // many pins you have — they are files in your projects, not a list it
                // keeps — and saying nothing means finding `.lanes` in a diff months
                // later with nothing to explain it.
                note("""
                Any \(Branding.lockFileName) project pins stay where they are. A pin \
                lives in your repository — quite possibly committed and shared — so \
                removing one is yours to do, not this app's. Without \(Branding.name) \
                installed they are inert text files that nothing reads.
                """)

                note("""
                Your Keychain is not touched, on the way out as on the way in. \
                \(Branding.name) has never read a token and does not start now.
                """)
            }
        }
    }

    /// Step 2, uninstalling — the one question that matters.
    private var uninstallChooseStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("What should be left behind?")
                .font(.headline)

            Picker("", selection: $uninstallChoice) {
                Text("Keep my Claude Code, remove \(Branding.name)").tag(UninstallChoice.restore)
                Text("Remove everything, including the profile folders")
                    .tag(UninstallChoice.removeEverything)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            switch uninstallChoice {
            case .restore:
                VStack(alignment: .leading, spacing: 6) {
                    Text("One profile becomes your normal install again — moved back to "
                         + "~/.claude as an ordinary folder, with its history and "
                         + "settings intact. The hook comes out of your shell config "
                         + "and the state file is deleted.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if store.profiles.isEmpty {
                        Text("No profiles to restore — only the hook and state file "
                             + "will be removed.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Profile to restore", selection: $restoreSlug) {
                            ForEach(store.profiles) { profile in
                                Text(profile.displayName).tag(profile.slug)
                            }
                        }
                        .frame(width: 320)

                        Text("The other profile folders stay exactly where they are. "
                             + "They are just folders; nothing needs \(Branding.name) "
                             + "to read them.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

            case .removeEverything:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Every ~/\(Branding.profilePrefix)* folder goes to the Trash, "
                         + "along with the symlink, the state directory and the hook "
                         + "blocks.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    note("""
                    Those folders hold every conversation, every session transcript, \
                    the memory files, your settings and your MCP servers — for every \
                    account. They go to the Trash and not to /dev/null, so this is \
                    recoverable until you empty it, but there is nothing else standing \
                    between you and losing all of it.
                    """)
                }
            }
        }
    }

    /// Step 5, uninstalling.
    private var uninstallDoneStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Two things left")
                .font(.title3.weight(.semibold))

            Text("""
            The app cannot change the environment of a shell that is already running, \
            so your open terminals still point at a profile path until you restart them.
            """)
                .font(.callout)
                .foregroundStyle(.secondary)

            command("exec \(status.shellName)",
                    "Clears \(Branding.configDirVariable) from this shell. A new tab "
                    + "works just as well.")

            if uninstallChoice == .restore {
                command("claude auth login",
                        "Once. The folder moved back to ~/.claude, so the path changed, "
                        + "and Claude Code names its Keychain item after that path.")
            }

            note("""
            \(Branding.name) itself is still in /Applications — drag it to the Trash \
            whenever you like. Quit it first from the menu bar, or macOS will refuse.
            """)
        }
    }

    private func buildUninstallPlan() -> [PlanItem] {
        var items: [PlanItem] = []

        switch uninstallChoice {
        case .restore:
            if let profile = store.profiles.first(where: { $0.slug == restoreSlug }) {
                let others = store.profiles.filter { $0.slug != profile.slug }
                let othersNote = others.isEmpty
                    ? "There are no other profile folders."
                    : "Left alone: "
                      + others.map { "~/" + Branding.profilePrefix + $0.slug }
                            .joined(separator: ", ") + "."

                items.append(PlanItem(
                    title: "Move ~/\(Branding.profilePrefix)\(profile.slug) back to "
                         + "~/.claude",
                    detail: "It becomes an ordinary folder again, with its history and "
                          + "settings intact. The hook comes out of every shell config "
                          + "and the state file is deleted. \(othersNote)",
                    requiresRelogin: true,
                    action: {
                        try Setup.restoreToNormalInstall(profile: profile, at: locations)
                    }))
            } else {
                // No profile to restore, so there is nothing to move — but a hook
                // pointing at a path that will not be there is worse than no hook.
                for flavor in status.installedHooks.map(\.flavor) {
                    items.append(PlanItem(
                        title: "Remove the \(flavor.displayName) hook",
                        detail: "Takes the managed block out of "
                              + "~/\(flavor.relativeConfigPath). Everything you wrote "
                              + "around it stays.",
                        action: { try ShellHook.remove(flavor, at: locations) }))
                }
            }

        case .removeEverything:
            let removal = Setup.removalPlan(profiles: store.profiles, at: locations)
            guard !removal.isEmpty else { return [] }

            var lines: [String] = []
            for directory in removal.profileDirs {
                lines.append(directory.lastPathComponent)
            }
            if removal.claudeLink != nil { lines.append(".claude (the symlink)") }
            if removal.stateDir != nil {
                lines.append(".config/\(Branding.slug)")
            }
            for flavor in removal.hookFlavors {
                lines.append("the block in ~/\(flavor.relativeConfigPath)")
            }

            items.append(PlanItem(
                title: "Move everything to the Trash",
                detail: lines.joined(separator: ", ")
                      + ". To the Trash and not deleted, so it is recoverable until you "
                      + "empty it.",
                action: { try Setup.removeEverything(plan: removal, at: locations) }))
        }

        return items
    }

    private var hookExplanation: String {
        guard let flavor = status.primaryFlavor else {
            return "Your login shell has no hook, so you will have to export "
                 + "\(Branding.configDirVariable) yourself."
        }
        var text = "Four lines go into ~/\(flavor.relativeConfigPath), between markers, "
                 + "with a backup beside it first. The hook itself lives in "
                 + "~/.config/\(Branding.slug)/\(flavor.hookFileName), so later updates "
                 + "never touch your shell config again."
        if !flavor.coversScripts {
            text += " Note that \(flavor.displayName) does not read that file for "
                  + "non-interactive shells, so `claude` from a script will not pick "
                  + "up the active profile."
        }
        return text
    }

    /// Step 3 — exactly what will happen, before anything happens.
    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What will happen")
                .font(.title3.weight(.semibold))

            if plan.isEmpty {
                Text("Nothing — there is nothing to change.")
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(plan.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, alignment: .trailing)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.callout.weight(.medium))
                        Text(item.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if plan.contains(where: \.requiresRelogin) {
                note("""
                You will need to log in once afterwards. Claude Code files its tokens \
                under a name derived from the folder path, and that path changes. This \
                app never touches your Keychain — not even to help.
                """)
            }

            // Only when setting up. On the way out, a line in .zshrc that overrides the
            // hook stops mattering the moment the hook is gone.
            if mode == .install, !status.conflicts.isEmpty {
                conflictBox
            }
        }
    }

    /// Step 4 — result per action.
    private var runStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(allSucceeded ? "Done" : "Something went wrong")
                .font(.title3.weight(.semibold))

            ForEach(plan) { item in
                HStack(alignment: .top, spacing: 10) {
                    switch item.result {
                    case .success:
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failure:
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    case nil:
                        Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.callout.weight(.medium))

                        if case .failure(let error) = item.result {
                            Text(error.localizedDescription)
                                .font(.callout)
                                .foregroundStyle(.red)
                        } else if item.result == nil {
                            Text("not attempted")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !allSucceeded {
                note("""
                Actions run in order and stop at the first failure, because later steps \
                depend on earlier ones. Anything with a checkmark above did happen.
                """)
            }
        }
    }

    /// Step 5 — what the user still has to do themselves.
    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Two things left, in a terminal")
                .font(.title3.weight(.semibold))

            Text("""
            The app cannot set an environment variable in a shell that is already \
            running — a process is given its environment when it starts. So these two \
            are yours to run.
            """)
                .font(.callout)
                .foregroundStyle(.secondary)

            command("exec \(status.shellName)",
                    "Restarts your current shell so the hook applies. A new tab works "
                    + "just as well.")
            command("claude auth login",
                    "Once per profile. Needed because the folder path — and with it the "
                    + "name of the Keychain item — has changed.")

            if !status.conflicts.isEmpty {
                conflictBox
            }

            if status.profileCount >= 2 {
                note("""
                Switch from the menu bar, or with `\(Branding.command) \
                \(status.profileSlugs.first ?? "work")` in a terminal. Both write the \
                same file, so they never disagree.

                For a project that must never use the wrong account, pin it: \
                `\(Branding.command) lock` in that directory. A pin beats whatever is \
                globally active, and `\(Branding.command) unlock` removes it.
                """)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if mode == .install, step == .diagnose, let first = status.conflicts.first {
                Button("Show ~/\(first.fileName)") {
                    NSWorkspace.shared.selectFile(first.file.path,
                                                  inFileViewerRootedAtPath: "")
                }
            }

            Spacer()

            if step != .run && step != .done {
                Button("Cancel", action: onClose)
            }

            if let back = previousStep {
                Button("Back") { step = back }
            }

            primaryButton
        }
        .padding(12)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch step {
        case .diagnose:
            // Nothing to do on this page's terms — a healthy machine when setting up, an
            // untouched one when uninstalling — so the only honest button is Close.
            if (mode == .install && status.kind == .ready)
                || (mode == .uninstall && !hasAnythingToUninstall) {
                Button("Close", action: onClose).keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") {
                    if hasChoices {
                        step = .choose
                    } else {
                        plan = buildPlan()      // nothing to ask, so skip step 2
                        step = .review
                    }
                }
                .keyboardShortcut(.defaultAction)
            }

        case .choose:
            Button("Continue") {
                plan = buildPlan()
                step = .review
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!choicesValid)

        case .review:
            // Named after the thing it does. "Apply" over a plan that moves every
            // conversation you have ever had to the Trash is not a label, it is a way of
            // not saying so.
            Button(plan.isEmpty ? "Close" : applyLabel) {
                if plan.isEmpty { onClose() } else { execute() }
            }
            .keyboardShortcut(.defaultAction)

        case .run:
            Button(allSucceeded ? "Continue" : "Close") {
                if allSucceeded { step = .done } else { onClose() }
            }
            .keyboardShortcut(.defaultAction)

        case .done:
            Button("Finish", action: onClose).keyboardShortcut(.defaultAction)
        }
    }

    private var applyLabel: String {
        switch mode {
        case .install:
            return "Apply"
        case .uninstall:
            return uninstallChoice == .removeEverything ? "Move to Trash" : "Restore"
        }
    }

    private var previousStep: Step? {
        // Going back after applying is pointless: the actions already happened, and a
        // second attempt would fail on "already exists".
        switch step {
        case .choose: return .diagnose
        case .review: return hasChoices ? .choose : .diagnose
        default:      return nil
        }
    }

    // MARK: - Decisions

    /// Does this machine need a profile name? Either `~/.claude` has to go somewhere, or
    /// there is no profile at all yet.
    private var needsPrimarySlug: Bool {
        status.needsMigration || status.profileCount == 0
    }

    /// Is the hook something to ask about? Not when it is already current, and not when
    /// the shell has no hook to install.
    private var needsHook: Bool {
        guard status.primaryFlavor != nil else { return false }
        guard let hook = status.primaryHook else { return false }
        return !hook.isCurrent
    }

    /// Is there anything to ask in step 2? If not it is skipped, rather than shown as an
    /// empty page.
    ///
    /// Uninstalling always asks. "What should be left behind" is not a detail to infer
    /// from the state of the disk — it is the entire decision, and the two answers differ
    /// by whether the user still has their conversation history afterwards.
    private var hasChoices: Bool {
        switch mode {
        case .uninstall:
            return true
        case .install:
            return needsPrimarySlug
                || needsHook
                || status.profileCount + (needsPrimarySlug ? 1 : 0) < 2
                || !ShellFlavor.allCases.filter { $0 != status.primaryFlavor }.isEmpty
        }
    }

    /// Is there anything on this Mac to undo?
    private var hasAnythingToUninstall: Bool {
        status.hasEvidenceOfSetup
    }

    /// Which existing profile should become active when repairing.
    ///
    /// Prefer what the state file already says, so a repair does not quietly move
    /// somebody to a different account than the one they were using.
    private var repairSlug: String? {
        if let slug = status.stateSlug, status.profileSlugs.contains(slug) {
            return slug
        }
        return status.profileSlugs.first
    }

    // MARK: - Building the plan

    private func buildPlan() -> [PlanItem] {
        switch mode {
        case .install:   return buildInstallPlan()
        case .uninstall: return buildUninstallPlan()
        }
    }

    private func buildInstallPlan() -> [PlanItem] {
        var items: [PlanItem] = []
        let slug = primarySlug.trimmingCharacters(in: .whitespaces)
        let second = secondSlug.trimmingCharacters(in: .whitespaces)

        /// Which profile should end up active once the plan is done.
        var slugToActivate: String?

        // The rename comes first when there is one. It carries over which profile was
        // active, and every later step should build on that rather than on a stale
        // answer.
        if status.legacy.isPresent {
            let legacy = status.legacy
            items.append(PlanItem(
                title: "Finish renaming from '\(Branding.legacySlug)'",
                detail: legacyDetail(legacy),
                action: { try LegacyInstall.adopt(legacy, at: locations) }))
        }

        if status.needsMigration {
            items.append(PlanItem(
                title: "Move ~/.claude to ~/\(Branding.profilePrefix)\(slug)",
                detail: "A rename within the same disk, so instant. A symlink goes back "
                      + "at the old path and ~/.claude.json is copied along.",
                requiresRelogin: true,
                action: {
                    try Setup.migrateExistingInstall(toSlug: slug, at: locations)
                }))
            // Migration writes the symlink and the state file itself.
        } else if status.profileCount == 0 {
            items.append(PlanItem(
                title: "Create profile folder ~/\(Branding.profilePrefix)\(slug)",
                detail: "An empty folder. Claude Code fills it on first login.",
                requiresRelogin: true,
                action: { _ = try Setup.createProfile(slug: slug, at: locations) }))
            slugToActivate = slug
        } else if !status.hasWorkingSymlink || !status.stateSlugResolves {
            // The repair path: the folders are fine, but nothing valid is active.
            slugToActivate = repairSlug
        }

        if wantSecondProfile && !second.isEmpty {
            items.append(PlanItem(
                title: "Create profile folder ~/\(Branding.profilePrefix)\(second)",
                detail: "So there is something to switch to.",
                action: { _ = try Setup.createProfile(slug: second, at: locations) }))
        }

        // A folder alone is not an active profile: without a symlink and a state file
        // nothing is active, and the menu bar would report "No profile active" after a
        // run that said it succeeded.
        if let target = slugToActivate {
            items.append(PlanItem(
                title: "Make \(target) the active profile",
                detail: "Points the ~/.claude symlink at it and writes the name to "
                      + "~/.config/\(Branding.slug)/active.",
                action: { try Setup.activate(slug: target, at: locations) }))
        }

        // Skipped when the rename already installed it, which it does as its last step.
        if wantHook && needsHook && !status.legacy.isPresent {
            let flavor = status.primaryFlavor
            items.append(PlanItem(
                title: "Install the shell hook"
                     + (flavor.map { " for \($0.displayName)" } ?? ""),
                detail: "A four-line block between markers, with a backup of the file "
                      + "beside it. Only that block is ever removed again.",
                action: { try Setup.installHook(at: locations) }))
        }

        // Sorted so the plan reads the same way twice running. A Set has no order, and a
        // numbered list that reshuffles between the review page and the run page would
        // undermine the one promise this wizard makes.
        for flavor in extraFlavors.sorted(by: { $0.rawValue < $1.rawValue }) {
            items.append(PlanItem(
                title: "Install the shell hook for \(flavor.displayName)",
                detail: "The same block, in ~/\(flavor.relativeConfigPath), with a "
                      + "backup of that file beside it."
                      + (flavor.coversScripts
                            ? ""
                            : " \(flavor.displayName) does not read that file for "
                              + "non-interactive shells, so `claude` from a script will "
                              + "not pick up the active profile."),
                action: { try ShellHook.install(flavor, at: locations) }))
        }

        return items
    }

    private func legacyDetail(_ legacy: LegacyInstall.Findings) -> String {
        var parts: [String] = []
        if !legacy.blockFiles.isEmpty {
            parts.append("Removes the old block from "
                         + legacy.blockFiles.map(\.lastPathComponent)
                            .joined(separator: ", ")
                         + " and installs the current hook.")
        }
        if let slug = legacy.stateSlug {
            parts.append("Keeps '\(slug)' as the active profile.")
        }
        if legacy.stateDirectory != nil {
            parts.append("Moves ~/.config/\(Branding.legacySlug) to the Trash.")
        }
        parts.append("Your profile folders are not touched.")
        return parts.joined(separator: " ")
    }

    private func execute() {
        // The one point of no return in this app. The review page has already listed
        // every folder by name, so this dialog does not repeat the list — it exists to
        // make the last gesture a deliberate one rather than the same Continue click
        // that got you through four harmless pages.
        if mode == .uninstall, uninstallChoice == .removeEverything {
            let count = store.profiles.count
            let ok = Confirm.ask(
                title: "Move \(count) profile folder(s) to the Trash?",
                message: "This is every conversation, transcript and memory file for "
                       + "every account. They go to the Trash, so you can get them back "
                       + "until you empty it — after that they are gone.",
                confirmButton: "Move to Trash",
                destructive: true)
            guard ok else { return }
        }

        for index in plan.indices {
            do {
                try plan[index].action()
                plan[index].result = .success(())
            } catch {
                plan[index].result = .failure(error)
                break      // later steps depend on earlier ones
            }
        }
        store.refresh()
        step = .run
    }

    private var allSucceeded: Bool {
        !plan.isEmpty && plan.allSatisfy {
            if case .success = $0.result { return true }
            return false
        }
    }

    // MARK: - Validation

    private var choicesValid: Bool {
        if mode == .uninstall {
            // Restoring needs a profile to restore — unless there are none, in which
            // case the plan is only "take the hook out" and there is nothing to pick.
            if uninstallChoice == .restore && !store.profiles.isEmpty {
                return store.profiles.contains { $0.slug == restoreSlug }
            }
            return true
        }
        if needsPrimarySlug && validate(primarySlug) != nil { return false }
        if wantSecondProfile
            && validate(secondSlug, against: [primarySlug]) != nil { return false }
        return true
    }

    private func validate(_ raw: String, against others: [String] = []) -> String? {
        Profile.validate(raw, against: others, in: locations)
    }

    /// Pre-fills sensible names so most people only have to press Continue.
    private func prefillSlugs() {
        // The profile to restore defaults to the active one: the account you are using
        // is the one you most likely want to still have afterwards.
        if restoreSlug.isEmpty {
            restoreSlug = store.activeSlug
                ?? store.profiles.first?.slug
                ?? ""
        }

        if primarySlug.isEmpty {
            let candidates = status.needsMigration
                ? Setup.migrationSlugs
                : Setup.newProfileSlugs
            primarySlug = candidates.first { validate($0) == nil } ?? ""
        }
        if secondSlug.isEmpty {
            secondSlug = Setup.newProfileSlugs
                .first { validate($0, against: [primarySlug]) == nil } ?? ""
        }
    }

    // MARK: - Small building blocks

    private func row(_ ok: Bool, _ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
                .font(.callout)

            Text(label)
                .font(.callout.weight(.medium))
                .frame(width: 92, alignment: .leading)

            Text(value)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var conflictBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Something else overrides the hook")
                .font(.callout.weight(.semibold))

            ForEach(status.conflicts) { conflict in
                Text("\(conflict.fileName):\(conflict.line)  \(conflict.text)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Text("""
            These files run after the hook, so their lines overwrite what it sets. And \
            an alias always beats a function in zsh. Remove them — the app does not, \
            because those are not the files it was given permission to manage.
            """)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private func command(_ text: String, _ why: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)

                Spacer()

                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .controlSize(.small)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))

            Text(why).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func displaySlug(_ raw: String) -> String {
        let slug = raw.trimmingCharacters(in: .whitespaces)
        return slug.isEmpty ? "…" : slug
    }
}
