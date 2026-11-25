#!/usr/bin/env bash
# Corre setup.sh en un contenedor de Linux Mint, como `curl | sh` pero sin
# terminal: no hay preguntas, no hay Tailscale (no hay systemd) y el acceso a
# GitHub es el de esta máquina (gh auth token). Después abre un repo con `up`
# en tmux y muestra la pantalla.
#
#     bash test/mint.sh <repo para abrir con up>
#
# Usa el código de esta carpeta, no el publicado.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
repo=${1:?uso: bash test/mint.sh <repo>}

docker run --rm --platform linux/amd64 -e GH_TOKEN="$(gh auth token)" -e REPO="$repo" \
  -v "$PWD:/src:ro" linuxmintd/mint22.2-amd64 bash -c '
set -e
useradd -m -s /bin/bash mint
echo "mint ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/mint   # como en el live
# Como en el live: una fuente cdrom:// sin archivo Release, que hace fallar apt-get update.
echo "deb cdrom:[Linux Mint 22.2 _Zara_]/ noble contrib main" >/etc/apt/sources.list.d/cdrom.list
como() { runuser -u mint -- env HOME=/home/mint USER=mint GH_TOKEN="$GH_TOKEN" TERM=xterm-256color "$@"; }
como mkdir -p /home/mint/dev
como cp -r /src /home/mint/dev/up   # el código de acá, no el publicado

echo "===== setup.sh"
if cat /src/setup.sh | como sh; then echo "setup.sh terminó bien"; else echo "setup.sh FALLÓ"; exit 1; fi

echo "===== qué quedó"
como bash -ic "
  for c in git gh tmux rg jq ffmpeg rclone yt-dlp claude up bye up-memoria; do
    printf \"%-11s %s\n\" \$c \"\$(command -v \$c || echo FALTA)\"
  done
  yt-dlp --version; claude --version
  echo \"git: \$(git config --global user.name) <\$(git config --global user.email)>\"
  echo \"hora: \$(readlink /etc/localtime)\"
  echo \"CLAUDE.md -> \$(readlink ~/.claude/CLAUDE.md)\"
  jq -c .hooks ~/.claude/settings.json
  jq -c .hasCompletedOnboarding ~/.claude.json
  ls ~/dev
"

echo "===== up $REPO (como en el live: desde una terminal)"
nombre=${REPO##*/}; sesion=${nombre//[.:]/_}   # como en up
# script le da una terminal de mentira; up abre tmux ahí y Claude adentro.
como setsid -f bash -ic "stty cols 120 rows 40 2>/dev/null; script -qfc \"up $REPO\" /dev/null" >/dev/null 2>&1
for _ in $(seq 60); do sleep 2; como tmux has-session -t "=$sesion" 2>/dev/null && break; done
sleep 20
como tmux capture-pane -p -t "=$sesion:" | sed "/^\s*$/d" | head -30
echo "===== memoria de $REPO"
jq -c . "/home/mint/dev/$nombre/.claude/settings.local.json"
ls "/home/mint/dev/up-priv/memoria/$nombre" | head -3
como git -C "/home/mint/dev/$nombre" status --porcelain
'
