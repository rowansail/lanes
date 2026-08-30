#!/bin/bash
#
# Installed by the Homebrew formula as `lanes`. Links the app into /Applications
# and opens it.
#
# This exists because of a hard limit rather than a preference: Homebrew sandboxes
# a formula's install *and* its post_install, so neither can write to
# /Applications. A cask could — casks have an `app` stanza that symlinks for you —
# but a cask installs a binary somebody else compiled, and this project ships
# source so that the code you audited is the code you ran. The sandbox is therefore
# not an obstacle to route around; it is the same boundary, doing its job.
#
# So the link has to be made by something the user runs. This is that something,
# reduced to one word. @APP_BUNDLE@ is replaced with the real path at install time.

set -euo pipefail

APP="@APP_BUNDLE@"
LINK="/Applications/Lanes.app"

# Spelled in two halves on purpose. The formula substitutes every occurrence of
# the token, so a guard containing it literally would be rewritten too, always
# compare equal, and refuse to run every time — with a message telling you to
# reinstall, which would not help. Split, it survives the substitution.
UNSUBSTITUTED="@APP_""BUNDLE@"
if [[ "$APP" == "$UNSUBSTITUTED" ]]; then
  echo "lanes: this script was installed without its path substituted." >&2
  echo "lanes: reinstall with 'brew reinstall rowansail/tap/lanes'." >&2
  exit 1
fi

if [[ ! -d "$APP" ]]; then
  echo "lanes: no app bundle at $APP" >&2
  echo "lanes: reinstall with 'brew reinstall rowansail/tap/lanes'." >&2
  exit 1
fi

# Why /Applications at all, when the app runs perfectly well from the keg: macOS
# only offers Launch at Login to apps that live there. SMAppService registers the
# bundle it is asked about, and from anywhere else the toggle is either refused or
# silently forgotten on the next restart.
if [[ ! -e "$LINK" ]]; then
  if ! ln -sfn "$APP" "$LINK" 2>/dev/null; then
    echo "lanes: could not write to /Applications." >&2
    echo "lanes: link it yourself, then run this again:" >&2
    echo "  sudo ln -sfn \"$APP\" \"$LINK\"" >&2
    exit 1
  fi
  echo "Linked /Applications/Lanes.app -> $APP"

elif [[ -L "$LINK" && "$(readlink "$LINK")" == "$APP" ]]; then
  : # already ours, and pointing at the right keg

elif [[ -L "$LINK" ]]; then
  # An old link, from a keg that brew has since removed. Ours to repoint.
  ln -sfn "$APP" "$LINK"
  echo "Repointed /Applications/Lanes.app -> $APP"

else
  # A real bundle, not a link — almost certainly one ./build.sh installed. Not
  # ours to delete: it may be a newer build, and replacing an app someone
  # compiled themselves with one a package manager compiled is exactly the kind
  # of silent substitution this project exists to avoid. Say so and open theirs.
  echo "/Applications/Lanes.app is a real app bundle, not a link — leaving it alone."
  echo "It was probably installed by ./build.sh. To use the Homebrew build instead:"
  echo "  rm -rf \"$LINK\" && lanes"
fi

open "$LINK"
