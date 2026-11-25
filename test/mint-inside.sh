#!/usr/bin/env bash
# What runs inside test/mint.sh's container, as root.
# shellcheck disable=SC2016,SC2034,SC2015 # checks are single-quoted on purpose: check() evals them
set -uo pipefail
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi; }
name=${REPO##*/}

apt-get -qq update >/dev/null && apt-get -qq install -y expect >/dev/null   # only for the test
useradd -m -s /bin/bash mint
echo "mint ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/mint                                # like the live system
echo "deb cdrom:[Linux Mint 22.2 _Zara_]/ noble contrib main" >>/etc/apt/sources.list   # like the live system

# A new terminal for mint: nothing setup.sh left in the environment.
as_mint() {
  runuser -u mint -- env -i HOME=/home/mint USER=mint LOGNAME=mint TERM=xterm-256color LANG=C.UTF-8 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin GH_TOKEN="$GH_TOKEN" "$@"
}
as_mint mkdir -p /home/mint/dev
as_mint cp -r /src /home/mint/dev/up   # the code from here, not the published one

echo "===== in one terminal: setup.sh, then up $REPO, then the commands"
as_mint env REPO="$REPO" expect /src/test/live.exp >/tmp/live.log 2>&1
code=$?
clean=$(sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' /tmp/live.log | tr -d '\r')
printf '%s\n' "$clean" | grep -a -E '▸|✗|^!|###|^E: |MISSING-' | head -40
check "setup.sh finishes, up opens Claude with the key, and it exits fine" '[ "$code" = 0 ]'
check "doesn't ask whether it trusts the folder" '! grep -aq "trust this folder" /tmp/live.log'
check "the cdrom source got disabled" '! grep -q "^deb cdrom" /etc/apt/sources.list'
check "setup.sh doesn't install Tailscale (it's optional)" '! command -v tailscale >/dev/null'
for c in up down vpn drive claude cargo rustc bun oc kubectl vim; do
  check "in the same terminal, $c works" 'printf "%s" "$clean" | grep -aq "HAS-$c"'
done

echo "===== afterwards, in a new terminal"
check "cargo, bun and oc run" 'as_mint bash --norc --noprofile -c "cargo --version && bun --version && oc version --client" >/dev/null'
check "Claude is still open in tmux" 'as_mint tmux has-session -t "=$name"'
mem=/home/mint/.claude/projects/$(printf %s "/home/mint/dev/$name" | sed 's/[^a-zA-Z0-9]/-/g')/memory
if [ -d "/home/mint/dev/$name/memoria" ]; then
  check "Claude has the notes from $name/memoria" 'diff -rq "/home/mint/dev/$name/memoria" "$mem" >/dev/null'
fi
check "no settings file was added to the repo" '[ ! -e "/home/mint/dev/$name/.claude/settings.local.json" ]'

dirty=$(for d in /home/mint/dev/*/; do as_mint git -C "$d" status --porcelain; done)
# down copies Claude's memory back into memoria/: it must be unchanged, or the test would push it.
[ -d "/home/mint/dev/$name/memoria" ] && ! diff -rq "/home/mint/dev/$name/memoria" "$mem" >/dev/null && dirty="memory changed"
if [ -z "$dirty" ]; then
  as_mint bash --norc --noprofile -c down >/tmp/down.log 2>&1
  sed 's/^/  down: /' /tmp/down.log
  check "down checks everything and gets to power off" 'grep -q "Everything pushed" /tmp/down.log'
else
  echo "FAIL repos have changes; not running down so the test pushes nothing:"
  echo "$dirty"
  failures=$((failures + 1))
fi

echo
[ "$failures" -eq 0 ] && echo "all good" || { echo "$failures failures"; exit 1; }
