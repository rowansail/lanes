// Lanes — account lanes for Claude Code
// Copyright (C) 2026 rowansail
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Darwin

public enum SetupError: LocalizedError {
    case claudeDirIsNotRealDirectory
    case destinationExists(String)
    case noProfileToActivate
    case claudeDirIsRealDirectory(String)
    case noSupportedShell(String)
    case posix(String, Int32)
    case partialFailure([String])

    public var errorDescription: String? {
        switch self {
        case .claudeDirIsNotRealDirectory:
            return "~/.claude is not a real folder — there is nothing to convert."
        case .destinationExists(let path):
            return "\(path) already exists. Pick another name, or clear that folder first."
        case .noProfileToActivate:
            return "There is no profile folder to activate."
        case .claudeDirIsRealDirectory(let path):
            return "\(path) is a real folder, not a symlink. \(Branding.name) will not "
                 + "touch it — its contents need a profile of their own first."
        case .noSupportedShell(let shell):
            return "Your login shell is \(shell), which \(Branding.name) has no hook "
                 + "for. Supported: " + ShellFlavor.allCases.map(\.displayName)
                    .joined(separator: ", ") + "."
        case .posix(let call, let code):
            return "\(call) failed: \(String(cString: strerror(code))) (errno \(code))"
        case .partialFailure(let items):
            return "Could not finish: " + items.joined(separator: ", ")
        }
    }
}

/// Converts a normal Claude Code install into the profile layout, and back again.
///
/// This exists because the rest of the app assumes the conversion already happened:
/// that `~/.claude` is a symlink, that `~/.claude-*` folders exist, and that the shell
/// hook is installed. On a fresh Mac none of that is true, and without this code the
/// app is a menu that refuses to do anything with no way forward.
///
/// Everything here is synchronous. These are renames within one volume and a few small
/// text files; none of it takes long enough to be worth the complexity of getting off
/// the main thread.
public enum Setup {

    /// Suggested name when converting an existing install.
    ///
    /// "original" rather than "main" or "personal": the whole point is that the user
    /// recognises this folder months later as the install they already had. A neutral
    /// word tells them nothing about where their history went.
    public static let migrationSlugs = ["original", "existing", "previous"]

    /// Suggested names for additional profiles. Used as a placeholder and a prefill,
    /// never as the only thing on offer — every surface that shows these also lets you
    /// type your own.
    ///
    /// Deliberately two and not three. The third used to be `client`, which reads as a
    /// suggestion until you notice it is a category rather than a name: the folder you
    /// actually want is `acme`, because that is what tells you whose repo you are in
    /// when you read it in the menu bar a year from now.
    public static let newProfileSlugs = ["work", "personal"]

    // MARK: - What is ~/.claude?

    public enum ClaudeDirState: Equatable, Sendable {
        case missing
        case symlink(target: String, targetExists: Bool)
        case realDirectory
        case somethingElse
    }

    /// A line in a startup file that quietly defeats the hook.
    public struct Conflict: Identifiable, Equatable, Sendable {
        public let file: URL
        public let line: Int
        public let text: String

        public var id: String { "\(file.path):\(line)" }
        public var fileName: String { file.lastPathComponent }
    }

    // MARK: - Diagnosis

    /// Something that is wrong and needs explaining to a human.
    public struct Problem: Identifiable, Equatable, Sendable {
        public let id: String
        public let summary: String
        public let detail: String

        /// Can the wizard actually do something about this?
        ///
        /// Not cosmetic. The automatic check opens the wizard when the setup is not
        /// `.ready`, and a problem the app has decided never to touch — a line in your
        /// `.zshrc`, which it reports and deliberately does not edit — can therefore
        /// never stop being a problem. Without this flag such a machine opens the
        /// wizard on every single launch, showing a page whose only advice is "fix this
        /// yourself", forever. That is not a warning any more, it is a nag, and the
        /// only escape was to switch the whole check off and lose the warnings that
        /// *are* actionable.
        ///
        /// It still counts as a problem: the menu shows it, the report prints it, and
        /// opening the wizard by hand still explains it. It just does not summon
        /// anything.
        public let isRepairable: Bool

        init(_ id: String,
             _ summary: String,
             _ detail: String,
             isRepairable: Bool = true) {
            self.id = id
            self.summary = summary
            self.detail = detail
            self.isRepairable = isRepairable
        }
    }

    /// Which of the four worlds are we in?
    ///
    /// The distinction matters for tone as much as for logic. "Never set up" is a
    /// welcome; "was set up and is now broken" is a report of what changed. Telling
    /// someone who has used this for months that they should get started would be
    /// worse than saying nothing at all.
    public enum Kind: Equatable, Sendable {
        /// Nothing to repair.
        case ready

        /// Never set up here. May still be a normal Claude Code install with history
        /// worth keeping.
        case neverInstalled

        /// Set up under the app's previous name, and never adopted.
        case legacy

        /// Set up before, and something has since changed underneath it.
        case broken
    }

    /// `Equatable` so the store can publish it only when it actually changed. Without
    /// that, a five-second poll redraws the menu bar twelve times a minute for nothing.
    public struct Status: Equatable {
        public var locations: Locations
        public var claudeDir: ClaudeDirState
        public var profileSlugs: [String]
        public var stateSlug: String?
        public var loginShell: String
        public var hooks: [ShellHook.State]
        public var conflicts: [Conflict]
        public var legacy: LegacyInstall.Findings

        public var profileCount: Int { profileSlugs.count }

        // MARK: Shell

        /// The flavour matching the user's login shell, if the app supports it.
        public var primaryFlavor: ShellFlavor? {
            ShellFlavor.matching(loginShell: loginShell)
        }

        public var shellIsSupported: Bool { primaryFlavor != nil }

        /// The hook state for the shell the user actually uses. That is the one whose
        /// health decides whether switching works; a hook installed for a shell they
        /// never open is decoration.
        public var primaryHook: ShellHook.State? {
            guard let flavor = primaryFlavor else { return nil }
            return hooks.first { $0.flavor == flavor }
        }

        public var installedHooks: [ShellHook.State] { hooks.filter(\.isInstalled) }

        public var hookInstalled: Bool { primaryHook?.isInstalled ?? false }
        public var hookIsCurrent: Bool { primaryHook?.isCurrent ?? false }

        // MARK: Layout

        /// Does `~/.claude` still need converting from a real folder to a profile?
        public var needsMigration: Bool { claudeDir == .realDirectory }

        public var hasWorkingSymlink: Bool {
            if case .symlink(_, let exists) = claudeDir { return exists }
            return false
        }

        public var stateSlugResolves: Bool {
            guard let stateSlug else { return false }
            return profileSlugs.contains(stateSlug)
        }

        /// Is there any trace of a previous setup on this machine?
        ///
        /// This is what separates "never installed" from "broken", and it is why the
        /// first-run experience is a welcome rather than a list of complaints.
        public var hasEvidenceOfSetup: Bool {
            profileCount > 0 || !installedHooks.isEmpty || stateSlug != nil
        }

        public var isReady: Bool { kind == .ready }

        /// Is there a problem the wizard could actually act on?
        ///
        /// What the automatic check asks, rather than "is anything wrong" — see
        /// ``Problem/isRepairable``.
        public var hasRepairableProblems: Bool {
            problems.contains { $0.isRepairable }
        }

        public var kind: Kind {
            // Checked first, and specifically gated on there being no *current* hook.
            //
            // The subtlety: profile folders are shared between the old name and the new
            // one — they are Claude Code's config directories, not ours — so a legacy
            // install looks like an install by every other measure. What distinguishes
            // it is that the old block is in the shell config and ours is not. Once
            // both are present the situation is no longer "not yet renamed" but "two
            // blocks fighting", which is a `.broken` problem with its own entry.
            if legacy.isPresent && installedHooks.isEmpty { return .legacy }
            if !hasEvidenceOfSetup && !legacy.isPresent { return .neverInstalled }
            return problems.isEmpty ? .ready : .broken
        }

        /// Everything currently wrong, in the order a person would want to hear it.
        ///
        /// Derived rather than stored so it can never disagree with the fields above.
        /// Read when a menu opens or the wizard draws, never in a hot path.
        public var problems: [Problem] {
            var found: [Problem] = []

            // Only a problem when something else claims this was set up. On a machine
            // that never had profiles, "there are no profiles" is the normal starting
            // state — reporting it as a fault would greet every first-time user with a
            // complaint.
            if profileCount == 0 && (!installedHooks.isEmpty || stateSlug != nil) {
                found.append(Problem(
                    "no-profiles",
                    "There are no \(Branding.profilePrefix)* profile folders",
                    "The hook or the state file says this was set up, so they were "
                    + "moved or removed. Without at least one profile there is nothing "
                    + "to switch between."))
            }

            switch claudeDir {
            case .realDirectory where profileCount > 0:
                found.append(Problem(
                    "claude-dir-real",
                    "~/.claude is a real folder again, not a symlink",
                    "Profile folders exist, so this was set up before. The app will not "
                    + "touch a real folder — its contents need a profile of their own "
                    + "first."))

            case .missing where profileCount > 0:
                found.append(Problem(
                    "claude-dir-missing",
                    "The ~/.claude symlink is gone",
                    "Claude Code still works through \(Branding.configDirVariable), but "
                    + "tools that read ~/.claude directly see nothing."))

            case .symlink(let target, let exists) where !exists:
                found.append(Problem(
                    "claude-dir-dangling",
                    "~/.claude points at something that no longer exists",
                    "The link target is \(target). Most likely a profile folder was "
                    + "renamed or deleted."))

            case .somethingElse:
                found.append(Problem(
                    "claude-dir-odd",
                    "~/.claude is neither a folder nor a symlink",
                    "Unexpected, so the app stays away from it."))

            case .realDirectory, .missing, .symlink:
                break   // the normal cases
            }

            if let stateSlug, !profileSlugs.contains(stateSlug) {
                found.append(Problem(
                    "state-dangling",
                    "The active profile '\(stateSlug)' does not exist",
                    "\(Branding.profilePrefix)\(stateSlug) is gone. Every new shell "
                    + "falls back to no profile at all until this points somewhere "
                    + "real."))
            }

            if !shellIsSupported && !loginShell.isEmpty {
                found.append(Problem(
                    "shell-unsupported",
                    "Your login shell is \(shellName), which has no hook",
                    "Supported shells are "
                    + ShellFlavor.allCases.map(\.displayName).joined(separator: ", ")
                    + ". In any other shell you have to export "
                    + "\(Branding.configDirVariable) yourself."))
            }

            if let hook = primaryHook, profileCount > 0 {
                if !hook.isInstalled {
                    found.append(Problem(
                        "hook-missing",
                        "The shell hook is missing from ~/\(hook.flavor.relativeConfigPath)",
                        "Without it a new terminal does not know which profile is "
                        + "active, so switching has no effect on Claude Code."))
                } else if hook.blockDamaged {
                    found.append(Problem(
                        "hook-damaged",
                        "The block in ~/\(hook.flavor.relativeConfigPath) is incomplete",
                        "It has a start marker but no end marker, so it was edited by "
                        + "hand and not finished. Reinstalling replaces it."))
                } else if hook.isOutdated {
                    found.append(Problem(
                        "hook-outdated",
                        "The shell hook is from an older version",
                        "It is revision \(hook.scriptRevision.map(String.init) ?? "unknown") "
                        + "and this version writes \(ShellHook.revision). Reinstalling "
                        + "the hook updates it; nothing else changes."))
                } else if !hook.scriptInstalled {
                    found.append(Problem(
                        "hook-script-missing",
                        "The hook file is gone but the block still loads it",
                        "~/\(hook.flavor.relativeConfigPath) sources a file that no "
                        + "longer exists. Harmless — it is guarded — but nothing is "
                        + "switching. Reinstalling restores it."))
                }
            }

            if !conflicts.isEmpty {
                let files = Set(conflicts.map(\.fileName)).sorted().joined(separator: ", ")
                found.append(Problem(
                    "shell-conflicts",
                    "\(files) overrides the hook on \(conflicts.count) line(s)",
                    "Those files run after the hook, so their lines win. This has to be "
                    + "fixed by hand — the app only manages the one file it installed "
                    + "into.",
                    // Hence not repairable, and hence not something to reopen the
                    // wizard about: the app has already decided it will not touch
                    // these files, so nothing it can offer will ever clear it.
                    isRepairable: false))
            }

            if legacy.isPresent {
                found.append(Problem(
                    "legacy-install",
                    "There is still an install under the previous name",
                    legacy.description))
            }

            return found
        }

        public var shellName: String {
            loginShell.isEmpty ? "unknown" : (loginShell as NSString).lastPathComponent
        }
    }

    /// The login shell from the passwd database, not from `$SHELL`.
    ///
    /// The app was launched by launchd and never saw a shell environment, so `$SHELL`
    /// is either absent or left over from something else. `getpwuid` reports what is
    /// actually configured for the account.
    public static var loginShell: String {
        guard let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell else {
            return ""
        }
        return String(cString: shell)
    }

    /// `loginShell` is a parameter with a default rather than read inline, so a test can
    /// pin it. Otherwise every assertion about hook state would depend on whichever
    /// shell the machine running the tests happens to be configured with — which is one
    /// thing on a developer's Mac and something else again on a CI runner.
    public static func status(at locations: Locations,
                             profileSlugs: [String],
                             loginShell: String = Setup.loginShell) -> Status {
        Status(
            locations: locations,
            claudeDir: claudeDirState(at: locations),
            profileSlugs: profileSlugs,
            stateSlug: AtomicFile.readTrimmed(locations.stateFile),
            loginShell: loginShell,
            hooks: ShellFlavor.allCases.map { ShellHook.state(of: $0, at: locations) },
            conflicts: conflicts(in: locations),
            legacy: LegacyInstall.detect(in: locations))
    }

    /// What `~/.claude` currently is.
    ///
    /// `lstat` and not `stat`: the entire question is what the path *is*, and `stat`
    /// follows symlinks and answers about the target instead — so a symlink to a real
    /// folder would be reported as a real folder, and the app would refuse to switch
    /// on a perfectly healthy install.
    public static func claudeDirState(at locations: Locations) -> ClaudeDirState {
        let fm = FileManager.default
        let path = locations.claudeLink.path

        var info = stat()
        guard lstat(path, &info) == 0 else { return .missing }

        if (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
            let target = (try? fm.destinationOfSymbolicLink(atPath: path)) ?? "?"

            // A stored target may be relative, in which case it resolves against the
            // directory holding the link — not against this process's working
            // directory, or a healthy link would be reported as broken.
            let resolved = URL(fileURLWithPath: target,
                               relativeTo: locations.claudeLink.deletingLastPathComponent())
            return .symlink(target: target,
                            targetExists: fm.fileExists(atPath: resolved.path))
        }
        if (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) { return .realDirectory }
        return .somethingElse
    }

    // MARK: - Reporting on files we do not manage

    /// Startup files that run *after* the hook and could override it.
    ///
    /// The order zsh reads its files is `.zshenv`, `.zprofile`, `.zshrc`, `.zlogin`;
    /// the hook goes in the first, so every later one can undo it. bash's `.bashrc`
    /// and the generic `.profile` are here for the same reason.
    static func conflictSources(in locations: Locations) -> [URL] {
        [".zprofile", ".zshrc", ".zlogin", ".bashrc", ".profile"]
            .map { locations.home.appendingPathComponent($0) }
    }

    /// Lines in those files that quietly defeat the hook.
    ///
    /// Two kinds, with different consequences:
    ///
    /// - `export CLAUDE_CONFIG_DIR=…` — runs after the hook, so it overwrites what the
    ///   hook just set. You end up pinned to one profile no matter what the menu bar
    ///   says.
    /// - `alias claude-…=…` — an alias always beats a function in zsh. Old aliases from
    ///   a hand-rolled setup do not write the state file, so switching with one leaves
    ///   the menu bar showing something else entirely.
    ///
    /// The app reports these and never fixes them. It was given permission to manage
    /// one file; reaching into another because it happens to be convenient is how a
    /// utility loses the right to be trusted with the first one.
    public static func conflicts(in locations: Locations) -> [Conflict] {
        var found: [Conflict] = []

        for file in conflictSources(in: locations) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }

            for (index, raw) in text.components(separatedBy: "\n").enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("#") else { continue }        // comments don't count

                let setsVariable = line.contains(Branding.configDirVariable)
                    && (line.contains("=") || line.contains("unset"))
                let shadowsCommand = (line.hasPrefix("alias claude")
                                      || line.hasPrefix("alias \(Branding.command)"))
                    && line.contains("=")

                if setsVariable || shadowsCommand {
                    found.append(Conflict(file: file, line: index + 1, text: line))
                }
            }
        }
        return found
    }

    // MARK: - Converting an existing install

    /// Moves a real `~/.claude` to `~/.claude-<slug>` and puts a symlink back. This is
    /// the step that turns a normal install into a profile.
    ///
    /// The Keychain item does *not* come along, and cannot. A normal install files its
    /// tokens under the fixed name `Claude Code-credentials`; a profile looks under
    /// `Claude Code-credentials-<hash of path>`. So one fresh login is required. That
    /// is a deliberate consequence of a deliberate choice: this app never touches
    /// secrets, and the alternative — copying Keychain items around — is precisely the
    /// behaviour that makes the other tools in this space hard to trust.
    public static func migrateExistingInstall(toSlug slug: String,
                                              at locations: Locations) throws {
        let fm = FileManager.default
        let link = locations.claudeLink

        // Only proceed if it really is a plain folder. A symlink here would mean the
        // conversion already happened, and there would be nothing to move.
        var info = stat()
        guard lstat(link.path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw SetupError.claudeDirIsNotRealDirectory
        }

        let destination = locations.profileDirectory(for: slug)
        guard !fm.fileExists(atPath: destination.path) else {
            throw SetupError.destinationExists(destination.path)
        }

        // A rename within one volume is instant, even for a profile of several hundred
        // megabytes. No copy, no wait, and no half-moved state to recover from.
        try fm.moveItem(at: link, to: destination)

        // From here `~/.claude` briefly does not exist, which is exactly why the
        // symlink goes back immediately rather than at the end of the function.
        try Symlink.repoint(link, to: destination, home: locations.home)

        // The config for the no-profile case lives in `~/.claude.json`, beside the
        // folder we just moved rather than inside it. Copy rather than move, so
        // settings and MCP config come along while the original stays as the
        // documented fallback for a shell with no profile active.
        let profileConfig = destination.appendingPathComponent(".claude.json")
        if fm.fileExists(atPath: locations.looseClaudeConfig.path),
           !fm.fileExists(atPath: profileConfig.path) {
            try? fm.copyItem(at: locations.looseClaudeConfig, to: profileConfig)
        }

        try writeState(slug, at: locations)
    }

    /// Makes a profile active without there being a `Profile` value for it yet.
    ///
    /// The wizard needs this on a fresh Mac: the folder is created moments earlier, and
    /// the normal switch path wants a `Profile` that only exists after the next
    /// refresh. Without this step the wizard leaves a correct folder layout with
    /// nothing active, and the menu bar says "No profile active" after a run that
    /// reported success.
    ///
    /// Also the repair path when a symlink went missing or dangling.
    public static func activate(slug: String, at locations: Locations) throws {
        let directory = locations.profileDirectory(for: slug)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw SetupError.noProfileToActivate
        }

        try repointSafely(to: directory, at: locations)
        try writeState(slug, at: locations)
    }

    /// Creates an empty profile folder.
    ///
    /// `0700`: this will hold conversation history and project data.
    public static func createProfile(slug: String, at locations: Locations) throws -> URL {
        let directory = locations.profileDirectory(for: slug)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw SetupError.destinationExists(directory.path)
        }
        try AtomicFile.createDirectory(directory)
        return directory
    }

    // MARK: - Switching

    /// Points `~/.claude` at a directory, refusing if a real folder is in the way.
    ///
    /// The safety interlock is not theoretical: the machine this was written on once
    /// had eighty megabytes of real state at that path. If a real folder ever turns up
    /// there again, the app has to stop and say so rather than try something clever
    /// with someone's history.
    static func repointSafely(to directory: URL, at locations: Locations) throws {
        let link = locations.claudeLink

        var info = stat()
        if lstat(link.path, &info) == 0,
           (info.st_mode & mode_t(S_IFMT)) != mode_t(S_IFLNK) {
            throw SetupError.claudeDirIsRealDirectory(link.path)
        }

        try Symlink.repoint(link, to: directory, home: locations.home)
    }

    static func writeState(_ slug: String, at locations: Locations) throws {
        try AtomicFile.write(slug + "\n", to: locations.stateFile)
    }

    // MARK: - The shell hook

    /// Installs the hook for the user's login shell.
    public static func installHook(at locations: Locations) throws {
        guard let flavor = ShellFlavor.matching(loginShell: loginShell) else {
            throw SetupError.noSupportedShell(
                loginShell.isEmpty ? "unknown" : loginShell)
        }
        try ShellHook.install(flavor, at: locations)
    }

    // MARK: - Restoring a normal install

    /// Reverses the conversion: the chosen profile becomes a real `~/.claude` again,
    /// every hook is removed, the state file is deleted.
    ///
    /// Other profile folders are left completely alone. Nothing is lost here — this is
    /// reversible by running setup again, which is the point of having it be a separate
    /// action from cleaning up.
    ///
    /// One fresh login here too: the path changes back, so the hash changes, so the
    /// name Claude Code files its tokens under changes.
    public static func restoreToNormalInstall(profile: Profile,
                                              at locations: Locations) throws {
        let fm = FileManager.default
        let link = locations.claudeLink

        // The symlink has to go first. Otherwise moveItem follows it and moves the
        // profile *into* its own target directory rather than onto the path.
        var info = stat()
        if lstat(link.path, &info) == 0 {
            guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) else {
                throw SetupError.claudeDirIsRealDirectory(link.path)
            }
            guard Darwin.unlink(link.path) == 0 else {
                throw SetupError.posix("unlink()", errno)
            }
        }

        try fm.moveItem(at: profile.directory, to: link)

        for flavor in ShellFlavor.allCases {
            try? ShellHook.remove(flavor, at: locations)
        }

        // The state file has to go. While it exists, a hook that survives somewhere —
        // a copy in a dotfiles repo, a second machine syncing — would point
        // CLAUDE_CONFIG_DIR at a folder that is no longer there.
        try? fm.removeItem(at: locations.stateFile)
    }

    // MARK: - Cleaning everything up

    public struct RemovalPlan {
        public var profileDirs: [URL] = []
        public var claudeLink: URL?
        public var stateDir: URL?
        public var hookFlavors: [ShellFlavor] = []

        public var isEmpty: Bool {
            profileDirs.isEmpty && claudeLink == nil && stateDir == nil
                && hookFlavors.isEmpty
        }
    }

    /// What would "remove everything" touch? List first, then ask — a confirmation
    /// without a list is not a confirmation, it is a dare.
    public static func removalPlan(profiles: [Profile],
                                   at locations: Locations) -> RemovalPlan {
        let fm = FileManager.default
        var plan = RemovalPlan()

        plan.profileDirs = profiles.map(\.directory)
            .filter { fm.fileExists(atPath: $0.path) }

        var info = stat()
        if lstat(locations.claudeLink.path, &info) == 0 {
            plan.claudeLink = locations.claudeLink
        }

        if fm.fileExists(atPath: locations.stateDirectory.path) {
            plan.stateDir = locations.stateDirectory
        }

        plan.hookFlavors = ShellFlavor.allCases.filter {
            ShellHook.state(of: $0, at: locations).isInstalled
        }

        // Lock files are deliberately absent from this plan. They live in the user's
        // projects, quite possibly committed to a repository shared with other people,
        // and deleting files out of someone's git working tree is not this app's
        // business — least of all on the way out.

        return plan
    }

    /// Moves everything to the Trash and takes the hooks out.
    ///
    /// `trashItem` and not `removeItem`: this covers entire conversation histories and
    /// project data. Irreversible deletion does not belong behind a menu click, however
    /// many dialogs are in front of it. What stays behind: the app itself, the project
    /// lock files, and the Keychain items — which this app has never touched and will
    /// not start touching on the way out.
    public static func removeEverything(plan: RemovalPlan,
                                        at locations: Locations) throws {
        let fm = FileManager.default
        var failures: [String] = []

        for directory in plan.profileDirs {
            do { try fm.trashItem(at: directory, resultingItemURL: nil) }
            catch { failures.append(directory.lastPathComponent) }
        }

        // The symlink itself goes with unlink rather than to the Trash: a dangling
        // symlink sitting in your Trash has no recovery value whatsoever.
        if let link = plan.claudeLink {
            var info = stat()
            if lstat(link.path, &info) == 0,
               (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
                Darwin.unlink(link.path)
            } else {
                do { try fm.trashItem(at: link, resultingItemURL: nil) }
                catch { failures.append(link.lastPathComponent) }
            }
        }

        // Hooks before the state directory: removing a hook deletes a file inside that
        // directory, and doing it the other way round would recreate it.
        for flavor in plan.hookFlavors {
            try? ShellHook.remove(flavor, at: locations)
        }

        if let stateDir = plan.stateDir, fm.fileExists(atPath: stateDir.path) {
            do { try fm.trashItem(at: stateDir, resultingItemURL: nil) }
            catch { failures.append(stateDir.lastPathComponent) }
        }

        if !failures.isEmpty {
            throw SetupError.partialFailure(failures)
        }
    }
}

/// The atomic symlink swap, kept separate because several places need it and exactly
/// one implementation of it should exist.
public enum Symlink {

    /// Creates the new symlink under a temporary name and slides it into place with
    /// `rename()`.
    ///
    /// `rename()` is atomic: there is no instant at which the path does not exist. The
    /// obvious alternative — unlink then symlink — has a window in which `~/.claude` is
    /// simply absent, and anything starting inside that window sees nothing at all.
    public static func repoint(_ link: URL, to target: URL, home: URL) throws {
        let temporary = home.appendingPathComponent(
            ".claude.switching-\(UUID().uuidString)")

        guard Darwin.symlink(target.path, temporary.path) == 0 else {
            throw SetupError.posix("symlink()", errno)
        }
        guard Darwin.rename(temporary.path, link.path) == 0 else {
            let saved = errno
            Darwin.unlink(temporary.path)
            throw SetupError.posix("rename()", saved)
        }
    }
}
