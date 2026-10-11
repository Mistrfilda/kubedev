#!/usr/bin/env python3
"""Exercise MariaDB maintenance against fake commands and temporary data only."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time

MOCK_COMMANDS = {
	"microk8s", "docker", "id", "hostname", "flock", "readlink", "du", "df",
	"sha256sum", "tar", "sleep", "timeout", "mv",
}


def write_state(root, state):
	path = root / f"state.{os.getpid()}.tmp"
	path.write_text(json.dumps(state))
	path.replace(root / "state.json")


def mock_command(name, args):
	root = Path(os.environ["MARIADB_TEST_ROOT"])
	state = json.loads((root / "state.json").read_text())
	case = state["case"]
	with (root / "calls.jsonl").open("a") as log:
		log.write(json.dumps([name, *args]) + "\n")
	if name == "id":
		print("501" if case == "not_root" else "0")
	elif name == "hostname":
		print("macbook" if case == "wrong_host" else "raspberrypi5")
	elif name == "flock":
		return 1 if case == "locked" else 0
	elif name == "readlink":
		print(Path(args[-1]).resolve())
	elif name == "du":
		print("1024\t" + args[-1])
	elif name == "df":
		print("Filesystem 1024-blocks Used Available Capacity Mounted-on")
		print(f"mock 99999999 1000 {10 if case == 'disk_full' else 9999999} 1% /")
	elif name == "sleep":
		time.sleep(0.15)
	elif name == "timeout":
		os.execv(args[1], args[1:])
	elif name == "sha256sum":
		if args[0] == "--check":
			expected, filename = Path(args[1]).read_text().strip().split("  ", 1)
			return 0 if hashlib.sha256(Path(filename).read_bytes()).hexdigest() == expected else 1
		print(hashlib.sha256(Path(args[0]).read_bytes()).hexdigest() + "  " + args[0])
	elif name == "tar":
		if "-cpf" in args:
			if case == "backup_error":
				return 12
			with tarfile.open(args[args.index("-cpf") + 1], "w") as archive:
				archive.add(args[args.index("-C") + 1], arcname=".")
		elif "-tf" in args:
			with tarfile.open(args[args.index("-tf") + 1]) as archive:
				assert archive.getmembers()
		else:
			if case == "restore_error":
				return 13
			with tarfile.open(args[args.index("-xpf") + 1]) as archive:
				archive.extractall(args[args.index("-C") + 1], filter="data")
	elif name == "mv":
		if case == "install_error" and ".restore." in Path(args[0]).name:
			return 14
		shutil.move(args[0], args[1])
	elif name == "docker":
		if args[0] == "build" and case == "build_error":
			return 15
	elif name == "microk8s":
		if args[0] == "ctr":
			return 16 if case == "pull_error" else 0
		assert args[:3] == ["kubectl", "--context=microk8s", "--namespace=default"]
		cmd = args[3:]
		if cmd[0] == "get":
			resource = cmd[1]
			if resource == "nodes":
				print("raspberrypi5")
			elif resource.startswith("statefulset/"):
				print(state["db_replicas"] if "replicas" in cmd[-1] else state["image"])
			elif resource.startswith("deployment/"):
				print(state["php" if "php-" in resource else "nginx"])
			elif resource == "pvc":
				if "phase" in cmd[-1]:
					print("Bound")
				elif "volumeName" in cmd[-1]:
					print("test-pv")
				else:
					print("other-pvc" if case == "pvc_changed" else "original-pvc")
			elif resource == "pv":
				print(state["data_dir"] if "hostPath" in cmd[-1] else "default/mariadb-pvc")
			elif resource == "cronjobs":
				print("\n".join(k for k, suspended in state["cronjobs"].items() if not suspended))
			elif resource == "jobs":
				state["job_polls"] += 1
				write_state(root, state)
				if case == "jobs_stuck" or (case == "jobs_finish" and state["job_polls"] < 3):
					print("php-consumer-job")
			elif resource == "pods":
				selectors = [x for x in cmd if x.startswith("--selector=")]
				if not selectors:
					if case == "orphan_job":
						print("php-orphan-pod")
				elif case == "pod_api_error":
					return 17
				else:
					selector = selectors[0].split("=", 1)[1]
					key = {"app=mariadb": "db_replicas", "app=my-pt-php-app": "php", "app=my-pt-nginx-app": "nginx"}[selector]
					if state[key] or (case == "pod_stuck" and key == "db_replicas"):
						print("pod/test-pod")
			else:
				raise AssertionError(cmd)
		elif cmd[0] == "patch":
			if cmd[1] == "cronjob":
				state["cronjobs"][cmd[2]] = json.loads(cmd[-1])["spec"]["suspend"]
			write_state(root, state)
		elif cmd[0] == "scale":
			replicas = int(cmd[-1].split("=")[1])
			for workload in cmd[2:-1]:
				key = {"mariadb": "db_replicas", "php-deployment": "php", "nginx-deployment": "nginx"}[workload]
				state[key] = replicas
			write_state(root, state)
		elif cmd[0] == "wait":
			return 18 if case == "pod_stuck" else 0
		elif cmd[0] == "logs":
			if "--follow" in cmd:
				while json.loads((root / "state.json").read_text())["db_replicas"]:
					time.sleep(0.02)
				if case != "unclean_shutdown":
					print("mariadbd: Shutdown complete", flush=True)
			else:
				print("MariaDB ready for connections")
		elif cmd[0] == "apply":
			if case == "apply_error":
				return 19
			state["image"] = "localhost:32000/my-mariadb:11.4.13"
			state["version"] = "11.4.13-MariaDB" if case != "wrong_version" else "11.4.12-MariaDB"
			state["db_replicas"] = 1
			Path(state["data_dir"], "ibdata1").write_text("upgraded-data")
			write_state(root, state)
		elif cmd[0] == "rollout":
			if case == "interrupt" and state["version"].startswith("11."):
				(root / "interrupt-ready").touch()
				time.sleep(20)
			return 20 if case == "rollout_error" and "statefulset/mariadb" in cmd else 0
		elif cmd[0] == "exec":
			if "php" in cmd:
				if state["version"].startswith("11.") and case == "app_error":
					return 21
				count = 42 if case == "table_mismatch" and state["version"].startswith("11.") else 43
				print(state["version"] + "\t" + str(count))
			elif "healthcheck.sh" in cmd:
				return 22 if case == "health_error" and state["version"].startswith("11.") else 0
			else:
				print(state["version"])
		elif cmd[:2] == ["set", "image"]:
			state["image"] = cmd[-1].split("=", 1)[1]
			state["version"] = "10.5.26-MariaDB"
			write_state(root, state)
		else:
			raise AssertionError(cmd)
	return 0


class Fixture:
	def __init__(self, folder, project, case="ok", php=1, nginx=1):
		self.root = Path(folder).resolve()
		self.project = self.root / "project"
		for directory in ["scripts", "docker/mysql", "deployment"]:
			(self.project / directory).mkdir(parents=True, exist_ok=True)
		for name in ["upgrade-mariadb.sh", "deploy-mariadb.sh", "build-mariadb.sh"]:
			shutil.copyfile(project / "scripts" / name, self.project / "scripts" / name)
		(self.project / "docker/mysql/Dockerfile").write_text("FROM mariadb:11.4.13\n")
		(self.project / "deployment/mariadb-deployment.yaml").write_text("- image: localhost:32000/my-mariadb:11.4.13\n")
		self.data = self.root / "storage/default-mariadb-pvc-test"
		self.data.mkdir(parents=True)
		(self.data / "ibdata1").write_text("original-data")
		self.original_cronjobs = {"php-consumer": False, "php-download": False, "php-already-paused": True, "unrelated": False}
		write_state(self.root, {"case": case, "db_replicas": 1, "php": php, "nginx": nginx, "cronjobs": self.original_cronjobs, "image": "localhost:32000/my-mariadb:1.0", "version": "10.5.26-MariaDB", "data_dir": str(self.data), "job_polls": 0})
		self.bin = self.root / "bin"
		self.bin.mkdir()
		mock_source = "#!" + sys.executable + "\n" + Path(__file__).read_text().split("\n", 1)[1]
		for name in MOCK_COMMANDS:
			path = self.bin / name
			path.write_text(mock_source)
			path.chmod(0o755)
		self.env = {"PATH": str(self.bin) + ":/usr/bin:/bin", "MARIADB_TEST_ROOT": str(self.root), "MARIADB_STATE_ROOT": str(self.root / "runs"), "MARIADB_JOB_TIMEOUT": "2" if case in {"jobs_stuck", "orphan_job"} else "1800"}

	def run(self, *args, script="upgrade-mariadb.sh"):
		return subprocess.run(["/bin/bash", str(self.project / "scripts" / script), *args], env=self.env, capture_output=True, text=True, timeout=25)

	def state(self):
		return json.loads((self.root / "state.json").read_text())

	def set_case(self, case):
		state = self.state()
		state["case"] = case
		write_state(self.root, state)

	def run_dir(self):
		return next((self.root / "runs").glob("upgrade.*"))

	def calls(self):
		return [json.loads(line) for line in (self.root / "calls.jsonl").read_text().splitlines()]

	def mutations(self):
		return [call[4:] for call in self.calls() if call[0] == "microk8s" and len(call) > 4 and call[1] == "kubectl" and call[4] in {"apply", "patch", "scale", "set"}]


def assert_success(result):
	assert result.returncode == 0, result.stdout + result.stderr


def main():
	project = Path(__file__).resolve().parents[1]
	checks = 0
	def check(name, test):
		nonlocal checks
		with tempfile.TemporaryDirectory(prefix="mariadb-test-") as folder:
			test(folder)
		checks += 1
		print("PASS", name, flush=True)

	def success(folder, php=1, nginx=1, case="ok"):
		fixture = Fixture(folder, project, case, php, nginx)
		assert_success(fixture.run())
		state = fixture.state()
		assert (state["php"], state["nginx"], state["db_replicas"]) == (php, nginx, 1)
		assert state["cronjobs"] == fixture.original_cronjobs
		assert state["version"] == "11.4.13-MariaDB"
		assert (fixture.run_dir() / "result").read_text().strip() == "completed"
		assert (fixture.run_dir() / "datadir.tar").stat().st_mode & 0o077 == 0
		assert all(not (cmd[0] == "apply" and "volumes" in cmd[-1]) for cmd in fixture.mutations())
		assert_success(fixture.run("rollback", str(fixture.run_dir())))
		assert fixture.state()["cronjobs"] == fixture.original_cronjobs
		assert (fixture.state()["php"], fixture.state()["nginx"]) == (php, nginx)
		assert (fixture.data / "ibdata1").read_text() == "original-data"
		assert any(fixture.data.parent.glob("*.failed.*"))

	check("upgrade and full rollback", success)
	check("preserve zero application replicas", lambda f: success(f, 0, 0))
	check("preserve multiple application replicas", lambda f: success(f, 2, 3))
	check("wait for running jobs", lambda f: success(f, case="jobs_finish"))

	for case in ["not_root", "wrong_host", "locked", "disk_full", "pull_error"]:
		def preflight(folder, case=case):
			fixture = Fixture(folder, project, case)
			assert fixture.run().returncode != 0
			assert not fixture.mutations()
		check("preflight: " + case, preflight)

	for case in ["jobs_stuck", "orphan_job", "pod_api_error", "pod_stuck", "unclean_shutdown", "backup_error", "apply_error", "rollout_error", "health_error", "wrong_version", "app_error", "table_mismatch"]:
		def failure(folder, case=case):
			fixture = Fixture(folder, project, case)
			result = fixture.run()
			assert result.returncode != 0, case
			assert "rollback" in result.stderr, result.stderr
			if case in {"jobs_stuck", "orphan_job", "pod_api_error", "pod_stuck", "unclean_shutdown", "backup_error"}:
				assert not any(cmd[0] == "apply" for cmd in fixture.mutations())
			fixture.set_case("ok")
			before = len(fixture.mutations())
			assert fixture.run().returncode != 0
			assert len(fixture.mutations()) == before
			assert_success(fixture.run("rollback", str(fixture.run_dir())))
			assert fixture.state()["version"] == "10.5.26-MariaDB"
			assert fixture.state()["cronjobs"] == fixture.original_cronjobs
			assert (fixture.state()["php"], fixture.state()["nginx"]) == (1, 1)
			assert (fixture.data / "ibdata1").read_text() == "original-data"
		check("failure and recovery: " + case, failure)

	for signum in [signal.SIGTERM, signal.SIGHUP]:
		def interrupted_upgrade(folder, signum=signum):
			fixture = Fixture(folder, project, "interrupt")
			process = subprocess.Popen(["/bin/bash", str(fixture.project / "scripts/upgrade-mariadb.sh")], env=fixture.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
			try:
				deadline = time.monotonic() + 20
				while not (fixture.root / "interrupt-ready").exists():
					assert process.poll() is None, process.communicate()
					assert time.monotonic() < deadline, "Upgrade did not reach the interruption point."
					time.sleep(0.02)
				os.killpg(process.pid, signum)
				stdout, stderr = process.communicate(timeout=5)
				assert process.returncode != 0, stdout + stderr
				assert "rollback" in stderr, stderr
				assert (fixture.run_dir() / "result").read_text().strip() == "failed"
			finally:
				if process.poll() is None:
					os.killpg(process.pid, signal.SIGKILL)
					process.communicate()
			fixture.set_case("ok")
			assert_success(fixture.run("rollback", str(fixture.run_dir())))
			assert fixture.state()["version"] == "10.5.26-MariaDB"
			assert fixture.state()["cronjobs"] == fixture.original_cronjobs
			assert (fixture.data / "ibdata1").read_text() == "original-data"
		check("interrupted upgrade: " + signum.name, interrupted_upgrade)

	for case in ["restore_error", "install_error"]:
		def interrupted_restore(folder, case=case):
			fixture = Fixture(folder, project)
			assert_success(fixture.run())
			fixture.set_case(case)
			assert fixture.run("rollback", str(fixture.run_dir())).returncode != 0
			fixture.set_case("ok")
			assert_success(fixture.run("rollback", str(fixture.run_dir())))
			assert (fixture.data / "ibdata1").read_text() == "original-data"
		check("repeat interrupted rollback: " + case, interrupted_restore)

	for case in ["corrupt_backup", "pvc_changed"]:
		def invalid_restore(folder, case=case):
			fixture = Fixture(folder, project)
			assert_success(fixture.run())
			if case == "corrupt_backup":
				with (fixture.run_dir() / "datadir.tar").open("ab") as archive:
					archive.write(b"corrupted")
			else:
				fixture.set_case(case)
			before = len(fixture.mutations())
			assert fixture.run("rollback", str(fixture.run_dir())).returncode != 0
			assert len(fixture.mutations()) == before
			assert (fixture.data / "ibdata1").read_text() == "upgraded-data"
		check("reject unsafe restore: " + case, invalid_restore)

	def build_failure(folder):
		fixture = Fixture(folder, project, "build_error")
		assert fixture.run(script="build-mariadb.sh").returncode != 0
		assert not any(call[:2] == ["docker", "push"] for call in fixture.calls())
	check("failed build never pushes", build_failure)
	print(f"{checks} scenarios passed; no real Docker or Kubernetes calls were made.")


if __name__ == "__main__":
	name = Path(sys.argv[0]).name
	if name in MOCK_COMMANDS:
		sys.exit(mock_command(name, sys.argv[1:]))
	main()
