#!/usr/bin/env bash
# Tests bin/up-memory with a fake HOME:  bash test/memory.sh
# shellcheck disable=SC2016,SC2034,SC2015 # checks are single-quoted on purpose: check() evals them
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
UP=$PWD/bin/up-memory
T=$(cd "$(mktemp -d)" && pwd -P)   # real path: on macOS /var is a link
trap 'rm -rf "$T"' EXIT
export HOME=$T/home GIT_CONFIG_GLOBAL=$T/gitconfig GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME=$T/xdg
git config --global user.name test
git config --global user.email test@example.com
git config --global init.defaultBranch main
mkdir -p "$HOME/dev"

failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi; }
encode() { printf %s "$1" | sed 's/[^a-zA-Z0-9]/-/g'; }   # how Claude names its folders
setting() { jq -r '.autoMemoryDirectory // empty' "$1/.claude/settings.local.json" 2>/dev/null; }

# up-priv with a local remote, to see the memory get pushed
git init -q --bare "$T/remote.git"
git clone -q "$T/remote.git" "$HOME/dev/up-priv" 2>/dev/null
git -C "$HOME/dev/up-priv" commit -q --allow-empty -m start
git -C "$HOME/dev/up-priv" push -q -u origin main
PRIV=$HOME/dev/up-priv

# 1. A GitHub project with memory in the default place (like on the Mac)
P=$HOME/dev/local-folder
git init -q "$P"
git -C "$P" remote add origin ssh://git@github.com/someone/project.git
echo hi >"$P/readme.md"; git -C "$P" add -A; git -C "$P" commit -qm start
MEM=$HOME/.claude/projects/$(encode "$P")/memory
mkdir -p "$MEM" "$P/.claude"
echo note >"$MEM/note.md"
echo index >"$MEM/MEMORY.md"
echo '{"permissions":{"allow":["Bash(ls)"]}}' >"$P/.claude/settings.local.json"
mkdir -p "$P/sub"
"$UP" "$P/sub" >/dev/null   # from a subfolder: it still uses the root
DST=$PRIV/memory/project
check "Claude uses up-priv/memory/<repo name on GitHub>" '[ "$(setting "$P")" = "~/dev/up-priv/memory/project" ]'
check "keeps what was already in settings.local.json" '[ "$(jq -r ".permissions.allow[0]" "$P/.claude/settings.local.json")" = "Bash(ls)" ]'
check "the notes were moved" '[ "$(cat "$DST/note.md")" = note ] && [ -f "$DST/MEMORY.md" ]'
check "the old folder is gone" '[ ! -e "$MEM" ]'
check "settings.local.json stays out of the repo" 'git -C "$P" check-ignore -q .claude/settings.local.json'
check "the repo doesn't change" '[ -z "$(git -C "$P" status --porcelain)" ]'

# The memory gets pushed by itself (in the background)
for _ in $(seq 50); do git --git-dir="$T/remote.git" show main:memory/project/note.md >/dev/null 2>&1 && break; sleep 0.2; done
check "the memory reaches the remote" 'git --git-dir="$T/remote.git" show main:memory/project/note.md 2>/dev/null | grep -q note'

# Running it again changes nothing
before=$(cat "$P/.claude/settings.local.json")
"$UP" "$P" >/dev/null
check "it's idempotent" '[ "$(cat "$P/.claude/settings.local.json")" = "$before" ] && [ ! -e "$MEM" ] && [ -f "$DST/note.md" ]'

# 2. A project with no memory yet (and not on GitHub): uses the folder name
Q=$HOME/dev/new
git init -q "$Q"
"$UP" "$Q" >/dev/null
check "new project: up-priv/memory/<folder>" '[ "$(setting "$Q")" = "~/dev/up-priv/memory/new" ] && [ -d "$PRIV/memory/new" ]'

# 2b. A repo that has settings.local.json in git: the setting stays local, never pushed
V=$HOME/dev/tracked
git init -q "$V"
mkdir -p "$V/.claude"
echo '{"permissions":{"allow":["Bash(ls)"]}}' >"$V/.claude/settings.local.json"
git -C "$V" add -A && git -C "$V" commit -qm start
"$UP" "$V" >/dev/null
check "tracked: Claude uses up-priv" '[ "$(setting "$V")" = "~/dev/up-priv/memory/tracked" ]'
check "tracked: git doesn't see the change" '[ -z "$(git -C "$V" status --porcelain)" ]'
git -C "$V" add -A && git -C "$V" commit -qm other 2>/dev/null
check "tracked: git add -A doesn't push it" '! git -C "$V" show HEAD:.claude/settings.local.json | grep -q autoMemoryDirectory'

# 3. A link from an older version is replaced by the setting; older up-priv/memoria/ moves to memory/
E=$HOME/dev/linked
git init -q "$E"
MEME=$HOME/.claude/projects/$(encode "$E")/memory
mkdir -p "$PRIV/memoria/linked" "${MEME%/*}"
echo old >"$PRIV/memoria/linked/n.md"
ln -s "$PRIV/memoria/linked" "$MEME"
"$UP" "$E" >/dev/null
check "old link: the link is removed" '[ ! -e "$MEME" ] && [ ! -L "$MEME" ]'
check "old memoria/: the notes move to memory/" '[ "$(cat "$PRIV/memory/linked/n.md")" = old ] && [ ! -e "$PRIV/memoria" ]'
check "old link: the setting is there" '[ "$(setting "$E")" = "~/dev/up-priv/memory/linked" ]'

# 3b. A setting from an older version (memoria/) is updated to memory/
O=$HOME/dev/older
git init -q "$O"
mkdir -p "$O/.claude" "$PRIV/memoria/older"
echo '{"autoMemoryDirectory":"~/dev/up-priv/memoria/older"}' >"$O/.claude/settings.local.json"
echo old >"$PRIV/memoria/older/o.md"
"$UP" "$O" >/dev/null
check "old setting: now points to memory/" '[ "$(setting "$O")" = "~/dev/up-priv/memory/older" ] && [ -f "$PRIV/memory/older/o.md" ]'

# 4. Clash: the local memory has a note that already exists in up-priv with other text
R=$HOME/dev/clash
git init -q "$R"
MEMR=$HOME/.claude/projects/$(encode "$R")/memory
mkdir -p "$MEMR" "$PRIV/memory/clash"
echo local >"$MEMR/a.md"
echo other >"$MEMR/b.md"
echo remote >"$PRIV/memory/clash/a.md"
out=$("$UP" "$R")
check "clash: doesn't overwrite the existing note" '[ "$(cat "$PRIV/memory/clash/a.md")" = remote ]'
check "clash: doesn't delete the local note" '[ "$(cat "$MEMR/a.md")" = local ]'
check "clash: Claude keeps using the local folder" '[ -z "$(setting "$R")" ]'
check "clash: what doesn't clash is moved anyway" '[ -f "$PRIV/memory/clash/b.md" ]'
check "clash: says so" 'printf %s "$out" | grep -q "$MEMR" && printf %s "$out" | grep -q "a.md"'

# 5. If the memory changed on two machines and can't be merged, it says so next time
sleep 1   # let earlier pushes finish
git clone -q "$T/remote.git" "$T/other" && echo from-there >"$T/other/memory/project/note.md" \
  && git -C "$T/other" commit -qam other && git -C "$T/other" push -q
echo from-here >"$DST/note.md"
"$UP" "$P" >/dev/null
for _ in $(seq 50); do [ -s "$HOME/.cache/up/notice" ] && break; sleep 0.2; done
check "conflict: leaves a notice" 'grep -q "two machines" "$HOME/.cache/up/notice"'
check "conflict: no rebase left half done" '[ ! -d "$PRIV/.git/rebase-merge" ]'
out=$("$UP" "$P")
check "conflict: reports it at startup" 'printf %s "$out" | grep -q "two machines"'

# 5b. Pushes don't step on each other
sleep 1
git -C "$PRIV" fetch -q && git -C "$PRIV" reset -q --hard origin/main && rm -f "$HOME/.cache/up/notice"
count() { git --git-dir="$T/remote.git" rev-list --count main; }
before=$(count)
mkdir "$PRIV/.git/up-memory.lock"   # another push in progress
echo new >"$DST/lock.md"
"$UP" "$P" >/dev/null; sleep 2
check "lock: doesn't push while another push runs" '[ "$(count)" = "$before" ]'
touch -t 202001010000 "$PRIV/.git/up-memory.lock"   # a push that died long ago
"$UP" "$P" >/dev/null
for _ in $(seq 50); do [ "$(count)" != "$before" ] && break; sleep 0.2; done
check "old lock: pushes anyway" 'git --git-dir="$T/remote.git" show main:memory/project/lock.md >/dev/null 2>&1'
check "lock: removed when done" '[ ! -e "$PRIV/.git/up-memory.lock" ]'
sleep 1
mkdir "$PRIV/.git/rebase-merge"   # someone is resolving a conflict
echo other >"$DST/rebase.md"
head_before=$(git -C "$PRIV" rev-parse HEAD)
"$UP" "$P" >/dev/null; sleep 2
check "half-done rebase: doesn't commit" '[ "$(git -C "$PRIV" rev-parse HEAD)" = "$head_before" ]'
check "half-done rebase: doesn't abort it" '[ -d "$PRIV/.git/rebase-merge" ]'
rmdir "$PRIV/.git/rebase-merge"

# 5c. --settings-only (used by up before opening Claude): no push, keeps the notice
mkdir -p "$HOME/.cache/up" && echo "test notice" >"$HOME/.cache/up/notice"
head_before=$(git -C "$PRIV" rev-parse HEAD)
out=$("$UP" --settings-only "$P"); sleep 1
check "settings only: doesn't print the notice" '[ -z "$out" ]'
check "settings only: the notice stays for Claude" 'grep -q "test notice" "$HOME/.cache/up/notice"'
check "settings only: doesn't push" '[ "$(git -C "$PRIV" rev-parse HEAD)" = "$head_before" ]'
rm -f "$HOME/.cache/up/notice"

# 5d. up-priv keeps its own memory too, and its setting stays out of git
"$UP" "$PRIV" >/dev/null
check "up-priv: its memory goes to memory/up-priv" '[ "$(setting "$PRIV")" = "~/dev/up-priv/memory/up-priv" ]'
check "up-priv: its setting stays out of git" 'git -C "$PRIV" check-ignore -q .claude/settings.local.json'

# 5e. If it can't hide the setting from git (an index.lock), it doesn't write it
W=$HOME/dev/locked
git init -q "$W" && mkdir -p "$W/.claude" && echo '{}' >"$W/.claude/settings.local.json"
git -C "$W" add -A && git -C "$W" commit -qm start
touch "$W/.git/index.lock"
out=$("$UP" "$W")
check "can't hide it: doesn't write the setting" '[ -z "$(setting "$W")" ]'
check "can't hide it: says so" 'printf %s "$out" | grep -q "settings.local.json"'
rm -f "$W/.git/index.lock"

# 6. Outside a repo, or without up-priv, it does nothing
sleep 1
mkdir -p "$HOME/loose"
"$UP" "$HOME/loose" >/dev/null
check "outside a repo: creates nothing" '[ ! -e "$HOME/loose/.claude" ]'
mv "$PRIV" "$T/saved"
S=$HOME/dev/nopriv
git init -q "$S"
"$UP" "$S" >/dev/null
check "without up-priv: creates nothing" '[ ! -e "$S/.claude" ]'

echo
[ "$failures" -eq 0 ] && echo "all good" || { echo "$failures failures"; exit 1; }
