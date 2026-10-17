//! Performance optimization examples
//!
//! This example demonstrates the performance improvements from:
//! - Tiled image processing
//! - Memory-mapped file access
//! - Thumbnail generation
//! - Progress callbacks

// Why: post, `process_tiled`/`process_with_progress` are sync
// CPU-bound functions; demo no longer needs `.await` for those calls.
use skotiq_imaging::{
    generate_thumbnail, process_tiled, process_with_progress, ImageData, MappedFitsReader,
    PixelType, ProcessOperation,
};
use std::path::Path;
use std::time::Instant;

#[tokio::main]
async fn main() {
    println!("=== Skotiq Performance Optimization Demo ===\n");

    // Example 1: Tiled Processing
    demo_tiled_processing().await;

    // Example 2: Memory-Mapped Reading
    demo_memory_mapped_reading().await;

    // Example 3: Thumbnail Generation
    demo_thumbnail_generation().await;

    // Example 4: Progress Callbacks
    demo_progress_callbacks().await;
}

/// Demonstrate tiled processing for large images
async fn demo_tiled_processing() {
    println!("--- Demo 1: Tiled Processing ---");

    // Simulate a 60MP image (7680x7680)
    let image = ImageData::new(7680, 7680, 1, PixelType::U16);
    let memory_size = image.size_bytes();

    println!("Image size: {}x{}", image.width, image.height);
    println!("Memory usage: {:.2} MB", memory_size as f64 / 1_048_576.0);

    // Process with different tile sizes
    for tile_size in [256, 512, 1024, 2048] {
        let start = Instant::now();

        let result = process_tiled(&image, tile_size, ProcessOperation::Normalize, None);

        let elapsed = start.elapsed();

        match result {
            Ok(_) => {
                println!(
                    "  Tile size {}: {:.2}ms",
                    tile_size,
                    elapsed.as_secs_f64() * 1000.0
                );
            }
            Err(e) => {
                println!("  Error with tile size {}: {}", tile_size, e);
            }
        }
    }

    println!();
}

/// Demonstrate memory-mapped file reading
async fn demo_memory_mapped_reading() {
    println!("--- Demo 2: Memory-Mapped Reading ---");

    // This would require an actual FITS file
    // For demonstration, we show the API usage

    let fits_path = Path::new("example_image.fits");

    if fits_path.exists() {
        match MappedFitsReader::open(fits_path) {
            Ok(reader) => {
                let (width, height, channels) = reader.dimensions();
                println!(
                    "Opened memory-mapped FITS: {}x{}x{}",
                    width, height, channels
                );
                println!(
                    "File size: {:.2} MB",
                    reader.file_size() as f64 / 1_048_576.0
                );

                // Read a small region (much faster than loading full image)
                let start = Instant::now();
                match reader.read_region(0, 0, 512, 512) {
                    Ok(region) => {
                        let elapsed = start.elapsed();
                        println!(
                            "Read 512x512 region in {:.2}ms",
                            elapsed.as_secs_f64() * 1000.0
                        );
                        println!(
                            "Region memory: {:.2} KB",
                            region.size_bytes() as f64 / 1024.0
                        );
                    }
                    Err(e) => println!("Error reading region: {}", e),
                }

                // Downsample for preview (much faster than full read + resize)
                let start = Instant::now();
                match reader.read_downsampled(4) {
                    Ok(thumbnail) => {
                        let elapsed = start.elapsed();
                        println!(
                            "Generated preview (4x downsample) in {:.2}ms",
                            elapsed.as_secs_f64() * 1000.0
                        );
                        println!("Preview size: {}x{}", thumbnail.width, thumbnail.height);
                    }
                    Err(e) => println!("Error downsampling: {}", e),
                }
            }
            Err(e) => println!("Could not open FITS file: {}", e),
        }
    } else {
        println!("Example FITS file not found, skipping demo");
    }

    println!();
}

/// Demonstrate thumbnail generation
async fn demo_thumbnail_generation() {
    println!("--- Demo 3: Thumbnail Generation ---");

    // Test with different file types
    let test_files = vec![
        ("example.fits", "FITS file"),
        ("example.cr3", "Canon RAW"),
        ("example.nef", "Nikon RAW"),
        ("example.raf", "Fujifilm RAW"),
    ];

    for (filename, description) in test_files {
        let path = Path::new(filename);

        if path.exists() {
            println!("  Testing {}", description);

            let start = Instant::now();
            match generate_thumbnail(path, 512) {
                Ok(thumbnail) => {
                    let elapsed = start.elapsed();
                    println!(
                        "    Generated {}x{} thumbnail in {:.2}ms",
                        thumbnail.width,
                        thumbnail.height,
                        elapsed.as_secs_f64() * 1000.0
                    );
                    println!(
                        "    Memory usage: {:.2} KB",
                        thumbnail.size_bytes() as f64 / 1024.0
                    );
                }
                Err(e) => println!("    Error: {}", e),
            }
        } else {
            println!("  Skipping {} (file not found)", description);
        }
    }

    println!();
}

/// Demonstrate progress callbacks
async fn demo_progress_callbacks() {
    println!("--- Demo 4: Progress Callbacks ---");

    let image = ImageData::new(4096, 4096, 1, PixelType::U16);
    println!(
        "Processing {}x{} image with progress...",
        image.width, image.height
    );

    let start = Instant::now();

    let result = process_with_progress(
        &image,
        ProcessOperation::AutoStretch {
            shadow: 0.0,
            midtone: 0.5,
            highlight: 1.0,
        },
        512,
        |progress| {
            // This callback is called as processing progresses
            let percent = (progress * 100.0) as i32;
            if percent % 10 == 0 {
                // Only print every 10%
                print!("\r  Progress: {}%", percent);
                use std::io::Write;
                std::io::stdout().flush().unwrap();
            }
        },
    );

    println!(); // New line after progress

    let elapsed = start.elapsed();

    match result {
        Ok(_) => {
            println!("  Completed in {:.2}ms", elapsed.as_secs_f64() * 1000.0);
        }
        Err(e) => {
            println!("  Error: {}", e);
        }
    }

    println!();
}

/// Performance comparison: Traditional vs Optimized
#[allow(dead_code)]
async fn performance_comparison() {
    println!("--- Performance Comparison ---");

    let image = ImageData::new(7680, 7680, 1, PixelType::U16);
    let memory_mb = image.size_bytes() as f64 / 1_048_576.0;

    println!(
        "Image: {}x{} ({:.2} MB)",
        image.width, image.height, memory_mb
    );
    println!();

    // Traditional: Load entire image
    println!("Traditional approach:");
    let start = Instant::now();
    let _full_image = image.clone(); // Simulates loading full image
    let traditional_time = start.elapsed();
    println!("  Time: {:.2}ms", traditional_time.as_secs_f64() * 1000.0);
    println!("  Memory: {:.2} MB", memory_mb);
    println!();

    // Optimized: Tiled processing
    println!("Optimized approach (tiled):");
    let start = Instant::now();
    let _result = process_tiled(&image, 512, ProcessOperation::Normalize, None);
    let optimized_time = start.elapsed();
    let tile_memory = 512.0 * 512.0 * 2.0 / 1_048_576.0; // One tile in MB
    println!("  Time: {:.2}ms", optimized_time.as_secs_f64() * 1000.0);
    println!("  Peak memory: ~{:.2} MB (per tile)", tile_memory * 4.0); // Assume 4 threads
    println!();

    let speedup = traditional_time.as_secs_f64() / optimized_time.as_secs_f64();
    let memory_savings = (1.0 - (tile_memory * 4.0 / memory_mb)) * 100.0;

    println!("Results:");
    println!("  Speedup: {:.2}x", speedup);
    println!("  Memory savings: {:.1}%", memory_savings);
}
