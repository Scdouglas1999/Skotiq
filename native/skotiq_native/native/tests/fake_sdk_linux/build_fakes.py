#!/usr/bin/env python3
"""Build the software-only fake vendor SDKs as Linux shared objects.

usage: build_fakes.py <out_dir>

The fake SDK sources are the `*_FAKE_SDK` string constants in
`tests/native_driver_tests.rs` (`mod fake_sdk_contract`, which itself only
builds on Windows). This compiles each one to `<out_dir>/<vendor>/lib*.so`
under the name the Linux loader looks for, after instrumenting every exported
function to append `Name(scalar args)` to `$FAKE_SDK_TRACE` and, for a gap of
100 ms or more since the previous call, a line to `$FAKE_SDK_TRACE.timing`.

A fake whose source is `include_str!`ed (SVBony: tests/fake_sdk/svbony.rs) is
read from that file; one named by its path (gPhoto2: fake_sdk/gphoto2.rs, which
only the Linux tests use) is read from it. The Touptek and Moravian fakes predate the entry points
those drivers now require (pull-mode callbacks; the gxccd API), so their
libraries fail to load and their sessions record the same load error before
and after.
"""
import os, pathlib, re, subprocess, sys

out = pathlib.Path(sys.argv[1])
tests = pathlib.Path(__file__).resolve().parent.parent
src = (tests / "native_driver_tests.rs").read_text()

FAKES = [
    ("zwo", "ASI_FAKE_SDK", "libASICamera2.so"),
    ("zwo", "EAF_FAKE_SDK", "libEAF_focuser.so"),
    ("zwo", "EFW_FAKE_SDK", "libEFW_filter.so"),
    ("atik", "ATIK_FAKE_SDK", "libatikcameras.so"),
    ("svbony", "SVBONY_FAKE_SDK", "libSVBCameraSDK.so"),
    ("player_one", "PLAYER_ONE_FAKE_SDK", "libPlayerOneCamera.so"),
    ("player_one", "PLAYER_ONE_PW_FAKE_SDK", "libPlayerOnePW.so"),
    ("qhy", "QHY_FAKE_SDK", "libqhyccd.so"),
    ("touptek", "TOUPTEK_FAKE_SDK", "libogmacam.so"),
    ("fli", "FLI_FAKE_SDK", "libfli.so"),
    ("moravian", "MORAVIAN_FAKE_SDK", "libgxccd.so"),
    ("gphoto2", "fake_sdk/gphoto2.rs", "libgphoto2.so"),
]
SCALARS = {"c_int", "c_long", "c_uint", "c_ulong", "c_double", "c_float", "bool", "f32", "f64", "i32",
           "u32", "i64", "u64", "c_uchar", "c_ushort", "c_short", "u8", "u16", "i16", "usize"}
TRACE = r'''
fn __trace(s: String){
    use std::io::Write;
    static LAST: std::sync::Mutex<Option<std::time::Instant>> = std::sync::Mutex::new(None);
    if let Ok(p)=std::env::var("FAKE_SDK_TRACE"){
        let now=std::time::Instant::now();
        let mut last=LAST.lock().unwrap();
        if let Some(prev)=*last { let gap=now.duration_since(prev).as_millis(); if gap>=100 {
            if let Ok(mut f)=std::fs::OpenOptions::new().create(true).append(true).open(format!("{}.timing",p)){ let _=writeln!(f,"gap {}00ms before {}",gap/100,s);} } }
        *last=Some(now);
        if let Ok(mut f)=std::fs::OpenOptions::new().create(true).append(true).open(p){ let _=writeln!(f,"{}",s);}
    }
}
'''

def instrument(m):
    head, name, args = m.group(1), m.group(2), m.group(3)
    fmt, vals = [], []
    for a in args.split(","):
        if ":" not in a:
            continue
        n, t = (x.strip() for x in a.split(":", 1))
        if n.startswith("mut "):
            n = n[4:]
        if t in SCALARS:
            fmt.append("{:?}")
            vals.append(n)
    call = '__trace(format!("%s(%s)"%s));' % (name, ",".join(fmt), "".join("," + v for v in vals))
    return head + "{ " + call + " "

PAT = re.compile(r'(#\[no_mangle\] pub (?:unsafe )?extern "C" fn (\w+)\(([^)]*)\)(?:->[^{]+)?)\{')
def fake_source(const):
    if const.endswith(".rs"):
        return (tests / const).read_text()
    m = re.search(r'const %s: &str = r#"\n(.*?)"#;' % const, src, flags=re.S)
    if m:
        return m.group(1)
    m = re.search(r'const %s: &str = include_str!\("([^"]+)"\);' % const, src)
    if m:
        return (tests / m.group(1)).read_text()
    sys.exit("fake source %s not found" % const)

for vendor, const, lib in FAKES:
    body, count = PAT.subn(instrument, fake_source(const))
    d = out / vendor
    d.mkdir(parents=True, exist_ok=True)
    rs = d / (pathlib.Path(const).stem.lower() + ".rs")
    rs.write_text(body + TRACE)
    r = subprocess.run([os.environ.get("RUSTC", "rustc"), "--crate-type", "cdylib", "--edition", "2021",
                        "-A", "warnings", str(rs), "-o", str(d / lib)], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("fake SDK build failed for %s:\n%s" % (lib, r.stderr))
    print("%s: %s (%d functions traced)" % (vendor, lib, count))
