# Safety review

What this plugin is allowed to touch, what was wrong with the previous version,
what the current code guarantees, and what is still out of scope.

The review covered `bin/configsync` (the engine) and the two QML entry points,
against the two things that can go wrong with a sync tool: **losing a file** and
**trusting something that came from another machine**.

## 1. What it touches

- Files under `$HOME`, only the paths that are enabled, plus the two backends:
  the git working tree in `~/.local/share/omarchy-configsync/git/` and the Drive
  folder you configured.
- `git`, `rsync`, `inotifywait` (optional), `systemctl --user` (optional),
  `pacman`/`omarchy` (read-only, to record what is installed).
- It writes exactly four things of its own:
  `~/.config/omarchy/configsync.json` (settings and last result),
  `~/.config/omarchy/configsync/software.json` (the plugin/package manifest,
  which is meant to travel), the baseline and state files under
  `~/.local/share/omarchy-configsync/`, and, when you ask it to, the two systemd
  user units for the periodic pass. It also starts `rsw`-style watcher processes,
  which are ordinary child processes of your session.

It never runs as root, never edits files outside those paths, never installs
anything without showing the plan first, and never unlinks a file: removals go
to `~/.local/share/omarchy-configsync/trash/`.

## 2. What was wrong in 0.1.0

Each item is something the previous engine did, with the evidence that it did.
Severities are about the user's files, not about the shell.

### 2.1 Deletions destroyed the other machine's work — High

The Drive backend ran, per path:

```
rsync -a --mkpath --delete --update  <local>/ <drive>/     # push newer
rsync -a --mkpath --update           <drive>/ <local>/     # pull newer
```

`--delete` removes files that exist on the destination only, and `--update` does
not protect them. A file created on the *other* machine — the exact thing a sync
tool exists to protect — was deleted from the Drive folder by the next sync here,
and then it existed nowhere.

Verified with `/tmp/proof.sh` (old engine, `delete` propagation on):

```
--- OLD backend (rsync --delete --update, delete propagation on) ---
Google Drive: 1 path(s) reconciled
backend copy after sync:
    mine.txt                    <- theirs.txt, created on the other machine, is gone
--- NEW backend (three-way reconcile, deletion propagation on) ---
2 received · 1 conflict copy(ies)
backend copy after sync:
    mine.txt
    theirs.txt                  <- kept
```

**Now:** a deletion is only propagated when the other side is unchanged since the
last pass, and it moves the file to the trash instead of unlinking it.

### 2.2 A two-sided edit silently lost one version — High

There was no record of what either side had looked like, so "newer" was decided
by mtime alone (`--update`). When both machines edited the same file, the older
version was simply overwritten in both places, with nothing kept anywhere.
A clock that is off by a few minutes — normal between machines — decides which
of the two edits survives.

**Now:** a baseline of fingerprints per pair makes "changed here" and "changed
there" distinguishable. If both changed, the local copy stays in place, the
other version is written next to it as `name.conflict-<host>-<date>` and pushed,
so both machines end up holding both versions.

### 2.3 A fresh machine could not restore itself — High (flow), no data loss

The git backend committed the local snapshot **before** fetching the remote.
On a fresh machine that means the empty local store commits the *distro default*
config, and the rebase that follows conflicts with the real config already in
the repository:

```
$ configsync sync            # on a fresh machine, old engine
conflict with the remote — the same file changed on both sides.
Resolve it in the git backend repo and sync again.
$ configsync download
git: downloaded latest; drive: no folder set
$ configsync deploy
deployed 1 path(s)
```

The one action a user would press does not restore anything, and the message
asks them to resolve a git conflict by hand inside an internal working tree.
The restore only worked if they knew to run `download` and then `deploy`.

**Now:** the backend is fetched and *reset* — no merge, no rebase — and then
every file is compared three ways. On a machine with no baseline the backend wins
(it is the setup being restored) and each differing local file is preserved under
`~/.local/share/omarchy-configsync/conflicts/first-sync-<date>/`. One `Sync now`
restores a fresh machine; `--prefer local` inverts the direction deliberately.
The store is a checkout of the remote, so there is no state in it that a pass
could conflict with, and no git error the user has to resolve by hand.

### 2.4 The software manifest was trusted input — High

`install-software` read the manifest that arrived through the sync backend and
passed its contents to package managers:

```python
args = ["omarchy", "plugin", "add", source, "--yes"]      # source: unvalidated
script = "omarchy pkg add " + " ".join(shlex.quote(p) for p in native)
```

Package names were shell-quoted, so a `;` could not start a new command — but
nothing stopped a *name* from being an option. A manifest entry of
`--config=/tmp/pacman.conf`, `-Sy` or `--overwrite=...` is passed straight to
`pacman`, and a plugin `source` starting with `-` is passed to `omarchy plugin
add` the same way. Because the manifest travels with the config, whoever can
write to your git remote or your Drive folder could get code of their choosing
installed on your other machines, and the old panel installed it on a single
click with no plan shown.

**Now:** names are validated strictly (package names must match
`^[a-z0-9@._+-]+$`, no leading `-`; plugin sources must be a URL or a plain
`owner/repo`), refused entries are listed instead of used, everything is shown as
a plan first, and nothing is installed without an explicit confirmation
(`--yes` on the CLI, the **Install** button after the plan in the panel).

### 2.5 Machine-local state was synced through the file it configures — Medium

`~/.config/omarchy` is one of the detected apps, and `configsync.json` — which
holds *this* machine's backend remotes, toggles and last result — was inside it.
One `download` was enough to land another machine's state file here, silently
repointing the Drive folder and re-enabling items.

**Now:** `configsync.json` is excluded from that pair while
`~/.config/omarchy/configsync/software.json` is deliberately kept in, since the
manifest is meant to travel. A test asserts both halves.

### 2.6 A path could be added that contains the sync store — Medium

`configsync add ~/.local/share` was accepted, which puts the git working tree
inside a tree that is copied into it. Every pass then copied the store into
itself, and the growth is only bounded by the disk.

**Now:** paths that contain the store, the trash, the conflicts or the baseline
directory are refused, as are duplicates and secret trees.

### 2.7 Transfers were reported that never happened — Medium

rsync's "quick check" compares timestamps **to whole seconds**, while the change
detection used different information. An edit that kept the file size and landed
in the same second as the last sync was listed, counted, and never copied: the
panel said `1 sent` while the other side kept the old bytes.

**Now:** the reconciler decides what to copy and passes `--ignore-times`, so the
decision is ours and the copy always happens. A test saves a same-size edit in
the same second and asserts the bytes arrived.

### 2.8 The trash index remembered the wrong path — Medium

Entries stored the path relative to the *synced pair*, while restore wrote to
`$HOME` + that path. A deleted `~/Documents/notes.txt` would have been restored
as `~/notes.txt`. Restoring also `rmtree`d the whole trash directory, deleting
every other entry.

**Now:** entries record the real absolute path, restore moves the file back
exactly where it was (and never overwrites a file that reappeared — it keeps
both), and only the emptied directories are pruned.

## 3. Hardening that is not a bug fix

- **Symlinked paths are resolved before copying**, so a link that points outside
  `$HOME` cannot end up as a link inside your Drive folder (and `--delete` can
  never be aimed at whatever it points to). `configsync add` still refuses paths
  outside the home directory.
- **Secrets are refused twice**: they are not detected, and the copy step skips
  them by path (`.ssh`, `.gnupg`, `.aws`, `.docker`, `.netrc`, `credentials`,
  `*.key`, …) even when a whole folder is enabled. `configsync set-secrets <id>
  true` is the explicit override.
- **State writes are atomic** (temp file + rename) and keep a `.bak`, so an
  interrupted write cannot leave a truncated config.
- **A lock file serialises runs**, so a watcher, a manual sync and the panel's
  button cannot interleave and see half-written state.
- **Paths that no longer exist are skipped, not treated as emptied**, so a path
  on an unmounted disk cannot look like "everything was deleted".

- **The change watcher is an rsw watcher, not a daemon of ours.** One
  `inotifywait` + `rsync -a` loop per enabled path, in the shape Omarchy documents
  in `omarchy.org/manual/shell-functions`: detached, marked `rsw-watch`, same
  events, so it shows up in `lsw` and stops under `dsw`. It goes **one way only**
  (local to backend) and its `rsync` has no `--delete`, so it can never delete
  anything on either side; a removal here waits for the three-way pass, where it
  can be checked against the other side.
- **The watcher's copy carries the same exclusions as the pass.** `rsw` itself
  takes exactly two arguments, so its `rsync` cannot be given `--exclude`, and a
  verbatim copy would put caches, logs, `node_modules`, `.git` directories and
  secret files into the backend — including the plugin's own machine-local
  `configsync.json`. The loop is therefore the same except for the `--exclude`
  arguments, built from the same pattern list the scan uses (`EXCLUDES` +
  `SECRET_FILES`, minus the secret list for an item explicitly allowed to carry
  secrets). `test_watcher_honours_the_exclusion_rules` holds that line.
- **The fast path is allowed to be approximate; the pass is not.** rsync's quick
  check is size + whole-second timestamp, so a same-size edit inside the same
  second waits for the next pass — which compares nanoseconds, and content when
  the stamps cannot settle it, before deciding anything. That is the same
  division of labour as rsw, and `test_the_pass_catches_what_the_fast_path_can_miss`
  proves the net is under it.
- **`watch --stop` stops only our own watchers.** Ownership is decided by the
  source path being one this plugin manages, read from the process table rather
  than from anything we wrote down, so a watcher someone started for their own
  work (`rsw ~/Work/app nyc-dev:Work/app`) is left alone. `--stop --all` is the
  `dsw` behaviour: every watcher on the machine, and it says so.
- **A watcher that dies is not silent.** `watch --ensure` — run by the pass
  timer, by the panel's `⋯` menu, and by the shell service at login — restarts a
  missing watcher and stops a stale one: one whose item was switched off or whose
  backend moved. Status is read live from the process table, so the panel reports
  what is actually running instead of what was last written down.

## 4. Still true, by design

- **Timestamps are trusted** for the fast path (size + mtime), like rsync's
  default check. When the size matches and the timestamps cannot settle it, the
  two sides are hashed and compared before anything is called identical — but a
  file edited on one machine with its timestamps faked back is invisible to any
  tool that does not read every byte on every pass. `sync --dry-run` reports what
  would move, without moving it.
- **The plugin does not encrypt anything.** Configs go to your git host and your
  Drive folder, where anyone with access there can read them. Use a private
  repository, and know that the Drive backend inherits Drive's own sharing.
- **The manifest is still an instruction to install software.** It is now
  validated and confirmed, but if you restore a machine from a backend that
  someone else controls, you are choosing to install what is in it. The plan
  screen exists so that choice is visible.
- **FUSE and network mounts round timestamps**, so the Drive backend allows a
  2-second difference before calling a remote file changed. A change is caught
  as soon as the stamp drifts past that window, not lost.
- **The timer and the watchers run as your user**, with the same access as your
  shell. The timer is `configsync watch --once` with no extra privilege, and its
  only job is to survive a shell restart; the watchers are the same `rsw`
  processes you would get by running `rsw` yourself.
- **Nothing here defends against a hostile plugin manifest in your own plugin
  directory.** Omarchy plugins run unsandboxed inside the shell; that is the
  platform's design, not something this plugin can fix.

## 5. Verifying it

```bash
python3 -m unittest discover -s tests -v     # 23 end-to-end tests
configsync sync --dry-run                    # what would move, changes nothing
configsync status                            # last result, notes, conflict paths
configsync trash list                        # what a sync removed, if anything
```

The test suite builds two throwaway machines with their own `$HOME`, a bare git
remote and a folder standing in for a Drive mount, and drives the real CLI as a
subprocess. The cases covering this document are the ones named
`test_backend_only_file_is_pulled_not_deleted`,
`test_deletion_does_not_propagate_when_off`,
`test_both_sides_edit_keeps_both_versions`,
`test_second_machine_pulls_instead_of_clobbering`,
`test_dry_run_writes_no_state`, `test_same_size_edit_in_the_same_second_is_copied`,
`test_restore_never_clobbers_a_newer_file`,
`test_machine_state_file_is_not_synced`, `test_manifest_package_names_are_validated`,
`test_add_refuses_the_store_and_secret_paths`, `test_watcher_pushes_local_edits`,
`test_watch_is_idempotent_and_stops_only_ours`,
`test_watcher_honours_the_exclusion_rules`,
`test_the_pass_catches_what_the_fast_path_can_miss` and
`test_a_watcher_push_is_committed_by_the_next_pass`.
