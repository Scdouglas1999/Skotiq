#!/usr/bin/env python3
"""Build all release APKs with bounded CI concurrency and memory telemetry."""

import argparse
import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading


TARGETS = (
    ("android-arm", "armeabi-v7a"),
    ("android-arm64", "arm64-v8a"),
    ("android-x64", "x86_64"),
)
GRADLE_PROPERTIES = """org.gradle.jvmargs=-Xmx3g -XX:MaxMetaspaceSize=768m -XX:ReservedCodeCacheSize=256m
org.gradle.workers.max=2
org.gradle.parallel=false
org.gradle.daemon=false
kotlin.compiler.execution.strategy=in-process
"""


def memory_sample():
    """Read resource counters only; never read process arguments or environment."""
    sample = {"utc": datetime.datetime.now(datetime.timezone.utc).isoformat()}
    try:
        fields = dict(line.split(":", 1) for line in Path("/proc/meminfo").read_text().splitlines())
        sample["host_memory_kib"] = {
            key: int(fields[key].split()[0])
            for key in ("MemTotal", "MemAvailable", "SwapTotal", "SwapFree")
        }
        counters = {}
        cgroup = Path("/sys/fs/cgroup")
        for name in ("memory.current", "memory.max", "memory.peak", "memory.events"):
            path = cgroup / name
            if path.is_file():
                counters[name] = path.read_text().strip()
        sample["root_cgroup"] = counters
        # comm contains only executable names, unlike args/cmdline.
        process = subprocess.run(
            ["ps", "-eo", "pid=,ppid=,rss=,comm=", "--sort=-rss"],
            text=True, capture_output=True, check=True,
        )
        sample["largest_processes"] = [
            dict(zip(("pid", "ppid", "rss_kib", "executable"), line.split(None, 3)))
            for line in process.stdout.splitlines()[:5]
        ]
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        sample["telemetry_error"] = type(error).__name__
    return sample


class MemoryMonitor:
    def __init__(self, path):
        self.path = path
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)

    def _sample(self):
        line = json.dumps(memory_sample(), sort_keys=True)
        with self.path.open("a") as stream:
            stream.write(line + "\n")
        print("CI_MEMORY " + line, flush=True)

    def _run(self):
        while not self.stop.wait(10):
            self._sample()

    def __enter__(self):
        self._sample()
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stop.set()
        self.thread.join()
        self._sample()


def build(app_dir, evidence_dir):
    if os.environ.get("GITHUB_ACTIONS") != "true" or not os.environ.get("RUNNER_TEMP"):
        raise RuntimeError("This helper is for GitHub Actions; use flutter build apk locally.")
    evidence_dir.mkdir(parents=True, exist_ok=True)
    (evidence_dir / "gradle.properties").write_text(GRADLE_PROPERTIES)
    outputs = app_dir / "build/app/outputs/flutter-apk"
    with tempfile.TemporaryDirectory(prefix="skotiq-android-", dir=os.environ["RUNNER_TEMP"]) as temporary:
        scratch = Path(temporary)
        gradle_home = scratch / "gradle"
        gradle_home.mkdir()
        # User-level Gradle properties override the unchanged project defaults.
        (gradle_home / "gradle.properties").write_text(GRADLE_PROPERTIES)
        env = dict(os.environ, GRADLE_USER_HOME=str(gradle_home))
        public_key = env.get("SKOTIQ_UPDATE_PUBLIC_KEY", "")
        with MemoryMonitor(evidence_dir / "memory.jsonl"):
            for target, abi in TARGETS:
                print(f"Building {abi} with one Flutter AOT target and two Gradle workers.", flush=True)
                source = outputs / f"app-{abi}-release.apk"
                source.unlink(missing_ok=True)
                command = [
                    "flutter", "build", "apk", "--release", "--split-per-abi",
                    f"--target-platform={target}",
                    f"--dart-define=SKOTIQ_UPDATE_PUBLIC_KEY={public_key}",
                ]
                result = subprocess.run(command, cwd=app_dir, env=env)
                if result.returncode:
                    return result.returncode
                if not source.is_file() or source.stat().st_size == 0:
                    raise RuntimeError(f"Build did not produce a nonempty release APK for {abi}.")
                # A later Flutter build may replace its output directory.
                shutil.copy2(source, scratch / source.name)
            outputs.mkdir(parents=True, exist_ok=True)
            for _, abi in TARGETS:
                name = f"app-{abi}-release.apk"
                shutil.copy2(scratch / name, outputs / name)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-dir", type=Path, default=Path(__file__).resolve().parent.parent / "apps/mobile")
    parser.add_argument("--evidence-dir", type=Path, required=True)
    args = parser.parse_args()
    return build(args.app_dir.resolve(), args.evidence_dir.resolve())


if __name__ == "__main__":
    raise SystemExit(main())
