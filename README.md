# Config Sync

An Omarchy shell plugin that finds every application on the machine that keeps
config in your home directory, and syncs the ones you choose across machines.

- **Detect** — walks `~/.config`, the usual shell/editor dotfiles, and Omarchy's
  own settings, then lists them with a switch each.
- **Choose a backend per app** — small configs go through a **git repo**;
  large or personal trees go through **rsync** to a **Google Drive** folder.
- **Automatic** — turn on Auto and the background service syncs on an interval
  and once shortly after login.
- **Safe by default** — credentials, keys, sessions and caches are never
  detected, and browser/editor profiles start switched off.

It is a bar widget plus a headless service, backed by a scriptable CLI.

## The panel

`Super+Space` → search "Config Sync", or click the sync icon on the bar.

The popup imitates Omaplug's layout: a title header with the item count, the two
backend fields, then **two subtabs** — **Apps** and **Folders** — each a
single-column list of compact cards. Every card has a colour tile, the name and
path, a **Git/Drive** picker, a remove `✕`, and the on/off switch. Splitting the
two keeps configs out of the way when you are managing personal folders, and
vice versa.

```
┌ ⣿  CONFIG SYNC             ⟳  Reset ┐
│   47 items · 35 syncing             │
│ [Download] [Deploy] [Sync now]      │
│ GIT REPO           DRIVE FOLDER     │
│ [git@github.com…] [~/Drive/…     ]  │
│ ( Apps · 46 ) ( Folders · 1 )       │
│ ⬒ Alacritty  ~/.config/alacritty    │
│      [Git][Drive]  ✕          [ on ]│
│ ⚠ Chromium  Browser profile         │
│                        ✕     [ off ]│
│ …                                   │
│ git: 33 up to date           Auto[ ]│
└─────────────────────────────────────┘
```

The **switch** decides whether an item syncs at all — turning sync off is the
switch, never a cycling button. The **Git/Drive picker** next to it only chooses
where:

| Target | What happens |
|--------|--------------|
| **Git** | Versioned in a git working tree; push/pull across machines |
| **Drive** | Mirrored with `rsync` into your Drive folder; newer file wins |

The `✕` removes a row: a folder you added is deleted outright, and a detected
app is remembered as hidden so the next scan does not put it straight back
(the **Reset** button brings everything back).

The header **⟳** rescans, the **package** button reinstalls your plugins and
packages (see below), **Reset** clears toggles and settings (click twice), and
the actions are **Download** (pull the backends into the local store),
**Deploy** (write the store into `$HOME`), and **Sync now** (capture, push and
apply). The Folders tab has a field to **add your own folder or file**.



## What gets detected

- **App configs** — every directory under `~/.config` that holds user config.
- **Home dotfiles** — `.bashrc`, `.zshrc`, `.profile`, `.gitconfig`,
  `.tmux.conf`, `.XCompose`, `.inputrc`, `.vimrc` and friends.
- **Omarchy settings** — `~/.config/hypr` and `~/.config/omarchy`
  (`shell.json`, extensions, hooks, themes, branding; `plugins/` is skipped
  because those are git-managed already).
- **Personal folders** — `Documents`, `Pictures`, `Music`, `Videos`, `Desktop`
  and `Downloads` (the non-empty ones). These are not config, so they default
  to the **Google Drive** backend, on, and live on the Folders tab.

### What is deliberately left out

- **Secrets** — `.ssh`, `.gnupg`, `.netrc`, `.config/gh`, `.config/gcloud`,
  Bitwarden, keyrings, `.aws`, `.docker`, `~/.config/pulse`, and more. These are
  never even listed.
- **Machine state** — `systemd`, `dconf`, `procps`, caches, logs, lock files,
  `plugins/`, `node_modules`.
- **Risky profiles start off** — browsers, VS Code, Obsidian, Proton, opencode
  are detected and flagged with `⚠`, but their switch begins off, because they
  hold cookies, sessions or tokens that a fresh machine is not really
  "restoring".

## Backends in detail

### Git repo

The repo is a normal working tree at
`~/.local/share/omarchy-configsync/git/`, whose `home/` subtree mirrors `$HOME`.
A sync:

1. copies each enabled app's paths into `home/` (with the standard excludes),
2. commits,
3. fetches and rebases onto the remote branch,
4. pushes,
5. copies the merged result back into `$HOME`.

If the same file changed on two machines, the rebase stops and the panel shows
an error; resolve it in the repo and sync again. Running the sync on the other
machine first — or committing there and syncing here — avoids the clash.

Set the remote once:

```bash
configsync set-backend git remote git@github.com:you/dotfiles.git
configsync set-backend git branch main
```

### Google Drive

Set the folder your Drive client mounts or syncs:

```bash
configsync set-backend gdrive remote ~/Drive/omarchy-configsync
```

Each path is reconciled both ways with `rsync -a --update`, so the newer copy
wins. Turn on deletion propagation with
`configsync set-backend gdrive delete true` if you want removed files removed
remotely too (off by default, because it is destructive).

## Auto sync

The **Auto sync** switch in the panel footer, or:

```bash
configsync set-backend auto enabled true
configsync set-backend auto interval 30      # minutes
```

When Auto is on, a slider appears beside the switch to set the interval
(5–180 minutes) without leaving the panel. The service watches the state file
and runs `configsync sync` on that interval, plus one catch-up sync ~45s after
the shell starts.

## Plugins and software

Config Sync restores more than files. Every `sync` also writes a **software
manifest** — the third-party Omarchy plugins you have (with their git source),
and the packages you installed on top of Arch — to
`~/.config/omarchy/configsync/software.json`, which travels with the rest of
the config.

On a fresh machine, the **package** button (or `configsync install-software`)
puts them back:

- **Plugins** clone straight from their recorded git URL with
  `omarchy plugin add <url> --yes --enable` — the ones you had enabled come back
  enabled.
- **Packages** are diffed against what's installed, and the missing ones are
  installed with `omarchy pkg add` / `omarchy pkg aur add`. This needs a
  password, so it opens a terminal to run in.

So a new machine is: install the plugin → set both backends → **Download** →
**Deploy** → **install software**.


## CLI

Everything the panel does is a command, so it works over SSH too:

```bash
configsync scan                      # detect apps and folders, merge into state
configsync state                     # whole state as JSON
configsync status                    # last sync result
configsync set-enabled <id> true|false
configsync set-target  <id> git|gdrive|none
configsync set-all true|false
configsync sync [--only git|gdrive] [--dry-run] [id ...]
configsync download                  # pull the backends into the local store
configsync deploy                    # write the local store into $HOME
configsync add <path> [--name N] [--target git|gdrive]
configsync remove <id>               # delete a custom path, or hide a detected one
configsync capture-software          # record plugins + packages into the manifest
configsync install-software          # reinstall missing plugins + packages
configsync reset [--purge]           # reset state (--purge also deletes local repos)
```

`id` is the item key shown in `configsync state` (e.g. `ghostty`, `bashrc`,
`hyprland`, `personal-Pictures`, `custom-Documents-notes`).

### Keyboard

While the popup is focused: **Page Up / Page Down** scroll the list,
**Up/Down** scroll a little, **Home/End** jump to the ends, and **Tab** flips
between the Apps and Folders subtabs. **Escape** closes.

## Files

| Path | Purpose |
|------|---------|
| `BarWidget.qml` | The bar button; loads the popup and forwards open/close |
| `Panel.qml` | The popup: header, backend fields, subtabs, list, footer |
| `panel/AppCell.qml` | One row in the list |
| `panel/Presentation.js` | Tile colours and backend labels |
| `Service.qml` | Background Auto sync |
| `bin/configsync` | The CLI and the sync engines |
| `~/.config/omarchy/configsync.json` | Which apps sync, where, and the last result |
| `~/.config/omarchy/configsync/software.json` | The plugin + package manifest, synced with the config |
| `~/.local/share/omarchy-configsync/git/` | The git backend working tree |

## Limits

- The git backend is "push wins with conflicts surfaced", not a full merge
  tool; a genuine two-sided edit is reported rather than guessed at.
- The Drive backend assumes the folder is already mounted/synced locally; it
  does no authenticating of its own (use `rclone`, a Drive client, or a
  systemd mount).
- Auto sync is best-effort inside the shell session; it does not run while no
  session is active.
