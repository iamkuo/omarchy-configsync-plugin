#!/usr/bin/env python3
"""End-to-end tests for configsync.

Every test builds throwaway "machines" (a fake $HOME), a bare git remote and a
folder standing in for a mounted Google Drive, then drives the real CLI as a
subprocess. Run with:

    python3 -m unittest discover -s tests -v
"""
from __future__ import annotations

import json
import fcntl
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "bin" / "configsync"
GHOSTTY = ".config/ghostty/config"
STORE_REL = ".local/share/omarchy-configsync/git/home"


def wait_for(predicate, message="", timeout=30.0, interval=0.4):
    """Spin until predicate() is true — watchers push asynchronously."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            if predicate():
                return
        except OSError:
            pass
        time.sleep(interval)
    raise AssertionError(message or "timed out waiting for the condition")


def watchers() -> list[tuple[int, str]]:
    """Every rsw watcher on the machine, the way `lsw` looks for them."""
    out = subprocess.run(["pgrep", "-af", "rsw-watch "], text=True,
                         stdout=subprocess.PIPE).stdout
    found = []
    for line in out.splitlines():
        pid, _, command = line.strip().partition(" ")
        if pid.isdigit():
            found.append((int(pid), command))
    return found


def start_foreign_watcher(source: Path, destination: Path) -> None:
    """A watcher this plugin did not start: the same shape rsw leaves behind."""
    subprocess.run(["setsid", "--fork", "env", "bash", "-c",
                    'while inotifywait -r -q -e modify,create "$1"; do :; done',
                    "rsw-watch", str(source), str(destination)],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                   check=False)


def watch_count(pid: int) -> int:
    """How many inotify watches a process holds, straight from /proc."""
    total = 0
    for fdinfo in Path(f"/proc/{pid}/fdinfo").glob("*"):
        try:
            total += fdinfo.read_text().count("inotify wd:")
        except OSError:
            continue
    return total


def wait_for_watch(source: Path, timeout=30.0) -> None:
    """Wait until inotify is really armed on `source`.

    rsw syncs once, and only then starts inotifywait — and `-r` needs a moment
    before its watches exist. A write that lands in either gap waits for the next
    event, or for the next full pass, so a test that writes the moment the process
    appears measures the gap instead of the feature. Count the watches in /proc
    and write only once they are all there.
    """
    wanted = sum(1 for _ in os.walk(source))
    deadline = time.time() + timeout
    while time.time() < deadline:
        out = subprocess.run(["pgrep", "-af", "inotifywait"], text=True,
                             stdout=subprocess.PIPE).stdout
        for line in out.splitlines():
            pid, _, command = line.strip().partition(" ")
            if not pid.isdigit() or not command.rstrip().endswith(str(source)):
                continue
            if watch_count(int(pid)) >= wanted:
                return
        time.sleep(0.2)
    raise AssertionError(f"inotify is not watching {source} yet")



class Machine:
    """A fake $HOME plus the CLI calls that act on it."""

    def __init__(self, root: Path, name: str):
        self.home = root / name
        (self.home / ".config/ghostty").mkdir(parents=True, exist_ok=True)
        (self.home / "Documents").mkdir(parents=True, exist_ok=True)
        self.env = {**os.environ, "HOME": str(self.home), "USER": "tester"}
        self.env.pop("XDG_RUNTIME_DIR", None)   # keep the systemd path honest
        # Hermetic tools: the tests must not depend on what this machine happens
        # to have installed. pacman reports nothing installed, omarchy no
        # plugins, and systemctl succeeds (only the watch tests turn systemd on).
        shim = root / "shim-bin"
        shim.mkdir(exist_ok=True)
        for tool, body in (
            ("pacman", "#!/bin/sh\nexit 0\n"),
            ("omarchy", '#!/bin/sh\n[ "$1 $2" = "plugin list" ] && echo "[]"\nexit 0\n'),
            ("systemctl", "#!/bin/sh\nexit 0\n"),
        ):
            path = shim / tool
            if not path.exists():
                path.write_text(body)
                path.chmod(0o755)
        self.env["PATH"] = str(shim) + os.pathsep + self.env.get("PATH", "")

    def write(self, rel: str, text: str) -> Path:
        path = self.home / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def read(self, rel: str) -> str:
        return (self.home / rel).read_text()

    def exists(self, rel: str) -> bool:
        return (self.home / rel).exists()

    def run(self, *args, check=True, timeout=120):
        proc = subprocess.run([sys.executable, str(SCRIPT), *args],
                              env=self.env, text=True, timeout=timeout,
                              stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if check and proc.returncode != 0:
            raise AssertionError(
                f"configsync {' '.join(args)} failed ({proc.returncode}):\n{proc.stdout}")
        return proc.stdout

    def state(self) -> dict:
        return json.loads(self.run("state"))

    def baseline_count(self) -> int:
        directory = self.home / ".local/share/omarchy-configsync/baseline"
        return len(list(directory.glob("*.json"))) if directory.exists() else 0

    def store(self, rel: str) -> Path:
        return self.home / STORE_REL / rel


class ConfigSyncTest(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="configsync-test-"))
        self.remote = self.root / "remote.git"
        subprocess.run(["git", "init", "--bare", "-q", str(self.remote)], check=True)
        self.drive = self.root / "Drive"
        self.drive.mkdir()

    def tearDown(self):
        # rsw watchers are detached, so they outlive the test unless we stop
        # them; kill every one whose paths are inside this test's temp root.
        for pid, command in watchers():
            if str(self.root) in command:
                subprocess.run(["kill", "--", f"-{pid}"], check=False)
        shutil.rmtree(self.root, ignore_errors=True)

    # -- helpers -----------------------------------------------------------
    def machine(self, name: str) -> Machine:
        return Machine(self.root, name)

    def configure(self, machine: Machine, delete=False):
        machine.run("scan")
        machine.run("set-backend", "git", "remote", str(self.remote))
        machine.run("set-backend", "gdrive", "remote", str(self.drive))
        if delete:
            machine.run("set-backend", "gdrive", "delete", "true")

    def remote_branch(self, name="main") -> str:
        proc = subprocess.run(
            ["git", "--git-dir", str(self.remote), "rev-parse", name],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        return proc.stdout.strip() if proc.returncode == 0 else ""

    def store_show(self, rel: str) -> str:
        proc = subprocess.run(
            ["git", "--git-dir", str(self.remote), "show", f"main:home/{rel}"],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        return proc.stdout if proc.returncode == 0 else ""

    def commit_count(self, machine: Machine, branch="main") -> int:
        proc = subprocess.run(["git", "-C", str(machine.store(".")), "rev-list",
                               "--count", "HEAD"], text=True, stdout=subprocess.PIPE)
        return int(proc.stdout.strip() or "0")

    def local_tip(self, machine: Machine) -> str:
        return subprocess.run(["git", "-C", str(machine.store(".")), "rev-parse", "HEAD"],
                              text=True, stdout=subprocess.PIPE).stdout.strip()

    def tags(self, machine: Machine) -> list[str]:
        out = subprocess.run(["git", "-C", str(machine.store(".")), "tag"],
                             text=True, stdout=subprocess.PIPE).stdout
        return out.split()

    def tag_content(self, machine: Machine, tag: str, rel: str) -> str:
        proc = subprocess.run(["git", "-C", str(machine.store(".")), "show",
                               f"{tag}:home/{rel}"], text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL)
        return proc.stdout

    def trash_rels(self, machine: Machine) -> list[str]:
        out = machine.run("trash", "list", "--limit", "50")
        return [line for line in out.splitlines() if '"rel"' in line]

    def conflict_copies(self, machine: Machine, rel=".config/ghostty") -> list[Path]:
        return sorted((machine.home / rel).glob("*.conflict-*"))

    # -- tests -------------------------------------------------------------
    def test_first_sync_captures_local_state(self):
        a = self.machine("a")
        a.write(GHOSTTY, "font-size = 14\n")
        a.write("Documents/notes.txt", "hello\n")
        self.configure(a)

        a.run("sync")

        self.assertTrue(self.remote_branch(), "the git backend should have a branch")
        self.assertEqual(self.store_show(GHOSTTY), "font-size = 14\n")
        self.assertEqual((self.drive / "Documents" / "notes.txt").read_text(), "hello\n")
        self.assertTrue(a.baseline_count() >= 2, "a baseline per pair")

    def test_second_machine_pulls_instead_of_clobbering(self):
        a = self.machine("a")
        a.write(GHOSTTY, "font-size = 14\n")
        a.write("Documents/notes.txt", "from a\n")
        self.configure(a)
        a.run("sync")

        b = self.machine("b")
        b.write(GHOSTTY, "font-size = 9\n")        # a fresh default, not an edit
        self.configure(b)
        b.run("sync")

        self.assertEqual(b.read(GHOSTTY), "font-size = 14\n",
                         "a fresh machine must take the backend's config")
        self.assertEqual(b.read("Documents/notes.txt"), "from a\n")
        conflicts = list((b.home / ".local/share/omarchy-configsync/conflicts").rglob("config"))
        self.assertTrue(conflicts, "the local version is kept, not dropped")
        self.assertEqual(conflicts[0].read_text(), "font-size = 9\n")

    def test_edits_travel_between_machines(self):
        a = self.machine("a")
        a.write(GHOSTTY, "one\n")
        self.configure(a)
        a.run("sync")

        b = self.machine("b")
        self.configure(b)
        b.run("sync")
        self.assertEqual(b.read(GHOSTTY), "one\n")

        b.write(GHOSTTY, "two\n")
        b.run("sync")
        self.assertEqual(self.store_show(GHOSTTY), "two\n")

        a.run("sync")
        self.assertEqual(a.read(GHOSTTY), "two\n")

    def test_last_sync_reports_each_backend_separately(self):
        a = self.machine("a")
        a.write(GHOSTTY, "one\n")
        a.write("Documents/notes.txt", "hello\n")
        self.configure(a)
        a.run("sync")

        state = a.state()
        git = state["lastSync"].get("git") or {}
        drive = state["lastSync"].get("drive") or {}
        self.assertTrue(git.get("at"), "git gets its own last-pass stamp")
        self.assertTrue(drive.get("at"), "Drive gets its own last-pass stamp")
        self.assertGreaterEqual(git.get("pushed", 0), 1)
        self.assertGreaterEqual(drive.get("pushed", 0), 1)
        self.assertIn("published", git, "the push outcome is recorded for git")
        self.assertIsInstance(state["git"]["ahead"], int)
        self.assertIsInstance(state["git"]["behind"], int)
        self.assertTrue(state["git"]["lastLog"], "the last commit time is exposed")

    def test_both_sides_edit_keeps_both_versions(self):
        a = self.machine("a")
        a.write(GHOSTTY, "one\n")
        self.configure(a)
        a.run("sync")
        b = self.machine("b")
        self.configure(b)
        b.run("sync")

        a.write(GHOSTTY, "from a\n")
        a.run("sync")
        b.write(GHOSTTY, "from b\n")
        out = b.run("sync")

        self.assertIn("conflict", out.lower())
        self.assertEqual(b.read(GHOSTTY), "from b\n", "the local edit wins in place")
        copies = list((b.home / ".config/ghostty").glob("config.conflict-*"))
        self.assertEqual(len(copies), 1)
        self.assertEqual(copies[0].read_text(), "from a\n",
                         "the other machine's version is kept")
        # The copy is a local recovery artefact: it must not travel, or every
        # conflict becomes a new file on the other machine as well.
        a.run("sync")
        self.assertEqual(list((a.home / ".config/ghostty").glob("config.conflict-*")), [],
                         "a conflict copy is never pushed to the other machine")
        self.assertEqual(list(a.store(".config/ghostty").glob("config.conflict-*")), [],
                         "a conflict copy never reaches the store")

    def test_a_file_rewritten_on_one_machine_never_conflicts(self):
        # A daemon that rewrites its own config (rclone, fcitx5, this tool's own
        # state save) used to conflict on every pass: the watcher's fast copy
        # landed in the backend, then the file changed again, so the pass read
        # its own earlier copy as a change from another machine and kept a
        # "conflicting" version of it. One machine, many passes, no conflict.
        a = self.machine("a")
        a.write(GHOSTTY, "v0\n")
        self.configure(a)
        a.run("sync")
        a.run("watch", "--on")
        for i in range(4):
            a.write(GHOSTTY, f"v{i + 1}\n")
            time.sleep(0.2)
            a.write(GHOSTTY, f"v{i + 1} again\n")
            a.run("sync")
        copies = list((a.home / ".config/ghostty").glob("config.conflict-*"))
        self.assertEqual(copies, [], "one machine's own rewrites are not a conflict")
        self.assertEqual(self.store_show(GHOSTTY), "v4 again\n")

    def test_a_conflict_copy_in_the_tree_is_never_synced(self):
        a = self.machine("a")
        a.write(GHOSTTY, "live\n")
        a.write(".config/ghostty/config.conflict-omarchy-20260101-000000", "old\n")
        self.configure(a)
        a.run("sync")
        self.assertEqual(self.store_show(".config/ghostty/config.conflict-omarchy-"
                                        "20260101-000000"), "",
                         "an existing conflict copy must not be published")
        self.assertEqual(a.store(GHOSTTY).read_text(), "live\n")

    def test_own_state_and_its_backup_never_travel(self):
        a = self.machine("a")
        a.write(".config/omarchy/configsync.json", '{"version": 3}\n')
        a.write(".config/omarchy/configsync.json.bak", '{"version": 2}\n')
        a.write(".config/omarchy/shell.json", "{}\n")
        self.configure(a)
        a.run("sync")
        self.assertFalse(a.store(".config/omarchy/configsync.json").exists())
        self.assertFalse(a.store(".config/omarchy/configsync.json.bak").exists(),
                         "the backup of our own state is just as local as the state")
        self.assertTrue(a.store(".config/omarchy/shell.json").exists())

    def test_generated_state_is_not_synced(self):
        # These are written by their app between passes, so syncing them can
        # only produce a conflict copy per pass.
        a = self.machine("a")
        a.write(".config/ibus/bus/916cc7b3-unix-0", "session\n")
        a.write(".config/ibus/config", "real config\n")
        a.write(".config/fcitx5/conf/cached_layouts", "cache\n")
        a.write(".config/fcitx5/profile", "real profile\n")
        a.write(".config/herdr/session.json", '{"tabs":[]}\n')
        a.write(".config/herdr/config.toml", "real config\n")
        self.configure(a)
        a.run("sync")
        self.assertFalse(a.store(".config/ibus/bus/916cc7b3-unix-0").exists())
        self.assertFalse(a.store(".config/fcitx5/conf/cached_layouts").exists())
        self.assertFalse(a.store(".config/herdr/session.json").exists())
        self.assertTrue(a.store(".config/ibus/config").exists())
        self.assertTrue(a.store(".config/fcitx5/profile").exists())
        self.assertTrue(a.store(".config/herdr/config.toml").exists())

    def test_conflicts_prune_keeps_the_newest_and_publishes(self):
        a = self.machine("a")
        a.write(GHOSTTY, "live\n")
        self.configure(a)
        a.run("sync")
        for stamp_text, body in (("20260101-000000", "oldest\n"),
                                 ("20260102-000000", "middle\n"),
                                 ("20260103-000000", "newest\n")):
            a.write(f".config/ghostty/config.conflict-omarchy-{stamp_text}", body)
        a.run("sync")                     # the copies are excluded, so they stay put
        self.assertEqual(len(self.conflict_copies(a)), 3)

        out = a.run("conflicts", "prune", "--keep", "1")
        self.assertIn("2", out)
        self.assertEqual([p.name for p in self.conflict_copies(a)],
                         ["config.conflict-omarchy-20260103-000000"],
                         "the newest copy per file is the one kept")
        self.assertIn("conflict", " ".join(self.trash_rels(a)),
                      "the pruned copies are recoverable from the trash")

        # A copy an older version already committed must leave the store too, or
        # it stays on the far side forever (the scan no longer sees it).
        stale = a.store(".config/ghostty") / "config.conflict-omarchy-20251231-000000"
        stale.write_text("stale\n")
        a.run("sync")                     # the pass commits what it finds in the store
        self.assertNotEqual(self.store_show(".config/ghostty/config.conflict-omarchy-"
                                           "20251231-000000"), "")
        a.run("conflicts", "prune", "--keep", "1")
        self.assertFalse(stale.exists(), "the store's copies are removed")
        self.assertEqual(self.store_show(".config/ghostty/config.conflict-omarchy-"
                                        "20251231-000000"), "",
                         "and the removal is published")

    def test_git_items_are_not_watched(self):
        # The fast copy into a git store cannot reach the other machine before a
        # pass commits it, so it buys nothing — and it hands the pass a working
        # tree it mistakes for the other machine's content.
        a = self.machine("a")
        a.write(GHOSTTY, "one\n")
        a.write("Documents/notes.txt", "hello\n")
        self.configure(a)
        a.run("watch", "--on")
        view = a.state()["watch"]
        self.assertEqual([w["source"] for w in view["watchers"]], ["~/Documents"])
        self.assertEqual(view["expected"], 1)
        a.write(GHOSTTY, "two\n")
        a.run("watch", "--once")
        self.assertEqual(self.store_show(GHOSTTY), "two\n",
                         "the pass is what carries a git item")

    def test_deletion_propagates_to_trash_and_restores(self):
        a = self.machine("a")
        a.write("Documents/notes.txt", "hello\n")
        self.configure(a, delete=True)
        a.run("sync")
        self.assertTrue((self.drive / "Documents" / "notes.txt").exists())

        (a.home / "Documents" / "notes.txt").unlink()
        a.run("sync")

        self.assertFalse((self.drive / "Documents" / "notes.txt").exists(),
                         "the deletion travels with delete propagation on")
        listing = json.loads(a.run("trash", "list"))
        self.assertEqual(len(listing), 1)
        self.assertEqual(listing[0]["path"],
                         str(self.drive / "Documents" / "notes.txt"),
                         "the deleted local file only existed in the backend by then")

        a.run("trash", "restore")
        self.assertEqual((self.drive / "Documents" / "notes.txt").read_text(), "hello\n",
                         "restoring puts it back where it was, with its contents")
        a.run("sync")
        self.assertEqual(a.read("Documents/notes.txt"), "hello\n",
                         "and the next sync brings it home again")

    def test_deletion_does_not_propagate_when_off(self):
        a = self.machine("a")
        a.write("Documents/notes.txt", "hello\n")
        self.configure(a)                    # gdrive delete defaults to off
        a.run("sync")

        (a.home / "Documents" / "notes.txt").unlink()
        out = a.run("sync")

        self.assertTrue((self.drive / "Documents" / "notes.txt").exists(),
                        "with propagation off the backend copy stays")
        self.assertIn("not propagated", out)

    def test_backend_only_file_is_pulled_not_deleted(self):
        a = self.machine("a")
        a.write("Documents/notes.txt", "local\n")
        self.configure(a, delete=True)
        a.run("sync")

        (self.drive / "Documents" / "from-laptop.txt").write_text("remote\n")
        a.run("sync")

        self.assertEqual(a.read("Documents/from-laptop.txt"), "remote\n")
        self.assertEqual(a.read("Documents/notes.txt"), "local\n")

    def test_secret_files_are_skipped_unless_allowed(self):
        a = self.machine("a")
        a.write("Documents/id_rsa", "PRIVATE\n")
        a.write("Documents/.env", "TOKEN=1\n")
        a.write("Documents/notes.txt", "fine\n")
        self.configure(a)
        a.run("sync")

        self.assertTrue((self.drive / "Documents" / "notes.txt").exists())
        self.assertFalse((self.drive / "Documents" / "id_rsa").exists())
        self.assertFalse((self.drive / "Documents" / ".env").exists())

        a.run("set-secrets", "personal-Documents", "true")
        a.run("sync")
        self.assertTrue((self.drive / "Documents" / "id_rsa").exists(),
                        "opting in copies them")

    def test_symlinked_folder_syncs_contents(self):
        a = self.machine("a")
        real = self.root / "real-documents"
        real.mkdir()
        (real / "notes.txt").write_text("through the link\n")
        shutil.rmtree(a.home / "Documents")
        (a.home / "Documents").symlink_to(real)

        self.configure(a)
        a.run("sync")

        target = self.drive / "Documents" / "notes.txt"
        self.assertTrue(target.exists(), "the linked folder's contents travel")
        self.assertFalse(target.is_symlink())

    def test_machine_state_file_is_not_synced(self):
        a = self.machine("a")
        a.write(".config/omarchy/shell.json", "{}\n")
        a.write(".config/omarchy/configsync.json", '{"version": 2}\n')
        a.write(".config/omarchy/configsync/software.json", '{"plugins": []}\n')
        self.configure(a)
        a.run("sync")

        self.assertTrue(a.store(".config/omarchy/shell.json").exists())
        self.assertTrue(a.store(".config/omarchy/configsync/software.json").exists(),
                        "the software manifest is meant to travel")
        self.assertFalse(a.store(".config/omarchy/configsync.json").exists(),
                         "machine-local state must stay local")

    def test_the_manifest_is_not_rewritten_when_nothing_changed(self):
        # The manifest travels, so a fresh `capturedAt` on every pass turned it
        # into a local edit every ten minutes — and a conflict on every pass once
        # the other machine had captured its own.
        a = self.machine("a")
        self.configure(a)
        a.run("sync")
        manifest = a.home / ".config/omarchy/configsync/software.json"
        first = manifest.read_text()
        stamp = manifest.stat().st_mtime_ns

        out = a.run("sync")
        self.assertEqual(manifest.read_text(), first,
                         "an unchanged manifest is not rewritten")
        self.assertEqual(manifest.stat().st_mtime_ns, stamp)
        self.assertIn("up to date", out, "and the pass has nothing to send")

    def test_manifest_package_names_are_validated(self):
        a = self.machine("a")
        manifest = {
            "capturedAt": "2026-01-01 00:00",
            "host": "other",
            "plugins": [{"id": "evil", "name": "evil", "source": "--upload-pack=/tmp/x",
                         "enabled": True}],
            "packages": {"native": ["firefox", "--config=/tmp/pacman.conf"],
                         "aur": ["good-pkg"]},
        }
        a.write(".config/omarchy/configsync/software.json", json.dumps(manifest))
        self.configure(a)

        plan = json.loads(a.run("install-software", "--plan"))
        names = [p["name"] for p in plan["packages"]]
        self.assertIn("firefox", names)
        self.assertNotIn("--config=/tmp/pacman.conf", names)
        self.assertEqual(plan["rejected"]["packages"], ["--config=/tmp/pacman.conf"])
        self.assertEqual(len(plan["rejected"]["plugins"]), 1)

        out = a.run("install-software", "--yes", check=False)
        self.assertIn("not valid", out)
        self.assertNotIn("would add", out)

    def test_install_software_without_yes_prints_a_plan(self):
        a = self.machine("a")
        a.write(".config/omarchy/configsync/software.json", json.dumps({
            "capturedAt": "2026-01-01 00:00", "host": "other",
            "plugins": [], "packages": {"native": ["firefox"], "aur": []}}))
        self.configure(a)
        out = a.run("install-software")
        self.assertIn("firefox", out, "no install happens without confirmation")

    def test_add_refuses_the_store_and_secret_paths(self):
        a = self.machine("a")
        self.configure(a)
        out = a.run("add", str(a.home / ".local/share"), check=False)
        self.assertIn("refusing", out)
        out = a.run("add", str(a.home / "Documents"), check=False)
        self.assertIn("already synced by", out,
                      "two items must not fight over the same path")
        out = a.run("add", str(a.home / ".ssh"), check=False)
        self.assertIn("no such file", out)          # absent here
        (a.home / ".ssh").mkdir()
        out = a.run("add", str(a.home / ".ssh"), check=False)
        self.assertIn("credentials", out)

    def test_dry_run_changes_nothing(self):
        a = self.machine("a")
        a.write("Documents/notes.txt", "hello\n")
        self.configure(a)
        a.run("sync", "--dry-run")
        self.assertFalse((self.drive / "Documents" / "notes.txt").exists())
        self.assertEqual(a.baseline_count(), 0)

    def test_dry_run_writes_no_state(self):
        a = self.machine("a")
        a.write(GHOSTTY, "one\n")
        self.configure(a)
        a.run("sync")
        baseline = a.home / ".local/share/omarchy-configsync/baseline"
        before = {p.name: p.read_text() for p in baseline.glob("*.json")}
        self.assertTrue(before)

        a.write(GHOSTTY, "two\n")
        a.run("sync", "--dry-run")

        after = {p.name: p.read_text() for p in baseline.glob("*.json")}
        self.assertEqual(before, after, "a dry run must not move the baseline")
        self.assertEqual(self.store_show(GHOSTTY), "one\n", "nor push anything")

    def test_same_size_edit_in_the_same_second_is_copied(self):
        # rsync's own quick check only compares whole seconds, so this edit used
        # to be reported as sent and then silently skipped.
        a = self.machine("a")
        a.write("Documents/notes.txt", "aaaa\n")
        self.configure(a)
        a.run("sync")

        a.write("Documents/notes.txt", "bbbb\n")
        a.run("sync")

        self.assertEqual((self.drive / "Documents" / "notes.txt").read_text(), "bbbb\n")

    def test_restore_never_clobbers_a_newer_file(self):
        a = self.machine("a")
        a.write("Documents/notes.txt", "hello\n")
        self.configure(a, delete=True)
        a.run("sync")
        (a.home / "Documents" / "notes.txt").unlink()
        a.run("sync")

        # The backend copy is in the trash; something takes its place.
        (self.drive / "Documents" / "notes.txt").write_text("newer\n")
        a.run("trash", "restore")

        self.assertEqual((self.drive / "Documents" / "notes.txt").read_text(), "newer\n")
        copies = list((self.drive / "Documents").glob("notes.conflict-*"))
        self.assertEqual(len(copies), 1)
        self.assertEqual(copies[0].read_text(), "hello\n")

    # -- the rolling commit and snapshots ----------------------------------

    def test_the_branch_keeps_exactly_one_commit(self):
        a = self.machine("a")
        a.write(GHOSTTY, "one\n")
        self.configure(a)
        a.run("sync")
        for text in ("two", "three", "four"):
            a.write(GHOSTTY, f"{text}\n")
            a.run("sync")
        self.assertEqual(self.commit_count(a), 1,
                         "every pass rewrites the one rolling commit")
        self.assertEqual(self.local_tip(a), self.remote_branch(),
                         "the remote tip is the rolling commit, force-pushed")
        self.assertEqual(self.store_show(".config/ghostty/config"), "four\n")

    def test_a_snapshot_is_a_named_tag_that_a_pass_cannot_rewrite(self):
        a = self.machine("a")
        a.write(GHOSTTY, "three\n")
        self.configure(a)
        a.run("sync")
        a.run("snapshot", "create", "before-theme-change")
        a.write(GHOSTTY, "four\n")
        a.run("sync")
        self.assertEqual(self.commit_count(a), 1)
        self.assertEqual(self.tag_content(a, "before-theme-change", ".config/ghostty/config"),
                         "three\n", "the tag keeps the point, not the rewritten commit")
        listing = a.run("snapshot", "list")
        self.assertIn("latest", listing)
        self.assertIn("before-theme-change", listing)

    def test_snapshot_names_are_validated_and_renamed_in_place(self):
        a = self.machine("a")
        a.write(GHOSTTY, "one\n")
        self.configure(a)
        a.run("sync")
        a.run("snapshot", "create", "keep-me")
        before = self.tag_content(a, "keep-me", ".config/ghostty/config")
        a.run("snapshot", "rename", "keep-me", "renamed")
        self.assertEqual(self.tags(a), ["renamed"])
        self.assertEqual(self.tag_content(a, "renamed", ".config/ghostty/config"), before)
        out = a.run("snapshot", "create", "bad name", check=False)
        self.assertIn("cannot contain spaces", out)
        out = a.run("snapshot", "create", "renamed", check=False)
        self.assertIn("already exists", out)
        a.run("snapshot", "drop", "renamed")
        self.assertEqual(self.tags(a), [])

    def test_resume_restores_the_snapshot_and_keeps_what_it_replaced(self):
        a = self.machine("a")
        a.write(GHOSTTY, "three\n")
        self.configure(a)
        a.run("sync")
        a.run("snapshot", "create", "good-state")
        a.write(GHOSTTY, "four\n")
        a.write(".config/ghostty/extra.conf", "made later\n")
        a.run("sync")
        out = a.run("snapshot", "resume", "good-state", "--yes")
        self.assertIn("pre-resume-good-state", out)
        self.assertEqual(a.read(GHOSTTY), "three\n", "the snapshot wins")
        self.assertFalse(a.exists(".config/ghostty/extra.conf"),
                         "what the snapshot does not have is removed")
        trashed = " ".join(self.trash_rels(a))
        self.assertIn('"rel": "config"', trashed)
        self.assertIn('"rel": "extra.conf"', trashed)
        self.assertEqual(self.commit_count(a), 1, "still one rolling commit")
        self.assertEqual(a.read(GHOSTTY), self.store_show(".config/ghostty/config"))
        listing = a.run("snapshot", "list")
        self.assertNotIn("pre-resume", listing,
                         "the picker shows what the user named")
        self.assertIn("pre-resume", a.run("snapshot", "list", "--all"))

    def test_a_resume_is_published_to_the_other_machine(self):
        a = self.machine("a")
        a.write(GHOSTTY, "three\n")
        self.configure(a)
        a.run("sync")
        a.run("snapshot", "create", "good-state")
        a.write(GHOSTTY, "four\n")
        a.run("sync")
        a.run("snapshot", "resume", "good-state", "--yes")
        b = self.machine("b")
        self.configure(b)
        b.run("sync")
        self.assertEqual(b.read(GHOSTTY), "three\n")

    def test_a_snapshot_from_another_machine_is_fetched(self):
        a = self.machine("a")
        a.write(GHOSTTY, "three\n")
        self.configure(a)
        a.run("sync")
        a.run("snapshot", "create", "before-theme-change")
        # The branch moves on, so the tag's commit is no longer its ancestor:
        # only an explicit tags fetch can bring it to the other machine.
        a.write(GHOSTTY, "four\n")
        a.run("sync")

        b = self.machine("b")
        self.configure(b)
        b.run("sync")
        self.assertIn("before-theme-change", self.tags(b),
                      "a pass fetches tags, not only the branch")
        self.assertEqual(
            self.tag_content(b, "before-theme-change", ".config/ghostty/config"),
            "three\n")

    def test_resume_dry_run_plans_against_the_snapshot(self):
        a = self.machine("a")
        a.write(GHOSTTY, "three\n")
        self.configure(a)
        a.run("sync")
        a.run("snapshot", "create", "good-state")
        a.write(GHOSTTY, "four\n")
        a.write(".config/ghostty/extra.conf", "made later\n")
        a.run("sync")

        out = a.run("snapshot", "resume", "good-state", "--dry-run")
        self.assertIn("would restore config", out,
                      "the snapshot's version is what would win")
        self.assertIn("would delete extra.conf", out,
                      "a file the snapshot does not have would be removed")
        self.assertEqual(a.read(GHOSTTY), "four\n", "a dry-run changes nothing")
        self.assertTrue(a.exists(".config/ghostty/extra.conf"))

    def test_an_unpublished_pass_does_not_lose_local_edits(self):
        a = self.machine("a")
        a.write(GHOSTTY, "one\n")
        a.run("scan")
        a.run("set-backend", "git", "remote", str(self.root / "not-there.git"))
        a.run("set-backend", "gdrive", "remote", str(self.drive))
        a.run("sync")
        a.write(GHOSTTY, "two\n")
        out = a.run("sync")
        self.assertEqual(a.read(GHOSTTY), "two\n",
                         "a push that never landed must not clobber the local edit")
        self.assertIn("not published", out)
        a.run("sync")
        self.assertEqual(a.read(GHOSTTY), "two\n", "and it stays put on the next pass")

    def test_a_two_sided_edit_is_a_conflict_copy_not_a_stopped_pass(self):
        a = self.machine("a")
        a.write(GHOSTTY, "font-size = 14\n")
        self.configure(a)
        a.run("sync")
        b = self.machine("b")
        self.configure(b)
        b.run("sync")
        a.write(GHOSTTY, "font-size = 16\n")
        a.run("sync")
        b.write(GHOSTTY, "font-size = 9\n")
        out = b.run("sync", check=False)
        self.assertNotIn("conflict with the remote", out,
                         "git no longer stops the pass: the reconciler decides")
        self.assertEqual(b.read(GHOSTTY), "font-size = 9\n")
        copies = list((b.home / ".config/ghostty").glob("config.conflict-*"))
        self.assertTrue(copies, "the version that lost is kept beside it")
        self.assertEqual(copies[0].read_text(), "font-size = 16\n")
        self.assertEqual(list((b.home / ".local/share/omarchy-configsync").rglob(
            "config.conflict-*")), [], "and only there: the copy is never published")
        self.assertEqual(self.commit_count(b), 1)

    def test_state_migrates_the_old_auto_switch(self):
        a = self.machine("a")
        a.write(".config/omarchy/configsync.json",
                json.dumps({"version": 1, "auto": {"enabled": True,
                                                   "intervalMinutes": 30}}))
        state = a.state()
        self.assertTrue(state["watch"]["enabled"])
        self.assertEqual(state["version"], 3)

    def test_state_file_keeps_a_backup(self):
        a = self.machine("a")
        self.configure(a)
        a.run("set-enabled", "personal-Documents", "false")
        backup = a.home / ".config/omarchy/configsync.json.bak"
        self.assertTrue(backup.exists())
        json.loads(backup.read_text())

    def test_watch_is_off_by_default_and_toggleable(self):
        a = self.machine("a")
        a.write("Documents/notes.txt", "start\n")
        self.configure(a)
        state = a.state()
        self.assertFalse(state["watch"]["enabled"])
        out = a.run("watch", "--on")
        self.assertIn("watch: on", out)
        self.assertTrue(a.state()["watch"]["enabled"])
        self.assertEqual(a.state()["watch"]["watching"],
                         a.state()["watch"]["expected"])
        self.assertIn("shell", out, "no systemd here, so the shell runs the passes")

        out = a.run("watch", "--off")
        self.assertIn("watch: off", out)
        self.assertFalse(a.state()["watch"]["enabled"])
        self.assertEqual(a.state()["watch"]["watching"], 0)

    def test_a_single_file_item_never_watches_home(self):
        # A dotfile's "base" is its parent, which for ~/.bashrc is all of $HOME.
        # Watching that, with the store under ~/.local, rsyncs the store into
        # itself until the disk is full.
        a = self.machine("a")
        a.write(".bashrc", "export X=1\n")
        self.configure(a)
        out = a.run("watch", "--on")
        view = a.state()["watch"]
        sources = [w["source"] for w in view["watchers"]]
        self.assertNotIn("~", sources, out)
        self.assertNotIn(str(a.home), sources, out)
        self.assertTrue(view["expected"] >= 1,
                        "directory items still get watched")
        self.assertEqual(view["watching"], view["expected"])

    def test_install_software_plan_answers_while_an_operation_holds_the_lock(self):
        a = self.machine("a")
        a.write(".config/omarchy/configsync/software.json", json.dumps({
            "capturedAt": "2026-01-01 00:00", "host": "other",
            "plugins": [],
            "packages": {"native": ["firefox"], "aur": []},
        }))
        lock = a.home / ".local/share/omarchy-configsync/lock"
        lock.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(str(lock), os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            raw = a.run("install-software", "--plan", check=False)
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)
        plan = json.loads(raw)
        self.assertTrue(plan["ready"], raw)
        self.assertIn("firefox", [p["name"] for p in plan["packages"]])

    def test_service_install_without_systemd_reports_the_fallback(self):
        a = self.machine("a")
        out = a.run("service", "install", check=False)
        self.assertIn("no systemd user session", out)
        self.assertEqual(json.loads(a.run("service", "status"))["installed"], False)

    def test_watch_on_records_whether_systemd_owns_the_timer(self):
        a = self.machine("a")
        a.run("scan")
        a.env["XDG_RUNTIME_DIR"] = str(self.root / "run")
        (self.root / "run").mkdir(exist_ok=True)
        a.run("watch", "--on")
        self.assertTrue(a.state()["watch"].get("systemd"),
                        "the shell service must know systemd owns the pass")
        a.run("watch", "--off")
        self.assertFalse(a.state()["watch"].get("systemd"),
                         "and know when it no longer does")

    def test_watcher_pushes_local_edits(self):
        # Same contract as rsw: one rsync at startup, then one per change.
        a = self.machine("a")
        a.write("Documents/notes.txt", "start\n")
        self.configure(a)
        a.run("watch", "--on")
        wait_for(lambda: (self.drive / "Documents" / "notes.txt").exists(),
                 "the watcher syncs once when it starts")
        wait_for_watch(a.home / "Documents")

        a.write("Documents/fresh.txt", "written while watching\n")
        wait_for(lambda: (self.drive / "Documents" / "fresh.txt").exists(),
                 "inotify picks a new file up within seconds")

        view = a.state()["watch"]
        self.assertEqual(view["watching"], view["expected"])
        self.assertEqual(view["expected"], 1,
                         "only a gdrive path gets a fast-copy watcher")
        # `watch_view` lists every rsw watcher on the machine, so a machine that
        # is really running this plugin (the live session, the timer restarting
        # its watchers) shows up here as someone else's. Only ours is ours.
        ours = [w for w in view["watchers"] if w["source"] == "~/Documents"]
        self.assertTrue(ours, view)
        self.assertTrue(all(w["mine"] for w in ours), view)

    def test_watch_is_idempotent_and_stops_only_ours(self):
        a = self.machine("a")
        a.write("Documents/notes.txt", "start\n")
        self.configure(a)
        a.run("watch", "--on")
        out = a.run("watch", "--ensure")
        self.assertIn("already being watched", out)
        self.assertEqual(a.state()["watch"]["watching"],
                         a.state()["watch"]["expected"])

        # Somebody else's watcher, started the way rsw starts one. Counts are
        # deltas: the machine may already have watchers of its own.
        other = self.root / "elsewhere"
        other.mkdir()
        before = a.state()["watch"]["others"]
        start_foreign_watcher(other, self.drive / "elsewhere")
        wait_for(lambda: a.state()["watch"]["others"] == before + 1,
                 "the foreign watcher is listed too")

        a.run("watch", "--stop")
        self.assertEqual(a.state()["watch"]["watching"], 0)
        self.assertEqual(a.state()["watch"]["others"], before + 1,
                         "stopping ours must leave everyone else's alone")
        a.run("watch", "--stop", "--all")      # dsw behaviour, on request
        self.assertEqual(a.state()["watch"]["others"], 0)

    def test_watcher_honours_the_exclusion_rules(self):
        # rsw's own loop is `rsync -a` with no excludes. The watcher runs the same
        # loop with this plugin's filters, so a cache or a secret that the scan
        # refuses to carry cannot ride along on the fast path either.
        a = self.machine("a")
        a.write("Documents/notes.txt", "start\n")
        a.write("Documents/Cache/blob", "junk\n")
        a.write("Documents/credentials", "token\n")
        a.write("Documents/id_rsa", "key\n")
        self.configure(a)
        a.run("watch", "--on")
        a.run("sync")
        wait_for_watch(a.home / "Documents")
        a.write("Documents/new.txt", "fresh\n")

        def copied(rel):
            return (self.drive / "Documents" / rel).exists()

        wait_for(lambda: copied("new.txt"),
                 "the watcher copies an ordinary new file")
        for rel in ("Cache/blob", "credentials", "id_rsa"):
            self.assertFalse(copied(rel), f"{rel} must not reach the backend")

    def test_the_pass_catches_what_the_fast_path_can_miss(self):
        # rsw's rsync skips a file whose size and whole-second mtime are
        # unchanged, so a same-size edit saved inside the same second does not
        # travel on the fast path. The pass compares nanoseconds and content, so
        # it does — that is the division of labour, and it is worth pinning down.
        a = self.machine("a")
        a.write("Documents/notes.txt", "one\n")
        self.configure(a)
        a.run("watch", "--on")
        a.run("sync")
        wait_for_watch(a.home / "Documents")
        a.write("Documents/notes.txt", "two\n")          # same size, same second
        time.sleep(2)
        out = a.run("watch", "--once")
        self.assertEqual(a.read("Documents/notes.txt"), "two\n")
        self.assertEqual((self.drive / "Documents" / "notes.txt").read_text(), "two\n",
                         f"the pass should carry it: {out}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
