//! Build script to embed the Windows application manifest (asInvoker: the
//! updater runs with the same rights as the app that starts it)

fn main() {
    #[cfg(windows)]
    {
        if std::env::var("PROFILE").as_deref() != Ok("release") {
            return;
        }

        let mut res = winres::WindowsResource::new();
        res.set_manifest_file("updater.manifest");
        if let Err(e) = res.compile() {
            eprintln!("Warning: Failed to embed manifest: {}", e);
        }
    }
}
