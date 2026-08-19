#!/usr/bin/env bash
#
# Builds Lanes.app and installs it into /Applications.
#
#   ./build.sh                build + install + launch
#   ./build.sh --no-install   build only, result in ./build/
#
# ---------------------------------------------------------------------------
# What a Mac app actually is
# ---------------------------------------------------------------------------
# Not a file, but a folder with a fixed structure. Finder pretends it is a single
# thing because the name ends in .app and there is an Info.plist inside:
#
#   Lanes.app/
#   └── Contents/
#       ├── Info.plist          metadata: bundle id, version, LSUIElement, ...
#       ├── MacOS/
#       │   └── Lanes           the executable binary
#       └── Resources/
#           └── AppIcon.icns    the icon, built from Resources/AppIcon.png
#
# SwiftPM compiles the binary; this script wraps it in that folder structure,
# because `swift build` produces a bare executable and macOS will not put a bare
# executable in the menu bar.
# ---------------------------------------------------------------------------

set -euo pipefail
cd "$(dirname "$0")"

# --- 0. identity ------------------------------------------------------------
# Every name comes out of Branding.swift. That file states the rule it exists to
# enforce: nothing outside it spells the product name in a string that ends up on
# disk. A hardcoded copy here is exactly the drift it was written to prevent —
# and it did drift once already, shipping a bundle id from the app's old name.
BRANDING="Sources/LanesKit/Core/Branding.swift"

if [[ ! -r "$BRANDING" ]]; then
  echo "Cannot read $BRANDING — run this from the repository root." >&2
  exit 1
fi

read_branding() {
  sed -n "s/.*static let $1 = \"\\(.*\\)\".*/\\1/p" "$BRANDING" | head -1
}

APP_NAME="$(read_branding name)"
BUNDLE_ID="$(read_branding bundleIdentifier)"
VERSION="$(read_branding version)"

# A silently empty value here would produce an app with no bundle id, which macOS
# accepts and then behaves strangely about — launch-at-login in particular. Fail
# loudly instead: if Branding.swift is reformatted, this is where you find out.
for var in APP_NAME BUNDLE_ID VERSION; do
  if [[ -z "${!var}" ]]; then
    echo "Could not parse $var from $BRANDING." >&2
    echo "Expected a line like:  public static let ... = \"...\"" >&2
    exit 1
  fi
done

# Must match the .executable(name:) product in Package.swift, and becomes
# CFBundleExecutable below.
BIN_NAME="Lanes"
MIN_MACOS="13.0"                   # MenuBarExtra exists from macOS 13 Ventura

# The 1024x1024 master the .icns is rendered from. Checked in as a PNG rather than
# as a finished .icns so that what the repository holds is the artwork, not a
# container format only Apple tooling can open.
ICON_SRC="Resources/AppIcon.png"
ICON_NAME="AppIcon"

APP="build/${APP_NAME}.app"

# Note: no `[[ ... ]] && INSTALL=false` here. With `set -e` the script would stop
# as soon as that test fails — the last exit code of a && list is then 1. Classic
# bash trap.
INSTALL=true
if [[ "${1:-}" == "--no-install" ]]; then
  INSTALL=false
fi

# --- 1. tooling -------------------------------------------------------------
# xcrun finds the right toolchain for the installed Xcode / Command Line Tools.
# Never hardcode those paths: they change with every Xcode version.
if ! xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
  echo "No macOS SDK found. Install Xcode, or run: xcode-select --install" >&2
  exit 1
fi
if ! command -v swift >/dev/null 2>&1; then
  echo "swift not found. Install Xcode or the Command Line Tools." >&2
  exit 1
fi

ARCH="$(uname -m)"                 # arm64 on Apple Silicon, x86_64 on Intel

# --- 2. compile -------------------------------------------------------------
# SwiftPM rather than a raw `swiftc Sources/*.swift` glob: the code is split into
# a LanesKit library and a one-line Lanes executable so that `swift test` can
# import it, and a flat glob cannot express that.
#
# Built for this machine only. That is the right trade for a build-from-source
# tool — every user compiles locally — and it avoids needing both SDKs for a
# universal binary. For a universal build: --arch arm64 --arch x86_64.
echo "==> compiling ($ARCH, macOS $MIN_MACOS minimum)"
swift build -c release --product "$BIN_NAME"

BUILT_BIN="$(swift build -c release --product "$BIN_NAME" --show-bin-path)/$BIN_NAME"
if [[ ! -x "$BUILT_BIN" ]]; then
  echo "Expected a binary at $BUILT_BIN but found none." >&2
  exit 1
fi

# --- 3. the bundle structure ------------------------------------------------
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILT_BIN" "$APP/Contents/MacOS/$BIN_NAME"

# --- 3a. the icon -----------------------------------------------------------
# macOS will not scale one big PNG for you: an .icns is a container holding the
# artwork pre-rendered at every size the system asks for, from 16pt in a Finder
# list to 512pt@2x in Quick Look. `iconutil` builds one from a folder of PNGs
# with names it recognises — the @2x files are the Retina variants, so
# icon_32x32@2x.png is 64 pixels of artwork shown at 32 points.
#
# Rendered here rather than checked in because a generated binary in the
# repository is a copy that can silently fall out of step with the PNG beside it.
# Both tools ship with the Command Line Tools, already required above.
echo "==> rendering icon"
if [[ ! -r "$ICON_SRC" ]]; then
  echo "Cannot read $ICON_SRC — the app will get the generic icon." >&2
else
  ICONSET="build/${ICON_NAME}.iconset"
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"

  # size:filename. Sizes repeat on purpose: 32 is both 32x32 and 16x16@2x, and
  # macOS looks them up by name, so both files have to exist.
  for entry in \
    16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x \
    128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 512:icon_256x256@2x \
    512:icon_512x512 1024:icon_512x512@2x
  do
    size="${entry%%:*}"
    name="${entry##*:}"
    sips -z "$size" "$size" "$ICON_SRC" --out "$ICONSET/${name}.png" >/dev/null
  done

  iconutil --convert icns "$ICONSET" --output "$APP/Contents/Resources/${ICON_NAME}.icns"
  rm -rf "$ICONSET"
fi

# Info.plist is generated, not checked in, for the same reason the names above are
# read from Branding.swift: a second copy of the version number is a second thing
# to forget on release day.
#
# The shell hook used to be copied in here as a Resources file. It now lives in
# ShellHookScripts.swift and is written out by the app itself, so there is nothing
# to copy — one fewer thing that can go missing from a bundle.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>

    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>

    <!-- Must be exactly the name of the binary in Contents/MacOS. -->
    <key>CFBundleExecutable</key>
    <string>${BIN_NAME}</string>

    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>

    <!--
      Names Resources/AppIcon.icns, extension optional. Not CFBundleIconName:
      that one resolves through a compiled asset catalog, which a bundle
      assembled by hand does not have.

      An agent app has no Dock icon, but the icon is not decoration — it is what
      Lanes looks like in Finder, in Login Items, and in the "Lanes would like
      to..." permission prompts, where a generic placeholder for an app that
      edits your shell config is exactly the wrong impression.
    -->
    <key>CFBundleIconFile</key>
    <string>${ICON_NAME}</string>

    <key>CFBundlePackageType</key>
    <string>APPL</string>

    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>

    <key>CFBundleVersion</key>
    <string>${VERSION}</string>

    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>

    <!--
      This is the whole trick to getting a menu bar app: no dock icon, no menu
      bar at the top, no app switcher (Cmd+Tab). Apple calls this an "agent"
      app. One plist key, no code.
    -->
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

# --- 4. sign ----------------------------------------------------------------
# "--sign -" is an ad-hoc signature: valid enough for macOS to trust the app
# locally, but not tied to a Developer ID. That is deliberate — Lanes is
# distributed as source, so every user signs their own build on their own machine
# and Gatekeeper is satisfied without anyone paying for a Developer ID.
#
# Without this step every rebuild triggers permission prompts again, because macOS
# then sees the app as a brand-new unknown one.
echo "==> signing (ad-hoc)"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

if ! $INSTALL; then
  echo "==> done: $APP"
  exit 0
fi

# --- 5. install -------------------------------------------------------------
# An old version has to go first: you cannot overwrite a running app, and
# "Launch at Login" only works reliably from /Applications.
echo "==> installing into /Applications"
pkill -x "$BIN_NAME" 2>/dev/null || true
sleep 0.5
rm -rf "/Applications/${APP_NAME}.app"
cp -R "$APP" "/Applications/${APP_NAME}.app"

open "/Applications/${APP_NAME}.app"
echo
echo "Done. Look at the top right of your menu bar."
echo "Not set up yet? The app checks on launch and opens the setup wizard."
