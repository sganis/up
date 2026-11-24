#!/usr/bin/env bash
# Prueba de bin/bye con un HOME de mentira y sudo/systemctl/tailscale/gh falsos:  bash test/bye.sh
# shellcheck disable=SC2016,SC2034,SC2015 # las comprobaciones van entre comillas simples a propósito: las evalúa chequear
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
BYE=$PWD/bin/bye
T=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$T"' EXIT
export HOME=$T/home GIT_CONFIG_GLOBAL=$T/gitconfig GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME=$T/xdg
git config --global user.name prueba
git config --global user.email prueba@example.com
git config --global init.defaultBranch main
mkdir -p "$HOME/dev" "$T/bin"

# Falsos: anotan la llamada en vez de apagar
for c in systemctl tailscale; do
  printf '#!/bin/sh\necho "%s $*" >>"%s/llamadas"\n' "$c" "$T" >"$T/bin/$c"
done
printf '#!/bin/sh\nexec "$@"\n' >"$T/bin/sudo"
printf '#!/bin/sh\n:\n' >"$T/bin/sleep"
# gh repo view: los repos con "publico" en el nombre son públicos
printf '#!/bin/sh\ncase "$PWD" in *publico*) echo PUBLIC ;; *) echo PRIVATE ;; esac\n' >"$T/bin/gh"
chmod +x "$T/bin"/*
export PATH=$T/bin:$PATH

fallas=0
chequear() { if eval "$2"; then echo "ok   $1"; else echo "MAL  $1"; fallas=$((fallas + 1)); fi; }
repo() {   # repo <nombre>: clon con remoto local y un primer commit subido
  git init -q --bare "$T/$1.git"
  git clone -q "$T/$1.git" "$HOME/dev/$1" 2>/dev/null
  echo hola >"$HOME/dev/$1/leeme.md"
  git -C "$HOME/dev/$1" add -A && git -C "$HOME/dev/$1" commit -qm inicio && git -C "$HOME/dev/$1" push -q -u origin main
}
remoto() { git --git-dir="$T/$1.git" show "main:$2" 2>/dev/null; }
apago() { grep -q "systemctl poweroff" "$T/llamadas" 2>/dev/null; }
correr() { rm -f "$T/llamadas"; salida=$("$BYE" 2>&1); codigo=$?; }
dice() { printf %s "$salida" | grep -qF -- "$1"; }

# 1. Todo sube: cambios sin commit, commits sin subir, y un repo sin cambios
repo a; repo b; repo c
echo cambio >>"$HOME/dev/a/leeme.md"; echo nuevo >"$HOME/dev/a/nuevo.md"
echo local >"$HOME/dev/b/b.md"; git -C "$HOME/dev/b" add -A; git -C "$HOME/dev/b" commit -qm local
correr
chequear "sube cambios sin commit" 'remoto a nuevo.md | grep -q nuevo && remoto a leeme.md | grep -q cambio'
chequear "sube commits que faltaban" 'remoto b b.md | grep -q local'
chequear "el repo sin cambios queda igual" '[ "$(git --git-dir="$T/c.git" rev-list --count main)" = 1 ]'
chequear "sale bien" '[ "$codigo" = 0 ]'
chequear "cierra Tailscale" 'grep -q "tailscale logout" "$T/llamadas"'
chequear "apaga" 'apago'

# 2. GitHub cambió mientras tanto: junta y sube
git clone -q "$T/a.git" "$T/otra" && echo de-otra >"$T/otra/otra.md" && git -C "$T/otra" add -A \
  && git -C "$T/otra" commit -qm otra && git -C "$T/otra" push -q
echo mio >"$HOME/dev/a/mio.md"
correr
chequear "junta con lo nuevo de GitHub y sube" 'remoto a mio.md | grep -q mio && remoto a otra.md | grep -q de-otra'

# 3. Algo no se puede subir: avisa y no apaga
echo cambio >"$HOME/dev/c/c.md"
rm -rf "$T/c.git"   # el remoto desaparece
correr
chequear "si falla, sale con error" '[ "$codigo" != 0 ]'
chequear "si falla, nombra el repo" 'dice "✗ c" && dice "falta subir c"'
chequear "si falla, no apaga ni cierra Tailscale" '[ ! -f "$T/llamadas" ]'
chequear "si falla, el cambio queda guardado en un commit" '[ -z "$(git -C "$HOME/dev/c" status --porcelain)" ]'
rm -rf "$HOME/dev/c"

# 4. Un archivo grande (un video bajado sin querer en el repo) no se sube ni se pierde
dd if=/dev/urandom of="$HOME/dev/a/video grande.mp4" bs=1048576 count=60 2>/dev/null
echo chico >"$HOME/dev/a/chico.md"
correr
chequear "grande: no lo sube" '! git --git-dir="$T/a.git" ls-tree -r --name-only main | grep -q video'
chequear "grande: ni lo copia a .git" '[ "$(du -sm "$HOME/dev/a/.git" | cut -f1)" -lt 50 ]'
chequear "grande: lo demás sí sube" 'remoto a chico.md | grep -q chico'
chequear "grande: sigue en el disco" '[ -f "$HOME/dev/a/video grande.mp4" ]'
chequear "grande: avisa con el nombre" 'dice "video grande.mp4"'
chequear "grande: no apaga" '[ "$codigo" != 0 ] && ! apago'
rm -f "$HOME/dev/a/video grande.mp4"

# 5. git add falla (un index.lock que quedó): no apaga
echo otro >"$HOME/dev/a/otro.md"
touch "$HOME/dev/a/.git/index.lock"
correr
chequear "add falla: no apaga" '[ "$codigo" != 0 ] && ! apago && dice "✗ a"'
rm -f "$HOME/dev/a/.git/index.lock"
correr
chequear "add falla: al reintentar sube" '[ "$codigo" = 0 ] && remoto a otro.md | grep -q otro'

# 6. Otra rama con commits sin subir, y un stash: no apaga
git -C "$HOME/dev/b" checkout -q -b arreglo && echo x >"$HOME/dev/b/x.md" && git -C "$HOME/dev/b" add -A \
  && git -C "$HOME/dev/b" commit -qm arreglo && git -C "$HOME/dev/b" checkout -q main
correr
chequear "otra rama sin subir: no apaga" '[ "$codigo" != 0 ] && ! apago && dice "arreglo"'
git -C "$HOME/dev/b" push -q -u origin arreglo
echo guardado >>"$HOME/dev/b/leeme.md" && git -C "$HOME/dev/b" stash -q
correr
chequear "stash: no apaga" '[ "$codigo" != 0 ] && ! apago && dice "stash"'
git -C "$HOME/dev/b" stash drop -q

# 7. Un worktree de Claude (.claude/worktrees/x, rama nueva): se sube su rama, no se mete en el repo
git -C "$HOME/dev/b" worktree add -q -b worktree-x "$HOME/dev/b/.claude/worktrees/x" 2>/dev/null
echo del-worktree >"$HOME/dev/b/.claude/worktrees/x/w.md"
correr
chequear "worktree: sube su rama" 'git --git-dir="$T/b.git" show worktree-x:w.md 2>/dev/null | grep -q del-worktree'
chequear "worktree: no queda adentro del repo" '! git --git-dir="$T/b.git" ls-tree -r --name-only main | grep -q worktrees'
chequear "worktree: apaga" '[ "$codigo" = 0 ] && apago'
git -C "$HOME/dev/b" worktree remove --force "$HOME/dev/b/.claude/worktrees/x"

# 8. Un merge a medias: no commitea las marcas de conflicto
git clone -q "$T/b.git" "$T/otrab" && echo de-alla >"$T/otrab/leeme.md" && git -C "$T/otrab" commit -qam alla && git -C "$T/otrab" push -q
echo de-aca >"$HOME/dev/b/leeme.md" && git -C "$HOME/dev/b" commit -qam aca
git -C "$HOME/dev/b" pull -q --no-rebase >/dev/null 2>&1
correr
chequear "merge a medias: no apaga" '[ "$codigo" != 0 ] && ! apago'
chequear "merge a medias: no sube marcas de conflicto" '! remoto b leeme.md | grep -q "<<<<<<<"'
git -C "$HOME/dev/b" merge --abort; git -C "$HOME/dev/b" reset -q --hard origin/main

# 9. Repo público: sube tus commits, pero no commitea por vos
repo publico
echo commit >"$HOME/dev/publico/hecho.md" && git -C "$HOME/dev/publico" add -A && git -C "$HOME/dev/publico" commit -qm hecho
echo secreto >"$HOME/dev/publico/.env"
echo cambio >>"$HOME/dev/publico/leeme.md"
correr
chequear "público: sube los commits" 'remoto publico hecho.md | grep -q commit'
chequear "público: no sube archivos nuevos" '! remoto publico .env >/dev/null'
chequear "público: no commitea cambios" '! remoto publico leeme.md | grep -q cambio'
chequear "público: los nombra y no apaga" 'dice ".env" && dice "leeme.md" && [ "$codigo" != 0 ] && ! apago'
rm -rf "$HOME/dev/publico"

# 10. settings.local.json (el ajuste de la memoria) nunca se sube
mkdir -p "$HOME/dev/a/.claude"
echo '{"autoMemoryDirectory":"~/dev/up-priv/memoria/a"}' >"$HOME/dev/a/.claude/settings.local.json"
echo ultimo >"$HOME/dev/a/ultimo.md"
correr
chequear "settings.local.json: no lo sube" '! git --git-dir="$T/a.git" ls-tree -r --name-only main | grep -q settings.local'
chequear "settings.local.json: lo demás sí" 'remoto a ultimo.md | grep -q ultimo'
rm -rf "$HOME/dev/a/.claude"

# 11. Memoria de Claude fuera de up-priv, o una carpeta sin git en ~/dev: no apaga
mkdir -p "$HOME/.claude/projects/-home-mint/memory" && echo nota >"$HOME/.claude/projects/-home-mint/memory/n.md"
correr
chequear "memoria suelta: no apaga y la nombra" '[ "$codigo" != 0 ] && ! apago && dice "-home-mint/memory"'
rm -rf "$HOME/.claude/projects/-home-mint"
mkdir -p "$HOME/dev/borrador" && echo x >"$HOME/dev/borrador/x.txt"
correr
chequear "carpeta sin git: no apaga y la nombra" '[ "$codigo" != 0 ] && ! apago && dice "borrador"'
rm -rf "$HOME/dev/borrador"
correr
chequear "todo en orden de nuevo: apaga" '[ "$codigo" = 0 ] && apago'

echo
[ "$fallas" -eq 0 ] && echo "todo bien" || { echo "$fallas fallas"; exit 1; }
