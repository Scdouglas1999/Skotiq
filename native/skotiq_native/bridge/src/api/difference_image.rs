//! FFI entry points for differencing a frame against the sky atlas.
//!
//! The work is in [`skotiq_processing::difference_image`].

/// Difference one plate-solved frame against the atlas, returning residual
/// transient candidates per the contract JSON schema.
pub fn api_difference_image(args_json: String) -> Result<String, String> {
    skotiq_processing::difference_image::difference_image(args_json)
}

/// Tile-centre helper: resolve a HEALPix tile id to its sky position, so the Dart
/// side can annotate a skipped/no-template tile without re-deriving the addressing.
/// JSON in (`{ "tileId": 42, "order": 9 }`) / JSON out (`{ "tileId", "ra", "dec" }`),
/// matching the rest of this surface's JSON boundary (FRB cannot wire a bare
/// `TileId` type-alias parameter, so the id rides inside the payload).
pub fn api_difference_tile_center(args_json: String) -> Result<String, String> {
    skotiq_processing::difference_image::difference_tile_center(args_json)
}
