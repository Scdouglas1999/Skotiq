#!/usr/bin/env python3
"""Run every soak scenario (or the ones named) a few at a time and print one
summary line per scenario.

  python3 tools/harness/sim_night_soak/run_all.py            # all, 3 at a time
  python3 tools/harness/sim_night_soak/run_all.py -j 2 baseline operator

Each scenario gets its own API and PHD2 port. Logs go to
~/.cache/ns-soak/<scenario>.log; results.json stays in each scratch dir.
Exit status is 0 only when no scenario failed an invariant.
"""
import argparse
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from scenarios import SCENARIOS  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("names", nargs="*")
    ap.add_argument("-j", "--jobs", type=int, default=3)
    ap.add_argument("--skip", default="smoke", help="comma-separated scenarios to leave out")
    args = ap.parse_args()
    skip = set(filter(None, args.skip.split(",")))
    names = args.names or [n for n in SCENARIOS if n not in skip]
    root = os.path.expanduser("~/.cache/ns-soak")
    os.makedirs(root, exist_ok=True)
    pending = list(enumerate(names))
    running = {}
    results = {}
    while pending or running:
        while pending and len(running) < args.jobs:
            i, name = pending.pop(0)
            log = open(os.path.join(root, f"{name}.log"), "w")
            proc = subprocess.Popen(
                [sys.executable, os.path.join(HERE, "soak.py"), "--scenario", name,
                 "--port", str(8480 + i), "--phd2-port", str(4480 + i)],
                stdout=log, stderr=subprocess.STDOUT)
            running[name] = proc
            print(f"[run_all {time.strftime('%H:%M:%S')}] started {name} (pid {proc.pid})",
                  flush=True)
        time.sleep(5)
        for name, proc in list(running.items()):
            if proc.poll() is None:
                continue
            del running[name]
            summary = [ln.strip() for ln in open(os.path.join(root, f"{name}.log"))
                       if ln.startswith("[soak] FAIL") or ln.startswith("[soak] RESULT")]
            results[name] = proc.returncode
            print(f"[run_all {time.strftime('%H:%M:%S')}] {name} exit={proc.returncode}",
                  flush=True)
            for line in summary:
                print("    " + line[:300], flush=True)
    failed = [n for n, rc in results.items() if rc != 0]
    print(f"[run_all] {len(results) - len(failed)}/{len(results)} scenarios clean; "
          f"failed: {failed}", flush=True)
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
