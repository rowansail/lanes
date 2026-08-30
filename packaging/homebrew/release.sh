#!/usr/bin/env bash
#
# Cuts a Homebrew release for a tag that already exists on GitHub.
#
#   packaging/homebrew/release.sh v1.0.0            print the finished formula
#   packaging/homebrew/release.sh v1.0.0 ../homebrew-tap
#                                                   write it into a tap checkout
#
# What it does: downloads the tag's source tarball from GitHub, checksums it, and
# substitutes the version and that checksum into lanes.rb.
#
# Why the checksum cannot live in the repository: it is the hash of a tarball that
# contains lanes.rb, so a correct value inside the tagged tree is arithmetically
# impossible. The committed formula therefore carries a placeholder and the real
# one is only ever produced here — which is also why the formula Homebrew reads
# lives in the tap and not in this repository.

set -euo pipefail
cd "$(dirname "$0")"

TAG="${1:-}"
TAP="${2:-}"

if [[ -z "$TAG" ]]; then
  echo "usage: $(basename "$0") <tag> [path-to-homebrew-tap-checkout]" >&2
  echo "example: $(basename "$0") v1.0.0 ../homebrew-tap" >&2
  exit 1
fi

# The tag has to exist before this is worth running: Homebrew pins a checksum, and
# a checksum of a tarball that GitHub has not generated yet is a guess.
if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "No local tag $TAG. Create and push it first:" >&2
  echo "  git tag -a $TAG -m '...' && git push origin $TAG" >&2
  exit 1
fi

VERSION="${TAG#v}"
URL="https://github.com/rowansail/lanes/archive/refs/tags/${TAG}.tar.gz"

# GitHub generates these tarballs on demand and they are byte-stable for a given
# tag — but only as long as the tag does not move. Moving a released tag changes
# the checksum under everyone who already installed; don't.
echo "==> fetching $URL" >&2
TARBALL="$(mktemp -t lanes-release)"
trap 'rm -f "$TARBALL"' EXIT
curl -fsSL "$URL" -o "$TARBALL"

SHA="$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
echo "==> sha256 $SHA" >&2

FORMULA="$(
  sed \
    -e "s|^  url \".*\"$|  url \"${URL}\"|" \
    -e "s|^  sha256 \".*\"$|  sha256 \"${SHA}\"|" \
    lanes.rb
)"

# Fail loudly rather than shipping a formula still carrying the placeholder — a
# checksum mismatch is a confusing error to receive as a user.
if [[ "$FORMULA" == *"0000000000000000000000000000000000000000000000000000000000000000"* ]]; then
  echo "Substitution did not take. Has the url/sha256 formatting in lanes.rb changed?" >&2
  exit 1
fi

if [[ -z "$TAP" ]]; then
  printf '%s\n' "$FORMULA"
  echo >&2
  echo "Nothing written. Pass a tap checkout as the second argument to install it:" >&2
  echo "  $(basename "$0") $TAG ../homebrew-tap" >&2
  exit 0
fi

if [[ ! -d "$TAP/.git" ]]; then
  echo "$TAP is not a git checkout. Clone the tap first:" >&2
  echo "  git clone https://github.com/rowansail/homebrew-tap $TAP" >&2
  exit 1
fi

mkdir -p "$TAP/Formula"
printf '%s\n' "$FORMULA" > "$TAP/Formula/lanes.rb"
echo "==> wrote $TAP/Formula/lanes.rb (version $VERSION)"
echo
echo "Next:"
echo "  cd $TAP && git add Formula/lanes.rb && git commit -m 'lanes $VERSION' && git push"
echo "  brew install --build-from-source rowansail/tap/lanes"
