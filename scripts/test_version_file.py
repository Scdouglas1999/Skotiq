import unittest
from pathlib import Path

import version_file


class VersionFileTest(unittest.TestCase):
    def test_reads_every_field(self):
        self.assertEqual(
            version_file.read('version: "9.3.5"\nbuild_number: 46\nchannel: "stable"  # note\n'),
            {"version": "9.3.5", "build_number": 46, "channel": "stable"},
        )

    def test_reads_unquoted_and_commented_values(self):
        fields = version_file.read("version: 9.4.0 # next\nbuild_number: 47\nchannel: beta\n")
        self.assertEqual((fields["version"], fields["build_number"], fields["channel"]),
                         ("9.4.0", 47, "beta"))

    def test_a_missing_or_repeated_field_is_none(self):
        fields = version_file.read("channel: stable\nchannel: beta\n")
        self.assertEqual(fields, {"version": None, "build_number": None, "channel": None})

    def test_the_tree_declares_every_field(self):
        root = Path(__file__).resolve().parent.parent
        fields = version_file.read((root / "version.yaml").read_text())
        self.assertNotIn(None, fields.values())


if __name__ == "__main__":
    unittest.main()
