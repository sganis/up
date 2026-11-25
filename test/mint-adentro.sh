#!/usr/bin/env bash
# Lo que corre adentro del contenedor de test/mint.sh, como root.
# shellcheck disable=SC2016,SC2034,SC2015 # las comprobaciones van entre comillas simples a propósito: las evalúa chequear
set -uo pipefail
fallas=0
chequear() { if eval "$2"; then echo "ok   $1"; else echo "MAL  $1"; fallas=$((fallas + 1)); fi; }
nombre=${REPO##*/}

apt-get -qq update >/dev/null && apt-get -qq install -y expect >/dev/null   # solo para la prueba
useradd -m -s /bin/bash mint
echo "mint ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/mint                                # como en el live
echo "deb cdrom:[Linux Mint 22.2 _Zara_]/ noble contrib main" >>/etc/apt/sources.list   # como en el live
mkdir -p /run/systemd/system   # que instale Tailscale (sin systemd de verdad, conectarlo falla)

# Una terminal nueva de mint: nada de lo que dejó setup.sh en el entorno.
como() {
  runuser -u mint -- env -i HOME=/home/mint USER=mint LOGNAME=mint TERM=xterm-256color LANG=C.UTF-8 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin GH_TOKEN="$GH_TOKEN" "$@"
}
como mkdir -p /home/mint/dev
como cp -r /src /home/mint/dev/up   # el código de acá, no el publicado

echo "===== setup.sh con terminal: elige $REPO en el menú y espera a Claude"
como env REPO="$REPO" expect /src/test/live.exp >/tmp/live.log 2>&1
codigo=$?
sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' /tmp/live.log | grep -a -E '▸|✗|!|###|^E: ' | head -30
chequear "setup.sh llega hasta Claude abierto, con la clave" '[ "$codigo" = 0 ]'
chequear "no pregunta si confía en la carpeta" '! grep -aq "trust this folder" /tmp/live.log'
chequear "la fuente cdrom quedó desactivada" '! grep -q "^deb cdrom" /etc/apt/sources.list'
chequear "si Tailscale no conecta, avisa y sigue" 'grep -aq "Tailscale" /tmp/live.log'

echo "===== después, en una terminal nueva"
chequear "up, down y up-memoria están en el PATH" 'como bash --norc --noprofile -c "command -v up && command -v down && command -v up-memoria" >/dev/null'
chequear "Claude sigue abierto en tmux" 'como tmux has-session -t "=$nombre"'
chequear "la memoria de $nombre va a up-priv" '[ "$(jq -r .autoMemoryDirectory "/home/mint/dev/$nombre/.claude/settings.local.json")" = "~/dev/up-priv/memoria/$nombre" ]'

sucios=$(for d in /home/mint/dev/*/; do como git -C "$d" status --porcelain; done)
if [ -z "$sucios" ]; then
  como bash --norc --noprofile -c down >/tmp/down.log 2>&1
  sed 's/^/  down: /' /tmp/down.log
  chequear "down revisa todo y llega a apagar" 'grep -q "Todo subido" /tmp/down.log'
else
  echo "MAL  quedaron cambios en los repos; no corro down para no subir nada desde la prueba:"
  echo "$sucios"
  fallas=$((fallas + 1))
fi

echo
[ "$fallas" -eq 0 ] && echo "todo bien" || { echo "$fallas fallas"; exit 1; }
