import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path


SCRIPT = Path(__file__).with_name("release_gate.py")
sys.path.insert(0, str(SCRIPT.parent))
from release_gate import REQUIRED_CHECKS  # noqa: E402

FAKE_GH = """#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
if args[:1] == ["api"]:
    sys.stdout.write(os.environ["TEST_CHECKS"])
elif args[:2] == ["release", "view"]:
    state = os.environ["TEST_RELEASE"]
    if state == "absent":
        sys.stderr.write("release not found\\n")
        sys.exit(1)
    print("true" if state == "draft" else "false")
else:
    sys.exit(2)
"""


def git(root, *args):
    return subprocess.run(
        ["git", "-C", str(root), *args], check=True, text=True, capture_output=True,
        env={**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
             "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid"},
    ).stdout.strip()


class ReleaseGateTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        repo = self.root / "repo"
        repo.mkdir()
        git(repo, "init", "-q", "-b", "main")
        git(repo, "commit", "-q", "--allow-empty", "-m", "on main")
        self.merged = git(repo, "rev-parse", "HEAD")
        git(repo, "update-ref", "refs/remotes/origin/main", self.merged)
        git(repo, "checkout", "-q", "-b", "release")
        git(repo, "commit", "-q", "--allow-empty", "-m", "not merged")
        self.unmerged = git(repo, "rev-parse", "HEAD")
        self.repo = repo
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        (bin_dir / "gh").write_text(FAKE_GH)
        (bin_dir / "gh").chmod(0o700)
        self.bin_dir = bin_dir

    def tearDown(self):
        self.temporary.cleanup()

    def gate(self, sha, *, tag_at=None, checks=None, release="absent"):
        git(self.repo, "tag", "-f", "v9.0.1", tag_at or sha)
        checks = {name: "success" for name in REQUIRED_CHECKS} if checks is None else checks
        lines = "".join(
            json.dumps({"name": name, "status": "completed", "conclusion": conclusion}) + "\n"
            for name, conclusion in checks.items()
        )
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--tag", "v9.0.1", "--sha", sha, "--repo", "o/r"],
            cwd=self.repo, text=True, capture_output=True,
            env={**os.environ, "PATH": f"{self.bin_dir}{os.pathsep}{os.environ['PATH']}",
                 "TEST_CHECKS": lines, "TEST_RELEASE": release},
        )

    def test_a_green_tagged_commit_on_main_may_publish(self):
        result = self.gate(self.merged)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_draft_of_the_release_may_receive_its_assets(self):
        self.assertEqual(self.gate(self.merged, release="draft").returncode, 0)

    def test_a_published_release_is_never_replaced(self):
        result = self.gate(self.merged, release="published")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already published", result.stderr)

    def test_a_commit_not_on_main_is_refused(self):
        result = self.gate(self.unmerged)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not on origin/main", result.stderr)

    def test_a_build_of_another_commit_than_the_tag_is_refused(self):
        result = self.gate(self.merged, tag_at=self.unmerged)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("run the release from the tag", result.stderr)

    def test_every_required_check_must_be_green(self):
        for name in REQUIRED_CHECKS:
            for conclusion in ("failure", "skipped", None):
                with self.subTest(name=name, conclusion=conclusion):
                    checks = {other: "success" for other in REQUIRED_CHECKS}
                    if conclusion is None:
                        del checks[name]
                    else:
                        checks[name] = conclusion
                    result = self.gate(self.merged, checks=checks)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(f"'{name}'", result.stderr)


class SourceCommitTest(unittest.TestCase):
    COMMIT = "4736791e4" + "0" * 31

    def verify(self, zip_commit, tar_commit, loose_commit=COMMIT):
        with tempfile.TemporaryDirectory() as temporary:
            assets = Path(temporary)
            (assets / "SOURCE-COMMIT.txt").write_text(loose_commit + "\n")
            with zipfile.ZipFile(assets / "skotiq-9.0.1-windows-x64.zip", "w") as archive:
                archive.writestr("skotiq.exe", b"")
                if zip_commit:
                    archive.writestr("SOURCE-COMMIT.txt", zip_commit + "\r\n")
            with tarfile.open(assets / "skotiq-9.0.1-linux-x64.tar.gz", "w:gz") as archive:
                data = (tar_commit + "\n").encode()
                member = tarfile.TarInfo("skotiq-9.0.1-linux-x64/SOURCE-COMMIT.txt")
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
            return subprocess.run(
                [sys.executable, str(SCRIPT.with_name("verify_source_commit.py")),
                 "--assets", str(assets), "--commit", self.COMMIT],
                text=True, capture_output=True,
            )

    def test_archives_built_from_the_tag_commit_pass(self):
        result = self.verify(self.COMMIT, self.COMMIT)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_an_archive_from_another_commit_is_refused(self):
        other = "a" * 40
        for zip_commit, tar_commit, loose in (
            (other, self.COMMIT, self.COMMIT),
            (self.COMMIT, other, self.COMMIT),
            (self.COMMIT, self.COMMIT, other),
            (None, self.COMMIT, self.COMMIT),
        ):
            with self.subTest(zip=zip_commit, tar=tar_commit, loose=loose):
                self.assertNotEqual(self.verify(zip_commit, tar_commit, loose).returncode, 0)


if __name__ == "__main__":
    unittest.main()
