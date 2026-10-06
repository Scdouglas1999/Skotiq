#!/usr/bin/env python3
"""The compressed night a soak run images: where, which targets, what sequence.

Three targets, shaped like the owner's real nights:

  T1 "Meridian Field"  starts east of the meridian and crosses it about a
                       quarter of an hour in, so the meridian-flip trigger has to
                       fire mid-target. Imaged with a Smart Exposure node cycling
                       Ha/OIII/SII on the same wheel autofocus wants "L" on --
                       the contention that cost the 2026-09-14 night.
  T2 "Setting Field"   low in the west and sinking; its end condition is an
                       altitude it reaches partway through, so the run has to
                       hand off to the next target at an altitude limit.
  T3 "Rising Field"    east, LRGB, fixed counts; the end of the night.

Coordinates are J2000 (what a catalogue holds). The site is a real observatory
where it is currently the middle of the night -- the executor refuses on-sky
work while the Sun is up, and every location-keyed feature reads the site.

Wire shape: {"json": "<stringified SequenceDefinition>"}, see
sequencer/src/lib.rs (NodeType is serde tag = "type").
"""
import json
import math
import os
import time

OBSERVATORY_SITES = [
    ("Mauna Kea", 19.8206, -155.4681),
    ("Kitt Peak", 31.9583, -111.5967),
    ("McDonald", 30.6717, -104.0217),
    ("Cerro Paranal", -24.6275, -70.4044),
    ("Roque de los Muchachos", 28.7606, -17.8814),
    ("Sutherland", -32.3783, 20.8106),
    ("Xinglong", 40.3939, 117.5750),
    ("Siding Spring", -31.2733, 149.0644),
]

FILTERS = ["L", "R", "G", "B", "Ha", "OIII", "SII"]


def julian_day(unix):
    return unix / 86400.0 + 2440587.5


def lst_hours(unix, lon_deg):
    d = julian_day(unix) - 2451545.0
    return ((18.697374558 + 24.06570982441908 * d) % 24.0 + lon_deg / 15.0) % 24.0


def altitude_deg(ra_hours, dec_deg, lat_deg, lon_deg, unix):
    ha = math.radians((lst_hours(unix, lon_deg) - ra_hours) * 15.0)
    dec, lat = math.radians(dec_deg), math.radians(lat_deg)
    return math.degrees(math.asin(math.sin(lat) * math.sin(dec)
                                  + math.cos(lat) * math.cos(dec) * math.cos(ha)))


def hour_angle_hours(ra_hours, lon_deg, unix):
    ha = (lst_hours(unix, lon_deg) - ra_hours) % 24.0
    return ha - 24.0 if ha > 12.0 else ha


def pick_site(unix=None, local_solar_target=23.0):
    """The observatory closest to `local_solar_target` o'clock local solar time.

    23:00 rather than midnight leaves the whole compressed night -- and a long
    margin after it -- before any dawn logic can arm."""
    unix = time.time() if unix is None else unix
    utc_hours = (unix / 3600.0) % 24.0

    def gap(site):
        local = (utc_hours + site[2] / 15.0) % 24.0
        g = abs(local - local_solar_target)
        return min(g, 24.0 - g)

    return min(OBSERVATORY_SITES, key=gap)


def node(nid, name, node_type, children=None):
    return {"id": nid, "name": name, "enabled": True, "children": children or [],
            "node_type": node_type}


def target_header(nid, name, ra, dec, children, end_when=None):
    cfg = {"type": "TargetHeader", "target_name": name, "ra_hours": round(ra, 5),
           "dec_degrees": round(dec, 4), "rotation": None, "priority": 0,
           "trigger_poll_interval_secs": 10}
    if end_when is not None:
        cfg["end_when"] = end_when
    return node(nid, name, cfg, children)


def exposure(nid, filt, secs, count, dither_every=None):
    return node(nid, f"Exposure {filt}", {
        "type": "TakeExposure", "duration_secs": secs, "count": count,
        "frame_type": "Light", "filter": filt, "filter_index": FILTERS.index(filt),
        "gain": 100, "offset": 10, "binning": "One", "dither_every": dither_every})


def change_filter(nid, filt):
    return node(nid, f"Filter {filt}", {"type": "ChangeFilter", "filter_name": filt,
                                        "filter_index": FILTERS.index(filt)})


def center(nid, exposure_secs=3.0):
    return node(nid, "Center", {"type": "CenterTarget", "use_target_coords": True,
                                "custom_ra": None, "custom_dec": None,
                                "accuracy_arcsec": 15.0, "max_attempts": 4,
                                "exposure_duration": exposure_secs, "filter": "L"})


def slew(nid):
    return node(nid, "Slew", {"type": "SlewToTarget", "use_target_coords": True,
                              "custom_ra": None, "custom_dec": None})


def start_guiding(nid):
    return node(nid, "Start Guiding", {"type": "StartGuiding", "settle_pixels": 1.5,
                                       "settle_time": 3.0, "settle_timeout": 30.0,
                                       "auto_select_star": True})


def smart_exposure(nid, plans, secs, dither_every):
    return node(nid, "Smart Exposure", {
        "type": "SmartExposure", "rotate_filters": True, "batch_size": 1,
        "dither_on_filter_change": False, "integration_budget_secs": 0.0,
        "loop_until_stopped": False,
        "plans": [{"filter_name": f, "filter_index": FILTERS.index(f), "count": n,
                   "duration_secs": secs, "gain": 100, "offset": 10, "binning": "One",
                   "dither_every": dither_every} for f, n in plans]})


def build_plan(minutes=80.0, exposure_secs=15.0, unix=None, site=None):
    """Return (definition_dict, facts) for a night that starts now.

    `facts` carries what the invariant checks need to know about the plan: the
    targets, the flip window, the handoff altitude."""
    unix = time.time() if unix is None else unix
    name, lat, lon = site or pick_site(unix)
    lst = lst_hours(unix, lon)
    per_frame = exposure_secs + 5.0      # readout, grading, save, dither share

    # T1: 12 minutes east of the meridian at the start, 12 degrees off the
    # zenith so the solve field is ordinary sky. The flip fires once the target
    # is `minutes_past_meridian` (5) west, about 17 minutes in; T1 is sized to
    # run well past that.
    t1_ra = (lst + 12.0 / 60.0) % 24.0
    t1_dec = lat - 12.0 if lat > 0 else lat + 12.0
    t1_frames_each = max(8, int(0.45 * minutes * 60.0 / per_frame / 3))

    # T2: in the west, sinking. It starts after T1 (estimated) and ends at the
    # altitude it will have ~12 minutes after that, which is above the global
    # 30-degree AltitudeLimit so the target's own condition is what hands off.
    t1_secs = 3 * t1_frames_each * per_frame + 240.0
    t2_start = unix + t1_secs
    t2_dec = lat * 0.5
    t2_ra = None
    for ha_minutes in range(60, 400, 2):
        ra = (lst_hours(t2_start, lon) - ha_minutes / 60.0) % 24.0
        if altitude_deg(ra, t2_dec, lat, lon, t2_start) < 52.0:
            t2_ra = ra
            break
    t2_ra = t2_ra if t2_ra is not None else (lst - 3.0) % 24.0
    t2_end_alt = round(altitude_deg(t2_ra, t2_dec, lat, lon, t2_start + 12 * 60.0), 1)

    # T3: rising in the east, high enough to stay above the global limit.
    t3_ra = (lst + 3.0) % 24.0
    t3_dec = lat * 0.6
    t3_frames_each = max(3, int(0.15 * minutes * 60.0 / per_frame / 4))

    # T1 and T3 slew before centering, the way the editor's "Slew & Center"
    # builds them (and the path the 2026-09-14 slew validator broke). T2
    # centers straight from T1's position, so its first solve is far off --
    # the way a Center-only target starts.
    nodes = []
    t1_children = ["t1_slew", "t1_center", "t1_guide", "t1_smart"]
    nodes += [
        target_header("t1", "Meridian Field", t1_ra, t1_dec, t1_children),
        slew("t1_slew"),
        center("t1_center"),
        start_guiding("t1_guide"),
        smart_exposure("t1_smart", [("Ha", t1_frames_each), ("OIII", t1_frames_each),
                                    ("SII", t1_frames_each)], exposure_secs, 4),
    ]
    t2_children = ["t2_center", "t2_guide", "t2_loop"]
    t2_loop_children = []
    for f in ["L", "R", "G", "B"]:
        t2_loop_children += [f"t2_cf_{f}", f"t2_exp_{f}"]
    nodes += [
        target_header("t2", "Setting Field", t2_ra, t2_dec, t2_children,
                      end_when={"kind": "AltitudeBelow", "value": t2_end_alt}),
        center("t2_center"),
        start_guiding("t2_guide"),
        node("t2_loop", "LRGB until it sets",
             {"type": "Loop", "iterations": 6, "condition": "Count",
              "condition_value": None}, t2_loop_children),
    ]
    for f in ["L", "R", "G", "B"]:
        nodes += [change_filter(f"t2_cf_{f}", f), exposure(f"t2_exp_{f}", f, exposure_secs, 3, 3)]
    t3_children = ["t3_slew", "t3_center", "t3_guide"]
    for f in ["L", "R", "G", "B"]:
        t3_children += [f"t3_cf_{f}", f"t3_exp_{f}"]
    nodes += [
        target_header("t3", "Rising Field", t3_ra, t3_dec, t3_children),
        slew("t3_slew"),
        center("t3_center"),
        start_guiding("t3_guide"),
    ]
    for f in ["L", "R", "G", "B"]:
        nodes += [change_filter(f"t3_cf_{f}", f),
                  exposure(f"t3_exp_{f}", f, exposure_secs, t3_frames_each, 4)]
    # The simulated mount powers up parked, like a real one left parked at the
    # end of the last session; the night starts by unparking it.
    nodes.append(node("unpark", "Unpark", {"type": "Unpark"}))
    nodes.insert(0, node("root", "Night", {"type": "Loop", "iterations": 1,
                                           "condition": "Count", "condition_value": None},
                         ["unpark", "t1", "t2", "t3"]))

    definition = {"id": "w23-sim-night", "name": "Simulated full night",
                  "description": "tools/harness/sim_night_soak", "root_node_id": "root",
                  "nodes": nodes, "metadata": {}}
    facts = {
        "site": {"name": name, "lat": lat, "lon": lon},
        "start_unix": unix,
        "exposure_secs": exposure_secs,
        "targets": {
            "Meridian Field": {"ra": t1_ra, "dec": t1_dec, "frames_planned": 3 * t1_frames_each,
                               "filters": ["Ha", "OIII", "SII"], "expect_flip": True},
            "Setting Field": {"ra": t2_ra, "dec": t2_dec, "end_alt": t2_end_alt,
                              "filters": ["L", "R", "G", "B"], "expect_flip": False},
            "Rising Field": {"ra": t3_ra, "dec": t3_dec, "frames_planned": 4 * t3_frames_each,
                             "filters": ["L", "R", "G", "B"], "expect_flip": False},
        },
    }
    return definition, facts


def envelope(definition):
    return {"json": json.dumps(definition)}


if __name__ == "__main__":
    d, f = build_plan(float(os.environ.get("SOAK_MINUTES", "80")))
    print(json.dumps(f, indent=2))
    print(f"{len(d['nodes'])} nodes")
