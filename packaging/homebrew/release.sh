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
# Not `mktemp -t lanes-release`: BSD mktemp treats that as a prefix and appends
# randomness, GNU mktemp demands the XXXXXX itself and fails outright. Spelling the
# template in full works on both, which matters for anyone auditing this on Linux.
TARBALL="$(mktemp "${TMPDIR:-/tmp}/lanes-release.XXXXXX")"
trap 'rm -f "$TARBALL"' EXIT
curl -fsSL "$URL" -o "$TARBALL"
# The trap is widened below, once there is a second thing to clean up.

SHA="$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
echo "==> sha256 $SHA" >&2

# Does the tag actually contain the version it claims?
#
# This exists because it has already gone wrong twice: a tag pushed from a stale
# checkout points at a commit from before the release, and every downstream symptom
# then looks like the bug you thought you had just fixed — the formula is generated
# from the wrong source, the tarball builds the wrong code, and nothing says so.
# Branding.version is the one place a release is numbered, so comparing it against
# the tag name catches the whole class in one line.
WORK="$(mktemp -d)"
trap 'rm -f "$TARBALL"; rm -rf "$WORK"' EXIT
tar xzf "$TARBALL" -C "$WORK"

BRANDING="$(find "$WORK" -name Branding.swift -type f | head -1)"
if [[ -z "$BRANDING" ]]; then
  echo "No Branding.swift in the $TAG tarball. Is that tag really this project?" >&2
  exit 1
fi

TAGGED_VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' "$BRANDING" | head -1)"
if [[ "$TAGGED_VERSION" != "$VERSION" ]]; then
  echo >&2
  echo "Tag $TAG contains version $TAGGED_VERSION, not $VERSION." >&2
  echo >&2
  echo "The tag points at a commit from before the version bump — almost always a" >&2
  echo "tag pushed from a checkout that had not been updated. Fix the tag rather" >&2
  echo "than the formula:" >&2
  echo >&2
  echo "  git checkout main && git pull" >&2
  echo "  git log --oneline -1          # is the release commit actually here?" >&2
  echo "  git push origin --delete $TAG && git tag -d $TAG" >&2
  echo "  git tag -a $TAG -m 'Lanes $VERSION' && git push origin $TAG" >&2
  exit 1
fi
echo "==> tag contains version $TAGGED_VERSION" >&2

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
