#!/usr/bin/env bash
#
# Types the demo commands at a readable pace and runs them for real.
#
#   docs/demo/record.sh [profile]      default profile: acme
#
# Everything on screen is genuine output — this script only controls the timing,
# so that a take is repeatable and lands inside twenty seconds. See README.md
# beside this file for the framing and the beats.
#
# Run it from the directory you want pinned, in a shell where the Lanes hook is
# active (`exec zsh` if you are unsure), with a *different* profile currently
# active in the menu bar. The whole point of the shot is that the two disagree.

set -uo pipefail

PROFILE="${1:-acme}"

if [[ ! -d "$HOME/.claude-$PROFILE" ]]; then
  echo "No profile '$PROFILE' (~/.claude-$PROFILE does not exist)." >&2
  echo "Pass the one you want: $(basename "$0") work" >&2
  exit 1
fi

# `lane` is a shell function from the hook, so it does not exist in this script's
# own shell — every command below is therefore run through an interactive login
# shell, the same way it would be typed. Checking here rather than failing four
# commands in gives a usable error before the recorder is rolling.
if ! "$SHELL" -lic 'typeset -f lane >/dev/null 2>&1 || declare -f lane >/dev/null 2>&1'; then
  echo "The Lanes hook is not active in $SHELL. Run 'exec zsh' and try again." >&2
  exit 1
fi

# A blank screen for a beat at the start: a GIF loops, and the first frame is also
# the frame after the last one.
clear
sleep 1.2

# Typing, one character at a time. 45ms is around 20 words a minute below a fast
# human — slow enough to read on a muted autoplaying loop, fast enough that four
# commands still fit in twenty seconds.
type_out() {
  local text="$1" i
  printf '%s ' "${PWD/#$HOME/~} $"
  for (( i = 0; i < ${#text}; i++ )); do
    printf '%s' "${text:i:1}"
    sleep 0.045
  done
  printf '\n'
}

run() {
  type_out "$1"
  sleep 0.35                       # the pause before Return, which reads as intent
  "$SHELL" -lic "$1"
  sleep "${2:-1.6}"                # long enough to read the output
}

run "lane lock $PROFILE"
run "lane" 2.4                     # the disagreement, in writing: active vs pinned

# The payoff, and the end of the take. `claude` prints the pin notice to stderr
# and then takes over the screen, so this one is not wrapped in `run`: there is
# nothing left to pace, and nothing may interrupt the recording here. Stop the
# recorder about a second after Claude has drawn itself, then Ctrl-C out.
type_out "claude"
sleep 0.35
exec "$SHELL" -lic "claude"
