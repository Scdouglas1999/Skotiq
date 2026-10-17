use std::env;

fn main() {
    // On Linux the bridge cdylib is loaded by the Flutter desktop executable.
    // The executable's RUNPATH ($ORIGIN/lib) does NOT propagate to this
    // transitively-loaded library, so without its own RUNPATH the bridge cannot
    // find sibling bundled libraries (libraw, sqlite, ...) that live next to it
    // in the bundle's lib/ directory — a double-clicked release then fails with
    // "libraw.so.20: cannot open shared object file". Giving the cdylib its own
    // RUNPATH of $ORIGIN makes the bundle self-contained without the launcher
    // having to set LD_LIBRARY_PATH.
    if env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux") {
        println!("cargo:rustc-cdylib-link-arg=-Wl,-rpath,$ORIGIN");
    }
}
