#!/usr/bin/env bash
#
# Shows the full state of your Claude profile setup. Changes nothing.
# Run this first, before building the app:  ./doctor.sh
#
# The same checks live in the app under "Check Setup…", but this script has one
# advantage: it runs in YOUR shell, so it sees your real CLAUDE_CONFIG_DIR. The app
# cannot — it was launched by launchd and never saw your shell environment.

set -uo pipefail

# The app owns ~/.config/lanes. It used to be called something else, and the app
# migrates the old directory on launch — but this script must not assume that has
# happened yet, so it reports on whichever one is actually there.
SLUG="lanes"
LEGACY_SLUG="claude-switcher"

STATE="$HOME/.config/$SLUG/active"
LEGACY_STATE="$HOME/.config/$LEGACY_SLUG/active"

USING_LEGACY=0
if [[ ! -r "$STATE" && -r "$LEGACY_STATE" ]]; then
  STATE="$LEGACY_STATE"
  USING_LEGACY=1
fi

LINK="$HOME/.claude"

hr() { printf '\n%s\n%s\n' "$1" "$(printf '%*s' "${#1}" '' | tr ' ' '-')"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }

# ──────────────────────────────────────────────────────────── active profile ───
hr "Active profile"

if [[ -r "$STATE" ]]; then
  ok "state file: $(tr -d '\n' < "$STATE")"
  info "$STATE"
  if (( USING_LEGACY )); then
    warn "this is the pre-rename location"
    info "the app moves it to ~/.config/$SLUG/active the next time it starts"
  fi
else
  warn "state file does not exist ($STATE)"
  info "normal: the app, or 'lane <name>' in a terminal, creates it on the"
  info "first switch"
fi

if [[ -L "$LINK" ]]; then
  target="$(readlink "$LINK")"
  ok "~/.claude -> $target"
  [[ -d "$target" ]] || bad "that target does NOT exist — broken symlink"
elif [[ -d "$LINK" ]]; then
  bad "~/.claude is a REAL FOLDER ($(du -sh "$LINK" 2>/dev/null | cut -f1))"
  info "this is a normal Claude install. The app's setup wizard converts it"
  info "into a profile for you — open the menu and pick 'Set Up Lanes…',"
  info "or do it by hand:"
  info "  mv ~/.claude ~/.claude-original"
  info "  ln -s ~/.claude-original ~/.claude"
elif [[ -e "$LINK" ]]; then
  bad "~/.claude exists but is neither a folder nor a symlink"
else
  warn "~/.claude does not exist"
fi

printf '\n'
if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
  ok "CLAUDE_CONFIG_DIR in this shell: $CLAUDE_CONFIG_DIR"
else
  warn "CLAUDE_CONFIG_DIR is not set in this shell"
  info "Claude then falls back to ~/.claude/ + ~/.claude.json + the default"
  info "Keychain item — i.e. nobody's account in particular. Install the"
  info "shell hook (see below)."
fi

# ───────────────────────────────────────────────────────────────── profiles ────
hr "Profiles"

shopt -s nullglob 2>/dev/null || true
found=0
for dir in "$HOME"/.claude-*/; do
  dir="${dir%/}"
  [[ -d "$dir" ]] || continue
  found=1
  slug="${dir##*/.claude-}"

  marker=" "
  [[ -r "$STATE" && "$(tr -d '\n' < "$STATE")" == "$slug" ]] && marker="●"
  printf '\n %s %s\n' "$marker" "$slug"
  info "folder   $dir  ($(du -sh "$dir" 2>/dev/null | cut -f1))"

  # account from .claude.json
  cfg="$dir/.claude.json"
  if [[ -r "$cfg" ]]; then
    email="$(python3 -c "
import json,sys
try:
    a = json.load(open(sys.argv[1])).get('oauthAccount') or {}
    print(a.get('emailAddress') or a.get('email') or a.get('accountUuid','')[:8] or '?')
except Exception as e:
    print('unreadable: %s' % e)
" "$cfg" 2>/dev/null)"
    info "account  ${email:-?}"
  else
    info "account  — no .claude.json (never logged in with this config dir)"
  fi

  # Keychain. Tokens do not live in the folder but in the login Keychain, under a
  # name derived from the path: sha256(path)[0:8].
  hash8="$(printf '%s' "$dir" | shasum -a 256 | cut -c1-8)"
  service="Claude Code-credentials-$hash8"
  if security find-generic-password -s "$service" >/dev/null 2>&1; then
    info "keychain present ($service)"
  else
    info "keychain MISSING ($service)"
    info "         -> CLAUDE_CONFIG_DIR=$dir claude auth login"
  fi
done
[[ $found -eq 1 ]] || bad "no ~/.claude-* folders found"

# A loose ~/.claude.json in your home is a leftover from before
# CLAUDE_CONFIG_DIR. Claude only uses it when the variable is NOT set.
if [[ -f "$HOME/.claude.json" ]]; then
  printf '\n'
  warn "~/.claude.json still exists (config for the 'no profile' situation)"
  info "not a problem as long as CLAUDE_CONFIG_DIR is always set, but it is"
  info "the explanation if you ever see an unexpected third account"
fi

# ──────────────────────────────────────────────────────────────── shell hook ───
hr "Shell hooks"

# One hook per shell, installed independently — a login shell and the shell you
# actually type in are often not the same one. Each is a marker block in that
# shell's startup file that sources a file the app owns, so either the current or
# the pre-rename marker counts as installed.
#
# Your login shell comes from the passwd database rather than $SHELL: $SHELL says
# which shell started this script, which is not the same question.
LOGIN_SHELL="$(dscl . -read "/Users/$USER" UserShell 2>/dev/null | awk '{print $2}')"
[[ -n "$LOGIN_SHELL" ]] || LOGIN_SHELL="${SHELL:-}"
LOGIN_SHELL_NAME="${LOGIN_SHELL##*/}"

info "login shell: ${LOGIN_SHELL:-unknown}"
printf '\n'

hook_installed=0
for pair in "zsh:.zshenv" "bash:.bash_profile" "fish:.config/fish/config.fish"; do
  flavor="${pair%%:*}"
  config="$HOME/${pair#*:}"
  hookfile="$HOME/.config/$SLUG/hook.$flavor"

  label="$flavor"
  [[ "$flavor" == "$LOGIN_SHELL_NAME" ]] && label="$flavor (yours)"

  if [[ -r "$config" ]] && grep -qE ">>> ($SLUG|$LEGACY_SLUG) >>>" "$config"; then
    hook_installed=1

    # A pre-rename block is self-contained — that version wrote its functions
    # straight into the startup file instead of sourcing a managed hook. So it
    # works, and looking for a hook file beside it would report a working
    # install as broken.
    if ! grep -q ">>> $SLUG >>>" "$config" && grep -q ">>> $LEGACY_SLUG >>>" "$config"; then
      warn "$label: installed under the previous name (~/${pair#*:})"
      info "it still switches, but it is the old block. Open the app and use"
      info "'Repair Setup…' — two blocks both exporting CLAUDE_CONFIG_DIR"
      info "from one file is exactly the bug this app exists to remove."
    else
      revision="$(sed -n "s/^# [a-z-]*-hook-revision: *//p" "$hookfile" 2>/dev/null | head -1)"

      if [[ ! -r "$hookfile" ]]; then
        bad "$label: block in ~/${pair#*:}, but $hookfile is missing"
        info "the block is guarded, so your shell is fine — but nothing is"
        info "switching. Reinstall from the app: menu > 'Repair Setup…'."
      else
        ok "$label: installed (~/${pair#*:}, hook revision ${revision:-unknown})"
      fi

      if grep -q ">>> $LEGACY_SLUG >>>" "$config"; then
        warn "$label: a block with the old marker name is still there too"
        info "two blocks, and the later one wins. Use 'Repair Setup…'."
      fi
    fi
  elif [[ "$flavor" == "$LOGIN_SHELL_NAME" ]]; then
    bad "$label: no hook in ~/${pair#*:}"
    info "this is the shell you log in with, so nothing switches. Install it"
    info "from the app: menu > 'Set Up Lanes…'. The app writes the hook"
    info "itself; there is no snippet file to copy."
  else
    info "$label: not installed (~/${pair#*:})"
  fi
done

if [[ -n "$LOGIN_SHELL_NAME" ]] \
   && [[ "$LOGIN_SHELL_NAME" != "zsh" && "$LOGIN_SHELL_NAME" != "bash" \
         && "$LOGIN_SHELL_NAME" != "fish" ]]; then
  printf '\n'
  warn "your login shell ($LOGIN_SHELL_NAME) has no hook"
  info "supported: zsh, bash, fish. In anything else you have to export"
  info "CLAUDE_CONFIG_DIR yourself."
fi

# Only zsh reads its hook for non-interactive shells, so `claude` from a script
# or a git hook picks up the active profile there and nowhere else.
if (( hook_installed )) && [[ "$LOGIN_SHELL_NAME" == "bash" || "$LOGIN_SHELL_NAME" == "fish" ]]; then
  printf '\n'
  info "note: only the zsh hook reaches non-interactive shells. In $LOGIN_SHELL_NAME,"
  info "'claude' run from a script does not pick up the active profile."
fi

# ─────────────────────────────────────────────────────────────── project pins ──
# A .lanes file pins a project to one profile, and the shell hook honours it
# whatever is globally active. Worth showing here because a pin explains an
# account you did not expect, and this script is the thing people run when
# something is unexpected.
hr "Project pins"

if [[ -r "$PWD/.lanes" ]]; then
  pin="$(tr -d '[:space:]' < "$PWD/.lanes")"
  if [[ -d "$HOME/.claude-$pin" ]]; then
    ok "this directory is pinned to '$pin'"
    info "$PWD/.lanes — claude here always uses that profile"
  else
    bad "this directory is pinned to '$pin', which does not exist"
    info "$PWD/.lanes names a profile this Mac does not have. The hook warns"
    info "and falls back to the active profile."
  fi
else
  # Walking up, exactly as the hook does: the pin is usually at the repo root.
  dir="$PWD"
  pin_holder=""
  while [[ -n "$dir" && "$dir" != "/" ]]; do
    if [[ -r "$dir/.lanes" ]]; then pin_holder="$dir"; break; fi
    dir="${dir%/*}"
  done

  if [[ -n "$pin_holder" ]]; then
    ok "pinned by a parent directory: $pin_holder/.lanes -> $(tr -d '[:space:]' < "$pin_holder/.lanes")"
  else
    info "no .lanes pin applies here"
    info "'lane lock <name>' in a project pins it, whatever the menu bar says"
  fi
fi

# ─────────────────────────────────────────────── leftovers from the old setup ──
hr "Leftovers from the old setup"

clean=1

if [[ -r "$HOME/.zshrc" ]] && grep -q "CLAUDE_CONFIG_DIR" "$HOME/.zshrc"; then
  clean=0
  warn "~/.zshrc still contains CLAUDE_CONFIG_DIR:"
  grep -n "CLAUDE_CONFIG_DIR" "$HOME/.zshrc" | sed 's/^/      /'
  info "-> remove those lines, and any hand-rolled switcher block around"
  info "   them. .zshrc runs after the hook in .zshenv, so a bare export"
  info "   there wins and you stay in one profile whatever the menu says."
  info "   Two things this list does not tell apart, so read it yourself:"
  info "   a bare 'export CLAUDE_CONFIG_DIR=...' runs at every shell start"
  info "   and does override the hook. An 'alias claude-work=\"export ...\"'"
  info "   only does anything when you type that alias — but switching that"
  info "   way skips the state file, so the menu bar falls behind. An alias"
  info "   named 'claude' or 'lane' is the one that would shadow the hook's"
  info "   own functions outright."
fi

# The rename produced a second app bundle rather than replacing the first, so a
# machine can run both: two menu bar items, two state files, and one of them
# silently wrong. Neither the app nor this script will remove an application.
LEGACY_APP="$(mdfind "kMDItemCFBundleIdentifier == 'nl.rowansail.claudeswitcher'" 2>/dev/null | head -1)"
if [[ -n "$LEGACY_APP" ]]; then
  clean=0
  warn "the previous version of this app is still installed"
  info "$LEGACY_APP"
  if pgrep -f "$LEGACY_APP" >/dev/null 2>&1; then
    info "and it is RUNNING — quit it first, or the two fight over the"
    info "~/.claude symlink and you get two menu bar items"
  fi
  info "-> quit it and drag it to the Trash once Lanes is set up"
fi

for editor in "Code" "Cursor" "Code - Insiders" "VSCodium" "Windsurf"; do
  s="$HOME/Library/Application Support/$editor/User/settings.json"
  [[ -r "$s" ]] || continue
  if grep -q "CLAUDE_CONFIG_DIR" "$s"; then
    clean=0
    warn "$editor: settings.json sets CLAUDE_CONFIG_DIR"
    grep -n "CLAUDE_CONFIG_DIR" "$s" | sed 's/^/      /'
    info "-> terminal.integrated.env.osx can go; the zshenv hook already"
    info "   covers the integrated terminal, and this line overrides it."
  fi
  if grep -q "claudeProfileSwitcher" "$s"; then
    clean=0
    warn "$editor: the old profile-switcher extension is still configured"
    info "-> it can stay (it reads the symlink, which this app keeps"
    info "   accurate), but do not switch from its status bar any more. Or:"
    info "   code --uninstall-extension sairambkrishnan.claude-code-profile-switcher"
  fi
done

[[ $clean -eq 1 ]] && ok "nothing found, clean"

# ────────────────────────────────────────────────────────────────── editors ────
# The Claude Code extension runs the same CLI, but starts it directly rather than
# through a shell. So it uses whatever environment its extension host was handed
# when the window opened, and it never sees a .lanes pin. Neither is visible from
# inside the editor, which is why this section reads the environment of the
# running processes instead of guessing.
hr "Editors"

active=""
[[ -r "$STATE" ]] && active="$(tr -d '[:space:]' < "$STATE")"

found=0
seen="|"
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"     # strip ps's leading padding
  pid="${line%% *}"
  path="${line#* }"

  # /Applications/Visual Studio Code.app/…/Code Helper (Plugin).app/… — the first
  # .app component is the editor, the second is the helper.
  head="${path%%.app/*}"
  name="${head##*/}"

  case "$name" in
    "Visual Studio Code"|"Visual Studio Code - Insiders"|Cursor|VSCodium|Windsurf|Positron|Trae) ;;
    *) continue ;;
  esac

  # ps eww prints a process's environment, and only for your own processes. Note
  # that a language server is a child of the extension host and inherits all of
  # this, so the test below admits those too — hence the dedupe on editor+lane.
  env_text="$(ps eww -p "$pid" 2>/dev/null)"
  case "$env_text" in
    *VSCODE_CRASH_REPORTER_PROCESS_TYPE=extensionHost*) ;;
    *) continue ;;
  esac

  dir="$(printf '%s' "$env_text" | tr ' ' '\n' \
         | grep -m1 '^CLAUDE_CONFIG_DIR=' | cut -d= -f2-)"

  case "$seen" in *"|$name=$dir|"*) continue ;; esac
  seen="$seen$name=$dir|"
  found=1

  if [[ -z "$dir" ]]; then
    bad "$name: CLAUDE_CONFIG_DIR is not set in this window"
    info "Claude Code there falls back to ~/.claude and to the default"
    info "Keychain item — a different account from every profile."
    info "Quit the editor and start it again."
    continue
  fi

  slug="${dir##*/.claude-}"
  if [[ -n "$active" && "$slug" == "$active" ]]; then
    ok "$name -> $slug"
  else
    warn "$name -> $slug, but the active profile is '${active:-none}'"
    info "the extension host inherits its environment from the editor's main"
    info "process, fixed when the editor launched. Reloading the window does"
    info "NOT change it — quit the editor entirely and open it again."
  fi
done < <(ps -xo pid=,command= 2>/dev/null | grep "Helper (Plugin)")

if (( found == 0 )); then
  info "no editor window open, or none could be inspected."
fi
info ""
info "Two things worth knowing about the editor extension:"
info "  - its account is fixed when the EDITOR launches, not when the window"
info "    opens. Reloading the window does not change it; quit and reopen."
info "  - .lanes pins do NOT apply in its panel, because it starts the CLI"
info "    without a shell. Set \"claudeCode.useTerminal\": true to run it in"
info "    the integrated terminal, where pins work as usual."

# ───────────────────────────────────────────────────────────────── remember ────
hr "Remember"
info "An already-running Claude session does not follow along. A process"
info "inherits its environment at launch; nothing can change it from outside"
info "afterwards. Switching always applies to what you start next."
printf '\n'
