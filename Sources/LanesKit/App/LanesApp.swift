// Lanes — account lanes for Claude Code
// Copyright (C) 2026 rowansail
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit

/// The entry point of the app.
///
/// This is the whole app shell: no AppDelegate, no storyboard, no window.
/// `MenuBarExtra` is a Scene just as `WindowGroup` is — except it lives at the top right
/// of the menu bar. Under the hood SwiftUI asks the system for an `NSStatusItem`, the
/// same thing every other menu bar app uses whatever language it is written in.
///
/// It is fair to ask why this is not plain AppKit with an `NSStatusItem` managed by
/// hand, which is the usual advice when you want full control over the button. The
/// answer is that the one thing this app needs from the button — variable-width text
/// that changes — is what a `MenuBarExtra` label gives for free, and the menu itself is a
/// list of checkmarks that `NSMenu` renders better than any custom view would. The moment this needs a coloured badge or a custom row, that trade
/// reverses.
public struct LanesApp: App {

    // @StateObject and not @State: the object has to be created exactly once and stay
    // alive for the whole run. Its @Published properties then drive redraws of both the
    // menu and the label in the bar.
    @StateObject private var store = ProfileStore()

    // Its own object rather than folded into ProfileStore: keeping the Mac awake has
    // nothing to do with profiles and has its own lifecycle.
    @StateObject private var keepAwake = KeepAwake()

    public init() {}

    public var body: some Scene {
        // The name as text, not just an icon: the entire point of this app is that you
        // can see which account you are in at a glance, without clicking anything.
        //
        // Hence the label closure rather than `MenuBarExtra(title:systemImage:)`. That
        // initializer treats the title as the accessibility label and renders the symbol
        // alone, so the profile name — and the keep-awake badge folded into it — never
        // reached the bar at all. `.titleAndIcon` is what actually puts text there;
        // `Label`'s default style in a status item is icon-only.
        MenuBarExtra {
            MenuView(store: store, keepAwake: keepAwake)
                .onAppear(perform: connectWizard)
        } label: {
            Label(title,
                  systemImage: store.activeProfile?.symbolName ?? "questionmark.circle")
                .labelStyle(.titleAndIcon)
        }
        // .menu = a classic dropdown, rendered by AppKit as a real NSMenu.
        // .window would give a floating SwiftUI panel, which you need as soon as you
        // want custom layout, colours or images. For a list of checkmarks .menu is
        // better: faster, and it behaves like every other menu on the Mac.
        .menuBarExtraStyle(.menu)
    }

    private var title: String {
        // "No profile" and not "No lane": the menu, the report, the wizard and the
        // `lane` command all call the thing a profile, and the one place the user
        // looks at all day should not be the one place using a different word.
        let name = store.activeProfile?.displayName ?? "No profile"

        // Only add the badge when there is something to report. Every character here
        // takes space in somebody's menu bar, and the profile name is the point.
        guard let badge = keepAwake.badge else { return name }
        return "\(name) · \(badge)"
    }

    /// Wires the store's "something needs attention" callback to the wizard window.
    ///
    /// Done here rather than inside the store so that all the logic worth testing lives
    /// in a file that does not import SwiftUI. `onAppear` on the menu content is a
    /// reliable "the app has finished launching" signal, and setting the closure twice
    /// is harmless.
    private func connectWizard() {
        store.isAttentionUIVisible = { SetupWizardWindow.shared.isVisible }
        store.onSetupNeedsAttention = { [store] in
            SetupWizardWindow.shared.show(store: store)
        }
    }
}
