#!/usr/bin/env python3
"""End-to-end tests for configsync.

Every test builds throwaway "machines" (a fake $HOME), a bare git remote and a
folder standing in for a mounted Google Drive, then drives the real CLI as a
subprocess. Run with:

    python3 -m unittest discover -s tests -v
"""
from __future__ import annotations

import json
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


class Machine:
    """A fake $HOME plus the CLI calls that act on it."""

    def __init__(self, root: Path, name: str):
        self.home = root / name
        (self.home / ".config/ghostty").mkdir(parents=True, exist_ok=True)
        (self.home / "Documents").mkdir(parents=True, exist_ok=True)
        self.env = {**os.environ, "HOME": str(self.home), "USER": "tester"}
        self.env.pop("XDG_RUNTIME_DIR", None)   # keep the systemd path honest

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
        # and the losing version is pushed, so machine A sees it too
        a.run("sync")
        self.assertTrue(list((a.home / ".config/ghostty").glob("config.conflict-*")))

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

    def test_state_migrates_the_old_auto_switch(self):
        a = self.machine("a")
        a.write(".config/omarchy/configsync.json",
                json.dumps({"version": 1, "auto": {"enabled": True,
                                                   "intervalMinutes": 30}}))
        state = a.state()
        self.assertTrue(state["watch"]["enabled"])
        self.assertEqual(state["version"], 2)

    def test_state_file_keeps_a_backup(self):
        a = self.machine("a")
        self.configure(a)
        a.run("set-enabled", "personal-Documents", "false")
        backup = a.home / ".config/omarchy/configsync.json.bak"
        self.assertTrue(backup.exists())
        json.loads(backup.read_text())

    def test_watch_is_off_by_default_and_toggleable(self):
        a = self.machine("a")
        self.configure(a)
        state = a.state()
        self.assertFalse(state["watch"]["enabled"])
        out = a.run("set-backend", "watch", "enabled", "true")
        self.assertIn("watch: on", out)
        self.assertTrue(a.state()["watch"]["enabled"])
        self.assertIn("shell", out, "no systemd here, so it falls back to the shell")

    def test_service_install_without_systemd_reports_the_fallback(self):
        a = self.machine("a")
        out = a.run("service", "install", check=False)
        self.assertIn("no systemd user session", out)
        self.assertEqual(json.loads(a.run("service", "status"))["installed"], False)

    def test_watcher_pushes_local_edits(self):
        a = self.machine("a")
        a.write("Documents/notes.txt", "start\n")
        self.configure(a)
        a.run("set-backend", "watch", "enabled", "true")
        a.run("set-backend", "watch", "debounce", "1")
        a.run("set-backend", "watch", "pull", "30")

        proc = subprocess.Popen([sys.executable, str(SCRIPT), "watch"],
                                env=a.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True)
        try:
            deadline = time.time() + 30
            while time.time() < deadline:
                if (self.drive / "Documents" / "notes.txt").exists():
                    break
                time.sleep(0.5)
            self.assertTrue((self.drive / "Documents" / "notes.txt").exists(),
                            "the startup pass should push what is there")

            a.write("Documents/fresh.txt", "written while watching\n")
            deadline = time.time() + 30
            while time.time() < deadline:
                if (self.drive / "Documents" / "fresh.txt").exists():
                    break
                time.sleep(0.5)
            self.assertTrue((self.drive / "Documents" / "fresh.txt").exists(),
                            "inotify should pick the new file up within seconds")
            # Read the live status while the watcher is still up.
            status = a.state()["watch"]
        finally:
            proc.terminate()
            proc.wait(timeout=15)
        self.assertTrue(status["running"], "the watcher reports itself as running")
        self.assertIn(status["mode"], ("inotify", "poll"))

    def test_only_one_watcher_runs(self):
        a = self.machine("a")
        self.configure(a)
        a.run("set-backend", "watch", "enabled", "true")
        first = subprocess.Popen([sys.executable, str(SCRIPT), "watch"],
                                 env=a.env, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, text=True)
        try:
            time.sleep(3)
            out = a.run("watch", check=False)
            self.assertIn("already running", out)
        finally:
            first.terminate()
            first.wait(timeout=15)


if __name__ == "__main__":
    unittest.main(verbosity=2)
