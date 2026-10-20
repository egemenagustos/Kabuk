#!/bin/zsh
# Quits the demo copy of Kabuk (only that one) and removes the demo stage and its worktrees.
demo=${KABUK_DEMO_ROOT:-$HOME/KabukDemo}
if [[ -r $demo/debug/pid ]]; then
  pid=$(<$demo/debug/pid)
  # Only if that pid is still the demo copy.
  ps -p $pid -E -o command= 2> /dev/null | grep -q "KABUK_DEMO=1" && kill $pid
fi
rm -rf $demo $HOME/.kabuk/worktrees/acme-web
rmdir $HOME/.kabuk/worktrees $HOME/.kabuk 2> /dev/null
print "Demo stage removed."
