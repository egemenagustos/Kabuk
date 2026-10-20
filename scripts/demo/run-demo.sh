#!/bin/zsh
# Plays the Kabuk demo in a separate copy of the app and records it.
#   scripts/demo/run-demo.sh               records to ~/Movies/Kabuk-Demo.mp4
#   scripts/demo/run-demo.sh --dry         no recording; a snapshot after every scene
#   scripts/demo/run-demo.sh --out <file>  records somewhere else
# Run scripts/demo/setup.sh first. The user's own Kabuk is never touched: the demo copy has
# its own state, socket and history (KABUK_SUPPORT_DIR) and is the only process quit at the end.
zmodload zsh/mathfunc
repo=${0:A:h:h:h}
demo=${KABUK_DEMO_ROOT:-$HOME/KabukDemo}
project=$demo/acme-web
debug=$demo/debug
out=$HOME/Movies/Kabuk-Demo.mp4
dry=0
while (( $# )); do
  case $1 in
    --dry) dry=1 ;;
    --out) out=$2; shift ;;
  esac
  shift
done
[[ -x $demo/kdbg ]] || { print "Run scripts/demo/setup.sh first."; exit 1 }

k() { $demo/kdbg "$@" }
cap() { k caption "$1" }
nocap() { k caption "" }
scene=0
shot() {
  (( dry )) || return 0
  (( scene++ ))
  rm -f $debug/snapshot.png
  k snapshot
  for i in {1..30}; do [[ -s $debug/snapshot.png ]] && break; sleep 0.1; done
  sleep 0.2
  cp $debug/snapshot.png $debug/scene-$(printf %02d $scene)-$1.png 2> /dev/null
}
# Types into whatever has focus and waits until the last key is in.
typed() {
  k keys "$1"
  sleep $(( ${#1} * 0.058 + ${2:-0.4} ))
}
run() { typed "$1\\r" ${2:-0.4} }

kabuks() { ps -axo pid=,comm= | awk '$2 ~ /\/Kabuk$/ { print $1 }' }
# Launch the demo copy through LaunchServices, so it asks for Screen Recording as itself.
before=(${(f)"$(kabuks)"})
open -n $repo/build/Kabuk.app \
  --env KABUK_DEMO=1 --env KABUK_SUPPORT_DIR=$demo/support --env KABUK_DEBUG_DIR=$debug \
  --env KABUK_DEMO_BIN=$repo/scripts/demo/bin --env KABUK_DEMO_DATA=$demo/data --env CODEX_HOME=$demo/codex
pid=
for i in {1..50}; do
  for p in ${(f)"$(kabuks)"}; do
    (( ${before[(Ie)$p]} )) || pid=$p
  done
  [[ -n $pid ]] && break
  sleep 0.1
done
[[ -n $pid ]] || { print "The demo copy didn't start."; exit 1 }
print $pid > $debug/pid
quit_demo() { kill $pid 2> /dev/null }
trap quit_demo INT TERM

sleep 2
k project $project
sleep 2.5
run "clear" 0.8

if (( ! dry )); then
  rm -f $debug/record.txt $debug/permission.txt
  k recpermission
  sleep 1
  if [[ $(<$debug/permission.txt) != granted ]]; then
    print "Kabuk needs Screen Recording permission: System Settings → Privacy & Security → Screen & System Audio Recording."
    print "Turn on Kabuk, then run this again."
    quit_demo
    exit 2
  fi
  k record "start $out"
  sleep 1.5
  [[ $(<$debug/record.txt 2> /dev/null) == recording ]] || { print "Recording didn't start: $(<$debug/record.txt)"; quit_demo; exit 3 }
fi

# 1. Hello
cap "Kabuk — a terminal built for AI agents"
sleep 3.5
shot intro

# 2. Every command has a state
cap "Every command shows its state as it runs"
run "npm test"
sleep 2
shot running
sleep 2.4
shot passed
sleep 1

# 3. Failures, handed to an agent
cap "Failed commands are captured"
run "npm run deploy"
sleep 2.6
shot failed
cap "…and handed to Claude in one click"
sleep 1.2
k ask claude
sleep 4
shot ask
sleep 9
cap "See what the agent changed this turn"
sleep 2.5
shot turncard
k showdiff src/config.ts
sleep 4
shot diff
k close
sleep 1.2

# 4. Agents at a glance
cap "Agents at a glance: status, time, tokens, cost"
run "Add a dark mode that follows the system setting"
sleep 4
shot thinking
sleep 9
shot darkdone

# 5. Parallel agents in worktrees, and a permission from the sidebar
cap "Parallel agents, each in its own git worktree|⌥ ⌘ T"
k action newClaudeWorktree:
sleep 3.2
run "Add rate limiting to the API routes"
sleep 0.6
k action newClaudeWorktree:
sleep 3.2
run "Write tests for the cart reducer"
sleep 0.6
k action newCodexWorktree:
sleep 3.2
run "Refactor checkout form validation"
sleep 2.5
shot worktrees
cap "Approve tool use right from the sidebar"
sleep 3.5
shot permission
k answer allow
sleep 3
cap "Every agent's state, side by side"
sleep 5
shot parallel

# 6. Ports
k select 0
sleep 0.8
k action focusLeft:
sleep 0.6
cap "Dev servers are detected — click to open"
run "npm run dev"
sleep 4.5
shot port
k key ctrl-c
sleep 3.5

# 7. Splits
cap "Split panes|⌘ D   ⇧ ⌘ D"
k action splitDown:
sleep 1.5
run "git log --oneline --graph" 1.5
k action focusRight:
sleep 0.8
k action focusUp:
sleep 0.8
shot splits

# 8. Command palette
cap "Everything is in the command palette|⌘ K"
k action togglePalette:
sleep 0.8
typed "worktree" 1.5
shot palette
k close
sleep 0.8

# 9. Themes and glass
cap "Themes|⌘ ⇧ T"
k action toggleThemes:
sleep 1.2
for theme in tokyo-night dracula nord gruvbox rose-pine solarized-dark kabuk; do
  k theme $theme
  sleep 1.3
done
shot themes
k close
sleep 0.8
cap "Glass, Tinted or Solid"
k opacity 0.4
sleep 1.6
k opacity 0.75
sleep 1.6
shot solid
k opacity 0.08
sleep 1.6

# 10. History, into the shell pane below
k action focusLeft:
sleep 0.3
k action focusDown:
sleep 0.4
cap "Search every command you've ever run|⌘ R"
k action toggleHistory:
sleep 0.8
typed "docker" 1.4
k key down
sleep 0.6
shot history
k key return
sleep 1.6
k key ctrl-c
sleep 0.6

# 11. Find
cap "Find in a pane|⌘ F"
k action focusLeft:
sleep 0.4
k action focusUp:
sleep 0.4
k action find:
sleep 0.6
typed "passed" 1.2
k key return
sleep 1.6
shot find
k close
sleep 0.8

# 12. Sidebar
cap "Hide the sidebar for a clean terminal|⌘ \\"
k action toggleSidebar:
sleep 2.2
k action toggleSidebar:
sleep 1.8

cap "Kabuk"
sleep 3
shot outro
nocap
sleep 1.2

if (( ! dry )); then
  k record stop
  for i in {1..40}; do
    [[ $(<$debug/record.txt 2> /dev/null) == done || $(<$debug/record.txt) == error* ]] && break
    sleep 0.25
  done
  print "Recording: $(<$debug/record.txt) → $out"
fi
quit_demo
