# Changelog

Notable changes, newest first. Versions follow [semantic versioning](https://semver.org),
and the version itself is defined once, in `Branding.version` — `build.sh` reads that
line into the Info.plist, so there is no second copy to forget on release day.

## 1.0.1 — 2026-08-30

Same-day fix. 1.0.0 could not be installed through Homebrew at all.

- `./build.sh` now takes `--disable-swiftpm-sandbox`, and the formula passes it.
  SwiftPM evaluates `Package.swift` inside its own `sandbox-exec`, macOS refuses to
  nest that inside Homebrew's, and the build died with `sandbox_apply: Operation not
  permitted` — reported as an invalid manifest, which is what made it expensive to
  read. A plain `./build.sh` keeps the sandbox it always had; only a caller that has
  already sandboxed the script asks for it to be dropped.

  A flag rather than an environment variable on purpose. A build system that scrubs
  the environment is exactly the kind that sandboxes you, and a dropped variable
  fails identically to not having fixed anything.

- `build.sh` now parses all its arguments instead of looking only at `$1`, and
  rejects unknown ones rather than ignoring them.

- Releasing now checks that a tag contains the version it claims, in both
  `packaging/homebrew/release.sh` and the release workflow. A tag pushed from a
  stale checkout points at a commit from before the release, and every symptom
  downstream then looks like the bug you thought you had just fixed. `Branding`
  numbers a release exactly once, so comparing it against the tag name catches the
  whole class.

- No change to the app. A `1.0.0` build and a `1.0.1` build are the same program
  with a different version string.

## 1.0.0 — 2026-08-30

First tagged release. The app has been usable for a while; this is the point at which
it is worth telling people about, and the point from which upgrades have a number.

### Switching

- Menu bar app showing the active profile by name, permanently, because the whole
  failure mode this exists to prevent is not knowing which account you are in.
- Every folder named `~/.claude-*` is a profile. No registry and no config file of
  its own: a new folder appears in the menu within five seconds.
- Switching points `CLAUDE_CONFIG_DIR` at a different folder. Claude Code derives its
  Keychain service name from a hash of that path, so it looks up a different item on
  its own — **no credential is ever read, copied or written**. See `SECURITY.md`.
- A shell hook for zsh, bash and fish applies the active profile to every new shell.
  In zsh it is installed in `~/.zshenv`, so `claude -p …` from a script, a git hook or
  a launchd job gets it too, not only interactive shells.
- `lane` shell function: show, switch, `lane app`, `lane lock`, `lane unlock`.

### Project pins

- A `.lanes` file naming a profile pins that directory and everything under it. It
  outranks whatever is globally active, because an explicit per-project statement
  should beat a menu click from last Tuesday.
- It is a file in the repository, so committing it puts everyone who clones on the
  right account on their first run. `LANES_NO_LOCK=1` bypasses it.

### Beyond the terminal

- Per-profile Electron data directories for the Claude desktop app, opened from the
  menu or with `lane app`. The Dock icon is not a lane and cannot be made into one —
  a profile is a launch argument, and a Dock icon has none.
- VS Code, Cursor, VSCodium and Windsurf inherit the lane the editor was launched
  with. `"claudeCode.useTerminal": true` makes pins apply there as well.

### Keeping the Mac awake

- `Keep Awake` for a fixed duration, until switched off, or while Claude Code is
  running — that last one follows the `claude` process and lets go when it exits.
  An IOKit power assertion, the same mechanism as `caffeinate`, and deliberately not
  persistent across a restart.

### Setup and repair

- A wizard that turns the Claude Code install you already have into your first
  profile, and installs the shell hook.
- `Check Setup…` in the menu, and `./doctor.sh` for the same checks from your own
  shell — which is the only place the real `CLAUDE_CONFIG_DIR` is visible, the app
  having been launched by macOS.
- `Skip Bypass Permissions Warning` writes one key into every lane's `settings.json`,
  leaves the rest of the file alone, and refuses to rewrite a file that is not plain
  JSON rather than reformatting it.
- Uninstall with two genuinely different answers: remove Lanes and keep your Claude
  Code, or remove everything, with profile folders listed by name and sent to the
  Trash. Project pins are never touched.
- Detects an install left by the app's former name and says so, rather than letting
  two hooks fight over `CLAUDE_CONFIG_DIR`.

### Installing

- `brew install rowansail/tap/lanes`. A formula, not a cask: it compiles from this
  tag on your machine with the same `build.sh` a manual clone runs. There are still
  no binary releases, and the source tarball attached to this tag is GitHub's, not
  a build artefact.

### Known limits

- macOS only, and macOS 13 or newer.
- An already-running terminal or Claude session does not follow a switch. Nothing can
  change a running process's environment from outside; switching applies to what you
  start next.
- `CLAUDE_CONFIG_DIR` and the Keychain naming it implies are undocumented, observed
  rather than specified, and Anthropic can change them in any release. If isolation
  stops working after an update, suspect that first.
- In bash, non-interactive shells read neither `.bash_profile` nor `.bashrc`, so
  `claude` from a script does not pick up the active profile. zsh does not have this
  gap.
