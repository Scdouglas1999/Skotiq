#!/usr/bin/env python3
"""Print the Linux scenario list for rehearse_linux.py as JSON.

  write_scenarios.py <dist> <N-ver> <N-build> <N1-ver> <N1-build> <down-ver> <down-build> <N1-marker>
"""

import json
import os
import sys

dist, nv, nb, n1v, n1b, dv, db, n1mark = sys.argv[1:9]
nb, n1b, db = int(nb), int(n1b), int(db)


def assets(folder):
    root = os.path.join(dist, folder)
    return [{"name": n, "path": os.path.join(root, n)}
            for n in sorted(os.listdir(root))
            if n.endswith(".json") or n.endswith(".zip") or n.endswith(".apk")]


def release(folder, version, body=None):
    return {"tag_name": f"v{version}", "name": f"Skotiq {version}",
            "body": body or f"Rehearsal release {version} ({folder}).\n\n"
                            f"**Full Changelog**: https://github.com/x/y/compare",
            "assets": assets(folder)}


good = release("good", n1v)
zip_name = f"skotiq-{n1v}-linux-x64.zip"
scenarios = [
    {"name": "happy_path", "release": good, "expect": "updated",
     "target_version": n1v, "target_build": n1b, "target_marker": n1mark,
     "after_apply": ["try_manual_rollback"]},
    {"name": "tampered_package", "release": release("tamper", n1v),
     "expect": "refused_at_download", "reason_contains": "integrity"},
    {"name": "wrong_key", "release": release("wrongkey", n1v),
     "expect": "refused_at_download",
     "reason_contains": "not signed by the Skotiq update key"},
    {"name": "unsigned_manifest", "release": release("unsigned", n1v),
     "expect": "refused_at_download",
     "reason_contains": "published without a signature"},
    {"name": "manifest_disagrees_with_name", "release": release("mismatch", n1v),
     "expect": "refused_at_check", "reason_contains": "windows"},
    {"name": "truncated_download", "release": good,
     "download_mode": {zip_name: "truncate"},
     "expect": "refused_at_download", "reason_contains": ""},
    {"name": "connection_dropped", "release": good,
     "download_mode": {zip_name: "drop"},
     "expect": "refused_at_download", "reason_contains": ""},
    {"name": "downgrade_offer", "release": release("downgrade", dv),
     "expect": "no_update"},
    {"name": "other_platform_only", "release": release("otherplatform", n1v),
     "expect": "refused_at_check",
     "reason_contains": "publishes no update manifest for linux/x64"},
    {"name": "staging_disk_full", "release": good,
     "before_launch": ["tiny_staging:40m"],
     "expect": "refused_at_download", "reason_contains": ""},
    {"name": "updater_verify_fails", "release": good,
     "before_apply": ["corrupt_staged_desktop_binary"],
     "expect": "rolled_back_and_running", "n_version": nv,
     "after_apply": ["watch_for_rollback"], "swap_timeout": 90},
    {"name": "new_build_cannot_start", "release": release("broken", n1v),
     "expect": "rolled_back_and_running", "n_version": nv,
     "after_apply": ["watch_for_rollback"], "swap_timeout": 90},
    {"name": "install_not_writable", "release": good,
     "before_launch": ["readonly_install"],
     "expect": "apply_refused_n_running", "n_version": nv, "swap_timeout": 60},
    {"name": "headless_by_argv", "release": good, "argv_config": True,
     "expect": "updated", "target_version": n1v, "target_build": n1b,
     "target_marker": n1mark, "swap_timeout": 120},
]
json.dump(scenarios, sys.stdout, indent=2)
