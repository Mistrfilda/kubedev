#!/usr/bin/env python3
"""Check registry maintenance with fake Kubernetes and HTTP commands."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/cleanup-registry-images.sh"
MOCK = r'''
import json
from pathlib import Path
import sys

root = Path(sys.argv[0]).parent
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps([name, *args]) + "\n")
if name == "curl":
    if "--output" in args:
        target = args[args.index("--output") + 1]
        Path(target).write_text('{"tags":[]}')
    if "POST" in args:
        print("202" if (root / "writes-allowed").exists() else "405")
    sys.exit(0)
if name == "sleep":
    sys.exit(0)
if args[:2] == ["get", "--raw=/readyz"]:
    sys.exit(0)
assert args[:2] == ["-n", "container-registry"] or args[0] == "get", args
if args[0] == "get":
    sys.exit(0)
args = args[2:]
if args[:3] == ["get", "deployment", "registry"]:
    if "go-template=" in args[-1]:
        print("app=registry,")
    elif (root / "maintenance.json").exists():
        if "{.name}" in args[-1]:
            print("REGISTRY_STORAGE_MAINTENANCE")
        else:
            print((root / "maintenance.json").read_text())
elif args[:2] == ["get", "pods"]:
    print("old-registry\t2026-10-27T19:30:00Z\ttrue")
    print("new-registry\t\ttrue")
    if (root / "multiple-ready").exists():
        print("another-registry\t\ttrue")
elif args[:2] == ["exec", "new-registry"]:
    if "garbage-collect" in args:
        if (root / "gc-failure").exists():
            print("unfiltered garbage collector diagnostic", file=sys.stderr)
            sys.exit(42)
        print("10 blobs marked, 2 blobs and 0 manifests eligible for deletion")
    elif "--version" in args:
        if (root / "probe-delayed").exists() and not (root / "probe-started").exists():
            (root / "probe-started").touch()
            print('container not found ("registry")', file=sys.stderr)
            sys.exit(1)
        print("registry version fixture")
    else:
        print("2G /var/lib/registry")
elif args[:2] == ["set", "env"] or args[:2] == ["rollout", "status"]:
    pass
else:
    raise AssertionError(args)
'''


class RegistryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for command in ("kubectl", "curl", "sleep"):
            path = self.root / command
            path.write_text(f"#!{sys.executable}\n" + MOCK)
            path.chmod(0o755)

    def run_cleanup(self):
        self.result = subprocess.run(
            ["/bin/bash", str(SCRIPT), "--apply", "--garbage-collect"],
            env={"PATH": f"{self.root}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                 "TMPDIR": str(self.root)},
            capture_output=True, text=True,
        )
        return [json.loads(line) for line in (self.root / "calls.jsonl").read_text().splitlines()]

    def assert_write_mode_restored(self, calls):
        changes = [call for call in calls if call[1:5] == ["-n", "container-registry", "set", "env"]]
        self.assertEqual(2, len(changes))
        self.assertIn('REGISTRY_STORAGE_MAINTENANCE={"readonly":{"enabled":true}}', changes[0])
        self.assertIn("REGISTRY_STORAGE_MAINTENANCE-", changes[1])

    def test_gc_uses_ready_non_terminating_pod_and_restores_writes(self):
        calls = self.run_cleanup()
        self.assertEqual(0, self.result.returncode, self.result.stderr)
        executions = [call for call in calls if "exec" in call]
        self.assertTrue(executions)
        self.assertTrue(all(call[4] == "new-registry" for call in executions))
        self.assert_write_mode_restored(calls)

    def test_failure_preserves_diagnostic_and_restores_writes(self):
        (self.root / "gc-failure").touch()
        calls = self.run_cleanup()
        self.assertNotEqual(0, self.result.returncode)
        self.assertIn("unfiltered garbage collector diagnostic", self.result.stderr)
        self.assert_write_mode_restored(calls)

    def test_ambiguous_ready_pods_abort_gc_and_restore_writes(self):
        (self.root / "multiple-ready").touch()
        calls = self.run_cleanup()
        self.assertNotEqual(0, self.result.returncode)
        self.assertFalse(any("exec" in call for call in calls))
        self.assert_write_mode_restored(calls)

    def test_waits_for_exec_connection_after_pod_becomes_ready(self):
        (self.root / "probe-delayed").touch()
        calls = self.run_cleanup()
        self.assertEqual(0, self.result.returncode, self.result.stderr)
        probes = [call for call in calls if "--version" in call]
        self.assertEqual(3, len(probes))
        self.assert_write_mode_restored(calls)

    def test_refuses_gc_if_registry_still_allows_uploads(self):
        (self.root / "writes-allowed").touch()
        calls = self.run_cleanup()
        self.assertNotEqual(0, self.result.returncode)
        self.assertIn("did not reject an upload", self.result.stderr)
        self.assertFalse(any("garbage-collect" in call for call in calls))
        self.assert_write_mode_restored(calls)

    def test_preserves_and_restores_existing_maintenance_settings(self):
        original = {"uploadpurging": {"enabled": False}, "readonly": {"enabled": False}}
        (self.root / "maintenance.json").write_text(json.dumps(original))
        calls = self.run_cleanup()
        self.assertEqual(0, self.result.returncode, self.result.stderr)
        changes = [call[-1] for call in calls if call[1:5] == ["-n", "container-registry", "set", "env"]]
        self.assertEqual(2, len(changes))
        applied = json.loads(changes[0].split("=", 1)[1])
        self.assertEqual({"enabled": False}, applied["uploadpurging"])
        self.assertEqual({"enabled": True}, applied["readonly"])
        self.assertEqual(original, json.loads(changes[1].split("=", 1)[1]))

    def test_existing_read_only_mode_is_left_intact(self):
        (self.root / "maintenance.json").write_text('{"readonly":{"enabled":true}}')
        calls = self.run_cleanup()
        self.assertEqual(0, self.result.returncode, self.result.stderr)
        self.assertFalse(any(call[1:5] == ["-n", "container-registry", "set", "env"] for call in calls))


if __name__ == "__main__":
    unittest.main()
