import json
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parent))
from name_failed_dart_tests import failures  # noqa: E402


def _lines(*events):
    return [json.dumps(event) for event in events]


SUITE = {"type": "suite", "suite": {"id": 0, "path": "test/a_test.dart"}}


def _start(test_id, name):
    return {"type": "testStart", "test": {"id": test_id, "name": name, "suiteID": 0}}


def _done(test_id, result="success", hidden=False):
    return {"type": "testDone", "testID": test_id, "result": result, "hidden": hidden, "skipped": False}


class NameFailedDartTests(unittest.TestCase):
    def test_a_hidden_failure_with_no_error_event_is_named(self):
        # The desktop package on CI: every test passed, and a hidden one
        # failed with no error event.
        lines = _lines(
            SUITE,
            _start(1, "a test"),
            _done(1),
            _start(2, "(tearDownAll)"),
            _done(2, result="error", hidden=True),
            {"type": "done", "success": False},
        )
        found = failures(lines)
        self.assertEqual(len(found), 1)
        self.assertIn("test/a_test.dart: (tearDownAll)", found[0])
        self.assertIn("hidden", found[0])

    def test_an_error_names_its_test_and_file(self):
        lines = _lines(
            SUITE,
            _start(1, "a test"),
            {"type": "error", "testID": 1, "error": "boom", "stackTrace": "", "isFailure": False},
            _done(1, result="error"),
            {"type": "done", "success": False},
        )
        found = failures(lines)
        self.assertTrue(any("ERROR test/a_test.dart: a test" in line and "boom" in line for line in found))

    def test_a_test_that_never_finished_is_named(self):
        lines = _lines(SUITE, _start(1, "a test"))
        found = failures(lines)
        self.assertIn("NEVER FINISHED test/a_test.dart: a test", found)

    def test_a_clean_run_names_nothing(self):
        lines = _lines(SUITE, _start(1, "a test"), _done(1), {"type": "done", "success": True})
        self.assertEqual(failures(lines), [])


if __name__ == "__main__":
    unittest.main()
