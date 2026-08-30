# The Homebrew tap

`brew install rowansail/tap/lanes` resolves to a second repository —
`github.com/rowansail/homebrew-tap`, `Formula/lanes.rb`. Homebrew derives that
name itself: `rowansail/tap` means "the repo `homebrew-tap` under `rowansail`",
and `lanes` is the formula file inside it. There is no way to point that shorthand
at this repository, so the tap has to exist.

What lives here is the source of truth for that file, plus the script that turns
it into the published copy.

## Files

| | |
|---|---|
| `lanes.rb` | the formula, with a placeholder checksum |
| `release.sh` | fills in the version and checksum from a pushed tag, writes the tap copy |

The placeholder is not laziness. The checksum is of a tarball that contains
`lanes.rb`, so no value written here can ever be correct inside the tag it
describes. `release.sh` computes it after the fact, which is the same reason the
published formula lives in the tap rather than in this repository.

## Creating the tap, once

```bash
gh repo create rowansail/homebrew-tap --public \
  --description "Homebrew formulae for rowansail projects"
git clone https://github.com/rowansail/homebrew-tap ../homebrew-tap
```

The repository needs nothing else — no workflow, no configuration. Homebrew treats
any repository named `homebrew-*` with a `Formula/` directory as a tap.

## Cutting a release

From the root of this repository, with the tag already pushed:

```bash
packaging/homebrew/release.sh v1.1.0 ../homebrew-tap
cd ../homebrew-tap && git add Formula/lanes.rb && git commit -m "lanes 1.1.0" && git push
```

The second argument is a path to your tap checkout — relative to this repository's
root, so an absolute path is safer if the tap does not sit beside it.

Then check it end to end on a machine that has never seen it:

```bash
brew untap rowansail/tap 2>/dev/null
brew install rowansail/tap/lanes
brew test rowansail/tap/lanes
```

`brew test` builds the bundle and asserts three things that have all broken before
in this project: the executable is there, the Info.plist carries a bundle
identifier — `build.sh` parses that out of `Branding.swift` and would otherwise
write an empty string — and the ad-hoc signature verifies.

## Why a formula and not a cask

A cask installs a binary somebody else compiled and signed. The README's claim is
that the code you audited is the code you ran, and Lanes edits your shell config,
so that claim is worth keeping. A formula compiles from the tag on your machine
with the same `build.sh` a manual clone would run.

The cost is that formulae have no `app` stanza, so the bundle lands in the keg and
the caveats ask for one `ln -s` into `/Applications`. macOS only offers Launch at
Login to apps that live there.
