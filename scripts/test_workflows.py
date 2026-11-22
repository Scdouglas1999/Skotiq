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


if __name__ == "__main__":
    unittest.main()
