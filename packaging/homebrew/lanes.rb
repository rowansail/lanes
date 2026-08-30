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
  url "https://github.com/rowansail/lanes/archive/refs/tags/v1.0.0.tar.gz"
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
    system "./build.sh", "--no-install"

    # Homebrew formulae have no `app` stanza — that belongs to casks — so the
    # bundle goes in the keg and the caveats hand over one line to symlink it.
    prefix.install "build/Lanes.app"
  end

  def caveats
    <<~EOS
      Lanes is a menu bar app, and macOS only offers Launch at Login to apps in
      /Applications. Link it there and start it:

        ln -sfn #{opt_prefix}/Lanes.app /Applications/Lanes.app
        open /Applications/Lanes.app

      The app checks your setup shortly after launching and opens a wizard if
      anything needs doing — it can turn the Claude Code install you already have
      into your first profile, and it installs the shell hook that defines `lane`.

      Then, once per profile:

        exec zsh                # activate the hook in this terminal
        claude auth login

      Upgrades replace the bundle in place, so the symlink keeps working. Quit
      Lanes from its menu before `brew upgrade` — a running app cannot be
      overwritten.
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
  end
end
