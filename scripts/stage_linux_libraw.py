#!/usr/bin/env python3
"""Stage LibRaw, its JPEG ABI dependency, and their distro copyright notices."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess


def output(*command):
    return subprocess.check_output(command, text=True).strip()


def library_cache():
    libraries = {}
    for line in output('ldconfig', '-p').splitlines():
        match = re.match(r'\s*(\S+)\s+\([^)]*\)\s+=>\s+(\S+)', line)
        if match:
            libraries.setdefault(match[1], Path(match[2]))
    return libraries


def elf_names(library):
    dynamic = output('readelf', '-d', str(library))
    soname = re.search(r'\(SONAME\).*\[(.+?)\]', dynamic)
    return soname[1] if soname else None, re.findall(r'\(NEEDED\).*\[(.+?)\]', dynamic)


def stage_library(source, bundle, notice_name):
    source = source.resolve(strict=True)
    soname, _ = elf_names(source)
    if soname is None or Path(soname).name != soname:
        raise ValueError(f'Invalid SONAME: {soname}')
    # Resolve the package owning the actual library, not a development symlink.
    owner = output('dpkg-query', '-S', str(source)).split(': ', 1)[0]
    package = owner.split(':', 1)[0]
    copyright_path = Path('/usr/share/doc') / package / 'copyright'
    if not copyright_path.is_file():
        raise FileNotFoundError(f'Copyright notice missing for {owner}')
    version = output('dpkg-query', '-W', '-f=${Version}', owner)
    destination = bundle / 'lib' / soname
    destination.parent.mkdir(parents=True, exist_ok=True)
    (bundle / 'LICENSES').mkdir(exist_ok=True)
    shutil.copy2(source, destination)
    shutil.copy2(copyright_path, bundle / 'LICENSES' / notice_name)
    return {
        'soname': soname,
        'package': owner,
        'version': version,
        'sha256': hashlib.sha256(destination.read_bytes()).hexdigest(),
        'copyright': f'LICENSES/{notice_name}',
    }


def stage(bundle, libraries=None):
    libraries = library_cache() if libraries is None else libraries
    _, bridge_needed = elf_names(bundle / 'lib' / 'libskotiq_bridge.so')
    raw_names = [name for name in bridge_needed if re.fullmatch(r'libraw\.so\.\d+', name)]
    if len(raw_names) != 1:
        raise ValueError(f'Expected one LibRaw ABI in bridge DT_NEEDED, got {raw_names}')
    raw_name = raw_names[0]
    if raw_name not in libraries or not libraries[raw_name].is_file():
        raise FileNotFoundError(f'Bridge needs {raw_name}, but it cannot be resolved')
    raw = libraries[raw_name]
    _, needed = elf_names(raw)
    jpeg = [name for name in needed if re.fullmatch(r'libjpeg\.so\.\d+', name)]
    for name in jpeg:
        if name not in libraries or not libraries[name].is_file():
            raise FileNotFoundError(f'LibRaw needs {name}, but it cannot be resolved')
    staged = [stage_library(raw, bundle, 'libraw-copyright.txt')]
    for name in jpeg:
        staged.append(stage_library(libraries[name], bundle, 'libjpeg-turbo-copyright.txt'))
    (bundle / 'NATIVE-LIBRARIES.json').write_text(json.dumps(staged, indent=2) + '\n')
    return staged


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    args = parser.parse_args()
    print(json.dumps(stage(args.bundle), indent=2))
