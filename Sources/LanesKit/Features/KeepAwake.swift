// Lanes — account lanes for Claude Code
// Copyright (C) 2026 rowansail
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Combine
import IOKit.pwr_mgt

/// Keeps the Mac awake, the way Amphetamine does.
///
/// Why this lives in an account switcher: you start a long Claude Code run and walk
/// away. If the Mac then goes to sleep, the run stops halfway. Hence also the end
/// condition "while Claude Code is running" — that is the case you actually want
/// this for, and nothing else keeps the Mac awake then because nobody is at the
/// keyboard.
///
/// The mechanism is an IOKit power assertion: the same thing `caffeinate` uses. No
/// subprocess, no kext, nothing to clean up — the assertion is bound to this process
/// and disappears automatically when the app quits.
///
/// That last point is also why nothing is written to disk. An assertion you
/// "remembered" across a restart would be a lie: if the app is not running, your Mac
/// simply sleeps. And a forgotten indefinite assertion that returns after every
/// reboot is exactly how you drain your battery without knowing why.
public final class KeepAwake: ObservableObject {

    public enum Mode: Equatable {
        case off
        case indefinite
        case until(Date)
        case whileClaudeRunning

        public var isOn: Bool { self != .off }
    }

    @Published public private(set) var mode: Mode = .off

    /// Does the display stay on too? Two different assertions, so this cannot just
    /// be a flag — changing it means retaking the assertion.
    @Published public private(set) var keepDisplayOn = false

    /// The text that goes after the profile name in the menu bar, or nil.
    @Published public private(set) var badge: String?

    /// Why the assertion is currently active, in plain words, for the menu.
    @Published public private(set) var statusLine: String?

    private var assertionID: IOPMAssertionID?
    private var timer: Timer?

    /// When we last saw Claude Code running.
    private var lastSeenClaude: Date?

    /// How long we stay awake after Claude Code disappears.
    ///
    /// Without this grace period the assertion flaps between two `claude`
    /// invocations: one command has finished, the next has not started, and that is
    /// exactly when your Mac is allowed to sleep. Releasing slightly late is clearly
    /// better here than releasing too early.
    private let claudeGrace: TimeInterval = 90

    public init() {
        // Five seconds. The countdown is displayed in minutes, so nobody can see a
        // five-second lag, and the grace period in whileClaudeRunning mode is ninety
        // seconds — far longer than this interval needs to resolve. The previous value
        // was two seconds, which woke the CPU thirty times a minute to format a string
        // that changes once a minute.
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    deinit {
        releaseAssertion()
        timer?.invalidate()
    }

    // MARK: - On and off

    public func start(_ mode: Mode) {
        guard mode != .off else { stop(); return }

        self.mode = mode
        if mode == .whileClaudeRunning {
            // Check once immediately, so the menu does not lie for two seconds.
            lastSeenClaude = Self.isClaudeCodeRunning() ? Date() : nil
        }

        applyAssertion(shouldBeOn: true)
        tick()
    }

    public func stop() {
        mode = .off
        lastSeenClaude = nil
        releaseAssertion()
        updateLabels()
    }

    /// Switches between "display may sleep" and "display stays on".
    ///
    /// These are two different assertion types, so a running assertion is released
    /// and retaken. There is a microsecond gap in between; for sleep behaviour that
    /// is completely irrelevant.
    public func setKeepDisplayOn(_ on: Bool) {
        guard on != keepDisplayOn else { return }
        keepDisplayOn = on

        if assertionID != nil {
            releaseAssertion()
            applyAssertion(shouldBeOn: true)
        }
        updateLabels()
    }

    // MARK: - The clock

    private func tick() {
        switch mode {
        case .off:
            break

        case .indefinite:
            break

        case .until(let deadline):
            if Date() >= deadline {
                stop()
                return
            }

        case .whileClaudeRunning:
            if Self.isClaudeCodeRunning() {
                lastSeenClaude = Date()
            } else if let last = lastSeenClaude,
                      Date().timeIntervalSince(last) > claudeGrace {
                stop()
                return
            } else if lastSeenClaude == nil {
                // Never seen since we started: stop after the grace period too, so
                // this does not hang around forever if you switch it on while
                // nothing is running.
                lastSeenClaude = Date()
            }
        }

        // The assertion may have been dropped in the meantime (for instance because
        // the system revoked it). Retake it if it is gone but should be on.
        if mode.isOn && assertionID == nil {
            applyAssertion(shouldBeOn: true)
        }

        updateLabels()
    }

    // MARK: - The assertion itself

    private func applyAssertion(shouldBeOn: Bool) {
        guard shouldBeOn, assertionID == nil else { return }

        // PreventUserIdleDisplaySleep keeps the system awake *too*; it is the
        // stricter of the two. PreventUserIdleSystemSleep does let the display turn
        // off, which is usually what you want during a long task.
        let type = keepDisplayOn
            ? kIOPMAssertionTypePreventUserIdleDisplaySleep
            : kIOPMAssertionTypePreventUserIdleSystemSleep

        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Branding.name as CFString,
            &id)

        if result == kIOReturnSuccess {
            assertionID = id
        } else {
            // Nothing the app can do about this; the menu then shows it as off,
            // which is the truth.
            mode = .off
            assertionID = nil
        }
    }

    private func releaseAssertion() {
        if let id = assertionID {
            IOPMAssertionRelease(id)
            assertionID = nil
        }
    }

    // MARK: - Is Claude Code running?

    /// Checks whether a `claude` process is running.
    ///
    /// Claude Code is a native binary literally named `claude`, so the basename of
    /// the command is enough. Note the case: the desktop app is called `Claude` and
    /// the menu bar app `Lanes`, so a lowercase comparison excludes both
    /// precisely. That is intended — if you are typing in the desktop app, your own
    /// activity already keeps the Mac awake.
    ///
    /// `ps` blocks until it finishes, but that is milliseconds. Only called in the
    /// whileClaudeRunning mode, so it costs nothing otherwise.
    public static func isClaudeCodeRunning() -> Bool {
        let output = Shell.run("/bin/ps", ["-axo", "comm="]).stdout

        return output.split(separator: "\n").contains { line in
            let path = line.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { return false }
            return (path as NSString).lastPathComponent == "claude"
        }
    }

    // MARK: - Labels

    private func updateLabels() {
        let newBadge: String?
        let newStatus: String?

        switch mode {
        case .off:
            newBadge = nil
            newStatus = nil

        case .indefinite:
            newBadge = "☕"
            newStatus = "Awake until you turn it off"

        case .until(let deadline):
            let remaining = max(0, deadline.timeIntervalSinceNow)
            newBadge = "☕ " + RemainingTime.short(remaining)
            newStatus = "Awake, " + RemainingTime.long(remaining)

        case .whileClaudeRunning:
            let running = lastSeenClaude.map {
                Date().timeIntervalSince($0) < 5
            } ?? false
            newBadge = "☕"
            newStatus = running
                ? "Awake while Claude Code runs"
                : "Awake — Claude Code is not running, stopping soon"
        }

        // Same discipline as in ProfileStore: only assign when the *displayed* text
        // really changes, or SwiftUI redraws every two seconds for nothing.
        if newBadge != badge { badge = newBadge }
        if newStatus != statusLine { statusLine = newStatus }
    }
}

/// The duration options in the menu.
public enum KeepAwakeDuration: Int, CaseIterable, Identifiable {
    case indefinite
    case minutes15
    case minutes30
    case hour1
    case hours2
    case hours4
    case hours8
    case whileClaude

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .indefinite:  return "Until I turn it off"
        case .minutes15:   return "15 minutes"
        case .minutes30:   return "30 minutes"
        case .hour1:       return "1 hour"
        case .hours2:      return "2 hours"
        case .hours4:      return "4 hours"
        case .hours8:      return "8 hours"
        case .whileClaude: return "While Claude Code is running"
        }
    }

    public var mode: KeepAwake.Mode {
        switch self {
        case .indefinite:  return .indefinite
        case .minutes15:   return .until(Date().addingTimeInterval(15 * 60))
        case .minutes30:   return .until(Date().addingTimeInterval(30 * 60))
        case .hour1:       return .until(Date().addingTimeInterval(3600))
        case .hours2:      return .until(Date().addingTimeInterval(2 * 3600))
        case .hours4:      return .until(Date().addingTimeInterval(4 * 3600))
        case .hours8:      return .until(Date().addingTimeInterval(8 * 3600))
        case .whileClaude: return .whileClaudeRunning
        }
    }
}
