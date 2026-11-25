#!/bin/sh
# up — sets up a Linux machine to work with Claude Code on any GitHub project.
# Made for Linux Mint live from a USB stick: everything lives in RAM and is
# gone after shutdown.
#
#     curl -fL https://sganis.github.io/up | sh
#
# This repo is public: no keys, no data. The private part (settings, Claude
# key, Claude memory) lives in the private repo <user>/up-priv, and is only
# downloaded after you approve GitHub access from your phone.
#
# When it's done, in the same terminal: `up` opens a project with Claude,
# `down` pushes everything and powers off.

UP=sganis/up   # this repo

step() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*"; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# Git must never stop to ask for anything (a password, an unknown ssh host).
export GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="ssh -o BatchMode=yes"

# clone owner/repo: clones it into ~/dev, or updates it if it's already there.
clone() {
  d=$HOME/dev/${1#*/}
  if [ -d "$d/.git" ]; then
    git -C "$d" pull -q --ff-only || warn "could not update $d"
  else
    gh repo clone "$1" "$d" -- -q
  fi
}

# The live system has a cdrom:// apt source (the USB stick) without a Release
# file. It makes every apt-get update fail, and it's useless anyway: disable
# it, always, first thing.
no_cdrom() {
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [ -f "$f" ] && grep -q '^[[:space:]]*[^#[:space:]].*cdrom:' "$f" &&
      sudo sed -i 's/^\([[:space:]]*[^#[:space:]].*cdrom:.*\)$/# \1/' "$f"
  done
  if grep -s -l '^[[:space:]]*[^#[:space:]].*cdrom:' /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; then
    warn "a cdrom: apt source is still enabled in the file above; apt-get update will fail"
  fi
  return 0
}

# Everything inside main: sh reads the whole script before running anything.
main() {
  set -eu
  # With `curl | sh`, stdin is the script: questions go to the terminal.
  # (In a subshell: if /dev/tty can't be opened, dash kills the whole shell.)
  if (exec </dev/tty) 2>/dev/null; then exec </dev/tty; tty=1; else tty=; fi
  [ "$(id -u)" != 0 ] || die "run it as a normal user, not as root"
  command -v apt-get >/dev/null || die "needs Linux with apt (Mint, Ubuntu, Debian)"

  step "Packages"
  no_cdrom
  # Every step is skipped when it's already done: running it again downloads nothing.
  missing=
  for c in curl git gh tmux vim rg jq ffmpeg rclone python3 qrencode unzip cc pkg-config; do
    command -v "$c" >/dev/null || missing=1
  done
  if [ -n "$missing" ]; then
    # Update errors are shown but don't stop: if something is really missing, the install fails.
    sudo apt-get -qq update || warn "apt-get update had errors (above)"
    sudo DEBIAN_FRONTEND=noninteractive apt-get -qq install -y \
      curl git gh tmux vim ripgrep jq ffmpeg rclone python3 qrencode unzip build-essential pkg-config libssl-dev \
      >/dev/null || die "could not install the packages (apt's error is above)"
  fi
  # yt-dlp from its own site: the apt one is old and YouTube changes often.
  if [ ! -x /usr/local/bin/yt-dlp ]; then
    { sudo curl -fsSL -o /usr/local/bin/yt-dlp https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp &&
      sudo chmod +x /usr/local/bin/yt-dlp; } || warn "could not download yt-dlp"
  fi

  step "GitHub"
  if ! gh auth status >/dev/null 2>&1; then
    [ -n "$tty" ] || die "without a terminal I can't ask for GitHub access"
    echo "Scan this QR with your phone (it opens github.com/login/device),"
    echo "type the code shown below and tap Authorize. Here, press Enter when asked."
    qrencode -t ANSIUTF8 -m 2 https://github.com/login/device || true
    GH_BROWSER=true gh auth login --hostname github.com --git-protocol https --web --insecure-storage
  fi
  gh auth setup-git
  me=$(gh api user --jq .login)

  step "Private settings ($me/up-priv)"
  mkdir -p "$HOME/dev"
  clone "$me/up-priv"
  clone "$UP"
  PRIV=$HOME/dev/up-priv
  GIT_NAME='' GIT_EMAIL='' TIMEZONE=''
  # shellcheck source=/dev/null
  [ -f "$PRIV/up.conf" ] && . "$PRIV/up.conf"
  [ -z "$GIT_NAME" ] || git config --global user.name "$GIT_NAME"
  [ -z "$GIT_EMAIL" ] || git config --global user.email "$GIT_EMAIL"
  git config --global init.defaultBranch main

  step "Time zone"
  if [ -n "$TIMEZONE" ]; then
    sudo timedatectl set-timezone "$TIMEZONE" 2>/dev/null ||
      sudo ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime || warn "could not set the time zone to $TIMEZONE"
  fi

  step "Commands"
  mkdir -p "$HOME/.local/bin" "$HOME/.claude"
  # Commands go to /usr/local/bin: they work in any terminal, this one too,
  # without opening another one or reloading anything.
  for c in up down vpn drive up-memory; do sudo ln -sf "$HOME/dev/up/bin/$c" "/usr/local/bin/$c"; done
  if ! grep -q '^# up:' "$HOME/.bashrc" 2>/dev/null; then
    cat >>"$HOME/.bashrc" <<'EOF'

# up: Claude key and personal shell settings, from up-priv
export PATH="$HOME/.local/bin:$PATH"
if [ -f ~/dev/up-priv/claude.env ]; then set -a; . ~/dev/up-priv/claude.env; set +a; fi
if [ -f ~/dev/up-priv/bashrc ]; then . ~/dev/up-priv/bashrc; fi
EOF
  fi

  # oc (OpenShift) and kubectl, from the official site: they're not in apt.
  if ! command -v oc >/dev/null; then
    case $(uname -m) in aarch64 | arm64) a=-arm64 ;; *) a= ;; esac
    curl -fsSL "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux$a.tar.gz" |
      sudo tar -xz -C /usr/local/bin oc kubectl || warn "could not install oc"
  fi

  step "Rust"
  # With rustup, the official installer. It adds ~/.cargo/bin to ~/.bashrc for
  # new terminals; the links in /usr/local/bin make it work in this one too.
  if [ ! -x "$HOME/.cargo/bin/rustup" ]; then
    curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y -q || warn "could not install Rust"
  fi
  for f in "$HOME"/.cargo/bin/*; do [ -x "$f" ] && sudo ln -sf "$f" /usr/local/bin/; done

  step "Bun"
  if [ ! -x "$HOME/.bun/bin/bun" ]; then
    curl -fsSL https://bun.sh/install | bash >/dev/null 2>&1 || warn "could not install Bun"
  fi
  for f in "$HOME"/.bun/bin/*; do [ -x "$f" ] && sudo ln -sf "$f" /usr/local/bin/; done

  step "Claude"
  [ -x "$HOME/.local/bin/claude" ] || curl -fsSL https://claude.ai/install.sh | bash
  [ -x "$HOME/.local/bin/claude" ] || die "Claude was not installed"
  # `claude` in any terminal, with the up-priv key even if the terminal doesn't have it.
  sudo tee /usr/local/bin/claude >/dev/null <<'EOF'
#!/bin/sh
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -f "$HOME/dev/up-priv/claude.env" ]; then
  set -a; . "$HOME/dev/up-priv/claude.env"; set +a
fi
exec "$HOME/.local/bin/claude" "$@"
EOF
  sudo chmod +x /usr/local/bin/claude
  # Global instructions: a link, so whatever changes here gets pushed by `down`.
  [ -f "$PRIV/CLAUDE.md" ] && ln -sf "$PRIV/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
  # Settings from up-priv, plus the hook that keeps the memory in up-priv.
  # shellcheck disable=SC2016 # $HOME is expanded by Claude when it runs the hook
  hook='{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"$HOME/dev/up/bin/up-memory"}]}]}}'
  if [ -f "$PRIV/settings.json" ]; then
    jq --argjson h "$hook" '. * $h' "$PRIV/settings.json" >"$HOME/.claude/settings.json"
  else
    printf '%s\n' "$hook" >"$HOME/.claude/settings.json"
  fi
  # Without this, Claude asks you to log in even though it has the key.
  f=$HOME/.claude.json
  [ -f "$f" ] || echo '{}' >"$f"
  jq '.hasCompletedOnboarding = true' "$f" >"$f.tmp" && mv "$f.tmp" "$f"

  [ -f "$PRIV/claude.env" ] || warn "up-priv has no claude.env: Claude will ask you to log in"
  step "Done. In this same terminal:"
  echo "  up      open a project (Claude, in tmux)"
  echo "  down    push everything and power off"
  echo "  drive   connect Google Drive (optional)"
  echo "  vpn     install and connect Tailscale (optional)"
}

main "$@"
