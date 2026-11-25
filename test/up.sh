#!/usr/bin/env bash
# Tests bin/up with fake gh and tmux:  bash test/up.sh
# shellcheck disable=SC2016,SC2034,SC2015 # checks are single-quoted on purpose: check() evals them
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
UP=$PWD/bin/up
T=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$T"' EXIT
export HOME=$T/home GIT_CONFIG_GLOBAL=$T/gitconfig GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME=$T/xdg T
mkdir -p "$HOME" "$T/bin"
git config --global init.defaultBranch main

# Fake gh: "me" is the user; cloning creates an empty repo and records it
cat >"$T/bin/gh" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "api user") echo me ;;
  "repo list") printf 'me/one\nme/two\n' ;;
  "repo clone") git init -q "$4" && git -C "$4" remote add origin "https://github.com/$3" && echo "$3" >>"$T/cloned"
    # a repo that keeps its Claude memory in memoria/
    if [ "${3##*/}" = withmem ]; then mkdir "$4/memoria" && echo note >"$4/memoria/note.md"; fi ;;
esac
EOF
printf '#!/bin/sh\necho "$*" >"%s/tmux"\n' "$T" >"$T/bin/tmux"   # records how it was opened
chmod +x "$T/bin"/*
export PATH=$T/bin:$PATH
unset TMUX

failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi; }
run() { rm -f "$T/cloned" "$T/tmux"; out=$("$UP" "$@" 2>&1 </dev/null); code=$?; }

run https://github.com/other/thing
check "URL: clones owner/repo" '[ "$(cat "$T/cloned")" = other/thing ]'
check "URL: into ~/dev/<repo>" '[ -d "$HOME/dev/thing/.git" ]'
check "URL: opens tmux there" 'grep -q -- "new-session -A -s thing -c $HOME/dev/thing" "$T/tmux"'

rm -rf "$HOME/dev/thing"
run github.com/other/thing.git/
check "without https and with .git/: the same" '[ "$(cat "$T/cloned")" = other/thing ]'

for odd in 'other/wi th' '../x' 'a;rm -rf x' 'other/thing/more' ''; do
  run "$odd"
  check "odd name [$odd]: does nothing" '[ "$code" != 0 ] && [ ! -e "$T/cloned" ] && [ ! -e "$T/tmux" ]'
done

run mine
check "without owner: it's yours" '[ "$(cat "$T/cloned")" = me/mine ]'
check "yours: Claude in your usual mode" '! grep -q -- "--permission-mode" "$T/tmux"'
check "yours: doesn't ask whether you trust the folder" '[ "$(jq -r --arg d "$HOME/dev/mine" ".projects[\$d].hasTrustDialogAccepted" "$HOME/.claude.json")" = true ]'
check "Claude loads the key even if the terminal doesn't have it" 'grep -q "config/up/claude.env" "$T/tmux"'
check "Claude is found even if the terminal lacks ~/.local/bin" 'grep -q "\.local/bin" "$T/tmux"'
check "cargo and bun are found in Claude's terminal" 'grep -q "\.cargo/bin" "$T/tmux" && grep -q "\.bun/bin" "$T/tmux"'

run other/thing
check "someone else's: Claude asks before everything" 'grep -q -- "claude --permission-mode default" "$T/tmux"'
check "someone else's: does ask whether you trust the folder" '[ "$(jq -r --arg d "$HOME/dev/thing" ".projects[\$d].hasTrustDialogAccepted // false" "$HOME/.claude.json")" = false ]'

MEMDIR=$HOME/.claude/projects/$(printf %s "$HOME/dev/withmem" | sed 's/[^a-zA-Z0-9]/-/g')/memory
run withmem
check "memoria/: copied to where Claude looks for it" '[ "$(cat "$MEMDIR/note.md")" = note ]'
echo edited >"$MEMDIR/note.md"
run withmem
check "memoria/: doesn't overwrite notes from this session" '[ "$(cat "$MEMDIR/note.md")" = edited ]'
check "without memoria/: no memory folder is created" '[ ! -e "$HOME/.claude/projects/$(printf %s "$HOME/dev/mine" | sed "s/[^a-zA-Z0-9]/-/g")" ]'

rm -f "$T/cloned" "$T/tmux"
printf '2\n' | "$UP" >/dev/null 2>&1
check "without a name: pick from the list" '[ "$(cat "$T/cloned")" = me/two ]'

echo
[ "$failures" -eq 0 ] && echo "all good" || { echo "$failures failures"; exit 1; }
