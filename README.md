# up

Sets up a Linux machine to work with Claude Code on any GitHub project. Made for someone else's machine booted from a Linux Mint live USB stick: everything lives in RAM and is gone after shutdown.

```sh
curl -fL https://sganis.github.io/up | sh
```

Always with `https://`: without it, the first request goes unencrypted and, on a foreign network, someone could hand you a different script.

1. Installs `git`, `gh`, `tmux`, `vim`, `ripgrep`, `jq`, `ffmpeg`, `rclone`, `qrencode`, what's needed to compile, and the latest `yt-dlp`.
2. Logs in to GitHub: it shows a QR that opens github.com/login/device on your phone, where you type the code.
3. Downloads your private repo `acto4` and takes the settings from its `up/` folder.
4. Sets the time zone.
5. Installs `oc` (OpenShift) and `kubectl`, Rust (rustup), Bun and Claude Code.

No password is typed on the machine. Anything already done is skipped: running it again downloads nothing.

## Commands

They work in the same terminal as soon as the script finishes, and in any other.

```sh
up                # your repos, to pick one: clones it into ~/dev and opens Claude in tmux
up project        # one of yours
up owner/repo     # any GitHub repo (its URL works too)
down              # pushes the changes of every repo in ~/dev and powers off
drive             # optional: connects Google Drive (rclone remote "gdrive")
vpn               # optional: installs and connects Tailscale (vpn --login-server <url>)
```

On someone else's repo, Claude asks before doing anything: the repo could carry hidden instructions, and the machine has access to all your repos.

`down` doesn't power off if something couldn't be pushed, and says what:

- In private repos it commits everything that changed. In public ones it doesn't commit for you: it pushes your commits and lists what's uncommitted.
- It never pushes files over 50 MB nor `.claude/settings.local.json`.
- It doesn't power off either if there are unpushed commits on another branch, a `stash`, a half-done merge, or folders without git in `~/dev`.
- Claude memory of a repo without `memoria/` is not kept: it warns.

## Claude's memory

A repo can keep its Claude memory in a `memoria/` folder (acto4 does; keep it only in private repos). `up` copies it to where Claude looks for it, and `down` copies it back before pushing. Nothing else is touched, and nothing runs in the background.

## `acto4/up/`

This repo is public and has nothing private. The private part goes in the `up/` folder of your private repo `acto4` (the name is set at the top of `setup.sh`):

| File | What it is |
|---|---|
| `up.conf` | `GIT_NAME`, `GIT_EMAIL`, `TIMEZONE` |
| `claude.env` | `CLAUDE_CODE_OAUTH_TOKEN=...`, from `claude setup-token` |
| `bashrc` | prompt and aliases |
| `CLAUDE.md` | Claude's global instructions |
| `settings.json` | Claude settings |

## Tests

```sh
bash test/down.sh
bash test/up.sh
bash test/mint.sh <repo>   # setup.sh end to end in a Linux Mint container (Docker)
```
