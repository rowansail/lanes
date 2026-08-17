// Lanes — account lanes for Claude Code
// Copyright (C) 2026 rowansail
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Combine          // ObservableObject and @Published live here, not in Foundation
import AppKit
import ServiceManagement

/// The only place in the app that reads and writes state.
///
/// The model has two layers, and the order of importance between them is worth being
/// explicit about:
///
///  1. `Locations.stateFile` is the source of truth: one line holding the slug of the
///     active profile. The shell hook reads that file and exports
///     `CLAUDE_CONFIG_DIR`, which is how *every* new shell gets the right account —
///     Terminal, iTerm, VS Code's integrated terminal, and non-interactive scripts
///     too.
///
///  2. The `~/.claude` symlink follows along. Claude Code does not need it and does not
///     read it. It exists so tools that only do a `readlink` — an older VS Code
///     extension, somebody's script — do not report something different from the menu
///     bar.
///
/// Everything here runs on the main thread: the app starts from main, the timer is on
/// the main run loop, the file watcher delivers on the main queue, and SwiftUI reads
/// these properties from main. So there is no locking and no dispatching, and that is a
/// deliberate simplification rather than an oversight.
public final class ProfileStore: ObservableObject {

    @Published public private(set) var profiles: [Profile] = []
    @Published public private(set) var activeSlug: String?
    @Published public private(set) var setupStatus: Setup.Status
    @Published public private(set) var lastError: String?

    /// Where everything lives. Injected rather than derived, so tests can point the
    /// whole store at a temporary directory.
    public let locations: Locations

    /// Called when the setup needs the user's attention.
    ///
    /// A closure rather than a direct call to the wizard window, so this file — which
    /// holds all the logic worth testing — does not depend on the UI. The app sets it;
    /// a test can set it to a counter and assert on how often it fires.
    public var onSetupNeedsAttention: (() -> Void)?

    /// Whether attention-demanding UI is already on screen, so the store never fights
    /// with a wizard the user opened themselves.
    public var isAttentionUIVisible: () -> Bool = { false }

    private var timer: Timer?
    private var watcher: FileWatcher?

    /// Which desktop instance belongs to which profile.
    ///
    /// Only knows about instances *this* app launched. Start Claude another way and we
    /// will not see it and will open a second one. The alternative is parsing `ps`
    /// output for `--user-data-dir`, which is more fragility than the problem deserves.
    private var desktopInstances: [String: NSRunningApplication] = [:]

    public var activeProfile: Profile? {
        profiles.first { $0.slug == activeSlug }
    }

    public var stateFile: URL { locations.stateFile }
    public var symlinkURL: URL { locations.claudeLink }

    public init(locations: Locations = .real,
                defaults: UserDefaults = .standard) {
        self.locations = locations
        self.defaults = defaults
        self.setupStatus = Setup.status(at: locations, profileSlugs: [])

        refresh()

        // The state file gets an event source rather than a poll: switching from a
        // terminal then shows up in the menu bar immediately instead of up to two
        // seconds later, and nothing wakes the CPU while nothing is happening.
        watcher = FileWatcher(url: locations.stateFile) { [weak self] in
            self?.refresh()
        }

        // The timer is now only a backstop for everything the watcher cannot see: a
        // new profile folder appearing, a shell config edited in an editor, the hook
        // being removed by hand. Five seconds instead of the old two, because none of
        // those are things anyone does and then stares at the menu bar waiting for.
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        timer?.invalidate()
        watcher?.stop()
    }

    private let defaults: UserDefaults

    // MARK: - Reading

    public func refresh() {
        let found = Profile.discover(in: locations)

        // Only assign when something actually changed. Without this check
        // objectWillChange fires on every tick and SwiftUI redraws the menu bar label
        // twelve times a minute for nothing.
        if found != profiles { profiles = found }

        let slug = readActiveSlug()
        if slug != activeSlug { activeSlug = slug }

        let status = Setup.status(at: locations, profileSlugs: found.map(\.slug))
        if status != setupStatus { setupStatus = status }

        considerAskingForAttention()
    }

    private func readActiveSlug() -> String? {
        if let slug = AtomicFile.readTrimmed(locations.stateFile) { return slug }

        // Never switched through the app? Derive it from the symlink, so the menu bar
        // tells the truth from the first second rather than showing a question mark on
        // a machine that is in fact perfectly set up.
        if let target = try? FileManager.default
            .destinationOfSymbolicLink(atPath: locations.claudeLink.path) {
            let name = (target as NSString).lastPathComponent
            if name.hasPrefix(Branding.profilePrefix) {
                return String(name.dropFirst(Branding.profilePrefix.count))
            }
        }

        return nil
    }

    /// Names used as a placeholder when asking for a new one.
    public static var suggestedSlugs: [String] { Setup.newProfileSlugs }

    /// Creates a profile, asking what to call it.
    ///
    /// This used to be a submenu of three fixed names. That was a workaround for an
    /// `NSMenu` not being able to hold a text field, and it showed: the third suggestion
    /// was `client`, which is a category and not a name. Nobody has an account called
    /// "client" — they have one called `acme`, and the folder is the thing they will be
    /// reading in a menu bar for the next year.
    ///
    /// Re-asks on an invalid name with the reason in the dialog, rather than failing into
    /// `lastError` where the answer is a grey line in a menu you have to reopen.
    public func createProfileAskingForName() {
        lastError = nil

        let placeholder = ProfileStore.suggestedSlugs
            .first { Profile.validate($0, in: locations) == nil } ?? "acme"
        var message = "Lowercase letters, digits and hyphens. It becomes the folder "
                    + "~/\(Branding.profilePrefix)<name> and the word you type after "
                    + "`\(Branding.command)`."
        var initial = ""

        while true {
            guard let raw = Prompt.text(title: "New profile",
                                        message: message,
                                        placeholder: placeholder,
                                        initial: initial,
                                        confirmButton: "Create") else { return }

            if let problem = Profile.validate(raw, in: locations) {
                message = problem
                initial = raw          // keep what they typed; they are fixing it
                continue
            }

            do {
                _ = try Setup.createProfile(slug: raw, at: locations)
            } catch {
                report(error)
            }
            refresh()
            return
        }
    }

    // MARK: - Claude Code itself

    /// What Claude Code looks like on this machine.
    ///
    /// Cached: detecting it runs `claude --version`, and a subprocess every five seconds
    /// to answer a question whose answer changes at most monthly would be absurd.
    /// Refreshed on demand from the report window.
    public private(set) lazy var claudeInstall: ClaudeCodeInstall = {
        ClaudeCodeInstall.detect(in: locations)
    }()

    public func redetectClaudeInstall() {
        claudeInstall = ClaudeCodeInstall.detect(in: locations)
        objectWillChange.send()
    }

    /// Whether the Keychain still looks the way the app assumes.
    ///
    /// Not cached in a property because it runs `security` once per profile; the report
    /// asks for it, and nothing else should.
    public func checkKeychainConsistency() -> KeychainConsistency.Verdict {
        KeychainConsistency.check(profiles: profiles)
    }

    // MARK: - Switching

    public func activate(_ profile: Profile) {
        lastError = nil
        do {
            // The order matters: the step that can fail goes first.
            //
            // Done the other way round, a rejected symlink swap — because `~/.claude`
            // turned out to be a real folder — would leave a state file that had
            // already switched. Shells would pick up the new profile while the symlink
            // still pointed at the old one, which is precisely the mismatch this app
            // exists to remove. In this order a failed switch is a non-event.
            try Setup.repointSafely(to: profile.directory, at: locations)
            try Setup.writeState(profile.slug, at: locations)
        } catch {
            report(error)
        }
        refresh()
    }

    // MARK: - Setup, restore and cleanup

    /// Should the app check the setup at startup and when it breaks?
    ///
    /// A real setting rather than a hardcoded yes: if somebody deliberately keeps those
    /// conflicting `.zshrc` lines, a wizard appearing at every launch stops being
    /// helpful and becomes nagging.
    public var checksSetupAutomatically: Bool {
        // The default has to be true, and UserDefaults returns false for a missing
        // bool — hence the explicit registration rather than a bare `bool(forKey:)`.
        defaults.register(defaults: [Self.autoCheckKey: true])
        return defaults.bool(forKey: Self.autoCheckKey)
    }

    public func setChecksSetupAutomatically(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.autoCheckKey)
        objectWillChange.send()
    }

    private static let autoCheckKey = "checkSetupAutomatically"

    /// Have we already asked about the problem currently on screen?
    ///
    /// Reset as soon as the setup is healthy again, so a *new* problem later in the
    /// same session does get announced. Without this flag the wizard would reappear on
    /// every tick.
    private var didAskForAttention = false

    /// Skip the very first refresh: that one runs from `init`, before the app has
    /// finished launching, and opening a window there is asking for trouble. The
    /// timer's first tick is a much better moment.
    private var isFirstRefresh = true

    private func considerAskingForAttention() {
        if isFirstRefresh {
            isFirstRefresh = false
            return
        }

        if setupStatus.kind == .ready {
            didAskForAttention = false
            return
        }

        // Only summon the wizard for something it can fix. A machine whose only
        // complaint is a line in the user's own .zshrc is broken in a sense the app has
        // deliberately declined to do anything about, and opening a wizard about it at
        // every launch is a nag rather than a warning. The menu still shows the
        // problem count, and opening the wizard by hand still explains it in full.
        guard setupStatus.hasRepairableProblems else {
            didAskForAttention = false
            return
        }

        guard checksSetupAutomatically,
              !didAskForAttention,
              !isAttentionUIVisible() else { return }

        didAskForAttention = true
        onSetupNeedsAttention?()
    }

    /// Rewrites the hook for the login shell, replacing our own block if present.
    ///
    /// The wizard only offers to install the hook when it is *missing*, so without this
    /// there is no way to update an existing install after the hook changes — you would
    /// silently keep running last version's script. Installing strips its own block
    /// first, so this is idempotent and safe to run repeatedly.
    public func reinstallShellHook() {
        lastError = nil
        do { try Setup.installHook(at: locations) } catch { report(error) }
        refresh()
    }

    /// Installs the hook for a shell other than the login shell.
    public func installHook(for flavor: ShellFlavor) {
        lastError = nil
        do { try ShellHook.install(flavor, at: locations) } catch { report(error) }
        refresh()
    }

    public func removeHook(for flavor: ShellFlavor) {
        lastError = nil
        do { try ShellHook.remove(flavor, at: locations) } catch { report(error) }
        refresh()
    }

    // MARK: - Project locks

    // Pinning used to be driven from here — an open panel to choose a folder, and a
    // UserDefaults list of the pins that panel had created. Both went with the menu
    // entry. The list could only ever hold pins made through the app, which made it a
    // list of your pins that omitted most of your pins, and the panel duplicated
    // `lane lock` while being strictly more work than it.
    //
    // The pin mechanism is untouched: it lives in the shell hook, which is the only
    // thing that can honour it, and `ProjectLocks` still models the file.

    // Restoring a normal install and cleaning everything up used to live here, each
    // behind its own confirmation dialog. Both are now steps in the uninstall wizard
    // instead: a dialog can only ask "are you sure", while the wizard can show the
    // numbered list of what is about to happen and let you go back. Two routes to
    // trashing every conversation you have ever had was one too many.

    // MARK: - The desktop app

    /// The bundle id of the Claude desktop app.
    public static let desktopAppBundleID = "com.anthropic.claudefordesktop"

    /// Where is Claude.app? Looked up by bundle id rather than assuming
    /// `/Applications`, so it keeps working when the app lives elsewhere.
    /// `nil` means not installed, and the menu hides the button accordingly.
    public var desktopAppURL: URL? {
        NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: Self.desktopAppBundleID)
    }

    /// Opens the desktop app with *this* profile's data directory.
    ///
    /// Note what this function does not do: it never touches a running instance
    /// belonging to another profile. Claude.app holds its cookie database open for as
    /// long as it lives, and pulling data out from under a live instance can corrupt
    /// that database. So each instance keeps its own directory for its whole life and
    /// there is never anything to swap.
    ///
    /// The consequence is that switching profiles in the menu does not close or restart
    /// the desktop app. This button only follows whichever profile is active.
    public func openDesktopApp(for profile: Profile) {
        lastError = nil

        guard let appURL = desktopAppURL else {
            lastError = "Claude.app was not found on this Mac."
            return
        }

        // Already an instance open for this profile? Bring it forward rather than
        // adding a second window logged into the same account.
        if let running = desktopInstances[profile.slug], !running.isTerminated {
            running.activate(options: [.activateIgnoringOtherApps])
            return
        }

        // Electron would create the data directory itself, but doing it here means a
        // failed launch is explainable straight away instead of leaving an empty window.
        do {
            try AtomicFile.createDirectory(profile.desktopDataDir)
        } catch {
            lastError = "Could not create \(profile.desktopDataDir.path): "
                      + error.localizedDescription
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--user-data-dir=\(profile.desktopDataDir.path)"]

        // Required. Without this, macOS focuses the already-running Claude and
        // discards our arguments, and the button looks broken.
        //
        // Worth knowing that this only works because the app is not sandboxed: a
        // sandboxed process has `configuration.arguments` ignored outright, which is
        // one of the reasons sandboxing was never an option here.
        configuration.createsNewApplicationInstance = true

        // openApplication and not Shell.run: the latter calls waitUntilExit() and would
        // block for as long as the desktop app stays open. Everything here is on the
        // main thread, so the menu bar would freeze for hours.
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) {
            [weak self] app, error in

            // This closure arrives on a background queue, and everything in this class
            // belongs on main, so hop back first.
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.lastError = "Could not start the Claude app: "
                                   + error.localizedDescription
                    NSSound.beep()
                    return
                }
                self.desktopInstances[profile.slug] = app
            }
        }
    }

    // MARK: - Launch at login

    /// `SMAppService` is the modern replacement for a LaunchAgent plist: macOS lists the
    /// app under System Settings › General › Login Items, where the user can switch it
    /// off. Only works reliably from `/Applications`.
    public var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()

                // register() can succeed *without* the login item being on: if it was
                // switched off in System Settings earlier, macOS remembers and the
                // status becomes .requiresApproval. No error is thrown, but the
                // checkbox springs back — and without this message that looks like a
                // bug in the app rather than a decision the user made months ago.
                if SMAppService.mainApp.status == .requiresApproval {
                    lastError = "Enable '\(Branding.name)' in System Settings "
                              + "› General › Login Items."
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            objectWillChange.send()
        } catch {
            lastError = "Could not set the login item: \(error.localizedDescription)"
        }
    }

    // MARK: - Errors

    private func report(_ error: Error) {
        lastError = error.localizedDescription
        NSSound.beep()
    }
}

/// A confirmation dialog.
///
/// Separate from the store so the destructive paths can be read without wading through
/// AppKit, and so there is exactly one place that remembers to call `activate` first.
/// Asking for one line of text.
///
/// An `NSAlert` with a text field in its accessory view, rather than a window of our
/// own, for the same reason `Confirm` is an alert: this is a single question with two
/// answers, and a whole window for it would be more ceremony than the question deserves.
///
/// It exists because an `NSMenu` cannot hold a text field — see the note at the top of
/// ``MenuView``. That constraint used to be answered by offering a submenu of three
/// hardcoded names, which meant the app decided what your accounts were called.
public enum Prompt {

    /// Returns the trimmed text, or `nil` if cancelled. Empty input counts as cancelled.
    public static func text(title: String,
                            message: String,
                            placeholder: String,
                            initial: String = "",
                            confirmButton: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: confirmButton)
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initial
        alert.accessoryView = field

        // Without this the text field is not focused and the first thing you type goes
        // nowhere — the classic NSAlert-with-accessory-view papercut.
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let value = field.stringValue.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}

public enum Confirm {

    /// The `activate` is required because this is an `LSUIElement` app: it is never
    /// "active", so without that line the dialog appears *behind* whatever the user is
    /// looking at, and the button appears to have done nothing.
    @discardableResult
    public static func ask(title: String,
                           message: String,
                           confirmButton: String,
                           destructive: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = destructive ? .critical : .warning

        let go = alert.addButton(withTitle: confirmButton)
        alert.addButton(withTitle: "Cancel")
        if destructive { go.hasDestructiveAction = true }

        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
