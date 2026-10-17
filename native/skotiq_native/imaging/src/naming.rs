//! File naming patterns for image file organization
//!
//! Supports patterns like:
//! - $TARGET - Target name (e.g., "M31")
//! - $FILTER - Filter name (e.g., "L", "Ha")
//! - $EXPTIME - Exposure time in seconds
//! - $DATE - Date in YYYY-MM-DD format
//! - $TIME - Time in HH-MM-SS format
//! - $DATETIME - Combined date and time
//! - $FRAMETYPE - Frame type (Light, Dark, Flat, Bias)
//! - $FRAMENUM - Frame number (auto-incremented)
//! - $GAIN - Camera gain
//! - $OFFSET - Camera offset
//! - $TEMP - Sensor temperature
//! - $BINNING - Binning (e.g., "1x1", "2x2")
//! - $CAMERA - Camera name
//! - $TELESCOPE - Telescope name
//! - $SEQUENCE - Sequence name
//!
//! # `unwrap_or` policy
//!
//! Every `unwrap_or` site here substitutes a documented per-token default
//! for missing metadata on the `NamingContext`. The contract is:
//! a sequence may run without a target name, without a filter wheel,
//! without a configured telescope alias, etc. — and the filename pattern
//! must still produce a valid path. The defaults below are the user-facing
//! convention enshrined in the naming UI: "Unknown" / "NoFilter" / "0" /
//! "Camera" / "Telescope" / "Sequence" / current local date. These are NOT
//! silent error fallbacks; the captured-image metadata is independently
//! persisted to the database via `image_metadata` (drift schema v14),
//! which preserves the structured per-field state regardless of filename.

use chrono::{DateTime, Local, Utc};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// Frame type for image classification
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum FrameType {
    #[default]
    Light,
    Dark,
    Flat,
    Bias,
    DarkFlat,
    Snapshot,
}

impl FrameType {
    pub fn as_str(&self) -> &'static str {
        match self {
            FrameType::Light => "Light",
            FrameType::Dark => "Dark",
            FrameType::Flat => "Flat",
            FrameType::Bias => "Bias",
            FrameType::DarkFlat => "DarkFlat",
            FrameType::Snapshot => "Snapshot",
        }
    }

    #[allow(clippy::should_implement_trait)]
    pub fn from_str(s: &str) -> Option<Self> {
        match s.to_lowercase().as_str() {
            "light" => Some(FrameType::Light),
            "dark" => Some(FrameType::Dark),
            "flat" => Some(FrameType::Flat),
            "bias" => Some(FrameType::Bias),
            "darkflat" | "dark_flat" => Some(FrameType::DarkFlat),
            "snapshot" => Some(FrameType::Snapshot),
            _ => None,
        }
    }
}

impl std::fmt::Display for FrameType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

/// Metadata for file naming
#[derive(Debug, Clone, Default)]
pub struct NamingContext {
    pub target: Option<String>,
    pub filter: Option<String>,
    pub exposure_time: Option<f64>,
    pub frame_type: FrameType,
    pub frame_number: Option<u32>,
    pub gain: Option<i32>,
    pub offset: Option<i32>,
    pub temperature: Option<f64>,
    pub binning_x: Option<u32>,
    pub binning_y: Option<u32>,
    pub camera: Option<String>,
    pub telescope: Option<String>,
    pub sequence: Option<String>,
    pub timestamp: Option<DateTime<Utc>>,
    pub session_id: Option<String>,
    /// Custom variables
    pub custom: HashMap<String, String>,
}

impl NamingContext {
    pub fn new() -> Self {
        Self::default()
    }

    /// Set the timestamp to now
    pub fn with_current_time(mut self) -> Self {
        self.timestamp = Some(Utc::now());
        self
    }

    /// Set target name
    pub fn with_target(mut self, target: impl Into<String>) -> Self {
        self.target = Some(target.into());
        self
    }

    /// Set filter name
    pub fn with_filter(mut self, filter: impl Into<String>) -> Self {
        self.filter = Some(filter.into());
        self
    }

    /// Set exposure time
    pub fn with_exposure(mut self, seconds: f64) -> Self {
        self.exposure_time = Some(seconds);
        self
    }

    /// Set frame type
    pub fn with_frame_type(mut self, frame_type: FrameType) -> Self {
        self.frame_type = frame_type;
        self
    }

    /// Set frame number
    pub fn with_frame_number(mut self, num: u32) -> Self {
        self.frame_number = Some(num);
        self
    }

    /// Set camera gain
    pub fn with_gain(mut self, gain: i32) -> Self {
        self.gain = Some(gain);
        self
    }

    /// Set camera offset
    pub fn with_offset(mut self, offset: i32) -> Self {
        self.offset = Some(offset);
        self
    }

    /// Set sensor temperature
    pub fn with_temperature(mut self, temp: f64) -> Self {
        self.temperature = Some(temp);
        self
    }

    /// Set binning
    pub fn with_binning(mut self, x: u32, y: u32) -> Self {
        self.binning_x = Some(x);
        self.binning_y = Some(y);
        self
    }

    /// Set camera name
    pub fn with_camera(mut self, camera: impl Into<String>) -> Self {
        self.camera = Some(camera.into());
        self
    }

    /// Set telescope name
    pub fn with_telescope(mut self, telescope: impl Into<String>) -> Self {
        self.telescope = Some(telescope.into());
        self
    }

    /// Set sequence name
    pub fn with_sequence(mut self, sequence: impl Into<String>) -> Self {
        self.sequence = Some(sequence.into());
        self
    }

    /// Add custom variable
    pub fn with_custom(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.custom.insert(key.into(), value.into());
        self
    }
}

/// File naming pattern
#[derive(Debug, Clone)]
pub struct NamingPattern {
    /// The pattern string
    pattern: String,
    /// File extension
    extension: String,
    /// Base directory
    base_dir: PathBuf,
    /// Whether to create subdirectories based on pattern
    create_subdirs: bool,
}

impl Default for NamingPattern {
    fn default() -> Self {
        Self {
            pattern: "$TARGET/$FRAMETYPE/$TARGET_$FILTER_$EXPTIME_$FRAMENUM".to_string(),
            extension: "fits".to_string(),
            base_dir: PathBuf::from("."),
            create_subdirs: true,
        }
    }
}

impl NamingPattern {
    /// Create a new naming pattern
    pub fn new(pattern: impl Into<String>) -> Self {
        Self {
            pattern: pattern.into(),
            ..Default::default()
        }
    }

    /// Set the file extension
    pub fn with_extension(mut self, ext: impl Into<String>) -> Self {
        self.extension = ext.into();
        self
    }

    /// Set the base directory
    pub fn with_base_dir(mut self, dir: impl Into<PathBuf>) -> Self {
        self.base_dir = dir.into();
        self
    }

    /// Set whether to create subdirectories
    pub fn with_subdirs(mut self, create: bool) -> Self {
        self.create_subdirs = create;
        self
    }

    /// Generate a filename from the context
    pub fn generate(&self, context: &NamingContext) -> PathBuf {
        let filename = self.expand_pattern(&self.pattern, context);
        let sanitized = sanitize_filename(&filename);

        let mut path = self.base_dir.clone();

        // Split by path separator to handle subdirectories
        let parts: Vec<&str> = sanitized.split('/').collect();
        for (i, part) in parts.iter().enumerate() {
            if i < parts.len() - 1 {
                // Directory component
                path.push(part);
            } else {
                // Filename component - add extension
                path.push(format!("{}.{}", part, self.extension));
            }
        }

        path
    }

    /// Expand pattern variables
    fn expand_pattern(&self, pattern: &str, ctx: &NamingContext) -> String {
        let mut result = pattern.to_string();

        // Get timestamp
        let ts = ctx.timestamp.unwrap_or_else(Utc::now);
        let local_ts: DateTime<Local> = ts.into();

        // Replace all variables
        let replacements: Vec<(&str, String)> = vec![
            (
                "$TARGET",
                ctx.target.clone().unwrap_or_else(|| "Unknown".to_string()),
            ),
            (
                "$FILTER",
                ctx.filter.clone().unwrap_or_else(|| "NoFilter".to_string()),
            ),
            (
                "$EXPTIME",
                format_exposure(ctx.exposure_time.unwrap_or(0.0)),
            ),
            ("$DATE", local_ts.format("%Y-%m-%d").to_string()),
            ("$TIME", local_ts.format("%H-%M-%S").to_string()),
            (
                "$DATETIME",
                local_ts.format("%Y-%m-%d_%H-%M-%S").to_string(),
            ),
            ("$FRAMETYPE", ctx.frame_type.as_str().to_string()),
            ("$FRAMENUM", format!("{:04}", ctx.frame_number.unwrap_or(1))),
            (
                "$GAIN",
                ctx.gain
                    .map(|g| g.to_string())
                    .unwrap_or_else(|| "0".to_string()),
            ),
            (
                "$OFFSET",
                ctx.offset
                    .map(|o| o.to_string())
                    .unwrap_or_else(|| "0".to_string()),
            ),
            ("$TEMP", format_temperature(ctx.temperature)),
            (
                "$BINNING",
                format!(
                    "{}x{}",
                    ctx.binning_x.unwrap_or(1),
                    ctx.binning_y.unwrap_or(1)
                ),
            ),
            (
                "$CAMERA",
                ctx.camera.clone().unwrap_or_else(|| "Camera".to_string()),
            ),
            (
                "$TELESCOPE",
                ctx.telescope
                    .clone()
                    .unwrap_or_else(|| "Telescope".to_string()),
            ),
            (
                "$SEQUENCE",
                ctx.sequence
                    .clone()
                    .unwrap_or_else(|| "Sequence".to_string()),
            ),
            (
                "$SESSION",
                ctx.session_id
                    .clone()
                    .unwrap_or_else(|| local_ts.format("%Y%m%d").to_string()),
            ),
        ];

        for (var, value) in replacements {
            result = result.replace(var, &value);
        }

        // Replace custom variables
        for (key, value) in &ctx.custom {
            let var = format!("${}", key.to_uppercase());
            result = result.replace(&var, value);
        }

        result
    }
}

/// Format exposure time for filename
fn format_exposure(seconds: f64) -> String {
    if seconds >= 1.0 {
        format!("{}s", seconds as i32)
    } else if seconds >= 0.001 {
        format!("{}ms", (seconds * 1000.0) as i32)
    } else {
        format!("{}us", (seconds * 1000000.0) as i32)
    }
}

/// Format temperature for filename
fn format_temperature(temp: Option<f64>) -> String {
    match temp {
        Some(t) => {
            if t >= 0.0 {
                format!("{}C", t as i32)
            } else {
                format!("m{}C", (-t) as i32)
            }
        }
        None => "NoTemp".to_string(),
    }
}

/// Sanitize a filename by removing/replacing invalid characters
fn sanitize_filename(name: &str) -> String {
    name.chars()
        .map(|c| match c {
            '<' | '>' | ':' | '"' | '\\' | '|' | '?' | '*' => '_',
            c if c.is_control() => '_',
            c => c,
        })
        .collect()
}

/// Frame counter for auto-incrementing frame numbers
#[derive(Debug, Clone)]
pub struct FrameCounter {
    counters: HashMap<String, u32>,
}

impl Default for FrameCounter {
    fn default() -> Self {
        Self::new()
    }
}

impl FrameCounter {
    pub fn new() -> Self {
        Self {
            counters: HashMap::new(),
        }
    }

    /// Get the next frame number for a given key
    /// Key is typically target_filter_frametype
    pub fn next(&mut self, key: &str) -> u32 {
        let counter = self.counters.entry(key.to_string()).or_insert(0);
        *counter += 1;
        *counter
    }

    /// Get current frame number without incrementing
    pub fn current(&self, key: &str) -> u32 {
        // Why: no entry for key → counter has never been incremented →
        // current() returns 0 — the documented zero-base convention. This is read-only
        // and pairs with `next()` which inserts-or-increments.
        *self.counters.get(key).unwrap_or(&0)
    }

    /// Reset a specific counter
    pub fn reset(&mut self, key: &str) {
        self.counters.remove(key);
    }

    /// Reset all counters
    pub fn reset_all(&mut self) {
        self.counters.clear();
    }

    /// Set a counter to a specific value
    pub fn set(&mut self, key: &str, value: u32) {
        self.counters.insert(key.to_string(), value);
    }

    /// Generate a key from context
    pub fn key_from_context(ctx: &NamingContext) -> String {
        format!(
            "{}_{}_{}",
            ctx.target.as_deref().unwrap_or("Unknown"),
            ctx.filter.as_deref().unwrap_or("NoFilter"),
            ctx.frame_type.as_str()
        )
    }
}

/// Directory organization modes
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum DirectoryMode {
    /// All files in one directory
    Flat,
    /// Organize by date: YYYY-MM-DD/
    #[default]
    ByDate,
    /// Organize by target: TARGET/
    ByTarget,
    /// Organize by target and date: TARGET/YYYY-MM-DD/
    ByTargetAndDate,
    /// Organize by date and target: YYYY-MM-DD/TARGET/
    ByDateAndTarget,
    /// Organize by frame type: Light/, Dark/, Flat/, Bias/
    ByFrameType,
    /// Full organization: TARGET/FRAMETYPE/FILTER/
    Full,
}

impl DirectoryMode {
    /// Get the pattern prefix for this mode
    pub fn pattern_prefix(&self) -> &'static str {
        match self {
            DirectoryMode::Flat => "",
            DirectoryMode::ByDate => "$DATE/",
            DirectoryMode::ByTarget => "$TARGET/",
            DirectoryMode::ByTargetAndDate => "$TARGET/$DATE/",
            DirectoryMode::ByDateAndTarget => "$DATE/$TARGET/",
            DirectoryMode::ByFrameType => "$FRAMETYPE/",
            DirectoryMode::Full => "$TARGET/$FRAMETYPE/$FILTER/",
        }
    }
}

/// Scan directory for existing frames and return next frame number
pub fn scan_for_next_frame_number(
    base_dir: &Path,
    pattern: &NamingPattern,
    context: &NamingContext,
) -> u32 {
    // Generate what the filename should look like (without the number)
    let mut test_context = context.clone();
    test_context.frame_number = Some(0);

    let test_path = pattern.generate(&test_context);
    // Why: `Path::parent()` returns None only for the empty path or
    // root. If `pattern.generate` produced a parent-less path (e.g. on a misconfigured
    // pattern with no directory tokens), scanning the original base_dir is the
    // semantically-correct fallback — we want to count siblings of the test path.
    let parent = test_path.parent().unwrap_or(base_dir);

    // If directory doesn't exist, start at 1
    if !parent.exists() {
        return 1;
    }

    // Scan for existing files
    let mut max_num = 0u32;

    if let Ok(entries) = std::fs::read_dir(parent) {
        for entry in entries.flatten() {
            let filename = entry.file_name();
            let name = filename.to_string_lossy();

            // Try to extract frame number from filename
            // Look for patterns like _0001. or _0001_
            for i in (0..name.len()).rev() {
                if let Some(num_str) = extract_frame_number(&name, i) {
                    if let Ok(num) = num_str.parse::<u32>() {
                        max_num = max_num.max(num);
                        break;
                    }
                }
            }
        }
    }

    max_num + 1
}

/// Extract frame number from filename at given position
fn extract_frame_number(name: &str, pos: usize) -> Option<&str> {
    let bytes = name.as_bytes();

    // Check if we're at a digit
    if !bytes.get(pos)?.is_ascii_digit() {
        return None;
    }

    // Find start of number sequence
    let mut start = pos;
    while start > 0 && bytes[start - 1].is_ascii_digit() {
        start -= 1;
    }

    // Find end of number sequence
    let mut end = pos;
    while end < bytes.len() && bytes[end].is_ascii_digit() {
        end += 1;
    }

    // Must be at least 3 digits (typical frame numbers)
    if end - start < 3 {
        return None;
    }

    let valid_left_boundary =
        start == 0 || matches!(bytes[start - 1], b'_' | b'-' | b' ' | b'(' | b'[');
    let valid_right_boundary =
        end == bytes.len() || matches!(bytes[end], b'_' | b'-' | b' ' | b'.' | b')' | b']');

    if valid_left_boundary && valid_right_boundary {
        Some(&name[start..end])
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_basic_pattern() {
        let pattern = NamingPattern::new("$TARGET_$FILTER_$FRAMENUM");
        let context = NamingContext::new()
            .with_target("M31")
            .with_filter("L")
            .with_frame_number(1);

        let path = pattern.generate(&context);
        assert!(path.to_string_lossy().contains("M31_L_0001"));
    }

    #[test]
    fn test_exposure_formatting() {
        assert_eq!(format_exposure(120.0), "120s");
        assert_eq!(format_exposure(0.5), "500ms");
        assert_eq!(format_exposure(0.0001), "100us");
    }

    #[test]
    fn extract_frame_number_rejects_camera_model_digits() {
        assert_eq!(extract_frame_number("M31_ASI2600_Light.fit", 8), None);
        assert_eq!(extract_frame_number("M31_Light_0007.fit", 12), Some("0007"));
    }
}
