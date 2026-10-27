#!/usr/bin/env python3
"""Verify destructive retention behavior using temporary files only."""

from datetime import datetime, timedelta
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/cleanup-vps-backups.py"
SPEC = importlib.util.spec_from_file_location("backup_retention", SCRIPT)
RETENTION = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = RETENTION
SPEC.loader.exec_module(RETENTION)


class RetentionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.now = datetime.now().replace(microsecond=0)

    def backup(self, age_days, database="example", content=b"backup fixture"):
        date = self.now - timedelta(days=age_days)
        path = self.directory / f"{date:%d%m%Y_%H%M%S}_{database}.sql"
        path.write_bytes(content)
        os.utime(path, (date.timestamp(), date.timestamp()))
        return path

    def run_cleanup(self, *arguments):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--backup-dir", str(self.directory), *arguments],
            capture_output=True, text=True,
        )

    def test_preview_has_no_filesystem_side_effects(self):
        for age in range(100):
            self.backup(age)
        before = {path.name: path.stat() for path in self.directory.iterdir()}
        result = self.run_cleanup("--months", "1")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("DRY RUN", result.stdout)
        self.assertEqual(before, {path.name: path.stat() for path in self.directory.iterdir()})

    def test_apply_preserves_daily_and_latest_monthly_per_database(self):
        for database in ("one", "two"):
            for age in range(450):
                self.backup(age, database)
        groups, _ = RETENTION.inventory(self.directory)
        expected = set()
        for backups in groups.values():
            monthly = {}
            for backup in sorted(backups, key=lambda item: item.timestamp):
                monthly[backup.timestamp.strftime("%Y-%m")] = backup.path
                if backup.timestamp.date() >= self.now.date() - timedelta(days=29):
                    expected.add(backup.path)
            expected.update(monthly[key] for key in sorted(monthly)[-12:])
        result = self.run_cleanup("--apply")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(expected, set(self.directory.iterdir()))
        second = self.run_cleanup("--apply")
        self.assertEqual(0, second.returncode, second.stderr)
        self.assertNotIn("Deleted ", second.stdout)

    def test_stale_database_aborts_all_groups_before_deletion(self):
        self.backup(0, "healthy")
        old = self.backup(100, "healthy")
        self.backup(3, "stale")
        result = self.run_cleanup("--apply", "--months", "1")
        self.assertNotEqual(0, result.returncode)
        self.assertIn("over 48 hours old", result.stderr)
        self.assertTrue(old.exists())

    def test_empty_latest_aborts_cleanup(self):
        self.backup(0, content=b"")
        old = self.backup(100)
        result = self.run_cleanup("--apply")
        self.assertNotEqual(0, result.returncode)
        self.assertIn("empty", result.stderr)
        self.assertTrue(old.exists())

    def test_unknown_files_symlinks_and_directories_are_untouched(self):
        self.backup(0)
        self.backup(100)
        script = self.directory / "download_backup.sh"
        script.write_text("fixture")
        link = self.directory / "01012020_020001_example.sql"
        link.symlink_to(script)
        folder = self.directory / "02012020_020001_example.sql"
        folder.mkdir()
        result = self.run_cleanup("--apply", "--months", "1")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertTrue(link.is_symlink())
        self.assertEqual("fixture", script.read_text())
        self.assertTrue(folder.is_dir())

    def test_recently_modified_old_dump_is_protected(self):
        self.backup(0)
        recent = self.backup(100)
        os.utime(recent, None)
        result = self.run_cleanup("--apply", "--months", "1")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertTrue(recent.exists())

    def test_changed_file_is_detected(self):
        path = self.backup(0)
        groups, _ = RETENTION.inventory(self.directory)
        path.write_bytes(b"changed fixture")
        with self.assertRaisesRegex(ValueError, "changed during cleanup"):
            RETENTION.verify_unchanged(groups["example"][0])

    def test_future_date_is_rejected(self):
        self.backup(-2)
        result = self.run_cleanup("--apply")
        self.assertNotEqual(0, result.returncode)
        self.assertIn("future", result.stderr)

    def test_invalid_retention_is_rejected(self):
        self.backup(0)
        for option in ("--days", "--months", "--max-age-hours"):
            result = self.run_cleanup(option, "0", "--apply")
            self.assertNotEqual(0, result.returncode)


if __name__ == "__main__":
    unittest.main()
