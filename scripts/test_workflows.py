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



class OneDartTestRunTest(unittest.TestCase):
    """The Dart suite runs once per PR, instrumented, and that run's lcov is
    the coverage report."""

    def test_dart_tests_runs_instrumented_and_publishes_coverage(self):
        text = (WORKFLOWS / "ci.yml").read_text()
        steps = steps_by_name(text, "test-dart")
        self.assertIn("--stage dart-tests --coverage", steps["Run Dart tests"])
        self.assertIn("Merge per-package coverage reports", steps)
        self.assertIn("Upload coverage to Codecov", steps)

    def test_no_second_job_reruns_the_suite_for_coverage(self):
        text = (WORKFLOWS / "ci.yml").read_text()
        reruns = [line for line in text.splitlines()
                  if "melos run test" in line and "--coverage" in line]
        self.assertEqual(reruns, [])
        self.assertNotRegex(text, r"(?m)^  coverage:\s*$")

if __name__ == "__main__":
    unittest.main()
