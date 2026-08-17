# Lanes

![The Lanes menu bar item, reading "Work" with a keep-awake timer](docs/img/menubar-gh.png)

Account lanes for Claude Code. Switch accounts from the macOS menu bar, and see at
a glance which one you are in.

*Not affiliated with, endorsed by, or sponsored by Anthropic. Claude is a trademark
of Anthropic, PBC.*

You have several Claude accounts on this Mac — work, personal, a client's. Claude
Code can only be logged into one at a time. This is a small menu bar app that
switches between them and keeps the active name permanently visible, because
running the wrong account against a client's codebase is a bad afternoon.

It covers all three places you actually use Claude: **Claude Code in a terminal**,
**Claude Code in Visual Studio Code** (and Cursor, VSCodium, Windsurf), and **the Claude desktop
app**.

```
                    ┌──────────────────────────────┐
  menu bar  ───────▶│ 💼 Work                      │
                    └──────────────────────────────┘
```

## How it works, in three lines

1. An account **is** a folder path: Claude looks for its credentials in the
   Keychain under a name derived from a hash of that path.
2. Which folder Claude uses is decided by one environment variable:
   `CLAUDE_CONFIG_DIR`.
3. A process receives its environment when it starts, and it cannot be changed from
   outside afterwards. So the app writes the active profile to a small file, and a
   hook in your shell's startup file — `~/.zshenv`, `~/.bash_profile` or
   `config.fish` — reads that file in every new shell.

The consequence that surprises everyone once: **an already-running Claude session
or terminal does not follow along.** Switching applies to what you start next.

## The three places you run Claude

You probably use more than one of these, and they do not all work the same way.
Lanes covers all three, with one honest caveat each.

| | How the account is decided | What Lanes does | What to know |
|---|---|---|---|
| **Claude Code in a terminal** | `CLAUDE_CONFIG_DIR` | Sets it in every new shell, and honours a `.lanes` project pin | Open a new shell after switching |
| **Claude Code in Visual Studio Code** (and the forks) | the same variable | The extension inherits it from the shell hook when the editor launches | The editor keeps that account until you quit it completely — reloading the window is not enough — and project pins do not apply; see below |
| **The Claude desktop app** | Electron session cookies | Gives each profile its own data directory | You have to open it **from the Lanes menu**; the Dock icon opens your original account |

## Requirements

- macOS 13 Ventura or newer — `MenuBarExtra` does not exist before that
- Xcode Command Line Tools: `xcode-select --install`
- zsh, bash or fish. Each gets its own hook and they install independently, because
  a login shell and the shell you actually type in are often not the same one. One
  caveat: only the zsh hook reaches non-interactive shells, so `claude` from a
  script picks up the active profile there and nowhere else.

## Installing

Lanes is distributed as source. There are no binary releases.

```bash
git clone https://github.com/rowansail/lanes
cd lanes
./build.sh
```

Compiles, signs ad-hoc, installs into `/Applications` and launches it. After that
it sits at the top right of your menu bar.

```bash
./build.sh --no-install     # build only, into ./build/
```

**Why source only.** The signature is ad-hoc — good enough for macOS to trust an
app you built yourself, not good enough to hand someone a `.app`. Shipping
binaries would mean notarisation and a paid Apple Developer account. Building
locally sidesteps that entirely: you sign your own copy, Gatekeeper is satisfied,
and nobody sees an "unidentified developer" warning.

It also suits the project. This is a tool that edits your shell config and reads
your home directory; compiling it yourself means the code you audited is the code
you ran.

## Setup happens by itself

The app checks the setup shortly after launch and opens the wizard when something is
off. Two situations, worded differently because they are different:

**Never set up here.** Either a fresh Mac, or one where you have used Claude Code
but never this app. The wizard offers to convert your existing install into your
first profile.

**Set up before, but something changed.** You renamed a profile folder, deleted one,
or `~/.claude` became a real folder again. The wizard lists exactly what is off and
offers to repair it.

You can always open it yourself from the menu, and switch the automatic check off
under `Check Setup Automatically` if you would rather be left alone.

### What the wizard does

```
Findings  ›  Choices  ›  Plan  ›  Apply  ›  Done
```

1. **Findings** — what is on this Mac, per item, with a checkmark or a warning.
2. **Choices** — a name for your profile, optionally a second one, and whether to
   install the hook. Steps with nothing to ask are skipped.
3. **Plan** — numbered, what is going to happen, before anything happens.
4. **Apply** — a checkmark or the error per action. On failure it stops there,
   because later steps depend on earlier ones.
5. **Done** — the two commands you still have to run, with a copy button.

Converting an existing install does this:

- `~/.claude` moves to `~/.claude-original`
- a symlink goes back at the old path
- `~/.claude.json` is **copied** into the profile, so settings and MCP config come
  along; the original stays put
- the hook goes into `~/.zshenv`, with a backup at
  `~/.zshenv.lanes-backup`

### Your existing install is called `original`

The wizard suggests `original` for the profile it converts, and that name is worth
keeping. Six months from now you will be looking at `~/.claude-work`,
`~/.claude-acme` and one more, and the only question that matters about the third
one is *"is that the account I had before I installed this?"* — `original` answers
it, `main` or `default` does not.

So: **`original` is your old install, moved and renamed, with everything in it.**
Same history, same projects, same MCP servers. Nothing was copied away from you and
nothing was deleted; `~/.claude` is now a symlink pointing at it.

The desktop app has an "original" in the same sense, and it is a different thing —
see [The desktop app](#the-desktop-app) below.

After that: **log in once.** The folder moves, so the path changes, so the hash
changes, so Claude looks for its tokens under a different name. The app deliberately
never touches secrets.

```bash
exec zsh                # activate the hook in this terminal
claude auth login       # once per profile
```

Adding another profile: `New Profile…` in the menu, which asks what to call it —
lowercase letters, digits and hyphens. Name it after the account, not the category:
`acme` is the folder you will still recognise in a year, `client` is not. Or by hand:

```bash
mkdir ~/.claude-acme
CLAUDE_CONFIG_DIR=~/.claude-acme claude auth login
```

Every folder named `~/.claude-*` is a profile. There is no registry and no config
file — a new folder shows up in the menu within five seconds.

## The menu

```
💼 Work                                   ← the menu bar itself
├─ Active: Work  —  you@work.example
├─ Applies to terminals and apps you open next
├─ History, memory, settings and MCP servers are per profile
├─ Switch to
│  ├─ ✓ Work  —  you@work.example         ← checking one switches
│  └─   Personal  —  you@personal.example
├─ New Profile…
├─ Open Claude App (Work)
├─ Only open from here — the Dock icon opens your original account
├─ Keep Awake                             ← stop the Mac from sleeping
├─ Setup Assistant…                       ← the install wizard
├─ Check Setup…                           ← full report in a window
├─ Uninstall Lanes…                       ← the uninstall wizard
├─ ☐ Launch at Login
├─ ☑ Check Setup Automatically
├─ Lanes 1.0.0
└─ Quit
```

The grey lines are labels, not buttons. Extra ones appear when something is wrong:
a missing hook, a login shell with no hook, or a broken setup.

Two doors and no third. Everything that used to sit under a `Maintenance` submenu —
reinstalling the hook, hooking a second shell, restoring a normal install, moving
everything to the Trash — is now a step inside one of the two wizards, where it can
be explained and reviewed before it happens instead of being a verb on a menu row.
`Setup Assistant…` becomes `Set Up Lanes…` on a fresh Mac and `Repair Setup…` when
something is off, including when it finds an install left by the app's previous name.

## Keep Awake

Start a long Claude Code run and walk away, and your Mac goes to sleep and the run
stops halfway. Menu → `Keep Awake`:

| Duration | |
|---|---|
| Until I turn it off | stays on until you turn it off |
| 15 min / 30 min / 1, 2, 4, 8 hours | countdown, visible in the menu bar |
| **While Claude Code is running** | follows the `claude` process |

That last one is why this lives here rather than in Amphetamine: it checks whether a
process named `claude` is running and lets go when it disappears. With a 90-second
grace period, so the assertion does not flap between two commands.

Separately switchable: **Keep Display On Too**. By default only the system stays
awake and your screen may turn off — usually what you want during a long task.

Active? Then there is a ☕ in the menu bar, with the remaining time on a timer:

```
💼 Work · ☕ 1:42
```

Underneath this is an IOKit power assertion, the same thing `caffeinate` uses. You
can see it:

```bash
pmset -g assertions | grep "Lanes"
```

**It does not survive a restart, and that is deliberate.** An assertion is bound to
the process: if the app is not running, your Mac simply sleeps. "Remembering" one
across a restart would be a lie — and a forgotten indefinite assertion that returns
after every reboot is exactly how you drain your battery without knowing why.

## From the terminal

**There is nothing to install.** `lane` is not a separate binary and not something
to `brew install` — it is a shell function, defined by the same hook the setup wizard
already put in your shell config. Build the app, finish the wizard, open a new
terminal, and the command is there. If it is not, the hook is not installed; the app
says so in the menu and offers to fix it.

That also explains two things about it. It is **not on `$PATH`**, so `which lane`
finds nothing and `sudo lane` or a `#!/bin/sh` script cannot call it. And it is
defined **only in interactive shells** — a script gets `CLAUDE_CONFIG_DIR` from the
hook, which is the part that actually switches anything, but not the command.

It writes the same small file the app writes, and the app watches that file, so the
menu bar follows immediately — it works both ways.

```bash
lane                        # show the active profile, the pin, and all profiles
lane work                   # switch to work
lane app                    # desktop app in the active profile
lane app personal           # desktop app in a specific profile
lane lock acme              # pin this directory to a profile
lane unlock                 # remove the pin
lane help                   # the same list, from the shell
```

```console
$ lane work
now: work  ->  ~/.claude-work
$ lane
config dir : ~/.claude-work
active     : work
profiles   :
    acme
    personal
  * work
```

Paths are printed abbreviated, the same way the app writes them, so what you see in
a terminal and what the report shows describe a folder identically.

## Claude Code in Visual Studio Code

The extension runs the same CLI, so `CLAUDE_CONFIG_DIR` decides its account exactly
as it does in a terminal, and the same Keychain isolation applies. It works, and
there is nothing to configure. Two things behave differently enough to be worth
knowing, both of which follow from *how* the extension starts the CLI — directly,
with no shell in between.

**The account is fixed when the editor launches** — not when the window opens, and
this is the one people lose an afternoon to. The extension host is a child of VS
Code's *main* process and inherits its environment, and that environment was resolved
once, when the main process started. Switch lanes afterwards and that editor does not
follow, exactly as an open terminal does not.

**`Developer: Reload Window` does not fix it.** Reloading spawns a fresh extension
host — the pid really does change — but a fresh child of an unchanged parent inherits
the unchanged environment. Nothing short of the main process exiting will do it, so
the fix is to quit the editor entirely (⌘Q, every window) and open it again.
`Check Setup…` lists every open editor with the account it is actually on, so you can
see when one has drifted.

**Project pins do not apply in the extension's panel.** The `.lanes` file is read by
the shell function, and no shell runs. So a pinned repo opened in the side panel uses
whatever lane the window is on. If you rely on pins, turn on:

```json
"claudeCode.useTerminal": true
```

That launches Claude in VS Code's integrated terminal instead of the native panel.
The integrated terminal is a real shell, so the hook and the pin both apply, and each
new terminal picks up the current lane — no reload, and no relaunch either. If you
switch lanes often, this one setting is the answer to both problems above.

One thing to remove rather than add: if `terminal.integrated.env.osx` in your VS Code
settings sets `CLAUDE_CONFIG_DIR`, delete it. It runs after the hook and overrides it,
which pins every integrated terminal to one account for good. `./doctor.sh` points at
the file.

## The desktop app

Claude Desktop is a separate story: it is Electron and logs in the way a browser
does, with session cookies. **`CLAUDE_CONFIG_DIR` does nothing there.**

The app gives each profile its own Electron data directory:

```
~/.claude-work/desktop/         work's cookies, session and MCP config
~/.claude-personal/desktop/     the same for personal
```

Claude.app has no single-instance lock, so both accounts can be open side by side in
separate windows. Each profile does need its own one-time login — cookies cannot be
shared between data directories.

### You have to open it from the menu

This is the one thing to remember about the desktop app, so it gets its own heading:

> **The Dock icon opens your original Claude app — the account you had before Lanes —
> not a profile.** To get a profile you open it from the Lanes menu, with
> `Open Claude App (Work)`, or from a terminal with `lane app`.

There is no way around this and it is not a missing feature. A profile is passed as a
launch argument (`--user-data-dir`), and a Dock icon has no launch arguments; macOS
starts the app with its defaults. Lanes could only change that by modifying Claude.app
itself, which it will not do.

So the original stays exactly as it was, in
`~/Library/Application Support/Claude`, still logged in, still one click away in the
Dock. It is simply not one of your lanes. If you find yourself in an account you did
not expect in the desktop app, this is almost always why — check the menu bar app
instead, and open it from there.

A practical habit: drag the Lanes menu item into your routine and leave the Dock icon
alone, or remove Claude from the Dock entirely once you have profiles set up.

### Logging in a second account

Log in to one account at a time, with the other instances closed.

The login flow hands off to your browser and comes back through a `claude://`
deep link, and macOS delivers that to whichever instance is frontmost — not
necessarily the one that asked. With two instances open you can complete a login
and find the session landed in the wrong lane. Closing the others removes the
ambiguity. This is a property of how macOS routes URL schemes, not something
Lanes can intercept.

## When something is wrong

```bash
./doctor.sh
```

A read-only report that changes nothing. It runs in *your* shell and therefore sees
your real `CLAUDE_CONFIG_DIR` — which the app cannot, because it was launched by
macOS and never saw your shell environment. `Check Setup…` in the menu runs the same
checks from inside the app.

The five you actually run into:

**Nothing changes after switching.** Your existing terminal keeps the old value
until you close it. `exec zsh`, or a new tab.

**VS Code is on the wrong account.** Same cause, one level up: the extension host
inherits from the editor's main process, whose environment was fixed when you launched
it. Quit the editor completely and reopen — `Developer: Reload Window` restarts the
extension host but not its parent, so it comes back on the same account.
`Check Setup…` names every editor that has drifted.

**`echo $CLAUDE_CONFIG_DIR` is empty.** The hook is not in `~/.zshenv`. The app
notices this by itself and offers to fix it.

**`lane` does something unexpected, or is not found.** Is there still an
`alias claude-…=...` or an old switcher block in your `.zshrc`? An alias always beats
a function in zsh, and the old aliases do not write the state file — so the menu bar
falls behind. Remove those lines. The app reports this but does not edit `.zshrc`
itself.

**You keep ending up in the same profile.** Something sets `CLAUDE_CONFIG_DIR`
*after* the hook: an `export` in `.zshrc`, or `terminal.integrated.env.osx` in VS
Code. `./doctor.sh` points at where.

## Uninstalling

`Uninstall Lanes…` in the menu. It runs the same five steps as setup — Findings,
Choices, Plan, Apply, Done — and asks one question, which has two genuinely different
answers:

**Keep my Claude Code, remove Lanes** — the profile you pick moves back to `~/.claude`
as an ordinary folder, with its history and settings intact. Every hook comes out of
your shell config and the state file is deleted. Other profile folders are left
completely alone; they are just folders, and nothing needs Lanes to read them. Nothing
is lost, you can set up again afterwards, and you log in once because the path changed
back.

**Remove everything** — all profile folders, the symlink, the state directory and the
hook blocks go. To the **Trash**, not deleted: your entire Claude history, every
session transcript, the memory files, your settings and your MCP servers are in there.
The plan page lists every folder by name, and there is one final confirmation after it.
What stays: the app itself, your project pins, and your Keychain items.

Project pins are never touched. A `.lanes` file lives in your repository, quite
possibly committed and shared with other people, so deleting one is yours to do —
and without Lanes installed it is an inert text file that nothing reads.

Only the hook block between these markers is taken out of `~/.zshenv`; the rest of
your file is left exactly as it was.

```
# >>> lanes >>>
# <<< lanes <<<
```

## What is in the repo

```
Sources/LanesKit/
  App/
    LanesApp.swift           the app's entry point
    MenuView.swift           the menu
    SetupWizard.swift        the five-step setup wizard
    ReportWindow.swift       displays the report text
  Core/
    ProfileStore.swift       reads and writes all state
    Profile.swift            one account: path, email, Keychain name
    Locations.swift          every path the app touches, from one home directory
    Branding.swift           every name the app writes
    AtomicFile.swift         writes that cannot be seen half-finished
    FileWatcher.swift        notices a new ~/.claude-* folder
    Shell.swift              runs a command-line tool
  Features/
    ClaudeCodeInstall.swift  what Claude Code looks like on this machine
    EditorEnvironment.swift  which lane each open editor window is on
    KeepAwake.swift          keeping the Mac awake (IOKit power assertion)
    ProjectLock.swift        .lanes project pins
    RemainingTime.swift      countdown as text
  Setup/
    Setup.swift              setting up, repairing, restoring, cleaning up
    ShellHook.swift          installing and removing the hook
    ShellHookScripts.swift   the zsh, bash and fish hooks themselves
    ManagedBlock.swift       the marked block in a shell config file
    LegacyInstall.swift      traces of the previous name
  Report/
    Diagnostics.swift        builds the report text
build.sh                     compile, sign, install
doctor.sh                    read-only diagnosis from your shell
docs/                        the landing page, as a static site
```

## Where things live on disk

```
~/.claude-<name>/            a profile: config, history, project data
~/.claude-<name>/desktop/    the desktop app's Electron session
~/.claude                    symlink to the active profile
~/.config/lanes/active       the active profile, one word
~/.config/lanes/hook.zsh     the hook itself (also hook.bash, hook.fish)
~/.zshenv                    four lines that source it, between markers
~/.zshenv.lanes-backup       backup from before the first change
<project>/.lanes             a project pin
```

The hook is two files on purpose: your startup file gets four lines that never
change again, and upgrades rewrite only the file in `~/.config/lanes/`. Editing
someone's shell config is the riskiest thing this app does, so it does it once.

Keychain: `Claude Code-credentials-<hash>` per profile, and
`Claude Code-credentials` without a hash for a normal install. The app never writes
or removes anything here.

## Further reading

[SECURITY.md](SECURITY.md) covers the security model — chiefly why the app never
reads a credential. [CONTRIBUTING.md](CONTRIBUTING.md) covers building, testing and
the three rules that are not negotiable.

## A standing caveat

`CLAUDE_CONFIG_DIR` and the Keychain naming scheme it implies are **undocumented**.
They were determined by observing how Claude Code behaves, not from a specification,
and Anthropic can change them in any release.

If profile isolation stops working after a Claude Code update, that is the first
thing to suspect. `Check Setup…` reports the detected Claude Code version for
exactly this reason, and a bug report with that version attached is the most useful
thing you can send.

## Licence

[GPL-3.0-or-later](LICENSE). If you distribute a modified version, it has to stay
open under the same licence.

## Trademark

Lanes is not affiliated with, endorsed by, or sponsored by Anthropic. Claude is a
trademark of Anthropic, PBC.

The name is deliberate: "Claude" appears only as a descriptor of what the tool works
with, never as the product name, and none of Anthropic's logos or brand styling are
used anywhere.
