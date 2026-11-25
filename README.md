# up

Deja una máquina Linux lista para trabajar con Claude Code en cualquier proyecto de GitHub. Está pensado para una máquina ajena con Linux Mint live desde un USB: todo queda en memoria y se borra al apagar.

```sh
curl -fsSL https://sganis.github.io/up | sh
```

Siempre con `https://`: sin eso, el primer pedido viaja sin cifrar y en una red ajena te pueden dar otro script.

1. Instala `git`, `gh`, `tmux`, `ripgrep`, `jq`, `ffmpeg`, `rclone`, `qrencode` y la última versión de `yt-dlp`.
2. Se conecta a GitHub: muestra un QR que abre github.com/login/device en el celular, y ahí se escribe el código.
3. Baja el repo privado `<usuario>/up-priv` y toma de ahí la configuración.
4. Pone la zona horaria.
5. Instala Claude Code.
6. Instala Tailscale y lo conecta con un QR que se aprueba desde el celular (Ctrl-C lo saltea).
7. Abre `up`.

En la máquina no se escribe ninguna contraseña.

## Comandos

```sh
up                # tus repos, para elegir: lo clona en ~/dev y abre Claude en tmux
up proyecto       # uno tuyo
up dueño/repo     # cualquier repo de GitHub (también sirve la URL)
bye               # sube los cambios de todos los repos de ~/dev, cierra Tailscale y apaga
```

En un repo ajeno, Claude pide permiso antes de cada cosa: el repo podría traer instrucciones escondidas, y la máquina tiene acceso a todos tus repos.

`bye` no apaga si algo no se pudo subir, y dice qué:

- En los repos privados commitea todo lo que cambió. En los públicos no commitea por vos: sube tus commits y nombra lo que quedó sin commitear.
- Nunca sube archivos de más de 50 MB ni `.claude/settings.local.json`.
- Tampoco apaga si hay commits sin subir en otra rama, un `stash`, un merge a medias, memoria de Claude fuera de `up-priv`, o carpetas sin git en `~/dev`.

## La memoria de Claude

`up-memoria` guarda la memoria de Claude de cada proyecto en `up-priv/memoria/<proyecto>/`, no en el repo del proyecto, que puede ser público. Se lo indica a Claude con `autoMemoryDirectory` en `.claude/settings.local.json`, que git ignora. Corre como hook `SessionStart` de Claude y sube los cambios de `up-priv` en segundo plano.

## `up-priv`

Este repo es público y no tiene nada privado. Lo privado va en `<usuario>/up-priv`:

| Archivo | Qué es |
|---|---|
| `up.conf` | `GIT_NAME`, `GIT_EMAIL`, `ZONA` |
| `claude.env` | `CLAUDE_CODE_OAUTH_TOKEN=...`, de `claude setup-token` |
| `bashrc` | prompt y alias |
| `CLAUDE.md` | instrucciones globales de Claude |
| `settings.json` | configuración de Claude |
| `memoria/` | la memoria de Claude, un directorio por proyecto |

## Pruebas

```sh
bash test/memoria.sh
bash test/bye.sh
bash test/up.sh
bash test/mint.sh <repo>   # setup.sh entero en un contenedor de Linux Mint (Docker)
```
