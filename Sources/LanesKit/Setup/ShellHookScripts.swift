// Lanes — account lanes for Claude Code
// Copyright (C) 2026 rowansail
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// The hook scripts themselves.
//
// Raw string literals (#"""…"""#) so that backslashes and $-signs are literal and
// Swift never tries to interpolate anything. The paths and names below are therefore
// hardcoded rather than built from `Branding` — shell text stays readable that way,
// and `ShellHookScriptTests` asserts that every hardcoded string still matches its
// `Branding` constant, so a rename cannot silently desynchronise them.
//
// One convention throughout: paths printed to a human are abbreviated with
// `${path/#$HOME/~}` — the same shortening `Locations.abbreviate` does in the app, so
// the terminal and the menu describe a folder the same way. It is a display change
// only; every path the scripts actually *use* stays absolute.
extension ShellHook {

    public static func script(for flavor: ShellFlavor) -> String {
        switch flavor {
        case .zsh:  return zshScript
        case .bash: return bashScript
        case .fish: return fishScript
        }
    }

    // MARK: - zsh

    private static let zshScript = #"""
    # lanes-hook-revision: 2
    #
    # Lanes — account lanes for Claude Code
    #
    # MANAGED FILE. Lanes rewrites this on upgrade, so edits here do not survive.
    # It is sourced from a marked block in ~/.zshenv; remove that block to switch
    # the whole thing off.
    #
    # Why ~/.zshenv and not ~/.zprofile: .zshenv is the only zsh startup file read
    # for every invocation, non-interactive ones included. Put this in .zprofile
    # and `claude -p …` from a script, a git hook or a launchd job runs against
    # whichever account happens to be the default. Section 1 costs one file read;
    # the parts that cost more are gated on an interactive shell.

    # ── 1. the active profile ─────────────────────────────────────────────────
    # The only part of this file that switches anything. CLAUDE_CONFIG_DIR decides
    # where Claude Code keeps its config and — through a hash of this very path —
    # which Keychain item holds its tokens. The ~/.claude symlink switches nothing.

    _lanes_state=${LANES_STATE:-$HOME/.config/lanes/active}
    if [[ -r $_lanes_state ]]; then
      # $(<file) is a zsh substitution, not a subprocess: no fork, no /bin/cat.
      _lanes_slug="$(<$_lanes_state)"
      _lanes_slug=${_lanes_slug//[[:space:]]/}
      if [[ -n $_lanes_slug && -d $HOME/.claude-$_lanes_slug ]]; then
        export CLAUDE_CONFIG_DIR=$HOME/.claude-$_lanes_slug
      fi
    fi
    unset _lanes_state _lanes_slug

    # ── 2. project locks ──────────────────────────────────────────────────────
    # A file named .lanes in a project — or in any parent of it — holding a profile
    # name pins that project. `claude` then runs against that profile whatever is
    # globally active. That asymmetry is deliberate: the menu bar setting is a
    # convenience, but running the wrong account against a client's repo is not a
    # small mistake, so an explicit pin outranks it.
    #
    # Inert without a .lanes file: your arguments go straight to the real binary.
    # LANES_NO_LOCK=1 bypasses it entirely.

    claude() {
      emulate -L zsh
      local dir=$PWD slug= holder=

      if [[ -z ${LANES_NO_LOCK:-} ]]; then
        while [[ -n $dir && $dir != / ]]; do
          if [[ -r $dir/.lanes ]]; then
            slug="$(<$dir/.lanes)"
            slug=${slug//[[:space:]]/}
            holder=$dir
            break
          fi
          dir=${dir:h}
        done
      fi

      if [[ -n $slug ]]; then
        if [[ ! -d $HOME/.claude-$slug ]]; then
          print -u2 "lanes: ${holder/#$HOME/~}/.lanes names profile '$slug', which does not exist."
          print -u2 "lanes: continuing with the active profile."
        elif [[ ${CLAUDE_CONFIG_DIR:-} != $HOME/.claude-$slug ]]; then
          print -u2 "lanes: ${holder/#$HOME/~} is pinned to '$slug' — using it for this command."
          CLAUDE_CONFIG_DIR=$HOME/.claude-$slug command claude "$@"
          return
        fi
      fi

      command claude "$@"
    }

    # ── 3. the lane command ───────────────────────────────────────────────────
    # Interactive shells only. Everything above is one file read and two function
    # definitions; this part globs your home directory, and a script has no use
    # for it.
    #
    # Note there are deliberately no per-profile shortcuts (claude-work and so on).
    # Generating those meant globbing $HOME on every shell start, and an alias of
    # the same name in .zshrc silently beats a function in zsh — so the shortcuts
    # could stop working without any sign of why. `lane work` is shorter anyway.

    if [[ -o interactive ]]; then

    _lane_active() {
      local state=${LANES_STATE:-$HOME/.config/lanes/active} slug
      if [[ ! -r $state ]]; then
        return 0
      fi
      slug="$(<$state)"
      print -r -- ${slug//[[:space:]]/}
    }

    _lane_pin() {
      local dir=$PWD
      while [[ -n $dir && $dir != / ]]; do
        if [[ -r $dir/.lanes ]]; then
          print -r -- $dir
          return 0
        fi
        dir=${dir:h}
      done
      return 1
    }

    lane() {
      emulate -L zsh
      local state=${LANES_STATE:-$HOME/.config/lanes/active}
      local cmd=${1:-} slug active holder d s

      case $cmd in
      ''|list|-l|--list)
        active="$(_lane_active)"
        if [[ -n ${CLAUDE_CONFIG_DIR:-} ]]; then
          print "config dir : ${CLAUDE_CONFIG_DIR/#$HOME/~}"
        else
          print "config dir : (not set — open a new shell)"
        fi
        print "active     : ${active:-(none)}"
        if holder="$(_lane_pin)"; then
          slug="$(<$holder/.lanes)"
          print "pinned     : ${slug//[[:space:]]/}  (${holder/#$HOME/~}/.lanes)"
        fi
        print "profiles   :"
        for d in $HOME/.claude-*(/N); do
          s=${${d:t}#.claude-}
          if [[ $s == $active ]]; then
            print "  * $s"
          else
            print "    $s"
          fi
        done
        ;;

      help|-h|--help)
        print 'lane                 show the active profile and all profiles'
        print 'lane <name>          switch to a profile'
        print 'lane app [name]      open the Claude desktop app for a profile'
        print 'lane lock [name]     pin this directory to a profile'
        print 'lane unlock          remove the pin from this directory'
        print ''
        print 'Switching applies to shells you start next. A running process keeps the'
        print 'environment it was given, and nothing can change that from outside.'
        ;;

      app)
        slug=${2:-$(_lane_active)}
        if [[ -z $slug ]]; then
          print -u2 'lane: no profile given and none active'
          return 1
        fi
        if [[ ! -d $HOME/.claude-$slug ]]; then
          print -u2 "lane: no profile '$slug'"
          return 1
        fi
        mkdir -p $HOME/.claude-$slug/desktop
        # -n forces a new instance. Without it macOS focuses the Claude that is
        # already running and discards --args, and this looks like it did nothing.
        open -n -a Claude --args --user-data-dir=$HOME/.claude-$slug/desktop
        print "Claude app: $slug"
        ;;

      lock)
        slug=${2:-$(_lane_active)}
        if [[ -z $slug ]]; then
          print -u2 'lane: no profile given and none active'
          return 1
        fi
        if [[ ! -d $HOME/.claude-$slug ]]; then
          print -u2 "lane: no profile '$slug'"
          return 1
        fi
        if ! print -r -- $slug > .lanes; then
          return 1
        fi
        print "pinned ${PWD/#$HOME/~} to '$slug'"
        print 'Commit .lanes to share the pin, or add it to .git/info/exclude to keep it yours.'
        ;;

      unlock)
        if [[ -e .lanes ]]; then
          rm -f .lanes && print "removed .lanes from ${PWD/#$HOME/~}"
        else
          print -u2 "lane: no .lanes in ${PWD/#$HOME/~}"
          return 1
        fi
        ;;

      *)
        if [[ ! -d $HOME/.claude-$cmd ]]; then
          print -u2 "lane: no profile '$cmd' (~/.claude-$cmd does not exist)"
          return 1
        fi
        mkdir -p ${state:h}
        # Write to a sibling and rename. A plain redirect truncates the file first,
        # and a shell starting inside that window reads nothing and silently falls
        # back to the default account.
        if ! { print -r -- $cmd > $state.new \
               && chmod 600 $state.new \
               && mv -f $state.new $state }; then
          print -u2 "lane: could not write ${state/#$HOME/~}"
          rm -f $state.new
          return 1
        fi
        # -n matters. Without it ln follows the existing symlink and creates the
        # new link INSIDE the target folder, so the switch silently does nothing.
        ln -sfn $HOME/.claude-$cmd $HOME/.claude
        export CLAUDE_CONFIG_DIR=$HOME/.claude-$cmd
        print "now: $cmd  ->  ~/.claude-$cmd"
        ;;
      esac
    }

    fi
    """#

    // MARK: - bash

    private static let bashScript = #"""
    # lanes-hook-revision: 2
    #
    # Lanes — account lanes for Claude Code
    #
    # MANAGED FILE. Lanes rewrites this on upgrade, so edits here do not survive.
    # It is sourced from a marked block in ~/.bash_profile.
    #
    # One limit worth knowing about bash on macOS: neither .bash_profile nor
    # .bashrc is read by non-interactive shells, so `claude` invoked from a script
    # does not pick up the active profile. bash reads $BASH_ENV for that, which is
    # not this app's variable to claim. In a script, export CLAUDE_CONFIG_DIR
    # yourself — or use zsh, where the hook covers every invocation.

    # ── 1. the active profile ─────────────────────────────────────────────────
    # The only part of this file that switches anything. CLAUDE_CONFIG_DIR decides
    # where Claude Code keeps its config and — through a hash of this very path —
    # which Keychain item holds its tokens. The ~/.claude symlink switches nothing.

    _lanes_state="${LANES_STATE:-$HOME/.config/lanes/active}"
    if [ -r "$_lanes_state" ]; then
      # $(<file) is a bash builtin substitution: no fork, no /bin/cat.
      _lanes_slug="$(<"$_lanes_state")"
      _lanes_slug="${_lanes_slug//[[:space:]]/}"
      if [ -n "$_lanes_slug" ] && [ -d "$HOME/.claude-$_lanes_slug" ]; then
        export CLAUDE_CONFIG_DIR="$HOME/.claude-$_lanes_slug"
      fi
    fi
    unset _lanes_state _lanes_slug

    # ── 2. project locks ──────────────────────────────────────────────────────
    # A file named .lanes in a project — or in any parent of it — holding a profile
    # name pins that project, and `claude` then uses that profile whatever is
    # globally active. Inert without a .lanes file; LANES_NO_LOCK=1 bypasses it.

    claude() {
      local dir="$PWD" slug="" holder=""

      if [ -z "${LANES_NO_LOCK:-}" ]; then
        while [ -n "$dir" ] && [ "$dir" != "/" ]; do
          if [ -r "$dir/.lanes" ]; then
            slug="$(<"$dir/.lanes")"
            slug="${slug//[[:space:]]/}"
            holder="$dir"
            break
          fi
          dir="${dir%/*}"
          if [ -z "$dir" ]; then dir="/"; fi
        done
      fi

      if [ -n "$slug" ]; then
        if [ ! -d "$HOME/.claude-$slug" ]; then
          echo "lanes: ${holder/#$HOME/~}/.lanes names profile '$slug', which does not exist." >&2
          echo "lanes: continuing with the active profile." >&2
        elif [ "${CLAUDE_CONFIG_DIR:-}" != "$HOME/.claude-$slug" ]; then
          echo "lanes: ${holder/#$HOME/~} is pinned to '$slug' — using it for this command." >&2
          CLAUDE_CONFIG_DIR="$HOME/.claude-$slug" command claude "$@"
          return
        fi
      fi

      command claude "$@"
    }

    # ── 3. the lane command ───────────────────────────────────────────────────
    # Interactive shells only: this part globs your home directory.

    case $- in *i*)

    _lane_active() {
      local state="${LANES_STATE:-$HOME/.config/lanes/active}" slug
      if [ ! -r "$state" ]; then return 0; fi
      slug="$(<"$state")"
      printf '%s\n' "${slug//[[:space:]]/}"
    }

    _lane_pin() {
      local dir="$PWD"
      while [ -n "$dir" ] && [ "$dir" != "/" ]; do
        if [ -r "$dir/.lanes" ]; then printf '%s\n' "$dir"; return 0; fi
        dir="${dir%/*}"
        if [ -z "$dir" ]; then dir="/"; fi
      done
      return 1
    }

    lane() {
      local state="${LANES_STATE:-$HOME/.config/lanes/active}"
      local cmd="${1:-}" slug active holder d s

      case "$cmd" in
      ''|list|-l|--list)
        active="$(_lane_active)"
        if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
          echo "config dir : ${CLAUDE_CONFIG_DIR/#$HOME/~}"
        else
          echo "config dir : (not set — open a new shell)"
        fi
        echo "active     : ${active:-(none)}"
        if holder="$(_lane_pin)"; then
          slug="$(<"$holder/.lanes")"
          echo "pinned     : ${slug//[[:space:]]/}  (${holder/#$HOME/~}/.lanes)"
        fi
        echo "profiles   :"
        for d in "$HOME"/.claude-*/; do
          [ -d "$d" ] || continue
          s="${d%/}"
          s="${s##*/.claude-}"
          if [ "$s" = "$active" ]; then echo "  * $s"; else echo "    $s"; fi
        done
        ;;

      help|-h|--help)
        echo 'lane                 show the active profile and all profiles'
        echo 'lane <name>          switch to a profile'
        echo 'lane app [name]      open the Claude desktop app for a profile'
        echo 'lane lock [name]     pin this directory to a profile'
        echo 'lane unlock          remove the pin from this directory'
        echo ''
        echo 'Switching applies to shells you start next. A running process keeps the'
        echo 'environment it was given, and nothing can change that from outside.'
        ;;

      app)
        slug="${2:-$(_lane_active)}"
        if [ -z "$slug" ]; then echo 'lane: no profile given and none active' >&2; return 1; fi
        if [ ! -d "$HOME/.claude-$slug" ]; then echo "lane: no profile '$slug'" >&2; return 1; fi
        mkdir -p "$HOME/.claude-$slug/desktop"
        # -n forces a new instance; without it macOS focuses the running Claude
        # and discards --args.
        open -n -a Claude --args --user-data-dir="$HOME/.claude-$slug/desktop"
        echo "Claude app: $slug"
        ;;

      lock)
        slug="${2:-$(_lane_active)}"
        if [ -z "$slug" ]; then echo 'lane: no profile given and none active' >&2; return 1; fi
        if [ ! -d "$HOME/.claude-$slug" ]; then echo "lane: no profile '$slug'" >&2; return 1; fi
        printf '%s\n' "$slug" > .lanes || return 1
        echo "pinned ${PWD/#$HOME/~} to '$slug'"
        echo 'Commit .lanes to share the pin, or add it to .git/info/exclude to keep it yours.'
        ;;

      unlock)
        if [ -e .lanes ]; then
          rm -f .lanes && echo "removed .lanes from ${PWD/#$HOME/~}"
        else
          echo "lane: no .lanes in ${PWD/#$HOME/~}" >&2
          return 1
        fi
        ;;

      *)
        if [ ! -d "$HOME/.claude-$cmd" ]; then
          echo "lane: no profile '$cmd' (~/.claude-$cmd does not exist)" >&2
          return 1
        fi
        mkdir -p "${state%/*}"
        # Write to a sibling and rename, so a shell starting at this exact moment
        # never reads a truncated file.
        if ! { printf '%s\n' "$cmd" > "$state.new" \
               && chmod 600 "$state.new" \
               && mv -f "$state.new" "$state"; }; then
          echo "lane: could not write ${state/#$HOME/~}" >&2
          rm -f "$state.new"
          return 1
        fi
        # -n matters: without it ln follows the existing symlink and creates the
        # new link INSIDE the target folder, so the switch silently does nothing.
        ln -sfn "$HOME/.claude-$cmd" "$HOME/.claude"
        export CLAUDE_CONFIG_DIR="$HOME/.claude-$cmd"
        echo "now: $cmd  ->  ~/.claude-$cmd"
        ;;
      esac
    }

    esac
    """#

    // MARK: - fish

    private static let fishScript = #"""
    # lanes-hook-revision: 2
    #
    # Lanes — account lanes for Claude Code
    #
    # MANAGED FILE. Lanes rewrites this on upgrade, so edits here do not survive.
    # It is sourced from a marked block in ~/.config/fish/config.fish.

    # ── 1. the active profile ─────────────────────────────────────────────────
    # The only part of this file that switches anything. CLAUDE_CONFIG_DIR decides
    # where Claude Code keeps its config and — through a hash of this very path —
    # which Keychain item holds its tokens. The ~/.claude symlink switches nothing.

    set -l _lanes_state $HOME/.config/lanes/active
    if set -q LANES_STATE
        set _lanes_state $LANES_STATE
    end
    if test -r $_lanes_state
        set -l _lanes_slug (string trim < $_lanes_state)
        if test -n "$_lanes_slug"; and test -d "$HOME/.claude-$_lanes_slug"
            set -gx CLAUDE_CONFIG_DIR "$HOME/.claude-$_lanes_slug"
        end
    end

    # ── 2. project locks ──────────────────────────────────────────────────────
    # A file named .lanes in a project — or in any parent of it — holding a profile
    # name pins that project, and `claude` then uses that profile whatever is
    # globally active. Inert without a .lanes file; set LANES_NO_LOCK to bypass.

    function claude --wraps claude --description 'Claude Code, honouring Lanes project pins'
        if set -q LANES_NO_LOCK
            command claude $argv
            return $status
        end

        set -l dir (pwd)
        set -l slug ''
        set -l holder ''
        while test -n "$dir"; and test "$dir" != '/'
            if test -r "$dir/.lanes"
                set slug (string trim < "$dir/.lanes")
                set holder "$dir"
                break
            end
            # string replace rather than `dirname`, which would fork once per level.
            set dir (string replace -r '/[^/]*$' '' "$dir")
            if test -z "$dir"
                set dir '/'
            end
        end

        if test -n "$slug"
            # Display only, and the same shortening the app does. fish has no
            # ${var/#$HOME/~}, so this is `string replace`; it is unanchored, which
            # only matters for a path that repeats the home directory inside itself.
            set -l shown (string replace -- $HOME '~' "$holder")
            if not test -d "$HOME/.claude-$slug"
                echo "lanes: $shown/.lanes names profile '$slug', which does not exist." >&2
                echo "lanes: continuing with the active profile." >&2
            else if test "$CLAUDE_CONFIG_DIR" != "$HOME/.claude-$slug"
                echo "lanes: $shown is pinned to '$slug' — using it for this command." >&2
                # env, not `command claude`: this has to be a one-off environment for
                # a single invocation, without changing the shell's own.
                env CLAUDE_CONFIG_DIR="$HOME/.claude-$slug" claude $argv
                return $status
            end
        end

        command claude $argv
    end

    # ── 3. the lane command ───────────────────────────────────────────────────

    if status is-interactive

    function _lane_active
        set -l state $HOME/.config/lanes/active
        if set -q LANES_STATE
            set state $LANES_STATE
        end
        if test -r $state
            string trim < $state
        end
    end

    function _lane_pin
        set -l dir (pwd)
        while test -n "$dir"; and test "$dir" != '/'
            if test -r "$dir/.lanes"
                echo "$dir"
                return 0
            end
            set dir (string replace -r '/[^/]*$' '' "$dir")
            if test -z "$dir"
                set dir '/'
            end
        end
        return 1
    end

    function lane --description 'Switch Claude Code profiles'
        set -l state $HOME/.config/lanes/active
        if set -q LANES_STATE
            set state $LANES_STATE
        end

        set -l cmd ''
        if test (count $argv) -gt 0
            set cmd $argv[1]
        end

        set -l active (_lane_active)

        switch $cmd
        case '' list -l --list
            if set -q CLAUDE_CONFIG_DIR
                echo "config dir : "(string replace -- $HOME '~' "$CLAUDE_CONFIG_DIR")
            else
                echo "config dir : (not set — open a new shell)"
            end
            if test -n "$active"
                echo "active     : $active"
            else
                echo "active     : (none)"
            end
            set -l holder (_lane_pin)
            if test -n "$holder"
                set -l shown (string replace -- $HOME '~' "$holder")
                echo "pinned     : "(string trim < "$holder/.lanes")"  ($shown/.lanes)"
            end
            echo "profiles   :"
            for d in $HOME/.claude-*/
                test -d "$d"; or continue
                set -l s (string replace -r '.*/\.claude-' '' (string trim -r -c / "$d"))
                if test "$s" = "$active"
                    echo "  * $s"
                else
                    echo "    $s"
                end
            end

        case help -h --help
            echo 'lane                 show the active profile and all profiles'
            echo 'lane <name>          switch to a profile'
            echo 'lane app [name]      open the Claude desktop app for a profile'
            echo 'lane lock [name]     pin this directory to a profile'
            echo 'lane unlock          remove the pin from this directory'
            echo ''
            echo 'Switching applies to shells you start next. A running process keeps the'
            echo 'environment it was given, and nothing can change that from outside.'

        case app
            set -l slug $active
            if test (count $argv) -gt 1
                set slug $argv[2]
            end
            if test -z "$slug"
                echo 'lane: no profile given and none active' >&2
                return 1
            end
            if not test -d "$HOME/.claude-$slug"
                echo "lane: no profile '$slug'" >&2
                return 1
            end
            mkdir -p "$HOME/.claude-$slug/desktop"
            # -n forces a new instance; without it macOS focuses the running Claude
            # and discards --args.
            open -n -a Claude --args --user-data-dir="$HOME/.claude-$slug/desktop"
            echo "Claude app: $slug"

        case lock
            set -l slug $active
            if test (count $argv) -gt 1
                set slug $argv[2]
            end
            if test -z "$slug"
                echo 'lane: no profile given and none active' >&2
                return 1
            end
            if not test -d "$HOME/.claude-$slug"
                echo "lane: no profile '$slug'" >&2
                return 1
            end
            echo $slug > .lanes; or return 1
            echo "pinned "(string replace -- $HOME '~' (pwd))" to '$slug'"
            echo 'Commit .lanes to share the pin, or add it to .git/info/exclude to keep it yours.'

        case unlock
            if test -e .lanes
                rm -f .lanes
                echo "removed .lanes from "(string replace -- $HOME '~' (pwd))
            else
                echo "lane: no .lanes in "(string replace -- $HOME '~' (pwd)) >&2
                return 1
            end

        case '*'
            if not test -d "$HOME/.claude-$cmd"
                echo "lane: no profile '$cmd' (~/.claude-$cmd does not exist)" >&2
                return 1
            end
            mkdir -p (string replace -r '/[^/]*$' '' $state)
            # Write to a sibling and rename, so a shell starting at this exact
            # moment never reads a truncated file.
            echo $cmd > "$state.new"; and chmod 600 "$state.new"; and mv -f "$state.new" "$state"
            if test $status -ne 0
                echo "lane: could not write "(string replace -- $HOME '~' "$state") >&2
                rm -f "$state.new"
                return 1
            end
            # -n matters: without it ln follows the existing symlink and creates
            # the new link INSIDE the target folder.
            ln -sfn "$HOME/.claude-$cmd" "$HOME/.claude"
            set -gx CLAUDE_CONFIG_DIR "$HOME/.claude-$cmd"
            echo "now: $cmd  ->  ~/.claude-$cmd"
        end
    end

    end
    """#
}
