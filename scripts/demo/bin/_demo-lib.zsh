# Shared helpers for the demo's stand-in agents. Sourced, not run.
zmodload zsh/datetime zsh/mathfunc

# JSON string escaping, enough for prompts and paths.
_json() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  REPLY="\"$s\""
}

dim()    { print -r -- $'\e[38;5;245m'"$*"$'\e[0m' }
bold()   { print -r -- $'\e[1m'"$*"$'\e[0m' }

# An in-place "✻ Thinking… (3s)" line, cleared when done.
think() {
  local seconds=$1 verb=$2 color=$3
  local frames=(· ✢ ✳ ✶ ✻ ✽ ✻ ✶ ✳ ✢) i=0 start=$EPOCHREALTIME
  while (( EPOCHREALTIME - start < seconds )); do
    local elapsed=$(( int(EPOCHREALTIME - start) ))
    printf '\r\e[38;5;%sm%s\e[0m \e[38;5;%sm%s…\e[0m \e[38;5;245m(%ss · esc to interrupt)\e[0m\e[K' \
      $color ${frames[i % 10 + 1]} $color $verb $elapsed
    (( i++ ))
    sleep 0.11
  done
  printf '\r\e[K'
}

# Types text out at a reading pace.
stream() {
  local text=$1 word
  for word in ${(s: :)text}; do
    printf '%s ' $word
    sleep 0.035
  done
  print
}
