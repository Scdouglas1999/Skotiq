#!/usr/bin/env python3
"""Run one compressed simulator night against the RELEASE bundle, headless,
with faults injected, and check what a real night must not get wrong.

  python3 tools/harness/sim_night_soak/soak.py --scenario baseline
  python3 tools/harness/sim_night_soak/soak.py --list

Everything lands under --scratch (default ~/.cache/ns-soak/<scenario>): the
database, frames, logs, the resource CSV, the guider timeline, the status
timeline and results.json. The exit status is 0 only when every invariant held.
See README.md for what each invariant means and why it is there.

Python standard library only.
"""
import argparse
import json
import os
import shutil
import signal
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import night_plan  # noqa: E402
import invariants  # noqa: E402
from scenarios import SCENARIOS  # noqa: E402

REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
DEFAULT_BUNDLE = os.path.join(REPO, "apps/desktop/build/linux/x64/release/bundle/skotiq_desktop")
DEFAULT_ASTAP = os.path.expanduser("~/.local/share/skotiq-audit/astap/bin")
TOKEN = "soak-secret-token"
TERMINAL = {"completed", "failed", "cancelled", "stopped", "error"}


class Soak:
    def __init__(self, args, scenario):
        self.args = args
        self.sc = scenario
        self.root = os.path.abspath(args.scratch)
        self.db_dir = os.path.join(self.root, "db")
        self.data_dir = os.path.join(self.root, "data")
        self.out_dir = os.path.join(self.root, "captures")
        self.tmp_dir = os.path.join(self.root, "tmp")
        self.base = f"http://127.0.0.1:{args.port}"
        self.app = None
        self.phd2 = None
        self.events = open(os.path.join(self.root, "timeline.jsonl"), "a", buffering=1) \
            if os.path.isdir(self.root) else None
        self.stop_sampler = threading.Event()
        self.actions = []

    # ---- plumbing ----------------------------------------------------------

    def note(self, what, **extra):
        rec = {"t": time.time(), "what": what}
        rec.update(extra)
        if self.events:
            self.events.write(json.dumps(rec) + "\n")
        print(f"[soak {time.strftime('%H:%M:%S')}] {what} "
              + (json.dumps(extra) if extra else ""), flush=True)

    def api(self, method, path, body=None, timeout=20, ok_statuses=(200,)):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.base + path, data=data, method=method,
                                     headers={"Authorization": "Bearer " + TOKEN,
                                              "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read().decode("utf-8", "replace")
                status = resp.status
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode("utf-8", "replace")
            status = exc.code
        try:
            parsed = json.loads(raw) if raw else None
        except ValueError:
            parsed = raw
        if status not in ok_statuses:
            raise RuntimeError(f"{method} {path} -> {status}: {raw[:400]}")
        return parsed

    def launch(self, extra_env=None):
        env = dict(os.environ)
        env.update({
            "SKOTIQ_DATABASE_DIR": self.db_dir,
            "SKOTIQ_DATA_DIR": self.data_dir,
            "TMPDIR": self.tmp_dir,
            "LIBGL_ALWAYS_SOFTWARE": "1",
        })
        env.pop("SKOTIQ_SIM_FAULTS", None)
        env.update(extra_env or {})
        log = open(os.path.join(self.root, "app.log"), "ab")
        self.app = subprocess.Popen(
            [self.args.bundle, "--headless", f"--auth-token={TOKEN}", f"--port={self.args.port}"],
            env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        with open(os.path.join(self.root, "app.pid"), "w") as fh:
            fh.write(str(self.app.pid))
        for _ in range(90):
            time.sleep(1)
            if self.app.poll() is not None:
                raise RuntimeError(f"app exited during launch with {self.app.returncode}")
            try:
                urllib.request.urlopen(self.base + "/api/info", timeout=2).read()
                self.note("app_up", pid=self.app.pid)
                return
            except (urllib.error.URLError, OSError):
                continue
        raise RuntimeError("API never came up")

    def stop_app(self, grace=30):
        if not self.app or self.app.poll() is not None:
            return None
        t0 = time.time()
        self.app.send_signal(signal.SIGTERM)
        try:
            self.app.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            self.note("app_sigterm_timeout", after_secs=grace)
            self.app.kill()
            self.app.wait(timeout=10)
        return time.time() - t0

    def start_phd2(self):
        faults = self.sc.get("phd2_faults", "")
        timeline = os.path.join(self.root, "phd2_timeline.jsonl")
        log = open(os.path.join(self.root, "phd2.log"), "ab")
        self.phd2 = subprocess.Popen(
            [sys.executable, os.path.join(HERE, "fake_phd2.py"), "--port", str(self.args.phd2_port),
             "--faults", faults, "--timeline", timeline,
             "--drop-secs", str(self.sc.get("phd2_drop_secs", 60))],
            stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        time.sleep(1.0)
        if self.phd2.poll() is not None:
            raise RuntimeError("fake PHD2 did not start (port busy?)")
        self.note("phd2_up", pid=self.phd2.pid, faults=faults)

    def db(self):
        conn = sqlite3.connect(os.path.join(self.db_dir, "skotiq.db"), timeout=15)
        conn.row_factory = sqlite3.Row
        return conn

    # ---- resource sampler ----------------------------------------------------

    def sampler(self):
        path = os.path.join(self.root, "resources.csv")
        with open(path, "w", buffering=1) as fh:
            fh.write("t,elapsed_s,rss_mb,swap_mb,mem_mb,fds,threads,db_mb,wal_mb,logs_mb,tmp_mb,captures_mb\n")
            t0 = time.time()
            while not self.stop_sampler.is_set():
                row = sample_process(self.app.pid, self.db_dir, self.data_dir, self.tmp_dir,
                                     self.out_dir, self.root)
                if row is None:
                    break
                fh.write(f"{time.time():.0f},{time.time() - t0:.0f}," + ",".join(
                    f"{row[k]:.2f}" for k in ("rss_mb", "swap_mb", "mem_mb", "fds", "threads", "db_mb", "wal_mb",
                                               "logs_mb", "tmp_mb", "captures_mb")) + "\n")
                self.stop_sampler.wait(self.args.sample_secs)

    # ---- the run ------------------------------------------------------------------

    def prepare(self):
        if os.path.exists(self.root):
            shutil.rmtree(self.root)
        for d in (self.db_dir, self.data_dir, self.out_dir, self.tmp_dir):
            os.makedirs(d)
        self.events = open(os.path.join(self.root, "timeline.jsonl"), "a", buffering=1)
        free_mb = shutil.disk_usage(self.root).free // (1 << 20)
        if free_mb < 8000:
            raise RuntimeError(f"{self.root} has {free_mb} MB free; a soak night needs 8 GB")

    def seed_settings(self):
        """Settings the headless start reads from the database (daemon stopped)."""
        now = int(time.time() * 1000)
        seeds = {
            # Autofocus every N frames; the operator's "L" autofocus filter is
            # set over the API below. Dither 3 px, settle 1.5 px for 3 s.
            "sequencer_autofocus_interval_frames": str(self.sc.get("af_interval", 60)),
            "sequencer_autofocus_step_size": "40",
            "sequencer_autofocus_steps_out": "5",
            "sequencer_autofocus_exposure_duration": "8.0",
            "sequencer_dither_pixels": "3.0",
            "sequencer_dither_settle_pixels": "1.5",
            "sequencer_dither_settle_time": "3.0",
            "sequencer_dither_settle_timeout": "30.0",
            "meridian_flip_settings": json.dumps({
                "minutesPastMeridian": 5.0, "pauseGuidingBeforeFlip": True,
                "recenterAfterFlip": True, "refocusAfterFlip": False,
                "settleTimeSeconds": 5.0, "resumeGuidingAfterFlip": True,
                "maxRetries": 2, "retryDelaysSeconds": [10.0, 20.0]}),
        }
        seeds.update(self.sc.get("settings_seed", {}))
        conn = self.db()
        for key, value in seeds.items():
            conn.execute("INSERT INTO app_settings(key,value,updated_at) VALUES(?,?,?) "
                         "ON CONFLICT(key) DO UPDATE SET value=excluded.value", (key, value, now))
        conn.commit()
        conn.close()
        self.note("settings_seeded", keys=sorted(seeds))

    def configure(self, facts):
        site = facts["site"]
        self.api("POST", "/api/settings", {"settings": {
            "imageOutputPath": self.out_dir, "latitude": site["lat"], "longitude": site["lon"],
            "afAutofocusFilterName": "L", "afStepSize": 40, "afExposureTime": 8.0,
            "afNumberOfAttempts": 2, "afExposuresPerPoint": 1,
            # The simulated sky is a faint field: at best focus a 15 s frame
            # measures ~3.7 px mean HFR, over the 3.5 px default.
            "enableImageGrading": True, "imageGradingHfrThresholdPx": 5.5}})
        self.api("POST", "/api/settings/location", {"location": {
            "latitude": site["lat"], "longitude": site["lon"], "elevation": 2000.0}})
        astap = self.args.astap_dir
        if os.path.exists(os.path.join(astap, "astap_cli")):
            self.api("POST", "/api/plate-solver/config", {
                "astapPath": os.path.join(astap, "astap_cli"), "astrometryPath": "",
                "catalogPath": astap, "solverChoice": "astap"})
        else:
            self.note("no_astap", dir=astap)
        profile = self.api("POST", "/api/profiles", {"profile": {
            "id": "", "name": "soak-sim-rig", "cameraId": "sim_camera_1",
            "mountId": "sim_mount_1", "filterWheelId": "sim_filterwheel_1",
            "focuserId": "sim_focuser_1", "focalLength": 1000.0, "aperture": 200.0,
            "defaultBinX": 1, "defaultBinY": 1,
            "filterNames": json.dumps(night_plan.FILTERS)}})
        pid = (profile or {}).get("id")
        if not pid:
            raise RuntimeError(f"profile create failed: {profile}")
        self.api("POST", f"/api/profiles/{pid}/load")
        for dtype, did in (("camera", "sim_camera_1"), ("mount", "sim_mount_1"),
                           ("filterWheel", "sim_filterwheel_1"), ("focuser", "sim_focuser_1")):
            self.api("POST", "/api/devices/connect", {"deviceId": did, "deviceType": dtype},
                     timeout=60)
            time.sleep(0.5)
        self.api("POST", "/api/phd2/connect", {"host": "127.0.0.1", "port": self.args.phd2_port},
                 timeout=60)
        self.api("POST", "/api/sequencer/save-path", {"path": self.out_dir})
        # A compressed recovery ladder, so a fault scenario reaches the
        # give-up branch inside the soak (the default is 10 min x 90 min).
        # Parking stays off: none of these nights opts in to it.
        self.api("POST", "/api/sequencer/recovery/update-config", {
            "retryIntervalSecs": self.sc.get("recovery_retry_secs", 60.0),
            "maxDurationSecs": self.sc.get("recovery_max_secs", 300.0),
            "stopTrackingDuringRecovery": True, "abortOnMeridian": True,
            "audibleAlertWhenEntered": False,
            "parkAndCloseWhenRecoveryGivesUp": False})
        self.note("configured", profile=pid)

    def run(self):
        self.prepare()
        definition, facts = night_plan.build_plan(self.args.minutes, self.sc.get("exposure_secs", 15.0))
        facts["scenario"] = self.args.scenario
        facts["sim_faults"] = self.sc.get("sim_faults", "")
        facts["phd2_faults"] = self.sc.get("phd2_faults", "")
        with open(os.path.join(self.root, "plan.json"), "w") as fh:
            json.dump({"facts": facts, "definition": definition}, fh, indent=1)
        self.note("plan", site=facts["site"]["name"], targets=list(facts["targets"]))

        self.launch()                       # schema-creation boot
        self.stop_app()
        self.seed_settings()
        self.start_phd2()
        env = {"SKOTIQ_SIM_NIGHT_COOLING_C_PER_HOUR": str(self.sc.get("cooling", 4.0))}
        if self.sc.get("sim_faults"):
            env["SKOTIQ_SIM_FAULTS"] = self.sc["sim_faults"]
        env.update(self.sc.get("env", {}))
        self.launch(env)
        sampler = threading.Thread(target=self.sampler, daemon=True)
        sampler.start()
        result = {"scenario": self.args.scenario, "facts": facts}
        try:
            self.configure(facts)
            loaded = self.api("POST", "/api/sequencer/load", night_plan.envelope(definition),
                              timeout=60, ok_statuses=(200, 400, 409))
            self.note("loaded", response=loaded if isinstance(loaded, dict) else str(loaded)[:200])
            start_t = time.time()
            started = self.api("POST", "/api/sequencer/start", {}, timeout=120,
                               ok_statuses=(200, 400, 409, 500))
            self.note("start", response=started)
            result["start_response"] = started
            result["run"] = self.watch(start_t, facts)
        except Exception as exc:  # noqa: BLE001 - the run's failure is a result
            self.note("harness_error", error=str(exc))
            result["harness_error"] = str(exc)
        finally:
            result["final"] = self.collect()
            self.stop_sampler.set()
            sampler.join(timeout=5)
            result["shutdown_secs"] = self.stop_app()
            if self.phd2 and self.phd2.poll() is None:
                self.phd2.terminate()
                try:
                    self.phd2.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.phd2.kill()
        verdicts = invariants.check_all(self.root, result, self.sc)
        result["invariants"] = verdicts
        with open(os.path.join(self.root, "results.json"), "w") as fh:
            json.dump(result, fh, indent=1, default=str)
        failed = [v for v in verdicts if v["verdict"] == "FAIL"]
        for v in verdicts:
            print(f"[soak] {v['verdict']:5s} {v['name']}: {v['detail']}")
        print(f"[soak] RESULT scenario={self.args.scenario} "
              f"PASS={sum(v['verdict'] == 'PASS' for v in verdicts)} FAIL={len(failed)} "
              f"SKIP={sum(v['verdict'] == 'SKIP' for v in verdicts)}")
        return 0 if not failed else 1

    def watch(self, start_t, facts):
        """Poll status until a terminal state, running scheduled operator actions."""
        deadline = start_t + self.args.minutes * 60.0 * 2.5 + 600
        last_state = None
        pending = sorted(self.sc.get("actions", []), key=lambda a: a["at_min"])
        paused_for = None
        operator_paused = False
        record = {"states": [], "actions": []}
        while time.time() < deadline:
            time.sleep(2)
            if self.app.poll() is not None:
                record["app_exit"] = self.app.returncode
                self.note("app_exited", code=self.app.returncode)
                break
            try:
                st = self.api("GET", "/api/sequencer/status", timeout=15)
            except Exception as exc:  # noqa: BLE001
                self.note("status_error", error=str(exc))
                continue
            state = (st or {}).get("state")
            if state != last_state:
                self.note("state", state=state, node=st.get("currentNodeName"),
                          target=st.get("currentTarget"), message=st.get("message"))
                record["states"].append({"t": time.time(), "state": state,
                                         "node": st.get("currentNodeName"),
                                         "message": st.get("message")})
                last_state = state
            record["last_status"] = st
            elapsed_min = (time.time() - start_t) / 60.0
            while pending and elapsed_min >= pending[0]["at_min"]:
                action = pending.pop(0)
                operator_paused = action["verb"] == "pause"
                record["actions"].append(self.do_action(action))
            # A run that holds itself for the operator: record it, leave it
            # held long enough to prove no frame is taken while held, then do
            # what the operator would and Stop it.
            if state in ("paused", "recovering") and not operator_paused:
                if paused_for is None:
                    paused_for = time.time()
                    record["self_paused_at"] = paused_for
                    record["self_pause_message"] = st.get("message")
                elif self.sc.get("stop_after_pause_s") is not None and \
                        time.time() - paused_for >= self.sc["stop_after_pause_s"] and \
                        not record.get("stopped_after_pause"):
                    record["stopped_after_pause"] = True
                    record["actions"].append(self.do_action({"verb": "stop", "budget_s": 45}))
            elif state not in ("paused", "recovering"):
                paused_for = None
            if state in TERMINAL or (state == "idle" and record.get("stopped_after_pause")):
                break
        else:
            record["timed_out"] = True
            self.note("watch_timeout")
        record["elapsed_s"] = time.time() - start_t
        return record

    def do_action(self, action):
        """An operator action, timed until the state it asks for is visible."""
        verb = action["verb"]
        want = {"pause": {"paused"}, "resume": {"running"},
                "stop": TERMINAL | {"idle"}}[verb]
        t0 = time.time()
        body = {"preserveCheckpoint": True} if verb == "stop" else {}
        try:
            resp = self.api("POST", f"/api/sequencer/{verb}", body, timeout=120,
                            ok_statuses=(200, 409))
        except Exception as exc:  # noqa: BLE001
            resp = {"error": str(exc)}
        seen = None
        while time.time() - t0 < action.get("budget_s", 60) + 30:
            try:
                st = self.api("GET", "/api/sequencer/status", timeout=10)
            except Exception:  # noqa: BLE001
                time.sleep(0.5)
                continue
            if st and st.get("state") in want:
                seen = st.get("state")
                break
            time.sleep(0.5)
        rec = {"verb": verb, "at": t0, "response": resp, "reached": seen,
               "latency_s": time.time() - t0, "budget_s": action.get("budget_s", 60)}
        self.note("action", **rec)
        return rec

    def collect(self):
        """Everything the invariants read, captured before shutdown."""
        out = {}
        for name, path in (("status", "/api/sequencer/status"), ("mount", "/api/mount/status"),
                           ("phd2", "/api/phd2/status"), ("recovery", "/api/sequencer/recovery/history")):
            try:
                out[name] = self.api("GET", path, timeout=15, ok_statuses=(200, 404, 409, 500))
            except Exception as exc:  # noqa: BLE001
                out[name] = {"error": str(exc)}
        try:
            conn = self.db()
            out["captured_images"] = [dict(r) for r in conn.execute(
                "SELECT ci.id, ci.file_path, ci.file_name, ci.session_id, ci.frame_type, "
                "ci.exposure_duration, ci.filter, ci.hfr, ci.star_count, ci.is_accepted, "
                "ci.rejection_reason, ci.mount_ra, ci.mount_dec, ci.captured_at, "
                "ci.focuser_position, ci.focuser_temp, ci.pier_side, ci.target_id "
                "FROM captured_images ci ORDER BY ci.id")]
            out["sequence_runs"] = [dict(r) for r in conn.execute("SELECT * FROM sequence_runs")]
            out["imaging_sessions"] = [dict(r) for r in conn.execute("SELECT * FROM imaging_sessions")]
            conn.close()
        except Exception as exc:  # noqa: BLE001
            out["db_error"] = str(exc)
        return out


def dir_mb(path):
    total = 0
    for base, _dirs, files in os.walk(path):
        for f in files:
            try:
                total += os.lstat(os.path.join(base, f)).st_size
            except OSError:
                pass
    return total / (1 << 20)


def sample_process(pid, db_dir, data_dir, tmp_dir, out_dir, root):
    try:
        with open(f"/proc/{pid}/status") as fh:
            status = fh.read()
    except OSError:
        return None
    fields = dict(line.split(":", 1) for line in status.splitlines() if ":" in line)
    rss_kb = float(fields.get("VmRSS", "0 kB").split()[0])
    # The machine swaps to zram under load, so RSS alone can fall while the
    # process grows; resident + swapped is what a leak moves.
    swap_kb = float(fields.get("VmSwap", "0 kB").split()[0])
    threads = float(fields.get("Threads", "0").strip())
    try:
        fds = float(len(os.listdir(f"/proc/{pid}/fd")))
    except OSError:
        fds = -1.0
    db = os.path.join(db_dir, "skotiq.db")
    size = lambda p: os.path.getsize(p) / (1 << 20) if os.path.exists(p) else 0.0  # noqa: E731
    logs = dir_mb(os.path.join(data_dir, "logs")) + size(os.path.join(root, "app.log"))
    return {"rss_mb": rss_kb / 1024.0, "swap_mb": swap_kb / 1024.0,
            "mem_mb": (rss_kb + swap_kb) / 1024.0, "fds": fds, "threads": threads,
            "db_mb": size(db), "wal_mb": size(db + "-wal"), "logs_mb": logs,
            "tmp_mb": dir_mb(tmp_dir), "captures_mb": dir_mb(out_dir)}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--scenario", default="baseline")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--bundle", default=os.environ.get("SOAK_BUNDLE", DEFAULT_BUNDLE))
    ap.add_argument("--scratch", default=None)
    ap.add_argument("--port", type=int, default=8470)
    ap.add_argument("--phd2-port", type=int, default=4470)
    ap.add_argument("--minutes", type=float, default=80.0,
                    help="planned length of the compressed night")
    ap.add_argument("--sample-secs", type=float, default=30.0)
    ap.add_argument("--astap-dir", default=os.environ.get("SOAK_ASTAP_DIR", DEFAULT_ASTAP))
    ap.add_argument("--recheck", action="store_true",
                    help="re-run the invariant checks on an existing scratch dir")
    args = ap.parse_args()
    if args.list:
        for name, sc in SCENARIOS.items():
            print(f"{name:22s} {sc['about']}")
        return 0
    if args.scenario not in SCENARIOS:
        print(f"unknown scenario {args.scenario}; --list shows them", file=sys.stderr)
        return 2
    sc = dict(SCENARIOS[args.scenario])
    args.minutes = sc.get("minutes", args.minutes)
    args.scratch = args.scratch or os.path.expanduser(f"~/.cache/ns-soak/{args.scenario}")
    if args.recheck:
        with open(os.path.join(args.scratch, "results.json")) as fh:
            result = json.load(fh)
        verdicts = invariants.check_all(os.path.abspath(args.scratch), result, sc)
        for v in verdicts:
            print(f"[soak] {v['verdict']:5s} {v['name']}: {v['detail']}")
        return 0 if all(v["verdict"] != "FAIL" for v in verdicts) else 1
    if not os.path.exists(args.bundle):
        print(f"no bundle at {args.bundle}; build it (see README)", file=sys.stderr)
        return 2
    return Soak(args, sc).run()


if __name__ == "__main__":
    sys.exit(main())
