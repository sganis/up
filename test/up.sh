#!/usr/bin/env bash
# Prueba de bin/up con gh y tmux falsos:  bash test/up.sh
# shellcheck disable=SC2016,SC2034,SC2015 # las comprobaciones van entre comillas simples a propósito: las evalúa chequear
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
UP=$PWD/bin/up
T=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$T"' EXIT
export HOME=$T/home GIT_CONFIG_GLOBAL=$T/gitconfig GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME=$T/xdg T
mkdir -p "$HOME" "$T/bin"
git config --global init.defaultBranch main

# gh falso: "yo" es el usuario; clonar crea un repo vacío y lo anota
cat >"$T/bin/gh" <<'FIN'
#!/bin/sh
case "$1 $2" in
  "api user") echo yo ;;
  "repo list") printf 'yo/uno\nyo/dos\n' ;;
  "repo clone") git init -q "$4" && git -C "$4" remote add origin "https://github.com/$3" && echo "$3" >>"$T/clonados" ;;
esac
FIN
printf '#!/bin/sh\necho "$*" >"%s/tmux"\n' "$T" >"$T/bin/tmux"   # anota cómo se abrió
chmod +x "$T/bin"/*
export PATH=$T/bin:$PATH
unset TMUX

fallas=0
chequear() { if eval "$2"; then echo "ok   $1"; else echo "MAL  $1"; fallas=$((fallas + 1)); fi; }
correr() { rm -f "$T/clonados" "$T/tmux"; salida=$("$UP" "$@" 2>&1 </dev/null); codigo=$?; }

correr https://github.com/otro/cosa
chequear "URL: clona dueño/repo" '[ "$(cat "$T/clonados")" = otro/cosa ]'
chequear "URL: en ~/dev/<repo>" '[ -d "$HOME/dev/cosa/.git" ]'
chequear "URL: abre tmux ahí" 'grep -q -- "new-session -A -s cosa -c $HOME/dev/cosa" "$T/tmux"'

rm -rf "$HOME/dev/cosa"
correr github.com/otro/cosa.git/
chequear "sin https y con .git/: igual" '[ "$(cat "$T/clonados")" = otro/cosa ]'

for raro in 'otro/re po' '../x' 'a;rm -rf x' 'otro/cosa/mas' ''; do
  correr "$raro"
  chequear "nombre raro [$raro]: no hace nada" '[ "$codigo" != 0 ] && [ ! -e "$T/clonados" ] && [ ! -e "$T/tmux" ]'
done

correr mio
chequear "sin dueño: es tuyo" '[ "$(cat "$T/clonados")" = yo/mio ]'
chequear "tuyo: Claude en tu modo de siempre" '! grep -q -- "--permission-mode" "$T/tmux"'

correr otro/cosa
chequear "ajeno: Claude pide permiso para todo" 'grep -q -- "claude --permission-mode default" "$T/tmux"'

rm -f "$T/clonados" "$T/tmux"
printf '2\n' | "$UP" >/dev/null 2>&1
chequear "sin nombre: elegir de la lista" '[ "$(cat "$T/clonados")" = yo/dos ]'

echo
[ "$fallas" -eq 0 ] && echo "todo bien" || { echo "$fallas fallas"; exit 1; }
