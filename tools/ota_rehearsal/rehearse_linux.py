#!/usr/bin/env python3
"""Drive a real Linux release bundle through an OTA update, one scenario at a time.

Run it inside netns_shim.sh (the README shows the full command). For each
scenario it:

  1. copies bundle N into a fresh install directory and starts it headless
     with a scratch data directory, database and HOME, on a private Xvfb
     display;
  2. seeds a profile and a setting through the API, so survival can be
     checked after the swap;
  3. points the fake GitHub at the scenario's release and drives
     check -> download -> apply through /api/system/update/*;
  4. records what the API said, what is on disk, which build answers
     afterwards, and whether the old build is still intact and runnable.

Each scenario leaves run/<name>/evidence.json plus app logs and the fake
server's request log. The process exit status is the number of scenarios
whose observed outcome did not match the expectation.
"""

import argparse
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
TOKEN = "ota-rehearsal-admin-token-0123456789abcdef"
OWNER, REPO = "Scdouglas1999", "Skotiq"


# --------------------------------------------------------------------------
# small helpers

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def tree_digest(root):
    """sha256 over (relative path, file sha256) for every regular file."""
    h = hashlib.sha256()
    for dirpath, dirnames, filenames in os.walk(root):
        if dirpath == root and "updates" in dirnames:
            # The updater keeps its lock file in <install>/updates.
            dirnames.remove("updates")
        dirnames.sort()
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            if os.path.islink(full) or not os.path.isfile(full):
                continue
            rel = os.path.relpath(full, root)
            h.update(rel.encode() + b"\0" + sha256(full).encode() + b"\n")
    return h.hexdigest()


class Api:
    def __init__(self, port):
        self.base = f"http://127.0.0.1:{port}"

    def call(self, method, path, body=None, timeout=15):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.base + path, data=data, method=method)
        req.add_header("Authorization", f"Bearer {TOKEN}")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read()
                return resp.status, (json.loads(raw) if raw else None)
        except urllib.error.HTTPError as e:
            raw = e.read()
            try:
                return e.code, json.loads(raw)
            except ValueError:
                return e.code, raw.decode(errors="replace")
        except (urllib.error.URLError, ConnectionError, TimeoutError) as e:
            return None, str(e)

    def up(self):
        status, _ = self.call("GET", "/api/info", timeout=2)
        return status == 200

    def job(self, job_id, timeout=600):
        """Poll /api/jobs/<id> until terminal. Returns the last body."""
        deadline = time.time() + timeout
        body = None
        while time.time() < deadline:
            status, body = self.call("GET", f"/api/jobs/{job_id}")
            if status is None:
                return {"state": "connection_lost", "detail": body}
            state = (body or {}).get("state") or (body or {}).get("status")
            if state in ("succeeded", "completed", "failed", "cancelled"):
                return body
            time.sleep(0.5)
        return {"state": "poll_timeout", "last": body}


# --------------------------------------------------------------------------
# process management: only ever signal processes whose executable lives in
# this run's own install directory

def pids_running_from(install_dir):
    install_dir = os.path.realpath(install_dir)
    found = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            exe = os.path.realpath(f"/proc/{entry}/exe")
        except OSError:
            continue
        if exe.startswith(install_dir + os.sep):
            found.append(int(entry))
    return found


def stop_install(install_dir, grace=20):
    pids = pids_running_from(install_dir)
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.time() + grace
    while time.time() < deadline and pids_running_from(install_dir):
        time.sleep(0.5)
    for pid in pids_running_from(install_dir):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


# --------------------------------------------------------------------------

class Run:
    def __init__(self, args, scenario):
        self.args = args
        self.sc = scenario
        self.name = scenario["name"]
        self.dir = os.path.join(args.root, "run", args.set, self.name)
        self.install = os.path.join(self.dir, "install")
        self.data = os.path.join(self.dir, "data")
        self.db = os.path.join(self.dir, "db")
        self.home = os.path.join(self.dir, "home")
        self.tmp = os.path.join(self.dir, "tmp")
        self.port = args.port
        self.api = Api(self.port)
        self.ev = {"scenario": self.name, "expect": scenario.get("expect"),
                   "steps": []}

    def step(self, what, **kw):
        kw["what"] = what
        kw["t"] = time.strftime("%H:%M:%S")
        self.ev["steps"].append(kw)
        print(f"  [{self.name}] {what}: " +
              json.dumps({k: v for k, v in kw.items() if k not in ("what", "t")})[:600],
              flush=True)

    # -- setup ------------------------------------------------------------

    def fresh(self):
        if os.path.exists(self.dir):
            subprocess.run(["chmod", "-R", "u+w", self.dir], check=False)
            if os.path.ismount(self.install):
                subprocess.run(["umount", self.install], check=False)
            shutil.rmtree(self.dir)
        for d in (self.dir, self.data, self.db, self.home, self.tmp):
            os.makedirs(d)
        shutil.copytree(self.args.bundle_n, self.install, symlinks=True)
        self.ev["n_tree_digest"] = tree_digest(self.install)

    def env(self):
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": self.home,
            "TMPDIR": self.tmp,
            "DISPLAY": self.args.display,
            "LIBGL_ALWAYS_SOFTWARE": "1",
            "GALLIUM_DRIVER": "softpipe",
            "SKOTIQ_DATA_DIR": self.data,
            "SKOTIQ_DATABASE_DIR": self.db,
        }
        if not self.sc.get("argv_config"):
            env.update({
                "SKOTIQ_HEADLESS": "1",
                "SKOTIQ_PORT": str(self.port),
                "SKOTIQ_AUTH_TOKEN": TOKEN,
            })
        return env

    def launch(self, label):
        log = open(os.path.join(self.dir, f"app-{label}.log"), "ab")
        cmd = [os.path.join(self.install, "skotiq")]
        if self.sc.get("argv_config"):
            cmd += ["--headless", f"--port={self.port}", f"--auth-token={TOKEN}"]
        proc = subprocess.Popen(cmd, env=self.env(), stdout=log, stderr=log,
                                cwd=self.dir, start_new_session=True)
        # Reap it as soon as it exits, the way a shell, a desktop launcher or
        # systemd does. An unreaped zombie still answers `kill -0`, and the
        # updater polls exactly that to decide the app has gone.
        threading.Thread(target=proc.wait, daemon=True).start()
        return proc

    def wait_up(self, timeout=90):
        # /api/info answers before the update endpoints are wired (the OTA
        # stack is provisioned late in startup and answers 503 until then),
        # so wait for the update status to answer too.
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.api.up():
                status, _ = self.api.call("GET", "/api/system/update/status", timeout=2)
                if status == 200:
                    return True
            time.sleep(1)
        return False

    def version(self):
        status, body = self.api.call("GET", "/api/system/version")
        return body if status == 200 else {"error": status, "body": body}

    def seed(self):
        status, body = self.api.call("POST", "/api/settings", {
            "settings": {"latitude": 12.345, "longitude": -67.891}})
        self.step("seed setting", status=status)
        status, body = self.api.call("POST", "/api/profiles", {"profile": {
            "id": "", "name": "ota-rehearsal-profile", "cameraId": "sim_camera_1",
            "mountId": "sim_mount_1", "focalLength": 1234.0, "aperture": 200.0}})
        self.step("seed profile", status=status)

    def survived(self):
        _, settings = self.api.call("GET", "/api/settings")
        _, profiles = self.api.call("GET", "/api/profiles")
        text_s = json.dumps(settings)
        text_p = json.dumps(profiles)
        return {"setting_latitude_kept": "12.345" in text_s,
                "profile_kept": "ota-rehearsal-profile" in text_p}

    # -- the update flow -----------------------------------------------------

    def set_release(self):
        scenario_file = os.path.join(self.args.root, "run", "server-scenario.json")
        rel = self.sc.get("release")
        doc = {"owner": OWNER, "repo": REPO,
               "releases": [rel] if rel else [],
               "download_mode": self.sc.get("download_mode", {})}
        tmp = scenario_file + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(doc, fh)
        os.replace(tmp, scenario_file)

    def check(self):
        status, body = self.api.call("POST", "/api/system/update/check")
        if status != 200:
            self.step("check request", status=status, body=body)
            return None
        result = self.api.job(body["jobId"], timeout=120)
        _, st = self.api.call("GET", "/api/system/update/status")
        self.step("check", job=result, status=st)
        return result, st

    def download(self):
        status, body = self.api.call("POST", "/api/system/update/download")
        if status != 200:
            self.step("download request", status=status, body=body)
            return None
        result = self.api.job(body["jobId"], timeout=900)
        _, st = self.api.call("GET", "/api/system/update/status")
        self.step("download", job=result, status=st)
        return result, st

    def apply(self):
        status, body = self.api.call("POST", "/api/system/update/apply")
        self.step("apply request", status=status, body=body)
        return status

    def staging_listing(self):
        root = os.path.join(self.data, "updates")
        out = []
        for dirpath, dirnames, filenames in os.walk(root):
            for n in filenames:
                out.append(os.path.relpath(os.path.join(dirpath, n), root))
        return sorted(out)[:60]

    def old_build_intact(self):
        return tree_digest(self.install) == self.ev["n_tree_digest"]

    def still_runnable(self):
        """Stop whatever is running from the install and start it again."""
        stop_install(self.install)
        proc = self.launch("restart-check")
        up = self.wait_up()
        v = self.version() if up else None
        stop_install(self.install)
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass
        return {"came_up": up, "version": v}


def wait_for_swap(run, timeout):
    """After apply: wait for the old process to go and something to answer."""
    t0 = time.time()
    went_down = False
    while time.time() - t0 < 30:
        if not run.api.up():
            went_down = True
            break
        time.sleep(0.25)
    back = False
    while time.time() - t0 < timeout:
        if run.api.up():
            back = True
            break
        time.sleep(1)
    return went_down, back, round(time.time() - t0, 1)


def run_scenario(args, sc):
    run = Run(args, sc)
    print(f"== {run.name}: {sc.get('expect')}", flush=True)
    run.fresh()
    for hook in sc.get("before_launch", []):
        pre_hook(run, hook)
    run.set_release()
    proc = run.launch("N")
    if not run.wait_up():
        run.step("N did not come up")
        return finish(run, False)
    run.step("N up", version=run.version())
    run.seed()

    outcome = {}
    checked = run.check()
    outcome["check"] = checked
    ok_check = checked is not None and checked[0].get("state") in ("succeeded", "completed")
    stop_after = sc.get("stop_after")
    if stop_after == "check" or not ok_check:
        return conclude(run, sc, outcome, proc)

    dl = run.download()
    outcome["download"] = dl
    if stop_after == "download" or dl is None or dl[0].get("state") not in ("succeeded", "completed"):
        return conclude(run, sc, outcome, proc)

    run.step("staging after download", files=run.staging_listing())
    for hook in sc.get("before_apply", []):
        pre_apply_hook(run, hook)

    run.apply()
    went_down, back, secs = wait_for_swap(run, sc.get("swap_timeout", 150))
    run.step("after apply", went_down=went_down, answered_again=back, seconds=secs)
    outcome["after_apply"] = {"went_down": went_down, "back": back}
    if back:
        time.sleep(3)
        v = run.version()
        _, st = run.api.call("GET", "/api/system/update/status")
        run.step("post-apply build", version=v, status=st,
                 survived=run.survived(), staging=run.staging_listing())
        outcome["post_version"] = v
        outcome["post_status"] = st
    marker = os.path.join(run.install, "REHEARSAL-MARKER.txt")
    run.ev["marker_after"] = open(marker).read().strip() if os.path.exists(marker) else None
    run.ev["install_is_N"] = run.old_build_intact()
    run.ev["updates_dir_after"] = run.staging_listing()
    err_log = os.path.join(run.tmp, "skotiq_update_error.log")
    if os.path.exists(err_log):
        run.ev["updater_error_log"] = open(err_log, errors="replace").read()[-3000:]
    for hook in sc.get("after_apply", []):
        after_apply_hook(run, hook, outcome)
    return conclude(run, sc, outcome, proc)


def pre_hook(run, hook):
    if hook == "readonly_install":
        # What ProtectSystem=strict does to /opt/skotiq in the appliance
        # unit: the service user cannot write its own install.
        subprocess.run(["mount", "--bind", run.install, run.install], check=True)
        subprocess.run(["mount", "-o", "remount,bind,ro", run.install], check=True)
        run.step("install made read-only (bind remount)")
    elif hook.startswith("tiny_staging:"):
        size = hook.split(":", 1)[1]
        staging = os.path.join(run.data, "updates", "staging")
        os.makedirs(staging, exist_ok=True)
        subprocess.run(["mount", "-t", "tmpfs", "-o", f"size={size}", "tmpfs",
                        staging], check=True)
        run.step("staging on a tmpfs", size=size)


def pre_apply_hook(run, hook):
    if hook == "corrupt_staged_desktop_binary":
        # Staged tree changed after verification: the Rust updater's own
        # post-apply hash check is what must catch it.
        # `skotiq` is the launcher wrapper; the real ELF is `skotiq.bin`.
        target = os.path.join(run.data, "updates", "staging", "extracted",
                              "skotiq.bin")
        with open(target, "r+b") as fh:
            fh.seek(4096)
            b = fh.read(1)
            fh.seek(4096)
            fh.write(bytes([b[0] ^ 0xFF]))
        run.step("flipped one byte in staged skotiq.bin")


def after_apply_hook(run, hook, outcome):
    if hook == "try_manual_rollback":
        _, st = run.api.call("GET", "/api/system/update/status")
        status, body = run.api.call("POST", "/api/system/update/rollback")
        run.step("manual rollback request", rollbackAvailable=(st or {}).get("rollbackAvailable"),
                 status=status, body=body)
        outcome["manual_rollback"] = {"status": status, "body": body}
        if status == 200:
            went_down, back, secs = wait_for_swap(run, 120)
            run.step("after rollback", went_down=went_down, back=back, seconds=secs,
                     version=run.version() if back else None)
    elif hook == "watch_for_rollback":
        # Give an updater that watches the relaunch time to notice and act.
        deadline = time.time() + 200
        while time.time() < deadline:
            if run.api.up():
                break
            time.sleep(2)
        up = run.api.up()
        run.step("after waiting for a rollback", answering=up,
                 version=run.version() if up else None,
                 marker=open(os.path.join(run.install, "REHEARSAL-MARKER.txt")).read().strip()
                 if os.path.exists(os.path.join(run.install, "REHEARSAL-MARKER.txt")) else None,
                 running=pids_running_from(run.install))
        outcome["after_rollback_wait"] = {"answering": up}


def conclude(run, sc, outcome, proc):
    run.ev["outcome"] = outcome
    run.ev["install_is_N_at_end"] = run.old_build_intact()
    if sc.get("check_runnable", True) and not outcome.get("after_apply", {}).get("back"):
        run.ev["restart"] = run.still_runnable()
    verdict = judge(run, sc, outcome)
    return finish(run, verdict)


def finish(run, verdict):
    stop_install(run.install)
    if os.path.ismount(run.install):
        subprocess.run(["umount", run.install], check=False)
    staging = os.path.join(run.data, "updates", "staging")
    if os.path.ismount(staging):
        subprocess.run(["umount", staging], check=False)
    run.ev["verdict"] = "as_expected" if verdict else "UNEXPECTED"
    with open(os.path.join(run.dir, "evidence.json"), "w") as fh:
        json.dump(run.ev, fh, indent=2, default=str)
    print(f"== {run.name}: {run.ev['verdict']}", flush=True)
    return verdict


def job_error(result):
    if not result:
        return ""
    job = result[0] or {}
    return json.dumps(job.get("error") or job.get("message") or job)


def judge(run, sc, outcome):
    exp = sc["expect"]
    if exp == "updated":
        v = outcome.get("post_version") or {}
        return (v.get("currentVersion") == sc["target_version"]
                and v.get("buildNumber") == sc["target_build"]
                and run.ev.get("marker_after") == sc.get("target_marker"))
    if exp.startswith("refused_at_check"):
        chk = outcome.get("check")
        if not chk:
            return False
        job, st = chk
        needle = sc.get("reason_contains", "")
        text = json.dumps(job) + json.dumps(st)
        return (st or {}).get("state") in ("failed", "idle") and needle in text \
            and run.ev["install_is_N_at_end"]
    if exp == "no_update":
        chk = outcome.get("check")
        if not chk:
            return False
        job, st = chk
        res = job.get("result") or {}
        return not res.get("available", False) \
            and run.ev["install_is_N_at_end"]
    if exp == "refused_at_download":
        dl = outcome.get("download")
        if not dl:
            return False
        job, st = dl
        text = json.dumps(job) + json.dumps(st)
        return job.get("state") == "failed" and sc.get("reason_contains", "") in text \
            and run.ev["install_is_N_at_end"] and (run.ev.get("restart") or {}).get("came_up")
    if exp == "rolled_back_and_running":
        # The restored build must be the one answering, say what happened,
        # and not offer the rolled-back update as ready to install.
        v = outcome.get("post_version") or {}
        st = outcome.get("post_status") or {}
        return (v.get("currentVersion") == sc["n_version"] and run.ev["install_is_N_at_end"]
                and "Rollback restored" in (st.get("message") or "")
                and st.get("state") != "staged")
    if exp == "apply_refused_n_running":
        after = outcome.get("after_apply") or {}
        v = outcome.get("post_version") or {}
        return (not after.get("went_down") and v.get("currentVersion") == sc["n_version"]
                and run.ev["install_is_N_at_end"])
    return False


# --------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True, help="rehearsal root (~/.cache/ns-ota)")
    ap.add_argument("--set", required=True, help="build set label, e.g. base or fixed")
    ap.add_argument("--bundle-n", required=True)
    ap.add_argument("--scenarios", required=True, help="scenarios JSON file")
    ap.add_argument("--only", nargs="*", help="run only these scenario names")
    ap.add_argument("--port", type=int, default=18931)
    ap.add_argument("--display", default=":79")
    ap.add_argument("--keys", required=True)
    args = ap.parse_args()

    os.makedirs(os.path.join(args.root, "run", args.set), exist_ok=True)
    scenario_file = os.path.join(args.root, "run", "server-scenario.json")
    with open(scenario_file, "w") as fh:
        json.dump({"owner": OWNER, "repo": REPO, "releases": []}, fh)

    xvfb = subprocess.Popen(["Xvfb", args.display, "-screen", "0", "1600x1000x24",
                             "-nolisten", "tcp"], stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
    server_log = os.path.join(args.root, "run", args.set, "requests.log")
    server = subprocess.Popen([sys.executable, os.path.join(HERE, "fake_github.py"),
                               "--scenario", scenario_file,
                               "--cert", os.path.join(args.keys, "tls", "srv.crt"),
                               "--key", os.path.join(args.keys, "tls", "srv.key"),
                               "--log", server_log])
    time.sleep(1.5)

    with open(args.scenarios) as fh:
        scenarios = json.load(fh)
    failures = 0
    try:
        for sc in scenarios:
            if args.only and sc["name"] not in args.only:
                continue
            if not run_scenario(args, sc):
                failures += 1
    finally:
        server.terminate()
        xvfb.terminate()
    print(f"scenarios not as expected: {failures}")
    return failures


if __name__ == "__main__":
    sys.exit(main())
