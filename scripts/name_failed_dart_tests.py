#!/usr/bin/env python3
"""Name every failed Dart test in `flutter test --file-reporter json:` files.

CI's console reporter said "1482 tests passed, 1 failed" for the desktop
package and printed no failed test, three runs in a row: all 1,483 tests in
the run printed as passing. The one that failed was a test the reporters hide
(a setUpAll, a tearDownAll, or the loading of a test file) and it failed with
no error event, so the earlier step, which printed only error events, named
nothing. This reads each JSON file and prints:

  * every test, hidden or not, whose testDone result is not success, with
    its file;
  * every error event, with the test and file it belongs to;
  * every test that started and never finished, and every file whose suite
    never ended, so a test process that died is named too.

Exits 1 when it found any of these, 0 otherwise.
"""

import glob
import json
import sys


def failures(lines):
    """The failures recorded in one JSON reporter file, as text lines."""
    suites = {}
    tests = {}
    done = set()
    out = []
    finished = False
    for line in lines:
        try:
            event = json.loads(line)
        except ValueError:
            continue
        kind = event.get("type")
        if kind == "suite":
            suites[event["suite"]["id"]] = event["suite"].get("path") or "?"
        elif kind == "testStart":
            test = event["test"]
            tests[test["id"]] = test
        elif kind == "testDone":
            done.add(event["testID"])
            if event.get("result") != "success" and not event.get("skipped"):
                test = tests.get(event["testID"], {})
                hidden = " (hidden: setUpAll, tearDownAll or loading)" if event.get("hidden") else ""
                out.append(
                    f"FAILED {suites.get(test.get('suiteID'), '?')}: "
                    f"{test.get('name', '?')}{hidden}, result {event.get('result')}"
                )
        elif kind == "error":
            test = tests.get(event.get("testID"), {})
            out.append(
                f"ERROR {suites.get(test.get('suiteID'), '?')}: {test.get('name', '?')}\n"
                f"  {event.get('error', '')[:2000]}\n"
                f"  {event.get('stackTrace', '')[:2000]}"
            )
        elif kind == "done":
            finished = True
    for test_id, test in tests.items():
        if test_id not in done:
            out.append(
                f"NEVER FINISHED {suites.get(test.get('suiteID'), '?')}: {test.get('name', '?')}"
            )
    if tests and not finished:
        out.append("The run never reported done: the test runner stopped early.")
    return out


def main(paths):
    found = False
    for path in paths:
        with open(path, encoding="utf-8", errors="replace") as handle:
            lines = failures(handle)
        if lines:
            found = True
            print(f"== {path}")
            for line in lines:
                print(line)
            print()
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:] or glob.glob("**/test-results.json", recursive=True)))
