#!/usr/bin/env bash
# Prueba de bin/up-memoria con un HOME de mentira:  bash test/memoria.sh
# shellcheck disable=SC2016,SC2034,SC2015 # las comprobaciones van entre comillas simples a propósito: las evalúa chequear
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
UP=$PWD/bin/up-memoria
T=$(cd "$(mktemp -d)" && pwd -P)   # ruta real: en macOS /var es un enlace
trap 'rm -rf "$T"' EXIT
export HOME=$T/home GIT_CONFIG_GLOBAL=$T/gitconfig GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME=$T/xdg
git config --global user.name prueba
git config --global user.email prueba@example.com
git config --global init.defaultBranch main
mkdir -p "$HOME/dev"

fallas=0
chequear() { if eval "$2"; then echo "ok   $1"; else echo "MAL  $1"; fallas=$((fallas + 1)); fi; }
cifrar() { printf %s "$1" | sed 's/[^a-zA-Z0-9]/-/g'; }   # como Claude nombra las carpetas
ajuste() { jq -r '.autoMemoryDirectory // empty' "$1/.claude/settings.local.json" 2>/dev/null; }

# up-priv con un remoto local, para ver que la memoria se sube
git init -q --bare "$T/remoto.git"
git clone -q "$T/remoto.git" "$HOME/dev/up-priv" 2>/dev/null
git -C "$HOME/dev/up-priv" commit -q --allow-empty -m inicio
git -C "$HOME/dev/up-priv" push -q -u origin main

# 1. Un proyecto de GitHub con memoria en el lugar de siempre (como en la Mac)
P=$HOME/dev/carpeta-local
git init -q "$P"
git -C "$P" remote add origin ssh://git@github.com/alguien/proyecto.git
echo hola >"$P/leeme.md"; git -C "$P" add -A; git -C "$P" commit -qm inicio
MEM=$HOME/.claude/projects/$(cifrar "$P")/memory
mkdir -p "$MEM" "$P/.claude"
echo nota >"$MEM/nota.md"
echo indice >"$MEM/MEMORY.md"
echo '{"permissions":{"allow":["Bash(ls)"]}}' >"$P/.claude/settings.local.json"
mkdir -p "$P/sub"
"$UP" "$P/sub" >/dev/null   # desde una subcarpeta: igual usa la raíz
DST=$HOME/dev/up-priv/memoria/proyecto
chequear "Claude usa up-priv/memoria/<nombre del repo en GitHub>" '[ "$(ajuste "$P")" = "~/dev/up-priv/memoria/proyecto" ]'
chequear "respeta lo que ya había en settings.local.json" '[ "$(jq -r ".permissions.allow[0]" "$P/.claude/settings.local.json")" = "Bash(ls)" ]'
chequear "las notas se mudaron" '[ "$(cat "$DST/nota.md")" = nota ] && [ -f "$DST/MEMORY.md" ]'
chequear "la carpeta vieja ya no está" '[ ! -e "$MEM" ]'
chequear "settings.local.json no entra al repo" 'git -C "$P" check-ignore -q .claude/settings.local.json'
chequear "el repo no cambia" '[ -z "$(git -C "$P" status --porcelain)" ]'

# La memoria se sube sola (en segundo plano)
for _ in $(seq 50); do git --git-dir="$T/remoto.git" show main:memoria/proyecto/nota.md >/dev/null 2>&1 && break; sleep 0.2; done
chequear "la memoria llega al remoto" 'git --git-dir="$T/remoto.git" show main:memoria/proyecto/nota.md 2>/dev/null | grep -q nota'

# Correrlo de nuevo no cambia nada
antes=$(cat "$P/.claude/settings.local.json")
"$UP" "$P" >/dev/null
chequear "es idempotente" '[ "$(cat "$P/.claude/settings.local.json")" = "$antes" ] && [ ! -e "$MEM" ] && [ -f "$DST/nota.md" ]'

# 2. Proyecto sin memoria todavía (y sin GitHub): usa el nombre de la carpeta
Q=$HOME/dev/nuevo
git init -q "$Q"
"$UP" "$Q" >/dev/null
chequear "proyecto nuevo: up-priv/memoria/<carpeta>" '[ "$(ajuste "$Q")" = "~/dev/up-priv/memoria/nuevo" ] && [ -d "$HOME/dev/up-priv/memoria/nuevo" ]'

# 2b. Un repo que tiene settings.local.json en git: el ajuste queda local, no se sube
V=$HOME/dev/versionado
git init -q "$V"
mkdir -p "$V/.claude"
echo '{"permissions":{"allow":["Bash(ls)"]}}' >"$V/.claude/settings.local.json"
git -C "$V" add -A && git -C "$V" commit -qm inicio
"$UP" "$V" >/dev/null
chequear "versionado: Claude usa up-priv" '[ "$(ajuste "$V")" = "~/dev/up-priv/memoria/versionado" ]'
chequear "versionado: git no ve el cambio" '[ -z "$(git -C "$V" status --porcelain)" ]'
git -C "$V" add -A && git -C "$V" commit -qm otro 2>/dev/null
chequear "versionado: git add -A no lo sube" '! git -C "$V" show HEAD:.claude/settings.local.json | grep -q autoMemoryDirectory'

# 3. Un enlace de la versión anterior de up-memoria se reemplaza por el ajuste
E=$HOME/dev/enlazado
git init -q "$E"
MEME=$HOME/.claude/projects/$(cifrar "$E")/memory
mkdir -p "$HOME/dev/up-priv/memoria/enlazado" "${MEME%/*}"
echo vieja >"$HOME/dev/up-priv/memoria/enlazado/n.md"
ln -s "$HOME/dev/up-priv/memoria/enlazado" "$MEME"
"$UP" "$E" >/dev/null
chequear "enlace viejo: se borra el enlace" '[ ! -e "$MEME" ] && [ ! -L "$MEME" ]'
chequear "enlace viejo: las notas siguen en up-priv" '[ "$(cat "$HOME/dev/up-priv/memoria/enlazado/n.md")" = vieja ]'
chequear "enlace viejo: queda el ajuste" '[ "$(ajuste "$E")" = "~/dev/up-priv/memoria/enlazado" ]'

# 4. Choque: la memoria local tiene una nota que ya existe en up-priv con otro texto
R=$HOME/dev/choque
git init -q "$R"
MEMR=$HOME/.claude/projects/$(cifrar "$R")/memory
mkdir -p "$MEMR" "$HOME/dev/up-priv/memoria/choque"
echo local >"$MEMR/a.md"
echo otra >"$MEMR/b.md"
echo remota >"$HOME/dev/up-priv/memoria/choque/a.md"
salida=$("$UP" "$R")
chequear "choque: no pisa la nota que ya estaba" '[ "$(cat "$HOME/dev/up-priv/memoria/choque/a.md")" = remota ]'
chequear "choque: no borra la nota local" '[ "$(cat "$MEMR/a.md")" = local ]'
chequear "choque: Claude sigue usando la carpeta local" '[ -z "$(ajuste "$R")" ]'
chequear "choque: lo que no choca se muda igual" '[ -f "$HOME/dev/up-priv/memoria/choque/b.md" ]'
chequear "choque: avisa" 'printf %s "$salida" | grep -q "$MEMR" && printf %s "$salida" | grep -q "a.md"'

# 5. Si la memoria cambió en dos máquinas y no se puede juntar, avisa la próxima vez
sleep 1   # que terminen las subidas anteriores
git clone -q "$T/remoto.git" "$T/otra" && echo de-otra >"$T/otra/memoria/proyecto/nota.md" \
  && git -C "$T/otra" commit -qam otra && git -C "$T/otra" push -q
echo de-aca >"$DST/nota.md"
"$UP" "$P" >/dev/null
for _ in $(seq 50); do [ -s "$HOME/.cache/up/aviso" ] && break; sleep 0.2; done
chequear "conflicto: deja el aviso" 'grep -q "dos máquinas" "$HOME/.cache/up/aviso"'
chequear "conflicto: no queda a mitad de un rebase" '[ ! -d "$HOME/dev/up-priv/.git/rebase-merge" ]'
salida=$("$UP" "$P")
chequear "conflicto: lo cuenta al arrancar" 'printf %s "$salida" | grep -q "dos máquinas"'

# 5b. Las subidas no se pisan
PRIV=$HOME/dev/up-priv
sleep 1
git -C "$PRIV" fetch -q && git -C "$PRIV" reset -q --hard origin/main && rm -f "$HOME/.cache/up/aviso"
cuenta() { git --git-dir="$T/remoto.git" rev-list --count main; }
antes=$(cuenta)
mkdir "$PRIV/.git/up-memoria.lock"   # otra subida en curso
echo nueva >"$DST/candado.md"
"$UP" "$P" >/dev/null; sleep 2
chequear "candado: no sube mientras corre otra subida" '[ "$(cuenta)" = "$antes" ]'
touch -t 202001010000 "$PRIV/.git/up-memoria.lock"   # una subida que murió hace rato
"$UP" "$P" >/dev/null
for _ in $(seq 50); do [ "$(cuenta)" != "$antes" ] && break; sleep 0.2; done
chequear "candado viejo: sube igual" 'git --git-dir="$T/remoto.git" show main:memoria/proyecto/candado.md >/dev/null 2>&1'
chequear "candado: lo saca al terminar" '[ ! -e "$PRIV/.git/up-memoria.lock" ]'
sleep 1
mkdir "$PRIV/.git/rebase-merge"   # alguien está resolviendo un conflicto
echo otra >"$DST/rebase.md"
head_antes=$(git -C "$PRIV" rev-parse HEAD)
"$UP" "$P" >/dev/null; sleep 2
chequear "rebase a medias: no commitea" '[ "$(git -C "$PRIV" rev-parse HEAD)" = "$head_antes" ]'
chequear "rebase a medias: no lo aborta" '[ -d "$PRIV/.git/rebase-merge" ]'
rmdir "$PRIV/.git/rebase-merge"

# 5c. --solo-ajuste (lo usa up antes de abrir Claude): no sube ni se come el aviso
mkdir -p "$HOME/.cache/up" && echo "aviso de prueba" >"$HOME/.cache/up/aviso"
head_antes=$(git -C "$PRIV" rev-parse HEAD)
salida=$("$UP" --solo-ajuste "$P"); sleep 1
chequear "solo ajuste: no imprime el aviso" '[ -z "$salida" ]'
chequear "solo ajuste: el aviso queda para Claude" 'grep -q "aviso de prueba" "$HOME/.cache/up/aviso"'
chequear "solo ajuste: no sube" '[ "$(git -C "$PRIV" rev-parse HEAD)" = "$head_antes" ]'
rm -f "$HOME/.cache/up/aviso"

# 5d. up-priv también guarda su propia memoria, y su ajuste no entra a git
"$UP" "$PRIV" >/dev/null
chequear "up-priv: su memoria va a memoria/up-priv" '[ "$(ajuste "$PRIV")" = "~/dev/up-priv/memoria/up-priv" ]'
chequear "up-priv: su ajuste no entra a git" 'git -C "$PRIV" check-ignore -q .claude/settings.local.json'

# 5e. Si no puede ocultar el ajuste de git (un index.lock), no lo escribe
W=$HOME/dev/bloqueado
git init -q "$W" && mkdir -p "$W/.claude" && echo '{}' >"$W/.claude/settings.local.json"
git -C "$W" add -A && git -C "$W" commit -qm inicio
touch "$W/.git/index.lock"
salida=$("$UP" "$W")
chequear "no lo puede ocultar: no escribe el ajuste" '[ -z "$(ajuste "$W")" ]'
chequear "no lo puede ocultar: avisa" 'printf %s "$salida" | grep -q "settings.local.json"'
rm -f "$W/.git/index.lock"

# 6. Fuera de un repo, o sin up-priv, no hace nada
sleep 1
mkdir -p "$HOME/suelto"
"$UP" "$HOME/suelto" >/dev/null
chequear "fuera de un repo no crea nada" '[ ! -e "$HOME/suelto/.claude" ]'
mv "$HOME/dev/up-priv" "$T/guardado"
S=$HOME/dev/sinpriv
git init -q "$S"
"$UP" "$S" >/dev/null
chequear "sin up-priv no crea nada" '[ ! -e "$S/.claude" ]'

echo
[ "$fallas" -eq 0 ] && echo "todo bien" || { echo "$fallas fallas"; exit 1; }
