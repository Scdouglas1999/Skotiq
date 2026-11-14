"""Resolve publication policy without reading or printing signing secrets."""

import argparse
import os
import re
import sys
from pathlib import Path


SIGNING_NAMES = (
    "ANDROID_KEYSTORE_BASE64",
    "ANDROID_KEYSTORE_PASSWORD",
    "ANDROID_KEY_ALIAS",
    "ANDROID_KEY_PASSWORD",
    "UPDATE_PRIVATE_KEY",
    "UPDATE_PUBLIC_KEY",
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version-file", type=Path, default=Path("version.yaml"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--distribute", action="store_true")
    args = parser.parse_args()
    version = args.version_file.read_text()
    channels = list(re.finditer(
        r"^channel:[ \t]*(?P<quote>[\"']?)(?P<channel>stable|beta|alpha)(?P=quote)[ \t]*(?:#.*)?$",
        version, re.MULTILINE,
    ))
    declarations = re.findall(r"^channel:", version, re.MULTILINE)
    if len(channels) != 1 or len(declarations) != 1:
        print("::error::version.yaml must declare one channel: stable, beta, or alpha.", file=sys.stderr)
        return 1
    channel = channels[0].group("channel")
    require_signing = args.distribute and channel == "stable"
    if require_signing:
        missing = [name for name in SIGNING_NAMES if os.environ.get(f"{name}_CONFIGURED") != "true"]
        if missing:
            print(
                "::error::Stable distribution requires signing configuration: "
                + ", ".join(missing)
                + ". UPDATE_* accepts the existing SKOTIQ_* or NIGHTSHADE_* identity. "
                "Use workflow_dispatch without release_tag for a validation build only.",
                file=sys.stderr,
            )
            return 1
    elif not args.distribute:
        print("Build-only validation: unsigned output is not a shipping stable release.")
    else:
        print(f"{channel} prerelease: unsigned output is allowed; OTA requires signed manifests.")

    values = {
        "release_channel": channel,
        "require_signing": str(require_signing).lower(),
        "prerelease": str(channel != "stable").lower(),
        "make_latest": str(channel == "stable").lower(),
    }
    with args.output.open("a") as output:
        for name, value in values.items():
            output.write(f"{name}={value}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
