#!/usr/bin/env python3
"""Summarize a science-sandbox output dir: one CSV row per frame plus stage totals.

    summarize.py <out dir> [--csv frames.csv]

Reads <out>/frames/*.json written by science_sandbox_test.dart.
"""
import collections
import csv
import json
import pathlib
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    out = pathlib.Path(sys.argv[1])
    csv_path = out / "frames.csv"
    if "--csv" in sys.argv:
        csv_path = pathlib.Path(sys.argv[sys.argv.index("--csv") + 1])
    rows = []
    outcomes = collections.defaultdict(collections.Counter)
    notes = collections.defaultdict(collections.Counter)
    for f in sorted((out / "frames").glob("*.json")):
        d = json.loads(f.read_text())
        img = d.get("capturedImage") or {}
        bundle = d.get("bundle") or {}
        stages = d.get("stages") or {}
        cal = (bundle.get("frame_photometric_calibration") or [{}])
        cal = cal[0] if cal else {}
        fq = (bundle.get("science_frame_quality_metrics") or [{}])
        fq = fq[0] if fq else {}
        row = {
            "file": pathlib.Path(d["file"]).name.split("\\")[-1],
            "image_id": d.get("capturedImageId"),
            "session_id": d.get("sessionId"),
            "captured_at": img.get("captured_at"),
            "filter": img.get("filter"),
            "pier_side": img.get("pier_side"),
            "solved": img.get("is_plate_solved"),
            "ra_deg": (img.get("solved_ra") or 0) * 15 if img.get("solved_ra") else None,
            "dec_deg": img.get("solved_dec"),
            "rotation": img.get("solved_rotation"),
            "scale": img.get("solved_pixel_scale"),
            "zero_point": cal.get("zero_point"),
            "zp_rms": cal.get("calibration_rms"),
            "zp_stars": cal.get("matched_star_count"),
            "background": fq.get("background"),
            "noise": fq.get("noise"),
            "snr": fq.get("snr"),
            "photometry_rows": len(bundle.get("photometry_measurements") or []),
            "psf_tiles": len(bundle.get("psf_field_tiles") or []),
            "residuals": len(bundle.get("astrometry_residual_vectors") or []),
            "moving": len(bundle.get("moving_object_candidates") or []),
            "transparency": len(bundle.get("transparency_samples") or []),
            "narrator": len(d.get("narratorEvents") or []),
            "first_light": len(d.get("firstLight") or []),
            "atlas_fold_rows": len(d.get("atlasFoldRows") or []),
            "ms_pipeline": (d.get("timing") or {}).get("processCapturedFrameMs"),
            "ms_total": (d.get("timing") or {}).get("totalMs"),
            "errors": "; ".join(d.get("errors") or []),
        }
        for name, st in stages.items():
            row[f"stage_{name}"] = st.get("outcome")
            outcomes[name][st.get("outcome")] += 1
            if st.get("outcome") in ("noData", "failed"):
                notes[name][(st.get("note") or "")[:120]] += 1
        rows.append(row)
    if not rows:
        print("no frames")
        return 1
    keys = list(dict.fromkeys(k for r in rows for k in r))
    with open(csv_path, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=keys)
        w.writeheader()
        w.writerows(rows)
    print(f"{len(rows)} frames -> {csv_path}")
    for name, c in outcomes.items():
        print(f"  {name:15s} " + ", ".join(f"{k}={v}" for k, v in c.most_common()))
        for note, n in notes[name].most_common(3):
            print(f"      {n:4d} x {note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
