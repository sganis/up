#!/usr/bin/env bash
# Prueba setup.sh entero en un contenedor de Linux Mint, lo más parecido al live:
# - con terminal: expect elige el repo en el menú de up y espera a que abra Claude;
# - con la fuente cdrom:// del USB, que hace fallar apt-get update;
# - con systemd a medias: instala Tailscale, pero conectarlo falla (el QR no se
#   puede probar acá) y setup.sh tiene que seguir igual.
# GitHub entra con el acceso de esta máquina (gh auth token); Claude, con la
# clave de up-priv. Al final prueba up y down desde una terminal nueva.
#
#     bash test/mint.sh <repo para abrir con up>
#
# Usa el código de esta carpeta, no el publicado. Lo de adentro está en
# test/mint-adentro.sh y test/live.exp.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
repo=${1:?uso: bash test/mint.sh <repo>}

docker run --rm --platform linux/amd64 -e GH_TOKEN="$(gh auth token)" -e REPO="$repo" \
  -v "$PWD:/src:ro" linuxmintd/mint22.2-amd64 bash /src/test/mint-adentro.sh
