# Config Sync

An Omarchy shell plugin that finds every application on the machine that keeps
config in your home directory, and syncs the ones you choose across machines.

- **Detect** — walks `~/.config`, the usual shell/editor dotfiles, and Omarchy's
  own settings, then lists them with a switch each.
- **Choose a backend per item** — small configs go through a **git repo**;
  large or personal trees go through **rsync** to a **Google Drive** folder.
- **Watched** — one switch starts Omarchy's own `rsw` watcher per path, so a
  local edit is copied across the moment it lands, with a periodic full pass for
  the changes made on other machines.
- **Nothing is lost** — a file edited on two machines keeps **both** versions, a
  file removed on one machine is only removed elsewhere when nothing changed
  there, and it goes to a **trash folder** you can restore from.
- **Secrets stay put** — credentials, keys and sessions are never detected, and
  browser/editor profiles start switched off.

It is a bar widget plus a headless service, backed by a scriptable CLI.

## Install

```bash
omarchy plugin validate ~/.config/omarchy/plugins/omarchy-configsync-plugin
omarchy plugin add ~/.config/omarchy/plugins/omarchy-configsync-plugin --enable bar-widget
```

`omarchy plugin add` validates the manifest the same way. The watcher needs two
small packages, and the backends need their tools:

```bash
sudo pacman -S --needed rsync inotify-tools git python
```

Then set the two backends once (`configsync set-backend ...`, below) and press
**Sync now**.

## The panel

`Super+Space` → search "Config Sync", or click the sync icon on the bar.

```
┌ ⣿  CONFIG SYNC           ⟳ Sync now  ⋯ ┐
│   47 items · 35 syncing               │
│ Git github.com:you/dotfiles · Drive … │
│ ( Items · 47 ) ( Repos · 12 )         │
│ ⬒ Alacritty  ~/.config/alacritty      │
│      [Git][Drive]  ✕          [ on ]  │
│ ⚠ Chromium  Browser profile           │
│                        ✕     [ off ]  │
│ …                                     │
│ 4 sent · 1 received · 2 conflict c…   │
│ Watch for changes              [ on ] │
└───────────────────────────────────────┘
```

Everything that can sync is one list, enabled items first. Each row has a tile,
the name and path, a **Git/Drive** picker, a remove `✕`, and the on/off switch.
The switch decides whether the item syncs at all; the picker only decides where:

| Target | What happens |
|--------|--------------|
| **Git** | Versioned in a git working tree; pushed and pulled across machines |
| **Drive** | Mirrored with `rsync` into your Drive folder, reconciled both ways |

The `✕` removes a row: a folder you added is deleted outright, and a detected
app is remembered as hidden so the next scan does not put it straight back
(**Reset plugin** in the `⋯` menu brings everything back).

The `⋯` menu holds the rare actions: **Rescan apps**, **Reinstall software**
(shows the plan before anything is installed) and **Reset plugin** (press twice).
The backend fields collapse to one dim line once both are set, and expand when
you press **Backends**.

### What is not in the GUI

Deliberate, because each one is a way to lose work by pressing the wrong thing:

- **Download / Deploy** are still available as `configsync download` and
  `configsync deploy`, but they are not buttons. `sync` already does both sides
  in the right order.
- **Turning deletion propagation on** is
  `configsync set-backend gdrive delete true`. It is a preference about how
  destructive the tool may be, not an everyday action, and it is off by default.
- **Emptying the trash** is `configsync trash empty`.

## The watcher

One switch, in the panel footer. It does two things, and the first one is
Omarchy's own:

**The change watchers are rsw watchers.** Omarchy ships `rsw <source>
<destination>` (`omarchy.org/manual/shell-functions`): a detached `inotifywait`
+ `rsync -a` loop, listed by **`lsw`** and stopped by **`dsw`**. The plugin
starts one per enabled path — local folder to its backend — so:

```bash
lsw                 # the same list, from your shell
configsync watch    # pid: source -> destination, and which ones are ours
```

Same process, same marker, same events, same one-way `rsync -a` — so `dsw` stops
our watchers like any other, they survive the shell exiting, and anyone who knows
`rsw` already knows what this does. One difference, and it is deliberate: `rsw`
takes two arguments and no flags, so its `rsync` has **no exclusions at all**.
The watcher the plugin starts runs the same loop with the same `--exclude`
patterns the scan uses, because otherwise a browser cache, a `node_modules`
tree or a `credentials` file would ride the fast path into your Drive folder.
(The `rsync` line is the only difference; see `fresh_loop()` in the CLI.)

The watcher only ever copies **local to backend**, and its rsync has no
`--delete`, so it can add or update a file but it can never remove one, on
either side. Removals wait for the three-way pass below, which knows whether the
other side changed.

**The full pass is `configsync watch --once`**, run by a systemd user timer
(`configsync-watch.timer`: 45s after login, every `pull` minutes — 10 by
default — and once more a minute after you switch watching on). That pass is
what pulls changes made on other machines (inotify cannot see those), folds
what the watchers copied into the store into the single rolling commit, pushes
it, and propagates deletions. With no systemd user session, `Service.qml` runs the same command on
a Qt timer instead, and starts the watchers when the shell comes up.

```bash
configsync watch                 # what is watching, and the switch state
configsync watch --on | --off    # the panel's switch
configsync watch --ensure        # start what is missing, stop what is stale
configsync watch --stop          # stop ours only
configsync watch --stop --all    # stop every watcher, like dsw
configsync watch --once          # one full pass (what the timer runs)
configsync watch --status        # JSON: watchers, timer, last pass
configsync service status        # is the timer installed, enabled, active
configsync service install       # write and start the timer units
configsync service uninstall
```

The switch is one command in either direction, so a stale watcher is easy to
fix: the panel's `⋯` menu has **Re-arm watchers**, which is `watch --ensure`.

## What happens when both machines change the same file

The reconciler compares three things per file: your copy, the backend's copy, and
a **baseline** recorded after the last successful pass. That is what makes
"changed here" and "changed there" distinguishable rather than guessed at:

| Local | Backend | Result |
|-------|---------|--------|
| changed | untouched | pushed |
| untouched | changed | pulled |
| changed | changed | **both kept**: your copy stays in place, the backend's version is written next to it as `name.conflict-<host>-<date>` and pushed, so the other machine can see what it lost |
| removed | untouched | removed from the backend too — into the trash, not unlinked |
| removed | changed | **not** propagated; the backend's version stays |
| new | — | pushed |
| — | new | pulled |

Removals only ever move a file into
`~/.local/share/omarchy-configsync/trash/`, and `configsync trash list`,
`trash restore` and `trash empty` work on it. Restoring never overwrites a file
that reappeared in the meantime; it keeps both.

The first sync on a machine with no baseline is the one case with no history to
compare against: the backend holds the setup being restored, so it wins, and
every local file that differed is kept under
`~/.local/share/omarchy-configsync/conflicts/first-sync-<date>/`. Run it with
`--dry-run` first, or `--prefer local` to push instead of pull.

## Snapshots

The branch keeps one commit, so the only history worth keeping is what you name
yourself. A snapshot is a tag: an immutable point the squash can never rewrite,
pushed to the remote so any machine can see it.

```bash
configsync snapshot create before-theme-change   # name it what you like
configsync snapshot list                         # latest + your snapshots, timestamped
configsync snapshot rename before-theme-change old-theme
configsync snapshot resume old-theme             # back to that point, this machine
configsync snapshot resume old-theme --dry-run   # say what would move first
configsync snapshot drop old-theme
```

`snapshot list` shows exactly two kinds of entry: **latest** (the rolling commit,
with its timestamp) and the snapshots you named. A resume tags the state it is
leaving as `pre-resume-<name>-<timestamp>` before it moves anything, so the point
you were on is a named, pushed point rather than a reflog entry — `snapshot list
--all` shows those automatic tags too.

A resume is a local operation with a fleet-wide effect, and it says so: the
snapshot's content is written over this machine's files, anything the snapshot
does not have is removed, and every local file that is replaced or removed is
moved to the trash first, so a resume you regret is still a resume you can undo
with `configsync trash restore`. The restored state is then published like any
other change, so your other machines pick it up on their next pass — keeping
their own unsynced edits as conflict copies, exactly as they would for any
two-sided change. Drive items are not part of a resume: a Drive folder has no
history to go back to, so only git items move.

## Requirements and limits

- **Backends are not authenticated by this plugin.** The Drive backend assumes
  the folder is already mounted or synced locally (`rclone`, a Drive client, a
  systemd mount). The git backend assumes you can already push to the remote.
- **Fingerprints are size + timestamp**, like rsync's default check. When a file
  is the same size and the timestamps cannot settle it, the two sides are
  compared by content before anything is called "identical" — but a file edited
  on one machine, with its timestamps faked back, is invisible to any tool that
  does not read every file on every pass. `configsync sync --dry-run` reports
  what would move.
- **Git is transport, not the decision maker.** The store is a checkout of the
  remote; every pass fetches, sets the store to what the remote holds, lets the
  reconciler decide every file, then rewrites the branch's single commit and
  pushes it with `--force-with-lease`. Nothing is ever merged by git, so a
  two-sided edit behaves the same here as it does on a Drive folder: both
  versions are kept, and the pass never stops with a git conflict.
- **The branch holds one commit, always.** `git log` is a single line, and the
  snapshot tags are the only points that are never rewritten. Anything you
  cloned or committed to that remote by hand is overwritten by the next pass —
  this remote is the plugin's, not a general-purpose one.
- **The Drive backend tolerates timestamp rounding** (2 seconds), because FUSE
  and network mounts round them. A same-size edit is then noticed as soon as the
  stamp drifts past that window, not lost.
- **A watcher copies; it never deletes.** That is rsw's `rsync -a` with no
  `--delete`, and it is deliberate: a removal here has to be checked against the
  other side first, so removals only ever happen in a full pass.
- **The fast path is rsync's quick check** — size, and a timestamp compared in
  whole seconds — exactly like rsw. A file edited to the *same size* inside the
  *same second* as the last copy therefore does not travel on the fast path; the
  next full pass compares nanoseconds and, when needed, content, so it is carried
  then. Anything else (a new file, a normal save) goes across in the moment.
- **The watcher syncs once, then watches.** Those are two steps, so a write that
  lands in the moment between them is not seen until the next change — or the
  next full pass, which is never more than `pull` minutes away. Deleting a
  watched folder makes inotifywait exit; `watch --ensure` (the `⋯` menu, or the
  timer's `ExecStartPre`) starts it again.
- **inotify watches are per-path, not free.** Watching a very large tree can
  exceed `fs.inotify.max_user_watches`; inotifywait then reports the error and
  the watcher stops, and the slow pass becomes the only sync until you re-arm it.
  Omarchy already raises that limit in `etc/sysctl.d/90-omarchy-file-watchers.conf`.
- **Nothing is encrypted by this plugin.** Your configs go to your git host and
  your Drive folder, where they are readable by whoever can read those. Use a
  private repository.

## Plugins and software

Every `sync` also writes a **software manifest** — the third-party Omarchy
plugins you have (with their git source) and the packages you installed on top of
Arch — to `~/.config/omarchy/configsync/software.json`, which travels with the
rest of the config.

Reinstalling is always shown as a **plan first**, in the panel and on the CLI:

```bash
configsync install-software           # print what is missing
configsync install-software --yes     # do it
```

- **Plugins** are cloned from their recorded git URL with
  `omarchy plugin add <url> --yes --enable`.
- **Packages** are diffed against what is installed and added with
  `omarchy pkg add` / `omarchy pkg aur add`, which opens a terminal because it
  needs a password.

The manifest is data that came off another machine, so names are validated
against a strict pattern before use (a plugin source may not start with `-`, a
package name may not contain `;`, `$`, spaces or a slash) and anything odd is
listed as refused instead of passed to a shell.

## CLI

Everything the panel does is a command, so it works over SSH too:

```bash
configsync scan                        # detect apps and folders, merge into state
configsync state                       # whole state as JSON
configsync status                      # last sync result, notes and conflict paths
configsync set-enabled <id> true|false
configsync set-target  <id> git|gdrive|none
configsync set-secrets <id> true|false
configsync sync [--only git|gdrive] [--dry-run] [--prefer local|remote] [id ...]
configsync watch [--on|--off|--ensure|--stop [--all]|--once|--status]
configsync service status|install|uninstall
configsync add <path> [--name N] [--target git|gdrive]
configsync remove <id>                 # delete a custom path, or hide a detected one
configsync trash list|restore|restore-all|empty
configsync capture-software            # record plugins + packages into the manifest
configsync install-software [--plan|--yes]
configsync repos                       # list git repositories on the machine
configsync reset [--purge]             # reset state (--purge also deletes local repos)
```

`id` is the item key shown in `configsync state` (e.g. `ghostty`, `bashrc`,
`hyprland`, `personal-Pictures`, `custom-Documents-notes`).

Unrecognised flags are an error, not something ignored: `configsync --delete`
stops with a message pointing at the replacement.

### Keyboard

While the popup is focused: **Page Up / Page Down** scroll the list,
**Up/Down** scroll a little, **Home/End** jump to the ends, and **Tab** flips
between the Items and Repos tabs. **Escape** closes.

## Repositories

The **Repos** tab is a read-only inventory of the git repositories on the
machine: every clone under `$HOME` (including the Omarchy plugin checkouts and
the sync backend itself), with its branch, whether it has uncommitted changes,
how far ahead/behind its upstream it is, and its origin URL.

Scanning is depth-limited and skips caches, `node_modules`, app profiles, and any
mounted filesystem (so the Google Drive mount is never walked). It takes well
under a second. **Refresh** rescans; it also runs when the tab is opened.

## Files

| Path | Purpose |
|------|---------|
| `BarWidget.qml` | The bar button; loads the popup and forwards open/close |
| `Panel.qml` | The popup: header, backends, tabs, list, footer |
| `panel/AppCell.qml` | One row in the item list |
| `panel/RepoCell.qml` | One row in the repos list |
| `panel/Presentation.js` | Tile colours and backend labels |
| `Service.qml` | The no-systemd fallback: starts the watchers, runs the pass |
| `bin/configsync` | The CLI: reconciler, watcher, service, software manifest |
| `tests/test_configsync.py` | End-to-end tests over two fake machines |
| `docs/SAFETY.md` | What the plugin is allowed to touch, and why |

| Runtime state | Purpose |
|---------------|---------|
| `~/.config/omarchy/configsync.json` | Which items sync, where, and the last result |
| `~/.config/omarchy/configsync/software.json` | Plugin + package manifest, synced with the config |
| `~/.local/share/omarchy-configsync/git/` | The git backend working tree |
| `~/.local/share/omarchy-configsync/baseline/` | Per-pair fingerprints from the last pass |
| `~/.local/share/omarchy-configsync/trash/` | Files a sync removed, with an index |
| `~/.local/share/omarchy-configsync/conflicts/` | Local copies a first sync kept aside |

## Tests

```bash
python3 -m unittest discover -s tests -v
```

They build two throwaway machines with their own `$HOME`, a bare git remote and
a folder standing in for a Drive mount, then drive the real CLI as a subprocess:
first sync, both-sides edits, deletions, trash restore, secret skipping,
symlinked folders, the software-plan validation, and the watcher actually
pushing a file it noticed.

## Upgrading from 0.1.0

Run `configsync scan` once. The interval **Auto sync** setting is migrated to the
watcher's switch (which now starts Omarchy's `rsw` watchers and enables the pass
timer), the old `watch debounce` setting is gone — the watcher is rsw, which has
no debounce — and the old flag forms (`sync --download`, `set-gdrive`, `set-git`,
`set-auto`, `panel-state`, `--delete`, …) were replaced by the subcommands above;
using one prints the replacement.
