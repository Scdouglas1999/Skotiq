use skotiq_imaging::{read_image, read_raw};
use std::path::Path;

fn main() {
    println!("========================================");
    println!("LibRaw Integration Test");
    println!("========================================\n");

    // Test with a RAW file
    let test_file = std::env::args().nth(1).unwrap_or_else(|| {
        eprintln!(
            "Usage: cargo run --package skotiq_imaging --example test_raw <path_to_raf_file>"
        );
        eprintln!("\nExample:");
        eprintln!(
            "  cargo run --package skotiq_imaging --example test_raw C:\\path\\to\\image.raf"
        );
        std::process::exit(1);
    });

    let path = Path::new(&test_file);

    if !path.exists() {
        eprintln!("Error: File not found: {}", test_file);
        std::process::exit(1);
    }

    println!("Testing file: {}\n", test_file);

    // Test direct RAW reading
    println!("--- Direct RAW Reading ---");
    match read_raw(path, None) {
        Ok((image, metadata)) => {
            println!("✓ SUCCESS!");
            println!("\nCamera Information:");
            println!("  Make: {}", metadata.camera_make);
            println!("  Model: {}", metadata.camera_model);

            if let Some(iso) = metadata.iso_speed {
                println!("  ISO: {}", iso);
            }
            if let Some(shutter) = metadata.shutter_speed {
                println!("  Shutter Speed: {:.6}s", shutter);
            }
            if let Some(aperture) = metadata.aperture {
                println!("  Aperture: f/{:.1}", aperture);
            }
            if let Some(focal_len) = metadata.focal_length {
                println!("  Focal Length: {:.1}mm", focal_len);
            }

            println!("\nImage Data:");
            println!("  Dimensions: {}x{}", image.width, image.height);
            println!(
                "  Channels: {} ({})",
                image.channels,
                if image.channels == 3 {
                    "RGB - Native!"
                } else {
                    "Grayscale"
                }
            );
            println!("  Pixel Type: {:?}", image.pixel_type);
            println!("  Data Size: {} bytes", image.data.len());

            println!("\nX-Trans Detection:");
            println!(
                "  X-Trans Sensor: {}",
                if metadata.is_xtrans {
                    "✓ YES (Fujifilm)"
                } else {
                    "No (Standard Bayer)"
                }
            );
            println!("  Color Description: {}", metadata.color_desc);

            println!("\nRaw Sensor:");
            println!("  Raw Width: {}", metadata.raw_width);
            println!("  Raw Height: {}", metadata.raw_height);

            // Test RGBA conversion (this is what Flutter will use for display)
            println!("\n--- RGBA Conversion Test ---");
            match image.to_rgba() {
                Ok(rgba) => {
                    let expected_size = (image.width * image.height * 4) as usize;
                    if rgba.len() == expected_size {
                        println!("✓ RGBA conversion successful!");
                        println!(
                            "  RGBA Size: {} bytes ({} pixels)",
                            rgba.len(),
                            image.width * image.height
                        );
                        println!("  Expected: {} bytes", expected_size);

                        // Sample first few pixels
                        println!("\n  Sample pixel values (first pixel):");
                        if rgba.len() >= 4 {
                            println!(
                                "    R: {}, G: {}, B: {}, A: {}",
                                rgba[0], rgba[1], rgba[2], rgba[3]
                            );
                        }
                    } else {
                        println!("✗ RGBA conversion size mismatch!");
                        println!("  Got: {} bytes", rgba.len());
                        println!("  Expected: {} bytes", expected_size);
                    }
                }
                Err(e) => {
                    eprintln!("✗ RGBA conversion FAILED: {}", e);
                    std::process::exit(1);
                }
            }
        }
        Err(e) => {
            eprintln!("✗ FAILED to read RAW file!");
            eprintln!("Error: {}", e);
            std::process::exit(1);
        }
    }

    // Test unified image reader
    println!("\n--- Unified Image Reader Test ---");
    match read_image(path) {
        Ok(result) => {
            println!("✓ Unified reader success!");
            println!("  Format: {:?}", result.format);
            println!(
                "  Image: {}x{}, {} channels",
                result.image.width, result.image.height, result.image.channels
            );

            println!("\n  Metadata from header:");
            for (key, value) in result.header.iter().take(10) {
                println!("    {}: {}", key, value);
            }
            if result.header.len() > 10 {
                println!("    ... and {} more", result.header.len() - 10);
            }
        }
        Err(e) => {
            eprintln!("✗ Unified reader failed: {}", e);
        }
    }

    println!("\n========================================");
    println!("Test Complete!");
    println!("========================================");
}
