# Contributing

## Getting set up

```bash
git clone https://github.com/rowansail/lanes
cd lanes
swift test          # fast, no side effects
./build.sh          # build, install into /Applications, launch
./build.sh --no-install   # build only, result in ./build/
```

You need Xcode or the Command Line Tools (`xcode-select --install`) and macOS 13
or newer.

`./doctor.sh` prints the full state of your setup and changes nothing. Run it
first when something looks wrong — unlike the app, it runs in *your* shell, so it
sees your real `CLAUDE_CONFIG_DIR`.

## Three rules that are not negotiable

**1. Never read a credential.** The app's entire security argument is that
switching accounts is a path change, so tokens never need to be touched. The one
Keychain call deliberately omits `-w` so that no secret is ever requested. See
[SECURITY.md](SECURITY.md). A patch that reads a token will not be merged.

**2. No dependencies.** Foundation, AppKit, SwiftUI and IOKit only — all ship with
macOS. A tool that edits your shell config should be auditable in an afternoon,
and every dependency is one more thing a reviewer has to take on trust.

**3. No product name in a path.** `Branding.swift` holds every name that ends up
on disk. Prose in the UI may say "Lanes"; a path, marker, bundle id or directory
name must come from `Branding`. This is partly hygiene and partly trademark care —
and it is enforced by having been broken once already, which shipped an app whose
bundle id still carried the pre-rename name.

## Code style

The house style is heavy on explanatory comments, and deliberately so. Comments
explain *why*, especially where the code looks odd:

```swift
// lstat and not stat: stat follows the symlink and reports on the target, which
// tells you nothing about the link itself.
```

That is the standard to match. A comment restating what the line already says is
worse than none; a comment explaining why the obvious approach is wrong is the
point. If you removed a subtlety from a code review, write it down.

Otherwise: standard Swift conventions, `let` by default, `private` where it fits,
and match the surrounding file.

## Tests

```bash
swift test
```

Almost everything lives in the `LanesKit` library rather than the `Lanes`
executable specifically so tests can import it. An executable target cannot be
imported by a test target — if you add something worth testing, it goes in the
library.

Worth testing: pure logic (path hashing, managed-block parsing, slug handling)
and anything that touches the user's files. `TestSupport` gives you a temporary
`HOME` so tests never touch your real one — use it, and never write a test that
touches `~` directly.

Not worth testing: SwiftUI view bodies.

**If you touch a shell hook**, two things. Bump `ShellHook.revision` — that number
is written into the script and parsed back out, and it is the only way an existing
install is told it is out of date. And run `swift test`: `ShellHookScriptTests`
parses each script with its own shell and then actually *runs* all three
hooks against a temporary home directory, switching profiles and honouring a pin
with a fake `claude` on `PATH`. A shell that is not installed skips rather than
fails, so `brew install fish` if you do not have it — otherwise a third of that
coverage silently does not run.

## Pull requests

- One change per PR.
- Say what breaks if the change is wrong. For anything touching shell config or
  the switch itself, that sentence matters more than the diff.
- `swift test` must pass and `./build.sh --no-install` must succeed.
- New user-visible strings go in the same voice as the existing ones: plain,
  specific, no exclamation marks.

Bug reports are more useful with `./doctor.sh` output attached, and most useful of
all when they include the Claude Code version — the behaviour this app relies on
is undocumented and can change between releases.

## Licence

Contributions are made under the GPL-3.0-or-later, the same licence as the
project. New files need the standard three-line SPDX header:

```swift
// Lanes — account lanes for Claude Code
// Copyright (C) 2026 rowansail
// SPDX-License-Identifier: GPL-3.0-or-later
```
