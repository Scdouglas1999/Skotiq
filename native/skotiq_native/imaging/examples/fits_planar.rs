//! Report how a color FITS file orders its planes, and optionally rewrite it in
//! the standard planar order.
//!
//! ```text
//! cargo run --release -p skotiq_imaging --example fits_planar -- IN.fits [OUT.fits]
//! ```
//!
//! Color files written by earlier builds hold interleaved samples under a
//! planar header, which other programs open scrambled. This app still reads
//! them correctly; given `OUT.fits`, the file is read and written back planar
//! so PixInsight, Siril and astropy read it too.

use skotiq_imaging::fits_layout::{layout_from_header, le_sample, plane_correlation};
use skotiq_imaging::{read_fits, read_fits_header, write_fits};
use std::path::PathBuf;

fn main() {
    let args: Vec<PathBuf> = std::env::args().skip(1).map(PathBuf::from).collect();
    let Some(input) = args.first() else {
        eprintln!("usage: fits_planar IN.fits [OUT.fits]");
        std::process::exit(2);
    };
    let header = read_fits_header(input).unwrap_or_else(|e| panic!("{}: {e}", input.display()));
    let (image, read_header) =
        read_fits(input).unwrap_or_else(|e| panic!("{}: {e}", input.display()));
    let stated = layout_from_header(&header);
    // `read_fits` returns interleaved samples. Their first two channels share
    // their stars when the read put every sample in its place.
    let pixels = (image.width * image.height) as usize;
    let channels = image.channels as usize;
    let as_planar = |k: usize| {
        let (c, p) = (k / pixels, k % pixels);
        le_sample(&image.data, image.pixel_type, p * channels + c)
    };
    let aligned = if channels < 2 {
        "null".to_string()
    } else {
        format!(
            "{:.3}",
            plane_correlation(
                image.width as usize,
                image.height as usize,
                channels,
                as_planar
            )
        )
    };
    println!(
        "{{\"file\":\"{}\",\"width\":{},\"height\":{},\"channels\":{},\"layoutCard\":{},\"channelCorrelation\":{}}}",
        input.display(),
        image.width,
        image.height,
        channels,
        stated.map_or("null".to_string(), |l| format!("\"{}\"", l.as_card())),
        aligned,
    );
    if let Some(output) = args.get(1) {
        write_fits(output, &image, &read_header)
            .unwrap_or_else(|e| panic!("{}: {e:?}", output.display()));
        println!("wrote {} plane by plane", output.display());
    }
}
