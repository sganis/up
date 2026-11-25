#!/usr/bin/env bash
# Runs setup.sh end to end in a Linux Mint container, as close to the live
# system as it gets:
# - with a terminal: expect runs setup.sh, then types `up <repo>` in the same
#   terminal, waits for Claude, and tries the commands there;
# - with the USB stick's cdrom:// apt source, which makes apt-get update fail.
# GitHub logs in with this machine's access (gh auth token); Claude, with the
# up-priv key. At the end it tries up and down from a new terminal.
#
#     bash test/mint.sh <repo to open with up>
#
# Uses the code in this folder, not the published one. What runs inside is in
# test/mint-inside.sh and test/live.exp.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
repo=${1:?usage: bash test/mint.sh <repo>}

docker run --rm --platform linux/amd64 -e GH_TOKEN="$(gh auth token)" -e REPO="$repo" \
  -v "$PWD:/src:ro" linuxmintd/mint22.2-amd64 bash /src/test/mint-inside.sh
