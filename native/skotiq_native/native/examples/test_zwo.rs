use skotiq_native::vendor::zwo::{discover_devices, is_sdk_available};

#[tokio::main]
async fn main() {
    println!("Checking ZWO SDK availability...");

    // Try explicit load to debug
    let path = "C:\\Users\\scdou\\Documents\\Skotiq2\\SDKs\\ZWO\\ASI_Camera_SDK\\ASI_Windows_SDK_V1.40\\ASI SDK\\lib\\x64\\ASICamera2.dll";
    println!("Attempting to load from: {}", path);
    // SAFETY: `libloading::Library::new` is unsafe because the dynamic linker may run
    // arbitrary initializer code in the loaded library. This is a developer test-only
    // example binary used to debug ZWO SDK loading on a known dev machine; the path is
    // a hard-coded local install location, and we immediately drop the loaded library
    // without resolving any symbols.
    unsafe {
        match libloading::Library::new(path) {
            Ok(_) => println!("Successfully loaded library directly!"),
            Err(e) => println!("Failed to load library directly: {}", e),
        }
    }

    if is_sdk_available() {
        println!("ZWO SDK is available via discovery!");
    } else {
        println!("ZWO SDK is NOT available via discovery.");
    }

    println!("Discovering ZWO cameras...");
    match discover_devices().await {
        Ok(cameras) => {
            println!("Found {} cameras:", cameras.len());
            for cam in cameras {
                println!(" - {} (ID: {})", cam.name, cam.camera_id);
            }
        }
        Err(e) => println!("Error discovering cameras: {:?}", e),
    }
}
