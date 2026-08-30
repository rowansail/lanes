# Lanes — Homebrew formula.
#
# This file is the source of truth. The copy Homebrew actually reads lives in the
# tap repository (rowansail/homebrew-tap, Formula/lanes.rb); `release.sh` beside
# this file fills in the version and checksum from a pushed tag and copies it
# there. Editing the tap copy by hand is how the two drift apart.
#
# A formula rather than a cask, deliberately. A cask installs a binary somebody
# else compiled and signed; this compiles on your machine from the tag you can
# read, which is the same claim the README makes about `./build.sh`. `brew`
# replaces the four commands, not the trust model.
class Lanes < Formula
  desc "Account lanes for Claude Code, in the macOS menu bar"
  homepage "https://github.com/rowansail/lanes"
  url "https://github.com/rowansail/lanes/archive/refs/tags/v1.1.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "GPL-3.0-or-later"
  head "https://github.com/rowansail/lanes.git", branch: "main"

  # MenuBarExtra, SMAppService and .foregroundStyle all arrive in macOS 13, which
  # is also the LSMinimumSystemVersion build.sh writes into the Info.plist.
  depends_on macos: :ventura

  # No `depends_on xcode: :build`. That would demand a full Xcode.app; the Swift
  # toolchain, sips and iconutil all ship with the Command Line Tools, which
  # Homebrew already requires on macOS. Package.swift has no dependencies, so the
  # build needs no network either.

  def install
    # --no-install stops build.sh after compiling and signing. Everything past
    # that point copies into /Applications and launches the app, which is not a
    # package manager's business and is blocked by the build sandbox anyway.
    #
    # --disable-swiftpm-sandbox: SwiftPM sandboxes the evaluation of Package.swift
    # with sandbox-exec, and macOS refuses to nest that inside the sandbox Homebrew
    # has already put this build in — "sandbox_apply: Operation not permitted",
    # reported as an invalid manifest. Homebrew's sandbox is the outer one and
    # stays; this drops the redundant inner one. Nothing is loosened: the package
    # has no dependencies and no plugins, so the only manifest being evaluated is
    # the one inside the tarball whose checksum is pinned above.
    system "./build.sh", "--no-install", "--disable-swiftpm-sandbox"

    # Homebrew formulae have no `app` stanza — that belongs to casks — so the
    # bundle goes in the keg, and `lanes` below is what links it into
    # /Applications. It cannot be done here: Homebrew sandboxes both install and
    # post_install, so a formula cannot write outside its own prefix. That is the
    # sandbox working, not an obstacle — a package manager writing into
    # /Applications behind your back is the thing it is there to prevent.
    prefix.install "build/Lanes.app"

    # One word instead of an ln -sfn line to paste. The script is checked into the
    # repository rather than written inline here, so it can be read before it is
    # run — the same reason this is a formula and not a cask.
    bin.install "packaging/homebrew/lanes-launcher.sh" => "lanes"
    inreplace bin/"lanes", "@APP_BUNDLE@", "#{opt_prefix}/Lanes.app"
  end

  def caveats
    <<~EOS
      Nothing is running yet, and Lanes is not in /Applications. One more command:

        lanes

      It links the app into /Applications — where macOS wants it, because Launch
      at Login is only offered to apps that live there — and opens it. Run it
      again any time to bring the menu back up.

      The app then checks your setup and opens a wizard if anything needs doing.
      It can turn the Claude Code install you already have into your first
      profile, and it installs the shell hook that defines `lane`.

      Then, once per profile:

        exec zsh                # activate the hook in this terminal
        claude auth login

      Two commands, easily confused: `lanes` is this launcher and exists only for
      Homebrew installs. `lane` is the shell function that switches accounts, and
      comes from the hook.

      Quit Lanes from its menu before `brew upgrade` — a running app cannot be
      overwritten. `brew uninstall` leaves the /Applications symlink behind;
      remove it with `rm /Applications/Lanes.app`.
    EOS
  end

  test do
    app = prefix/"Lanes.app"
    assert_predicate app/"Contents/MacOS/Lanes", :executable?

    # Every name in the bundle is read out of Branding.swift by build.sh. If that
    # parsing ever breaks it produces a plist with empty strings rather than
    # failing, and an app with no bundle identifier misbehaves in ways that are
    # hard to trace back here — so assert the identifier actually arrived.
    plist = app/"Contents/Info.plist"
    assert_equal "nl.rowansail.lanes",
                 shell_output("/usr/bin/plutil -extract CFBundleIdentifier raw -o - #{plist}").strip

    # Ad-hoc signature. Without it macOS treats each rebuild as a new unknown app
    # and re-asks for every permission.
    system "/usr/bin/codesign", "--verify", "--deep", app

    # The launcher is useless if the substitution did not happen, and it fails in
    # a way that looks like a broken install rather than a broken formula.
    refute_match "@APP_BUNDLE@", (bin/"lanes").read
    assert_match "#{opt_prefix}/Lanes.app", (bin/"lanes").read
  end
end
