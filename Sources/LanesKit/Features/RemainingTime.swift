// Lanes — account lanes for Claude Code
// Copyright (C) 2026 rowansail
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Remaining time as text, in two lengths.
///
/// Separate from KeepAwake because it is pure string formatting: no state, no IOKit,
/// and therefore the only part of the keep-awake feature that can be tested
/// headlessly.
public enum RemainingTime {

    /// For the menu bar, where every pixel belongs to someone else: "1:23", "23m".
    public static func short(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        if total < 60 { return "<1m" }

        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m" }

        return "\(minutes / 60):" + String(format: "%02d", minutes % 60)
    }

    /// For inside the menu, where there is room: "1 hr 30 min left".
    public static func long(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        if total < 60 { return "less than a minute left" }

        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min left" }

        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) hr left" : "\(hours) hr \(rest) min left"
    }
}
