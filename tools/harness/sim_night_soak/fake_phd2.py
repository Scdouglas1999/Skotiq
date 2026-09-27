#!/usr/bin/env python3
"""A PHD2 stand-in for simulator nights: speaks PHD2's JSON-RPC and event
protocol on a TCP port, guides a make-believe star, and fails on a schedule.

Why this exists: the owner's rig guides with PHD2, and the night of 2026-09-14
was lost to a guider that accepted a resume and never locked again while the run
kept exposing. The in-app simulators have no guider at all, so a sequence with
StartGuiding or Dither could not run offline, and none of the guiding failure
paths could be exercised. This server can be told to lose the star, refuse to
re-acquire, stall a settle, or drop the connection, and it writes a timeline of
what it did so an invariant check can compare the app's frames against the
guider's real state.

Protocol per the PHD2 EventMonitoring wiki: newline-delimited JSON, events carry
"Event", RPC requests carry "method"/"id", responses carry "result" or "error"
and the request's "id". Only what Nightshade calls is implemented; anything
else answers a JSON-RPC error, which is what a real PHD2 does for a method it
does not know.

Faults (--faults, comma separated, times in seconds after the FIRST `guide`):
  lose_star_at=T        star lost at T: StarLost events, AppState LostLock,
                        no more GuideSteps until a `guide` re-acquires
  resume_fails          after a loss, `guide` answers success but never locks
                        (the 2026-09-14 failure); the state stays LostLock
  resume_fails_times=N  like resume_fails for the first N `guide` calls only
  settle_fails_at=T     the first dither/guide settle after T reports
                        SettleDone Status 1 "timed-out"
  drop_at=T             close the connection at T and refuse reconnects for
                        --drop-secs seconds
Timeline: JSON lines to --timeline, one per state change, with wall-clock time.
"""
import argparse
import json
import random
import socket
import socketserver
import sys
import threading
import time

LOCK = threading.RLock()


class Guider:
    def __init__(self, args):
        self.args = args
        self.state = "Stopped"
        self.first_guide_at = None
        self.faults = parse_faults(args.faults)
        self.lost = False
        self.resume_refusals_left = self.faults.get("resume_fails_times", 0)
        if "resume_fails" in self.faults:
            self.resume_refusals_left = 10**9
        self.settle_fail_armed = False
        self.dropped_until = 0.0
        self.frame = 0
        self.clients = []
        self.timeline = open(args.timeline, "a", buffering=1) if args.timeline else None
        self.dither_kick = 0.0
        self.rng = random.Random(args.seed)
        self.log("start", state=self.state)

    def log(self, what, **extra):
        rec = {"t": time.time(), "what": what, "state": self.state}
        rec.update(extra)
        if self.timeline:
            self.timeline.write(json.dumps(rec) + "\n")
        print("[fake-phd2] " + json.dumps(rec), flush=True)

    def set_state(self, state, why):
        if state != self.state:
            self.state = state
            self.log("state", why=why)
        self.broadcast({"Event": "AppState", "State": state})

    def since_first_guide(self):
        return None if self.first_guide_at is None else time.time() - self.first_guide_at

    def broadcast(self, event):
        event.setdefault("Timestamp", time.time())
        event.setdefault("Host", "sim")
        event.setdefault("Inst", 1)
        line = (json.dumps(event) + "\r\n").encode()
        for client in list(self.clients):
            try:
                client.sendall(line)
            except OSError:
                pass

    # ---- the guide loop -------------------------------------------------

    def tick(self):
        """Advance scheduled faults and emit one frame's worth of events."""
        with LOCK:
            elapsed = self.since_first_guide()
            if elapsed is not None:
                t_lose = self.faults.get("lose_star_at")
                if t_lose is not None and elapsed >= t_lose and not self.faults.get("_lost_done"):
                    self.faults["_lost_done"] = True
                    self.lost = True
                    self.log("fault", fault="lose_star")
                    self.broadcast({"Event": "StarLost", "Frame": self.frame, "SNR": 2.1,
                                    "StarMass": 900, "AvgDist": 40.0,
                                    "ErrorCode": 1, "Status": "star lost"})
                    self.set_state("LostLock", "star lost")
                t_settle = self.faults.get("settle_fails_at")
                if t_settle is not None and elapsed >= t_settle and not self.faults.get("_settle_armed"):
                    self.faults["_settle_armed"] = True
                    self.settle_fail_armed = True
                    self.log("fault", fault="settle_fails_armed")
                t_drop = self.faults.get("drop_at")
                if t_drop is not None and elapsed >= t_drop and not self.faults.get("_drop_done"):
                    self.faults["_drop_done"] = True
                    self.dropped_until = time.time() + self.args.drop_secs
                    self.log("fault", fault="drop", secs=self.args.drop_secs)
                    for client in list(self.clients):
                        try:
                            client.shutdown(socket.SHUT_RDWR)
                            client.close()
                        except OSError:
                            pass
                    self.clients.clear()
                    self.state = "Stopped"
                    self.lost = False
            self.frame += 1
            if self.state == "Guiding":
                kick = self.dither_kick
                self.dither_kick *= 0.4
                ra = self.rng.gauss(0.0, 0.25) + kick
                dec = self.rng.gauss(0.0, 0.2) + kick * 0.5
                self.broadcast({"Event": "GuideStep", "Frame": self.frame, "Time": 2.0,
                                "Mount": "Sim", "dx": ra, "dy": dec,
                                "RADistanceRaw": ra, "DECDistanceRaw": dec,
                                "RADistanceGuide": ra, "DECDistanceGuide": dec,
                                "RADuration": int(abs(ra) * 100),
                                "RADirection": "East" if ra > 0 else "West",
                                "DECDuration": int(abs(dec) * 100),
                                "DECDirection": "North" if dec > 0 else "South",
                                "StarMass": 120000 + self.rng.gauss(0, 3000),
                                "SNR": 60.0 + self.rng.gauss(0, 2), "HFD": 2.4,
                                "AvgDist": abs(ra) + abs(dec)})
            elif self.state == "LostLock":
                self.broadcast({"Event": "StarLost", "Frame": self.frame, "SNR": 2.0,
                                "StarMass": 800, "AvgDist": 40.0, "ErrorCode": 1,
                                "Status": "star lost"})
            elif self.state == "Looping":
                self.broadcast({"Event": "LoopingExposures", "Frame": self.frame})

    # ---- settle bookkeeping ----------------------------------------------

    def settle_later(self, settle, why):
        """Emit SettleBegin now and SettleDone after the requested settle time."""
        secs = float(settle.get("time", 3.0)) if isinstance(settle, dict) else 3.0
        timeout = float(settle.get("timeout", 30.0)) if isinstance(settle, dict) else 30.0
        self.broadcast({"Event": "SettleBegin"})

        def done():
            with LOCK:
                if self.settle_fail_armed:
                    self.settle_fail_armed = False
                    self.log("settle", ok=False, why=why)
                    self.broadcast({"Event": "SettleDone", "Status": 1, "Error": "timed-out",
                                    "TotalFrames": 8, "DroppedFrames": 0})
                    return
                if self.state != "Guiding":
                    self.log("settle", ok=False, why=why + " (not guiding)")
                    self.broadcast({"Event": "SettleDone", "Status": 1,
                                    "Error": "lost lock position", "TotalFrames": 3,
                                    "DroppedFrames": 3})
                    return
                self.log("settle", ok=True, why=why)
                self.broadcast({"Event": "SettleDone", "Status": 0, "TotalFrames": 5,
                                "DroppedFrames": 0})

        delay = min(secs + 1.0, timeout)
        threading.Timer(delay, done).start()

    # ---- RPC ---------------------------------------------------------------

    def rpc(self, method, params):
        with LOCK:
            if method == "get_app_state":
                return self.state
            if method == "get_connected":
                return True
            if method in ("set_connected", "set_exposure", "set_lock_position",
                          "clear_calibration", "flip_calibration", "deselect_star",
                          "set_guide_output_enabled", "set_algo_param"):
                return 0
            if method == "get_pixel_scale":
                return 1.25
            if method == "get_exposure":
                return 2000
            if method == "get_calibrated":
                return True
            if method == "get_calibration_data":
                return {"calibrated": True, "xAngle": 0.0, "xRate": 6.0, "xParity": "+",
                        "yAngle": 90.0, "yRate": 6.0, "yParity": "+",
                        "declination": 0.0}
            if method == "get_lock_position":
                return [320.0, 240.0]
            if method == "find_star":
                return [320.0, 240.0]
            if method == "get_camera_frame_size":
                return [640, 480]
            if method == "get_guide_output_enabled":
                return True
            if method == "get_profile":
                return {"id": 1, "name": "Nightshade simulator"}
            if method == "get_current_equipment":
                return {"camera": {"name": "Simulator", "connected": True},
                        "mount": {"name": "On-camera", "connected": True}}
            if method == "get_algo_param_names":
                return ["MinMove"]
            if method == "get_algo_param":
                return 0.15
            if method == "loop":
                if self.state in ("Stopped", "LostLock"):
                    self.set_state("Looping", "loop")
                return 0
            if method == "stop_capture":
                self.lost = False
                self.broadcast({"Event": "GuidingStopped"})
                self.set_state("Stopped", "stop_capture")
                return 0
            if method == "set_paused":
                paused = bool(params[0]) if isinstance(params, list) and params else bool(params)
                if paused and self.state == "Guiding":
                    self.broadcast({"Event": "Paused"})
                    self.set_state("Paused", "set_paused true")
                elif not paused and self.state == "Paused":
                    self.broadcast({"Event": "Resumed"})
                    self.set_state("Guiding", "set_paused false")
                return 0
            if method == "guide":
                settle = params.get("settle", {}) if isinstance(params, dict) else {}
                if self.first_guide_at is None:
                    self.first_guide_at = time.time()
                if self.lost and self.resume_refusals_left > 0:
                    # Accepted, and nothing happens: PHD2 keeps hunting for a
                    # star that is not there. This is the 2026-09-14 shape.
                    self.resume_refusals_left -= 1
                    self.log("guide", accepted=True, locked=False)
                    self.broadcast({"Event": "SettleBegin"})
                    return 0
                self.lost = False
                self.broadcast({"Event": "StartGuiding"})
                self.set_state("Guiding", "guide")
                self.log("guide", accepted=True, locked=True)
                self.settle_later(settle, "guide")
                return 0
            if method == "dither":
                settle = params.get("settle", {}) if isinstance(params, dict) else {}
                if self.state != "Guiding":
                    raise RpcError(1, "cannot dither when not guiding")
                self.dither_kick = float(params.get("amount", 3.0)) * 0.3
                self.log("dither", amount=params.get("amount"))
                self.settle_later(settle, "dither")
                return 0
            raise RpcError(1, "method not implemented by the simulator: " + method)


class RpcError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def parse_faults(text):
    faults = {}
    for part in filter(None, (p.strip() for p in (text or "").split(","))):
        if "=" in part:
            key, value = part.split("=", 1)
            faults[key.strip()] = float(value) if key.strip() != "resume_fails_times" else int(value)
        else:
            faults[part] = True
    return faults


def make_handler(guider):
    class Handler(socketserver.StreamRequestHandler):
        def handle(self):
            with LOCK:
                if time.time() < guider.dropped_until:
                    guider.log("refused_connection")
                    return
                guider.clients.append(self.connection)
                guider.log("client_connected")
            self.connection.sendall((json.dumps({
                "Event": "Version", "Timestamp": time.time(), "Host": "sim", "Inst": 1,
                "PHDVersion": "2.6.13", "PHDSubver": "sim", "OverlapSupport": True,
                "MsgVersion": 1}) + "\r\n").encode())
            guider.broadcast({"Event": "AppState", "State": guider.state})
            try:
                for raw in self.rfile:
                    line = raw.decode("utf-8", "replace").strip()
                    if not line:
                        continue
                    try:
                        request = json.loads(line)
                    except ValueError:
                        continue
                    rid = request.get("id")
                    try:
                        result = guider.rpc(request.get("method", ""), request.get("params"))
                        reply = {"jsonrpc": "2.0", "result": result, "id": rid}
                    except RpcError as exc:
                        reply = {"jsonrpc": "2.0",
                                 "error": {"code": exc.code, "message": exc.message}, "id": rid}
                    try:
                        self.connection.sendall((json.dumps(reply) + "\r\n").encode())
                    except OSError:
                        return
            finally:
                with LOCK:
                    if self.connection in guider.clients:
                        guider.clients.remove(self.connection)
                    guider.log("client_disconnected")

    return Handler


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=4400)
    ap.add_argument("--faults", default="")
    ap.add_argument("--timeline", default="")
    ap.add_argument("--drop-secs", type=float, default=60.0)
    ap.add_argument("--cadence", type=float, default=2.0, help="seconds per guide frame")
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()
    guider = Guider(args)
    server = Server(("127.0.0.1", args.port), make_handler(guider))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f"[fake-phd2] listening on 127.0.0.1:{args.port} faults={guider.faults}", flush=True)
    try:
        while True:
            time.sleep(args.cadence)
            guider.tick()
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
