#!/usr/bin/env python3
"""Builds the D1 sim-night sequence envelope: {"json": "<stringified SequenceDefinition>"}.

Wire shape per sequence_serializer.dart:301-329 and sequencer/src/lib.rs
(SequenceDefinition:146, NodeDefinition:174, NodeType tag="type":191,
TargetHeaderConfig:1220, LoopConfig:1692, FilterConfig:2279). Optional keys
with serde(default) are omitted; required ones are stated.
"""
import json, os, sys, time, math

FILTERS = ["L", "R", "G", "B"]

# Real observatory sites, spread around the globe so one of them is always
# near local midnight. REAL sites, not a computed longitude: the site the
# harness writes is the profile's observing location, and every
# geography-dependent feature reads it — the weather radar providers
# (GOES/NEXRAD are US-only), the cloud forecast, the planner. A longitude
# derived purely from the clock put the site at 40N/164W, the middle of the
# North Pacific, where the radar map correctly showed no coverage and read as
# a broken screen.
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


def site(unix=None):
    """The harness observing site: the real observatory closest to 01:00 LOCAL
    SOLAR TIME right now.

    Two properties have to hold at once. (1) Mid-night at the site: a fixed
    40N/105W landed inside the DawnApproaching trigger's lead window whenever
    a wave ran near 04:00 UTC, and the trigger — behaving correctly for that
    site — parked a run the harness then failed as its own. (2) A real place:
    the site is written to the profile as the observing location, so a
    computed mid-ocean longitude leaves every location-keyed feature
    truthfully reporting nothing.

    The table spans ~all longitudes, so the closest site is always within
    about 1.5 hours of local solar 01:00 — comfortably inside the night, with
    hours of margin before any dawn logic arms."""
    unix = time.time() if unix is None else unix
    utc_hours = (unix / 3600.0) % 24.0

    def hours_from_solar_1am(lon):
        local = (utc_hours + lon / 15.0) % 24.0
        gap = abs(local - 1.0)
        return min(gap, 24.0 - gap)

    name, lat, lon = min(
        OBSERVATORY_SITES, key=lambda s: hours_from_solar_1am(s[2])
    )
    return lat, lon, name

# The site is CHOSEN ONCE PER LEG, not once per invocation. Each shell leg
# runs this file twice — `--print-site` to get the location it POSTs, then
# again to build the sequence — and a leg that straddles a site crossover got
# two different observatories from the two calls: the profile said Mauna Kea
# while the target was computed for Kitt Peak, which is a fabricated sky.
# The leg exports SKOTIQ_HARNESS_SITE from the first call and every later
# call reads it back, so one leg is always one place.
_pinned = os.environ.get("SKOTIQ_HARNESS_SITE")
if _pinned:
    _lat, _lon, _name = _pinned.split(",", 2)
    SITE_LAT, SITE_LON, SITE_NAME = float(_lat), float(_lon), _name
else:
    SITE_LAT, SITE_LON, SITE_NAME = site()

if len(sys.argv) > 1 and sys.argv[1] == "--print-site":
    # lat, lon, and the pin the caller must export for the rest of the leg.
    print(f"{SITE_LAT} {SITE_LON} {SITE_LAT},{SITE_LON},{SITE_NAME}")
    sys.exit(0)

def lst_hours(unix, lon_deg):
    jd = unix / 86400.0 + 2440587.5
    d = jd - 2451545.0
    gmst = (18.697374558 + 24.06570982441908 * d) % 24.0
    return (gmst + lon_deg / 15.0) % 24.0

# High-and-east target: 1.5h east of the meridian at dec=latitude — altitude
# ~75 degrees (clears any altitude gate) while transit stays 1.5h away, so
# the meridian-flip window can never fire during a short harness night.
# (RA == LST put the target AT transit: every run rolled dice with the flip
# window, and a fired flip pauses on the unsolvable simulator field.)
ZENITH_RA = round((lst_hours(time.time(), SITE_LON) + 1.5) % 24.0, 4)
ZENITH_DEC = SITE_LAT

def exposure(fid, filt, idx):
    return {
        "id": fid,
        "name": f"Exposure {filt}",
        "node_type": {
            "type": "TakeExposure",
            "duration_secs": 2.0,
            "count": 3,
            "frame_type": "Light",
            "filter": filt,
            "filter_index": idx,
            "gain": 100,
            "offset": 10,
            "binning": "One",
        },
        "enabled": True,
        "children": [],
    }

def change_filter(fid, filt, idx):
    return {
        "id": fid,
        "name": f"Filter {filt}",
        "node_type": {"type": "ChangeFilter", "filter_name": filt, "filter_index": idx},
        "enabled": True,
        "children": [],
    }

nodes = []
target_children = []
for i, f in enumerate(FILTERS):
    cf, ex = f"cf_{f.lower()}", f"exp_{f.lower()}"
    nodes.append(change_filter(cf, f, i))
    nodes.append(exposure(ex, f, i))
    target_children += [cf, ex]

nodes.insert(0, {
    "id": "target_1",
    "name": "D1 Simulated Field",
    "node_type": {
        "type": "TargetHeader",
        "target_name": "D1 Simulated Field",
        "ra_hours": ZENITH_RA,
        "dec_degrees": ZENITH_DEC,
        "rotation": None,
        "priority": 0,
    },
    "enabled": True,
    "children": target_children,
})
nodes.insert(0, {
    "id": "root",
    "name": "Night root",
    "node_type": {"type": "Loop", "iterations": 1, "condition": "Count", "condition_value": None},
    "enabled": True,
    "children": ["target_1"],
})

definition = {
    "id": "d1-sim-night",
    "name": "D1 sim night",
    "description": "Phase D leg-1 harness sequence",
    "root_node_id": "root",
    "nodes": nodes,
    "metadata": {},
}

envelope = {"json": json.dumps(definition)}
with open(sys.argv[1], "w") as fh:
    json.dump(envelope, fh)
print(f"wrote {sys.argv[1]}: {len(nodes)} nodes, {sum(1 for n in nodes if n['node_type']['type']=='TakeExposure')*3} frames")
