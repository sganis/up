#!/bin/sh
# up — deja una máquina Linux lista para trabajar con Claude Code en cualquier
# proyecto de GitHub. Pensado para Linux Mint live desde un USB: todo queda en
# memoria y se borra al apagar.
#
#     curl -fsSL https://sganis.github.io/up | sh
#
# Este repo es público: no tiene claves ni datos. Lo privado (configuración,
# clave de Claude, memoria de Claude) está en el repo privado <usuario>/up-priv,
# y se baja recién después de aprobar el acceso a GitHub desde el celular.
#
# Al terminar abre `up`: elegís un proyecto y se abre Claude ahí.
# Antes de apagar: `bye`.

UP=sganis/up   # este repo

paso()  { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
aviso() { printf '\033[33m! %s\033[0m\n' "$*"; }
falla() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# clonar dueño/repo: lo clona en ~/dev, o lo actualiza si ya está.
clonar() {
  d=$HOME/dev/${1#*/}
  if [ -d "$d/.git" ]; then
    git -C "$d" pull -q --ff-only || aviso "no pude actualizar $d"
  else
    gh repo clone "$1" "$d" -- -q
  fi
}

# El live trae una fuente cdrom:// (el USB) sin archivo Release, que hace
# fallar todo apt-get update, también el del instalador de Tailscale. No sirve
# para nada: se desactiva. Los demás errores de update se muestran pero no
# frenan: si de verdad falta algo, falla la instalación.
actualizar() {
  sudo sed -i 's/^deb cdrom:/# deb cdrom:/' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null || true
  sudo apt-get -qq update || aviso "apt-get update dio errores (arriba)"
}

# Todo adentro de main: así sh lee el script entero antes de empezar.
main() {
  set -eu
  # Con `curl | sh` la entrada es el script: las preguntas van a la terminal.
  # (En una subshell: si /dev/tty no se puede abrir, dash cierra el shell entero.)
  if (exec </dev/tty) 2>/dev/null; then exec </dev/tty; tty=1; else tty=; fi
  [ "$(id -u)" != 0 ] || falla "corrélo como usuario normal, no como root"
  command -v apt-get >/dev/null || falla "hace falta Linux con apt (Mint, Ubuntu, Debian)"

  paso "Programas"
  # Cada paso se saltea si ya está hecho: correrlo de nuevo no baja nada otra vez.
  falta=
  for c in curl git gh tmux rg jq ffmpeg rclone python3 qrencode; do command -v "$c" >/dev/null || falta=1; done
  if [ -n "$falta" ]; then
    actualizar
    sudo DEBIAN_FRONTEND=noninteractive apt-get -qq install -y \
      curl git gh tmux ripgrep jq ffmpeg rclone python3 qrencode >/dev/null || falla "no pude instalar los programas (el error de apt está arriba)"
  fi
  # yt-dlp de su sitio: el de apt viene viejo y YouTube cambia seguido.
  if [ ! -x /usr/local/bin/yt-dlp ]; then
    { sudo curl -fsSL -o /usr/local/bin/yt-dlp https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp &&
      sudo chmod +x /usr/local/bin/yt-dlp; } || aviso "no pude bajar yt-dlp"
  fi

  paso "GitHub"
  if ! gh auth status >/dev/null 2>&1; then
    [ -n "$tty" ] || falla "sin terminal no puedo pedir el acceso a GitHub"
    echo "Escaneá este QR con el celular (abre github.com/login/device),"
    echo "escribí el código que aparece abajo y tocá Authorize. Acá, apretá Enter cuando lo pida."
    qrencode -t ANSIUTF8 -m 2 https://github.com/login/device || true
    GH_BROWSER=true gh auth login --hostname github.com --git-protocol https --web --insecure-storage
  fi
  gh auth setup-git
  yo=$(gh api user --jq .login)

  paso "Lo privado ($yo/up-priv)"
  mkdir -p "$HOME/dev"
  clonar "$yo/up-priv"
  clonar "$UP"
  PRIV=$HOME/dev/up-priv
  GIT_NAME='' GIT_EMAIL='' ZONA=''
  # shellcheck source=/dev/null
  [ -f "$PRIV/up.conf" ] && . "$PRIV/up.conf"
  [ -z "$GIT_NAME" ] || git config --global user.name "$GIT_NAME"
  [ -z "$GIT_EMAIL" ] || git config --global user.email "$GIT_EMAIL"
  git config --global init.defaultBranch main

  paso "Hora"
  if [ -n "$ZONA" ]; then
    sudo timedatectl set-timezone "$ZONA" 2>/dev/null ||
      sudo ln -sf "/usr/share/zoneinfo/$ZONA" /etc/localtime || aviso "no pude poner la hora de $ZONA"
  fi

  paso "Terminal"
  mkdir -p "$HOME/.local/bin" "$HOME/.claude"
  for c in up bye up-memoria; do ln -sf "$HOME/dev/up/bin/$c" "$HOME/.local/bin/$c"; done
  if ! grep -q '^# up:' "$HOME/.bashrc" 2>/dev/null; then
    cat >>"$HOME/.bashrc" <<'FIN'

# up: comandos (up, bye), clave de Claude y configuración propia, de up-priv
export PATH="$HOME/.local/bin:$PATH"
if [ -f ~/dev/up-priv/claude.env ]; then set -a; . ~/dev/up-priv/claude.env; set +a; fi
if [ -f ~/dev/up-priv/bashrc ]; then . ~/dev/up-priv/bashrc; fi
FIN
  fi

  paso "Claude"
  [ -x "$HOME/.local/bin/claude" ] || curl -fsSL https://claude.ai/install.sh | bash
  [ -x "$HOME/.local/bin/claude" ] || falla "no se instaló Claude"
  # Instrucciones globales: un enlace, así lo que cambie acá lo sube bye.
  [ -f "$PRIV/CLAUDE.md" ] && ln -sf "$PRIV/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
  # Configuración de up-priv, más el hook que guarda la memoria en up-priv.
  # shellcheck disable=SC2016 # $HOME lo expande Claude al correr el hook
  hook='{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"$HOME/dev/up/bin/up-memoria"}]}]}}'
  if [ -f "$PRIV/settings.json" ]; then
    jq --argjson h "$hook" '. * $h' "$PRIV/settings.json" >"$HOME/.claude/settings.json"
  else
    printf '%s\n' "$hook" >"$HOME/.claude/settings.json"
  fi
  # Sin esto, Claude pide entrar aunque tenga la clave.
  f=$HOME/.claude.json
  [ -f "$f" ] || echo '{}' >"$f"
  jq '.hasCompletedOnboarding = true' "$f" >"$f.tmp" && mv "$f.tmp" "$f"

  # Al final: si no hace falta, se saltea con Ctrl-C y lo demás ya está.
  if [ -d /run/systemd/system ]; then
    paso "Tailscale"
    command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
    if [ "$(tailscale status --json 2>/dev/null | jq -r .BackendState)" != Running ]; then
      echo "Escaneá el QR con el celular y aprobá esta máquina (Ctrl-C para saltearlo)."
      trap : INT
      sudo tailscale up --qr || aviso "Tailscale no quedó conectado"
      trap - INT
    fi
  else
    aviso "sin systemd: no instalo Tailscale"
  fi

  paso "Listo"
  export PATH="$HOME/.local/bin:$PATH"
  if [ -f "$PRIV/claude.env" ]; then
    set -a
    # shellcheck source=/dev/null
    . "$PRIV/claude.env"
    set +a
  else
    aviso "up-priv no tiene claude.env: Claude te va a pedir que entres"
  fi
  echo "up: abrir un proyecto.   bye: subir todo y apagar."
  if [ -n "$tty" ]; then exec "$HOME/.local/bin/up"; fi
}

main "$@"
