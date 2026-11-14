import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("build_android_ci.py")
FLUTTER_FIXTURE = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import sys

target = next(arg.split('=', 1)[1] for arg in sys.argv if arg.startswith('--target-platform='))
abi = {'android-arm': 'armeabi-v7a', 'android-arm64': 'arm64-v8a', 'android-x64': 'x86_64'}[target]
assert os.environ['KEYSTORE_PASSWORD'] == 'fixture-private-password'
assert os.environ['KEY_ALIAS'] == 'fixture-release'
assert os.environ['KEY_PASSWORD'] == 'fixture-private-password'
assert os.environ['KEYSTORE_FILE'] == '/fixture/release.jks'
assert os.environ['SKOTIQ_REQUIRE_RELEASE_SIGNING'] == 'true'
properties = (Path(os.environ['GRADLE_USER_HOME']) / 'gradle.properties').read_text()
with Path(os.environ['FIXTURE_CALLS']).open('a') as stream:
    stream.write(json.dumps({'target': target, 'args': sys.argv[1:], 'properties': properties}) + '\n')
outputs = Path('build/app/outputs/flutter-apk')
shutil.rmtree(outputs, ignore_errors=True)
outputs.mkdir(parents=True)
if target == os.environ.get('FIXTURE_FAIL'):
    raise SystemExit(23)
if target != os.environ.get('FIXTURE_MISSING'):
    (outputs / f'app-{abi}-release.apk').write_bytes(abi.encode())
'''


class AndroidCiBuildTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "app"
        (self.app / "android").mkdir(parents=True)
        self.original = "org.gradle.jvmargs=-Xmx8G -XX:MaxMetaspaceSize=4G\n"
        (self.app / "android/gradle.properties").write_text(self.original)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        flutter = self.bin / "flutter"
        flutter.write_text(FLUTTER_FIXTURE)
        flutter.chmod(0o700)
        self.calls = self.root / "calls.jsonl"
        self.evidence = self.root / "evidence"

    def run_build(self, **overrides):
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                   GITHUB_ACTIONS="true", RUNNER_TEMP=str(self.root),
                   KEYSTORE_PASSWORD="fixture-private-password", KEY_ALIAS="fixture-release",
                   KEY_PASSWORD="fixture-private-password", KEYSTORE_FILE="/fixture/release.jks",
                   SKOTIQ_REQUIRE_RELEASE_SIGNING="true", SKOTIQ_UPDATE_PUBLIC_KEY="fixture-public-key",
                   FIXTURE_CALLS=str(self.calls))
        env.update(overrides)
        result = subprocess.run([sys.executable, str(SCRIPT), "--app-dir", str(self.app),
                                 "--evidence-dir", str(self.evidence)],
                                env=env, text=True, capture_output=True)
        self.assertEqual((self.app / "android/gradle.properties").read_text(), self.original)
        self.assertNotIn("fixture-private-password", result.stdout + result.stderr)
        return result

    def call_rows(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def test_all_abis_survive_flutter_replacing_its_output_directory(self):
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = self.call_rows()
        self.assertEqual([row["target"] for row in rows], ["android-arm", "android-arm64", "android-x64"])
        for row in rows:
            self.assertIn("--release", row["args"])
            self.assertIn("--split-per-abi", row["args"])
            self.assertIn("--dart-define=SKOTIQ_UPDATE_PUBLIC_KEY=fixture-public-key", row["args"])
            self.assertIn("org.gradle.jvmargs=-Xmx3g", row["properties"])
            self.assertIn("org.gradle.workers.max=2", row["properties"])
            self.assertIn("kotlin.compiler.execution.strategy=in-process", row["properties"])
        for abi in ("armeabi-v7a", "arm64-v8a", "x86_64"):
            apk = self.app / f"build/app/outputs/flutter-apk/app-{abi}-release.apk"
            self.assertEqual(apk.read_bytes(), abi.encode())
        samples = [json.loads(line) for line in (self.evidence / "memory.jsonl").read_text().splitlines()]
        self.assertGreaterEqual(len(samples), 2)
        self.assertNotIn("fixture-private-password", json.dumps(samples))
        self.assertIn("CI_MEMORY", result.stdout)

    def test_build_failure_stops_before_the_next_abi_and_preserves_exit_code(self):
        result = self.run_build(FIXTURE_FAIL="android-arm64")
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(len(self.call_rows()), 2)
        self.assertTrue((self.evidence / "memory.jsonl").is_file())

    def test_success_without_expected_apk_fails_closed(self):
        result = self.run_build(FIXTURE_MISSING="android-arm64")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("nonempty release APK for arm64-v8a", result.stderr)
        self.assertEqual(len(self.call_rows()), 2)

    def test_stale_expected_apk_cannot_satisfy_a_build(self):
        outputs = self.app / "build/app/outputs/flutter-apk"
        outputs.mkdir(parents=True)
        (outputs / "app-armeabi-v7a-release.apk").write_bytes(b"stale")
        result = self.run_build(FIXTURE_MISSING="android-arm")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.call_rows()), 1)

    def test_local_invocation_refuses_without_changing_configuration(self):
        result = self.run_build(GITHUB_ACTIONS="false")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.evidence.exists())
        self.assertFalse(self.calls.exists())


if __name__ == "__main__":
    unittest.main()
