#!/usr/bin/env bash
# Tests bin/down with a fake HOME and fake sudo/systemctl/tailscale/gh:  bash test/down.sh
# shellcheck disable=SC2016,SC2034,SC2015 # checks are single-quoted on purpose: check() evals them
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
DOWN=$PWD/bin/down
T=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$T"' EXIT
export HOME=$T/home GIT_CONFIG_GLOBAL=$T/gitconfig GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME=$T/xdg
git config --global user.name test
git config --global user.email test@example.com
git config --global init.defaultBranch main
mkdir -p "$HOME/dev" "$T/bin"

# Fakes: they record the call instead of powering off
for c in systemctl tailscale; do
  printf '#!/bin/sh\necho "%s $*" >>"%s/calls"\n' "$c" "$T" >"$T/bin/$c"
done
printf '#!/bin/sh\nexec "$@"\n' >"$T/bin/sudo"
printf '#!/bin/sh\n:\n' >"$T/bin/sleep"
# gh repo view: repos with "public" in their name are public
printf '#!/bin/sh\ncase "$PWD" in *public*) echo PUBLIC ;; *) echo PRIVATE ;; esac\n' >"$T/bin/gh"
chmod +x "$T/bin"/*
export PATH=$T/bin:$PATH

failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi; }
repo() {   # repo <name>: a clone with a local remote and a first commit pushed
  git init -q --bare "$T/$1.git"
  git clone -q "$T/$1.git" "$HOME/dev/$1" 2>/dev/null
  echo hi >"$HOME/dev/$1/readme.md"
  git -C "$HOME/dev/$1" add -A && git -C "$HOME/dev/$1" commit -qm start && git -C "$HOME/dev/$1" push -q -u origin main
}
remote() { git --git-dir="$T/$1.git" show "main:$2" 2>/dev/null; }
powered_off() { grep -q "systemctl poweroff" "$T/calls" 2>/dev/null; }
run() { rm -f "$T/calls"; out=$("$DOWN" 2>&1); code=$?; }
says() { printf %s "$out" | grep -qF -- "$1"; }

# 1. Everything gets pushed: uncommitted changes, unpushed commits, and a repo without changes
repo a; repo b; repo c
echo change >>"$HOME/dev/a/readme.md"; echo new >"$HOME/dev/a/new.md"
echo local >"$HOME/dev/b/b.md"; git -C "$HOME/dev/b" add -A; git -C "$HOME/dev/b" commit -qm local
run
check "pushes uncommitted changes" 'remote a new.md | grep -q new && remote a readme.md | grep -q change'
check "pushes unpushed commits" 'remote b b.md | grep -q local'
check "the repo without changes stays the same" '[ "$(git --git-dir="$T/c.git" rev-list --count main)" = 1 ]'
check "exits fine" '[ "$code" = 0 ]'
check "logs out of Tailscale" 'grep -q "tailscale logout" "$T/calls"'
check "powers off" 'powered_off'

# 2. GitHub changed meanwhile: merges and pushes
git clone -q "$T/a.git" "$T/other" && echo from-there >"$T/other/other.md" && git -C "$T/other" add -A \
  && git -C "$T/other" commit -qm other && git -C "$T/other" push -q
echo mine >"$HOME/dev/a/mine.md"
run
check "merges what's new on GitHub and pushes" 'remote a mine.md | grep -q mine && remote a other.md | grep -q from-there'

# 3. Something can't be pushed: says so and doesn't power off
echo change >"$HOME/dev/c/c.md"
rm -rf "$T/c.git"   # the remote is gone
run
check "on failure, exits with an error" '[ "$code" != 0 ]'
check "on failure, names the repo" 'says "✗ c" && says "still to push: c"'
check "on failure, neither powers off nor logs out of Tailscale" '[ ! -f "$T/calls" ]'
check "on failure, the change is kept in a commit" '[ -z "$(git -C "$HOME/dev/c" status --porcelain)" ]'
rm -rf "$HOME/dev/c"

# 4. A big file (a video downloaded by mistake into the repo) is neither pushed nor lost
dd if=/dev/urandom of="$HOME/dev/a/big video.mp4" bs=1048576 count=60 2>/dev/null
echo small >"$HOME/dev/a/small.md"
run
check "big: not pushed" '! git --git-dir="$T/a.git" ls-tree -r --name-only main | grep -q video'
check "big: not even copied into .git" '[ "$(du -sm "$HOME/dev/a/.git" | cut -f1)" -lt 50 ]'
check "big: the rest is pushed" 'remote a small.md | grep -q small'
check "big: still on disk" '[ -f "$HOME/dev/a/big video.mp4" ]'
check "big: names it" 'says "big video.mp4"'
check "big: doesn't power off" '[ "$code" != 0 ] && ! powered_off'
rm -f "$HOME/dev/a/big video.mp4"

# 5. git add fails (a leftover index.lock): doesn't power off
echo another >"$HOME/dev/a/another.md"
touch "$HOME/dev/a/.git/index.lock"
run
check "add fails: doesn't power off" '[ "$code" != 0 ] && ! powered_off && says "✗ a"'
rm -f "$HOME/dev/a/.git/index.lock"
run
check "add fails: pushes on the next try" '[ "$code" = 0 ] && remote a another.md | grep -q another'

# 6. Another branch with unpushed commits, and a stash: doesn't power off
git -C "$HOME/dev/b" checkout -q -b fix && echo x >"$HOME/dev/b/x.md" && git -C "$HOME/dev/b" add -A \
  && git -C "$HOME/dev/b" commit -qm fix && git -C "$HOME/dev/b" checkout -q main
run
check "unpushed branch: doesn't power off" '[ "$code" != 0 ] && ! powered_off && says "branch fix"'
git -C "$HOME/dev/b" push -q -u origin fix
echo saved >>"$HOME/dev/b/readme.md" && git -C "$HOME/dev/b" stash -q
run
check "stash: doesn't power off" '[ "$code" != 0 ] && ! powered_off && says "stash"'
git -C "$HOME/dev/b" stash drop -q

# 7. A Claude worktree (.claude/worktrees/x, new branch): its branch is pushed, not added to the repo
git -C "$HOME/dev/b" worktree add -q -b worktree-x "$HOME/dev/b/.claude/worktrees/x" 2>/dev/null
echo from-worktree >"$HOME/dev/b/.claude/worktrees/x/w.md"
run
check "worktree: pushes its branch" 'git --git-dir="$T/b.git" show worktree-x:w.md 2>/dev/null | grep -q from-worktree'
check "worktree: not added to the repo" '! git --git-dir="$T/b.git" ls-tree -r --name-only main | grep -q worktrees'
check "worktree: powers off" '[ "$code" = 0 ] && powered_off'
git -C "$HOME/dev/b" worktree remove --force "$HOME/dev/b/.claude/worktrees/x"

# 8. A half-done merge: doesn't commit the conflict markers
git clone -q "$T/b.git" "$T/otherb" && echo from-there >"$T/otherb/readme.md" && git -C "$T/otherb" commit -qam there && git -C "$T/otherb" push -q
echo from-here >"$HOME/dev/b/readme.md" && git -C "$HOME/dev/b" commit -qam here
git -C "$HOME/dev/b" pull -q --no-rebase >/dev/null 2>&1
run
check "half-done merge: doesn't power off" '[ "$code" != 0 ] && ! powered_off'
check "half-done merge: doesn't push conflict markers" '! remote b readme.md | grep -q "<<<<<<<"'
git -C "$HOME/dev/b" merge --abort; git -C "$HOME/dev/b" reset -q --hard origin/main

# 9. Public repo: pushes your commits, but doesn't commit for you
repo public
echo commit >"$HOME/dev/public/done.md" && git -C "$HOME/dev/public" add -A && git -C "$HOME/dev/public" commit -qm finished
echo secret >"$HOME/dev/public/.env"
echo change >>"$HOME/dev/public/readme.md"
run
check "public: pushes the commits" 'remote public done.md | grep -q commit'
check "public: doesn't push new files" '! remote public .env >/dev/null'
check "public: doesn't commit changes" '! remote public readme.md | grep -q change'
check "public: names them and doesn't power off" 'says ".env" && says "readme.md" && [ "$code" != 0 ] && ! powered_off'
rm -rf "$HOME/dev/public"

# 10. settings.local.json (the memory setting) is never pushed
mkdir -p "$HOME/dev/a/.claude"
echo '{"autoMemoryDirectory":"~/dev/up-priv/memory/a"}' >"$HOME/dev/a/.claude/settings.local.json"
echo last >"$HOME/dev/a/last.md"
run
check "settings.local.json: not pushed" '! git --git-dir="$T/a.git" ls-tree -r --name-only main | grep -q settings.local'
check "settings.local.json: the rest is" 'remote a last.md | grep -q last'
rm -rf "$HOME/dev/a/.claude"

# 11. Claude memory outside up-priv, or a folder without git in ~/dev: doesn't power off
mkdir -p "$HOME/.claude/projects/-home-mint/memory" && echo note >"$HOME/.claude/projects/-home-mint/memory/n.md"
run
check "loose memory: doesn't power off and names it" '[ "$code" != 0 ] && ! powered_off && says "-home-mint/memory"'
rm -rf "$HOME/.claude/projects/-home-mint"
mkdir -p "$HOME/dev/draft" && echo x >"$HOME/dev/draft/x.txt"
run
check "folder without git: doesn't power off and names it" '[ "$code" != 0 ] && ! powered_off && says "draft"'
rm -rf "$HOME/dev/draft"
run
check "all in order again: powers off" '[ "$code" = 0 ] && powered_off'

echo
[ "$failures" -eq 0 ] && echo "all good" || { echo "$failures failures"; exit 1; }
