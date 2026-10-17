//! Manual smoke example: enumerate ASCOM camera drivers and try to connect.
//!
//! ASCOM is a Windows COM technology; every symbol this example uses is
//! `#[cfg(windows)]`-gated in the crate, so the example body is gated the
//! same way. On other platforms it compiles to a stub so `cargo test
//! --workspace` (which builds examples) stays green on Linux/macOS CI.

#[cfg(not(windows))]
fn main() {
    eprintln!("ASCOM COM drivers exist only on Windows; nothing to do here.");
}

#[cfg(windows)]
fn main() {
    use skotiq_ascom::{discover_devices, AscomCamera, AscomDeviceType};

    // Initialize COM
    skotiq_ascom::init_com().expect("Failed to init COM");

    println!("Discovering cameras...");
    let devices = discover_devices(AscomDeviceType::Camera);

    for device in &devices {
        println!("Found: {} ({})", device.name, device.prog_id);
    }

    for device in &devices {
        println!(
            "Attempting to connect to {} ({})",
            device.name, device.prog_id
        );
        match AscomCamera::new(&device.prog_id) {
            Ok(mut camera) => {
                println!("Created camera object for {}", device.name);
                match camera.connect() {
                    Ok(_) => {
                        println!("Connected successfully to {}!", device.name);
                        let _ = camera.disconnect();
                    }
                    Err(e) => println!("Failed to connect to {}: {}", device.name, e),
                }
            }
            Err(e) => println!("Failed to create camera object for {}: {}", device.name, e),
        }
        println!("---");
    }

    skotiq_ascom::uninit_com();
}
