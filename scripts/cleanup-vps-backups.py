#!/usr/bin/env python3
"""Preview or apply daily/monthly retention without opening database dumps."""

import argparse
from collections import defaultdict
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timedelta
import fcntl
import os
from pathlib import Path
import re
import stat
import sys


BACKUP_NAME = re.compile(r"(\d{8})_(\d{6})_([A-Za-z0-9_-]+)\.sql")


@dataclass(frozen=True)
class Backup:
    path: Path
    timestamp: datetime
    database: str
    info: os.stat_result


def positive_integer(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return number


def inventory(directory):
    groups = defaultdict(list)
    ignored = 0
    for path in directory.iterdir():
        match = BACKUP_NAME.fullmatch(path.name)
        info = path.lstat()
        if match is None or not stat.S_ISREG(info.st_mode):
            ignored += 1
            continue
        try:
            timestamp = datetime.strptime(match[1] + match[2], "%d%m%Y%H%M%S")
        except ValueError as error:
            raise ValueError(f"Invalid backup date: {path.name}") from error
        groups[match[3]].append(Backup(path, timestamp, match[3], info))
    if not groups:
        raise ValueError("No recognized SQL backups found; refusing cleanup")
    return groups, ignored


def make_plan(backups, now, days, months, max_age_hours):
    backups = sorted(backups, key=lambda backup: (backup.timestamp, backup.path.name))
    latest = backups[-1]
    if latest.timestamp > now + timedelta(minutes=5):
        raise ValueError(f"Backup date is in the future: {latest.path.name}")
    if latest.timestamp < now - timedelta(hours=max_age_hours):
        raise ValueError(f"Newest backup is over {max_age_hours} hours old: {latest.path.name}")
    if latest.info.st_size == 0:
        raise ValueError(f"Newest backup is empty: {latest.path.name}")

    cutoff = now.date() - timedelta(days=days - 1)
    keep = {backup.path for backup in backups if backup.timestamp.date() >= cutoff}
    monthly = {}
    for backup in backups:
        if backup.info.st_size > 0:
            monthly[backup.timestamp.strftime("%Y-%m")] = backup
    keep.update(monthly[month].path for month in sorted(monthly)[-months:])
    keep.add(latest.path)
    # The downloader writes straight to .sql. Never touch recently modified files.
    keep.update(
        backup.path for backup in backups
        if backup.info.st_mtime >= now.timestamp() - 86400
    )
    return [backup for backup in backups if backup.path not in keep]


def verify_unchanged(backup):
    current = backup.path.lstat()
    before = backup.info
    if not stat.S_ISREG(current.st_mode) or any(
        getattr(current, field) != getattr(before, field)
        for field in ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
    ):
        raise ValueError(f"Backup changed during cleanup: {backup.path.name}")


@contextmanager
def locked_directory(directory):
    descriptor = os.open(directory, os.O_RDONLY)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(descriptor)


def cleanup(args):
    directory = args.backup_dir.resolve(strict=True)
    if not directory.is_dir() or directory == Path("/"):
        raise ValueError("Backup directory must be an existing directory other than /")
    # Lock the directory inode so previews leave no lock file behind.
    with locked_directory(directory):
        groups, ignored = inventory(directory)
        now = datetime.now()
        plans = {
            database: make_plan(backups, now, args.days, args.months, args.max_age_hours)
            for database, backups in groups.items()
        }
        print(f"Directory: {directory}")
        print(f"Mode: {'APPLY' if args.apply else 'DRY RUN (nothing will be deleted)'}")
        print(f"Retention: {args.days} calendar days + {args.months} available monthly backups per database")
        for database, backups in sorted(groups.items()):
            deleted = plans[database]
            size = sum(backup.info.st_size for backup in deleted) / 1024 ** 3
            print(f"{database}: keep {len(backups) - len(deleted)} / {len(backups)}, delete {len(deleted)}, reclaim {size:.2f} GiB")
            if deleted:
                print(f"  Delete dates: {deleted[0].timestamp.date()} ... {deleted[-1].timestamp.date()} (monthly backups excluded)")
            if args.verbose:
                for backup in sorted(backups, key=lambda item: item.timestamp):
                    action = "DELETE" if backup in deleted else "KEEP"
                    print(f"  {action} {backup.path.name}")
        print(f"Ignored {ignored} unrecognized files/directories/symlinks")
        if not args.apply:
            print("Preview complete. Use --apply to delete the selected files.")
            return

        # Validate every group and candidate before deleting the first file.
        for backups in groups.values():
            for backup in backups:
                verify_unchanged(backup)
        for deleted in plans.values():
            for backup in deleted:
                verify_unchanged(backup)
                backup.path.unlink()
                print(f"Deleted {backup.path.name}", flush=True)
        print("Backup retention complete.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backup-dir", type=Path, default=Path("/var/vps-backups"))
    parser.add_argument("--days", type=positive_integer, default=30)
    parser.add_argument("--months", type=positive_integer, default=12)
    parser.add_argument("--max-age-hours", type=positive_integer, default=48,
                        help="refuse cleanup if the newest dated backup is older (default: 48)")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(argv)
    try:
        cleanup(args)
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
