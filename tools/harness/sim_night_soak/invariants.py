"""What a night must not get wrong, checked from the API, the database and the
files on disk after a soak run. Every join is by identity -- file path, target
name, timestamp -- never by list position.

Each check returns {"name", "verdict": PASS|FAIL|SKIP, "detail"}. SKIP means the
run never reached the situation the check is about; it is reported, never
counted as a pass.
"""
import csv
import datetime as dt
import glob
import json
import math
import os
import re

LIGHT_EXCLUDE = ("master", "darkroom", "rejmap", "calibrat", "flat", "bias", "dark_")


def verdict(name, ok, detail, skip=False):
    return {"name": name, "verdict": "SKIP" if skip else ("PASS" if ok else "FAIL"),
            "detail": detail}


# ---- FITS --------------------------------------------------------------------

def read_header(path):
    cards = {}
    with open(path, "rb") as fh:
        while True:
            block = fh.read(2880)
            if len(block) < 2880:
                break
            done = False
            for i in range(0, 2880, 80):
                card = block[i:i + 80].decode("ascii", "replace")
                key = card[:8].strip()
                if key == "END":
                    done = True
                    break
                if card[8:10] != "= ":
                    continue
                value = card[10:]
                if value.lstrip().startswith("'"):
                    value = value.lstrip()[1:]
                    value = value[:value.find("'")] if "'" in value else value
                    cards[key] = value.strip()
                else:
                    cards[key] = value.split("/")[0].strip()
            if done:
                break
    return cards


def light_fits(out_dir):
    files = []
    for path in glob.glob(os.path.join(out_dir, "**", "*.fit*"), recursive=True):
        low = path.lower()
        if any(x in low for x in LIGHT_EXCLUDE):
            continue
        files.append(os.path.realpath(path))
    return sorted(files)


def parse_time(text):
    if not text:
        return None
    text = text.strip().replace("Z", "")
    for fmt in ("%Y-%m-%dT%H:%M:%S.%f", "%Y-%m-%dT%H:%M:%S"):
        try:
            return dt.datetime.strptime(text, fmt).replace(tzinfo=dt.timezone.utc).timestamp()
        except ValueError:
            continue
    return None


def ra_to_hours(text):
    """Header RA as hours: decimal degrees, or sexagesimal hours."""
    if text is None:
        return None
    text = str(text).strip()
    try:
        return float(text) / 15.0
    except ValueError:
        pass
    parts = re.split(r"[ :hms]+", text)
    try:
        h, m, s = (float(p) for p in parts[:3])
        return h + m / 60.0 + s / 3600.0
    except ValueError:
        return None


def dec_to_deg(text):
    if text is None:
        return None
    text = str(text).strip()
    try:
        return float(text)
    except ValueError:
        pass
    sign = -1.0 if text.startswith("-") else 1.0
    parts = re.split(r"[ :dms'\"]+", text.lstrip("+-"))
    try:
        d, m, s = (float(p) for p in parts[:3])
        return sign * (d + m / 60.0 + s / 3600.0)
    except ValueError:
        return None


def sep_arcmin(ra1, dec1, ra2, dec2):
    a1, d1, a2, d2 = (math.radians(ra1 * 15), math.radians(dec1),
                      math.radians(ra2 * 15), math.radians(dec2))
    c = math.sin(d1) * math.sin(d2) + math.cos(d1) * math.cos(d2) * math.cos(a1 - a2)
    return math.degrees(math.acos(max(-1.0, min(1.0, c)))) * 60.0


# ---- logs --------------------------------------------------------------------

def log_lines(root):
    """Rust daily logs under data/, plus the process's own stdout log."""
    paths = sorted(glob.glob(os.path.join(root, "data", "**", "nightshade.log*"), recursive=True))
    paths += sorted(glob.glob(os.path.join(root, "**", "logs", "*.log*"), recursive=True))
    paths.append(os.path.join(root, "app.log"))
    seen, lines = set(), []
    for p in paths:
        rp = os.path.realpath(p)
        if rp in seen or not os.path.exists(rp):
            continue
        seen.add(rp)
        with open(rp, "r", errors="replace") as fh:
            lines.extend(fh.read().splitlines())
    return lines


LOG_TS = re.compile(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?)Z?")


def line_time(line):
    m = LOG_TS.search(line)
    return parse_time(m.group(1)) if m else None


# ---- the checks ----------------------------------------------------------------

def check_all(root, result, sc):
    final = result.get("final", {}) or {}
    run = result.get("run", {}) or {}
    facts = result.get("facts", {}) or {}
    rows = final.get("captured_images", []) or []
    lights = [r for r in rows if (r.get("frame_type") or "Light").lower() == "light"]
    out_dir = os.path.join(root, "captures")
    files = light_fits(out_dir)
    headers = {}
    for f in files:
        try:
            headers[f] = read_header(f)
        except OSError as exc:
            headers[f] = {"_error": str(exc)}
    lines = log_lines(root)
    checks = [
        check_survived(result, run),
        check_disk_vs_db(files, lights),
        check_vitals(run, final, lights),
        check_terminal(run, final, sc),
        check_guider_dead(root, headers, sc),
        check_no_park(final, lines, sc),
        check_causes(run, final, sc),
        check_actions(run, sc),
        check_flip(lines, facts, sc, rows),
        check_autofocus(lines),
        check_unique(files, headers, out_dir),
        check_headers(headers, rows, facts),
        check_resources(root),
    ]
    return checks


def check_survived(result, run):
    if result.get("harness_error"):
        return verdict("app_survived", False, "harness error: " + result["harness_error"])
    if "app_exit" in run:
        return verdict("app_survived", False, f"app exited mid-run with {run['app_exit']}")
    if run.get("timed_out"):
        return verdict("app_survived", False, "run never reached a terminal state before the deadline")
    shutdown = result.get("shutdown_secs")
    if shutdown is not None and shutdown > 30:
        return verdict("app_survived", False, f"SIGTERM shutdown took {shutdown:.0f}s")
    return verdict("app_survived", True, f"ran {run.get('elapsed_s', 0) / 60:.1f} min; "
                   f"shutdown {shutdown if shutdown is None else round(shutdown, 1)}s")


def check_disk_vs_db(files, lights):
    db_paths = {}
    for r in lights:
        p = r.get("file_path")
        if p:
            db_paths.setdefault(os.path.realpath(p), []).append(r["id"])
    disk = set(files)
    only_disk = sorted(disk - set(db_paths))
    only_db = sorted(set(db_paths) - disk)
    dup_rows = {p: ids for p, ids in db_paths.items() if len(ids) > 1}
    ok = not only_disk and not only_db and not dup_rows
    detail = (f"{len(disk)} light FITS on disk, {len(lights)} light rows "
              f"({len(db_paths)} distinct paths)")
    if only_disk:
        detail += f"; {len(only_disk)} files with no row e.g. {only_disk[:3]}"
    if only_db:
        detail += f"; {len(only_db)} rows with no file e.g. {only_db[:3]}"
    if dup_rows:
        detail += f"; {len(dup_rows)} paths registered twice e.g. {list(dup_rows.items())[:2]}"
    if not disk and not lights:
        return verdict("frames_disk_eq_db", False, "no frames at all")
    return verdict("frames_disk_eq_db", ok, detail)


def run_vitals(run, final):
    for st in ((final.get("status") or {}), (run.get("last_status") or {})):
        if isinstance(st, dict) and st.get("runVitals"):
            return st["runVitals"]
    return None


def check_vitals(run, final, lights):
    vitals = run_vitals(run, final)
    if not vitals:
        return verdict("vitals_eq_db", False, "no runVitals in the final or last status")
    accepted = sum(1 for r in lights if r.get("is_accepted") in (1, True))
    rejected = sum(1 for r in lights if r.get("is_accepted") in (0, False))
    cap, rej = vitals.get("framesCaptured"), vitals.get("framesRejected")
    ok = cap == len(lights) and rej == rejected
    return verdict("vitals_eq_db", ok,
                   f"runVitals framesCaptured={cap} framesRejected={rej}; DB lights={len(lights)} "
                   f"accepted={accepted} rejected={rejected}; afRuns={vitals.get('autofocusRuns')} "
                   f"flips={vitals.get('meridianFlips')} dithers={vitals.get('ditherCount')}")


def check_terminal(run, final, sc):
    status = final.get("status") or {}
    api_state = status.get("state") if isinstance(status, dict) else None
    runs = final.get("sequence_runs") or []
    latest = runs[-1] if runs else {}
    db_state = latest.get("status") or latest.get("state")
    allowed = sc.get("expect_terminal", ["completed"])
    ok = api_state in allowed or (api_state == "idle" and db_state in allowed)
    detail = f"API state={api_state}, sequence_runs.status={db_state}, allowed={allowed}"
    # sequence_runs only records terminal states; a held run is still "running" there.
    if db_state and api_state in ("completed", "failed", "cancelled", "stopped") \
            and db_state != api_state:
        ok = False
        detail += " (API and DB disagree)"
    return verdict("terminal_state_truthful", ok, detail)


def guider_dead_intervals(root):
    path = os.path.join(root, "phd2_timeline.jsonl")
    if not os.path.exists(path):
        return []
    events = [json.loads(line) for line in open(path) if line.strip()]
    dead, start = [], None
    for ev in events:
        lost = (ev.get("what") == "fault" and ev.get("fault") in ("lose_star", "drop")) or \
            (ev.get("what") == "state" and ev.get("state") == "LostLock")
        if lost and start is None:
            start = ev["t"]
        elif start is not None and ev.get("what") == "state" and ev.get("state") == "Guiding":
            dead.append((start, ev["t"]))
            start = None
        elif start is not None and ev.get("what") == "client_connected" and \
                any(e.get("fault") == "drop" for e in events):
            pass
    if start is not None:
        dead.append((start, float("inf")))
    return dead


def check_guider_dead(root, headers, sc):
    dead = guider_dead_intervals(root)
    if not dead:
        return verdict("no_frames_while_guider_dead", True, "guider never lost",
                       skip=not sc.get("phd2_faults"))
    grace = 20.0
    bad = []
    for path, h in headers.items():
        start = parse_time(h.get("DATE-OBS"))
        if start is None:
            continue
        for a, b in dead:
            if a + grace <= start <= b:
                bad.append((os.path.basename(path), round(start - a, 1)))
    detail = (f"dead intervals {[(round(a), 'open' if b == float('inf') else round(b - a)) for a, b in dead]}; "
              f"{len(bad)} frames started >{grace:.0f}s into one")
    if bad:
        detail += f" e.g. {bad[:4]}"
    return verdict("no_frames_while_guider_dead", not bad, detail)


# `(?<!un)` so an Unpark node's "Unparking mount" is not read as a park.
PARK_LINE = re.compile(r"((?<!un)Parking mount|\bmount_park\b|(?<!un)park(ed|ing)? the mount|"
                       r"close (the )?cover|close (the )?dome|ParkAndAbort|abandoning safely)", re.I)
NEGATED = re.compile(r"(not park|never park|no park|without park|won't park|will not park|"
                     r"did not park|skipp)", re.I)


def check_no_park(final, lines, sc):
    mount = final.get("mount") or {}
    parked = mount.get("parked") if isinstance(mount, dict) else None
    hits = [ln for ln in lines if PARK_LINE.search(ln) and not NEGATED.search(ln)]
    ok = parked is not True and not hits
    detail = f"final mount parked={parked}; {len(hits)} park/close lines"
    if hits:
        detail += ": " + " | ".join(h.strip()[:160] for h in hits[:3])
    return verdict("no_unrequested_park", ok, detail)


GENERIC = re.compile(r"^(error|operation cancelled|cancelled|failed|type=error|unknown error)\.?$", re.I)


def check_causes(run, final, sc):
    vitals = run_vitals(run, final) or {}
    msgs = list(vitals.get("errorMessages") or [])
    if vitals.get("terminalCause"):
        msgs.append(vitals["terminalCause"])
    if run.get("self_pause_message"):
        msgs.append(run["self_pause_message"])
    msgs = [str(m) for m in msgs if m]
    generic = [m for m in msgs if GENERIC.match(m.strip())]
    keywords = sc.get("cause_keywords") or []
    if not keywords:
        ok = not generic
        return verdict("failures_name_a_cause", ok,
                       f"{len(msgs)} error messages, {len(generic)} generic"
                       + (f": {generic[:3]}" if generic else "")
                       + (f"; first: {msgs[0][:200]}" if msgs else ""))
    named = [m for m in msgs if any(k in m.lower() for k in keywords)]
    faulted = bool(sc.get("sim_faults") or sc.get("phd2_faults"))
    ok = bool(named) and not generic if faulted and msgs else not generic
    detail = (f"{len(msgs)} messages, {len(named)} name {keywords}, {len(generic)} generic; "
              f"terminalCause={vitals.get('terminalCause')!r}")
    if msgs and not named:
        detail += f"; messages: {[m[:160] for m in msgs[:4]]}"
    return verdict("failures_name_a_cause", ok, detail)


def check_actions(run, sc):
    acts = run.get("actions") or []
    if not acts:
        return verdict("operator_actions_prompt", True, "no operator actions", skip=True)
    bad = [a for a in acts if not a.get("reached") or a["latency_s"] > a.get("budget_s", 60)]
    detail = "; ".join(f"{a['verb']}->{a.get('reached')} in {a['latency_s']:.1f}s "
                       f"(budget {a.get('budget_s')}s)" for a in acts)
    return verdict("operator_actions_prompt", not bad, detail)


FLIP_START = re.compile(r"\[MERIDIAN\] Slewing to target \(flip side\)")


def check_flip(lines, facts, sc, rows):
    t1 = (facts.get("targets") or {}).get("Meridian Field")
    if not t1:
        return verdict("meridian_flip_once_on_time", True, "no meridian target", skip=True)
    starts = [(line_time(ln), ln) for ln in lines if FLIP_START.search(ln)]
    starts = [(t, ln) for t, ln in starts if t is not None]
    sides = []
    for r in rows:
        if r.get("pier_side") and r.get("target_id") is not None:
            sides.append(r["pier_side"])
    changes = sum(1 for a, b in zip(sides, sides[1:]) if a != b)
    if not sc.get("expect_flip"):
        return verdict("meridian_flip_once_on_time", True,
                       f"flip not expected in this scenario; {len(starts)} flip starts logged",
                       skip=True)
    if not starts:
        return verdict("meridian_flip_once_on_time", False,
                       f"no flip logged; pier side changes across frames={changes}")
    lon = facts["site"]["lon"]
    from night_plan import hour_angle_hours
    has = [hour_angle_hours(t1["ra"], lon, t) * 60.0 for t, _ in starts]
    first_ha = has[0]
    distinct = len({round(t / 120.0) for t, _ in starts})
    ok = distinct == 1 and 3.0 <= first_ha <= 12.0
    return verdict("meridian_flip_once_on_time", ok,
                   f"{distinct} flip(s); first at target HA {first_ha:+.1f} min "
                   f"(setting: 5 min past); pier side changes across frames={changes}")


RUNUP = re.compile(r"Final approach: run up from (-?\d+) to (-?\d+)")
AF_BEST = re.compile(r"Best focus at position (-?\d+)")
AF_UNVERIFIED = re.compile(r"Autofocus could not verify the landing")
AF_BAD_LANDING = re.compile(r"Autofocus landed at (-?\d+) measuring HFR ([\d.]+)")


def check_autofocus(lines):
    runups = [(int(a), int(b)) for ln in lines for a, b in RUNUP.findall(ln)]
    best = [int(p) for ln in lines for p in AF_BEST.findall(ln)]
    unverified = [ln for ln in lines if AF_UNVERIFIED.search(ln)]
    bad = [m for ln in lines for m in AF_BAD_LANDING.findall(ln)]
    if not best and not runups:
        return verdict("autofocus_from_below_verified", False, "no autofocus ran")
    from_above = [(a, b) for a, b in runups if a >= b]
    ok = bool(runups) and not from_above and not unverified and not bad
    return verdict("autofocus_from_below_verified", ok,
                   f"{len(best)} curve fits, {len(runups)} final approaches "
                   f"({len(from_above)} from above), {len(unverified)} landings unverified, "
                   f"{len(bad)} landings worse than the curve"
                   + (f" e.g. {bad[:2]}" if bad else ""))


def check_unique(files, headers, out_dir):
    stray = [p for p in glob.glob(os.path.join(out_dir, "**", "*"), recursive=True)
             if os.path.isfile(p) and re.search(r"\.(tmp|part|partial)$|~$", p)]
    by_obs = {}
    for f, h in headers.items():
        key = (h.get("DATE-OBS"), h.get("FILTER"))
        if key[0]:
            by_obs.setdefault(key, []).append(os.path.basename(f))
    dups = {k: v for k, v in by_obs.items() if len(v) > 1}
    ok = not stray and not dups
    return verdict("fits_unique_no_strays", ok,
                   f"{len(files)} lights; {len(dups)} duplicate DATE-OBS+FILTER; {len(stray)} partial files"
                   + (f"; dup e.g. {list(dups.items())[:2]}" if dups else "")
                   + (f"; stray e.g. {stray[:3]}" if stray else ""))


def check_headers(headers, rows, facts):
    targets = facts.get("targets") or {}
    by_path = {os.path.realpath(r["file_path"]): r for r in rows if r.get("file_path")}
    problems, far = [], []
    for f, h in headers.items():
        row = by_path.get(f)
        name = os.path.basename(f)
        if "_error" in h:
            problems.append(f"{name}: unreadable")
            continue
        filt = h.get("FILTER")
        if row and row.get("filter") and filt and row["filter"] != filt:
            problems.append(f"{name}: FILTER {filt} vs row {row['filter']}")
        exp = h.get("EXPTIME") or h.get("EXPOSURE")
        if row and exp and row.get("exposure_duration") and \
                abs(float(exp) - float(row["exposure_duration"])) > 0.01:
            problems.append(f"{name}: EXPTIME {exp} vs row {row['exposure_duration']}")
        obj = h.get("OBJECT")
        if obj not in targets:
            problems.append(f"{name}: OBJECT {obj!r} is not a planned target")
            continue
        ra, dec = ra_to_hours(h.get("RA")), dec_to_deg(h.get("DEC"))
        if ra is None or dec is None:
            ra, dec = ra_to_hours(h.get("OBJCTRA")), dec_to_deg(h.get("OBJCTDEC"))
            if ra is not None:
                ra = ra  # OBJCTRA is sexagesimal hours already
        if ra is None or dec is None:
            problems.append(f"{name}: no RA/DEC")
            continue
        t = targets[obj]
        d = sep_arcmin(ra, dec, t["ra"], t["dec"])
        if d > 3.0:
            far.append((name, round(d, 1)))
    ok = not problems and not far
    detail = f"{len(headers)} headers; {len(problems)} inconsistent; {len(far)} pointed >3' from the J2000 target"
    if problems:
        detail += f"; e.g. {problems[:3]}"
    if far:
        seps = sorted(d for _, d in far)
        detail += f"; separations {seps[0]}'..{seps[-1]}' e.g. {far[:2]}"
    return verdict("fits_headers_sane", ok, detail)


def slope_per_hour(xs, ys):
    n = len(xs)
    if n < 3:
        return 0.0
    mx, my = sum(xs) / n, sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    if sxx == 0:
        return 0.0
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx * 3600.0


def monotonic_fraction(ys):
    steps = [b - a for a, b in zip(ys, ys[1:])]
    moving = [s for s in steps if s != 0]
    return (sum(1 for s in moving if s > 0) / len(moving)) if moving else 0.0


# Growth that would matter over a real 8-10 h night. The 2026-09-13 hang sat at
# 3.2 GB; a leak of 150 MB/h reaches that from a 1.5 GB start in about 11 h.
LIMITS = {"rss_mb": 150.0, "fds": 30.0, "threads": 20.0, "wal_mb": 100.0, "tmp_mb": 200.0,
          "logs_mb": 200.0}


def check_resources(root):
    path = os.path.join(root, "resources.csv")
    if not os.path.exists(path):
        return verdict("no_monotonic_resource_growth", False, "no resources.csv")
    rows = list(csv.DictReader(open(path)))
    if len(rows) < 6:
        return verdict("no_monotonic_resource_growth", True, f"only {len(rows)} samples", skip=True)
    half = rows[len(rows) // 3:]      # skip warm-up: caches and catalogs fill first
    xs = [float(r["elapsed_s"]) for r in half]
    flagged, report = [], []
    for key, limit in LIMITS.items():
        ys = [float(r[key]) for r in half]
        s = slope_per_hour(xs, ys)
        mono = monotonic_fraction(ys)
        report.append(f"{key} {ys[0]:.0f}->{ys[-1]:.0f} ({s:+.1f}/h, {mono:.0%} rising)")
        if s > limit and mono > 0.7:
            flagged.append(key)
    peak = max(float(r["rss_mb"]) for r in rows)
    return verdict("no_monotonic_resource_growth", not flagged,
                   f"peak RSS {peak:.0f} MB; " + "; ".join(report)
                   + (f"; FLAGGED {flagged}" if flagged else ""))
