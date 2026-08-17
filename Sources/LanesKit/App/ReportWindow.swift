// Lanes — account lanes for Claude Code
// Copyright (C) 2026 rowansail
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit

/// A separate window for the setup report.
///
/// Why AppKit and not a SwiftUI `Window` scene? Because a Window scene opens
/// immediately at launch on macOS 13. For an app that should only live in the menu
/// bar you do not want that — you want a window that does not exist until the user
/// asks for it. Managing one NSWindow yourself is simpler than fighting the scene
/// lifecycle.
///
/// This is also a useful pattern to know: SwiftUI and AppKit are not separate worlds.
/// `NSHostingView` puts a SwiftUI view inside an AppKit window, and
/// `NSViewRepresentable` does the reverse.
final class ReportWindow {

    static let shared = ReportWindow()
    private var window: NSWindow?

    /// Which request the visible window belongs to.
    ///
    /// Click `Check Setup…` twice quickly and two probes are in flight. Without this the
    /// slower one lands last and overwrites the newer report with older facts — rare,
    /// silent, and exactly the kind of thing this report exists to disprove. Each request
    /// takes a number and only the current one is allowed to draw.
    private var generation = 0

    private init() {}

    /// Opens the window at once, then fills it in.
    ///
    /// The order here is the whole point. Building the report runs `claude --version`,
    /// `security` once per profile and `ps` once per editor helper — comfortably over a
    /// second on a cold Mac. Doing that before opening the window meant the menu closed
    /// and nothing happened, for long enough that the honest reading was "the click did
    /// not register".
    ///
    /// `profiles` and `locations` are read here, on the main thread, and handed to the
    /// background queue as values. The store itself never leaves main — see the note at
    /// the top of ``ProfileStore``.
    func showReport(store: ProfileStore, title: String) {
        let profiles = store.profiles
        let locations = store.locations

        generation += 1
        let mine = generation

        present(title: title, view: AnyView(ReportLoadingView()))

        DispatchQueue.global(qos: .userInitiated).async {
            let probe = Diagnostics.Probe.run(profiles: profiles, locations: locations)

            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == mine else { return }

                // Back on main, so reading the store here is fine — and everything that
                // was going to be slow has already happened.
                let text = Diagnostics.report(store: store, probe: probe)
                self.present(title: title, view: AnyView(ReportView(text: text)))
            }
        }
    }

    private func present(title: String, view: AnyView) {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false)

            // Without this the app crashes as soon as you close the window and open
            // it again later: AppKit releases a closed window by default.
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }

        window?.title = title
        window?.contentView = NSHostingView(rootView: view)

        // The app has LSUIElement = true and is therefore never "active". Without
        // this activate the window appears behind your current app.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// What the window shows while the report is being gathered.
///
/// It names the three things being done rather than saying "Loading…". They are the
/// slow parts precisely because each one asks something outside this app — and if the
/// wait ever gets long enough to read, the reason is on screen. A spinner alone would
/// leave somebody wondering whether a menu bar utility had any business taking a second.
private struct ReportLoadingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)

            Text("Checking this Mac…")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("• Reading your shell config and the state file")
                Text("• Asking Claude Code for its version")
                Text("• Looking at the Keychain layout — never at a token")
                Text("• Checking which account each open editor is on")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct ReportView: View {

    let text: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }

            Divider()

            HStack {
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                }
                .disabled(copied)
            }
            .padding(12)
        }
    }
}
