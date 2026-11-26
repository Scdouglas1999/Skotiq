"""Checks on the GitHub workflows that span more than one file."""

import re
import unittest
from pathlib import Path

WORKFLOWS = Path(__file__).resolve().parent.parent / ".github" / "workflows"


def flutter_versions(text):
    """The workflow-level FLUTTER_VERSION and every literal flutter-version."""
    declared = re.findall(r"^  FLUTTER_VERSION:\s*'([^']+)'", text, re.M)
    literal = [v for v in re.findall(r"flutter-version:\s*(\S+)", text)
               if v != "${{" and not v.startswith("${{")]
    return declared, literal


class FlutterVersionTest(unittest.TestCase):
    def test_every_workflow_builds_with_one_flutter_version(self):
        versions = {}
        for path in sorted(WORKFLOWS.glob("*.yml")):
            text = path.read_text()
            if "flutter-version:" not in text:
                continue
            declared, literal = flutter_versions(text)
            self.assertEqual(literal, [], f"{path.name} names a Flutter version outside FLUTTER_VERSION")
            self.assertEqual(len(declared), 1, f"{path.name} declares FLUTTER_VERSION {len(declared)} times")
            versions[path.name] = declared[0]
        self.assertGreater(len(versions), 1)
        self.assertEqual(len(set(versions.values())), 1, f"workflows disagree: {versions}")


def steps_by_name(text, job):
    """{step name: run text} for one job, read without a YAML parser."""
    steps, name, run, in_job, collecting = {}, None, [], False, False
    for line in text.splitlines():
        if re.match(r"^  [\w-]+:\s*$", line):
            in_job = line.strip() == f"{job}:"
            continue
        if not in_job:
            continue
        step = re.match(r"^      - name:\s*(.+?)\s*$", line)
        if step:
            if name:
                steps[name] = "\n".join(run).strip()
            name, run, collecting = step.group(1), [], False
            continue
        inline = re.match(r"^        run:\s*(.*)$", line)
        if inline:
            collecting = inline.group(1) in ("|", "")
            if not collecting:
                run.append(inline.group(1))
            continue
        if collecting and (line.startswith("          ") or not line.strip()):
            run.append(line.strip())
        elif re.match(r"^        \S", line):
            collecting = False
    if name:
        steps[name] = "\n".join(run).strip()
    return steps


def package_commands(text):
    return sorted(re.findall(r"bash scripts/package_linux\.sh [^\n]*", text))


class BuildOnlyArtifactTest(unittest.TestCase):
    """The build-only workflows package what the release ships."""

    def test_linux_build_only_packages_like_the_release(self):
        release = (WORKFLOWS / "release.yml").read_text()
        build_only = (WORKFLOWS / "linux-release-build.yml").read_text()
        self.assertEqual(
            package_commands(build_only),
            [c.replace('"$BUNDLE"', "apps/desktop/build/linux/x64/release/bundle")
             for c in package_commands(release)])

    def test_linux_build_only_compiles_in_the_update_key(self):
        release = steps_by_name((WORKFLOWS / "release.yml").read_text(), "linux")
        build_only = steps_by_name(
            (WORKFLOWS / "linux-release-build.yml").read_text(), "linux-release-build")
        self.assertEqual(build_only["Build Linux release bundle"],
                         release["Build Linux release bundle"])

    def test_windows_build_only_builds_like_the_release(self):
        release = steps_by_name((WORKFLOWS / "release.yml").read_text(), "windows")
        build_only = steps_by_name(
            (WORKFLOWS / "windows-release-build.yml").read_text(), "windows-release-build")
        for step in ("Build Rust native bridge (release)", "Build Flutter Windows app (release)",
                     "Stage native DLLs (bridge, libraw, MSVC runtime) into Release",
                     "Build + stage updater.exe"):
            self.assertEqual(build_only.get(step), release[step], step)



class DartTestPartsTest(unittest.TestCase):
    """The Dart suite runs in parts on every push, and whole with coverage
    every night."""

    def setUp(self):
        self.text = (WORKFLOWS / "ci.yml").read_text()

    def test_the_parts_cover_every_shard_and_the_rest(self):
        steps = steps_by_name(self.text, "test-dart-part")
        self.assertIn("melos run gate -- ${{ matrix.gate }}", steps["Run Dart tests"])
        for package in ("skotiq_app", "skotiq_core"):
            shards = re.findall(
                rf"gate: --only flutter-tests:{package} --shard (\d+)/(\d+)", self.text)
            self.assertTrue(shards, package)
            count = {int(n) for _, n in shards}
            self.assertEqual(len(count), 1, f"{package} parts disagree on the count")
            self.assertEqual(sorted(int(i) for i, _ in shards),
                             list(range(1, count.pop() + 1)), package)
        self.assertIn(
            "gate: --stage dart-tests --skip flutter-tests:skotiq_app "
            "--skip flutter-tests:skotiq_core", self.text)

    def test_dart_tests_is_green_only_when_every_part_is(self):
        steps = steps_by_name(self.text, "test-dart")
        self.assertIn('[ "${{ needs.test-dart-part.result }}" = success ]',
                      steps["Every part passed"])
        self.assertRegex(self.text, r"(?m)^    name: Dart Tests$")

    def test_coverage_runs_whole_and_nightly(self):
        steps = steps_by_name(self.text, "test-dart-coverage")
        self.assertIn("--stage dart-tests --coverage", steps["Run Dart tests with coverage"])
        self.assertIn("Merge per-package coverage reports", steps)
        self.assertIn("Upload coverage to Codecov", steps)
        job = self.text[self.text.index("  test-dart-coverage:"):]
        self.assertIn("if: github.event_name == 'schedule'", job.split("steps:")[0])

if __name__ == "__main__":
    unittest.main()
