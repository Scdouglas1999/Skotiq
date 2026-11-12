//! The app's frame metadata (`FitsHeader`) to and from an XISF image.
//!
//! Writing, every card becomes a `FITSKeyword` element in header order, and
//! the cards the XISF standard has a property for are also written as that
//! property (`Observation:*`, `Instrument:*`, the image type, the color
//! filter array, the astrometric solution), which is where PixInsight looks
//! first. Reading, the keywords come back as cards, and a property fills a
//! card only when the file has no such keyword, so a file another program
//! wrote with properties alone still tells the app its exposure, filter,
//! date and solution.

use super::property::{PropertyValue, XisfProperty};
use super::{ColorFilterArray, FitsKeyword, XisfImageHeader};
use crate::fits::{parse_value_card_text, value_card_text};
use crate::fits_reader::{RANGE_HIGH_CARD, RANGE_LOW_CARD};
use crate::{FitsHeader, FitsValue, SampleRange};

/// Cards that describe how a FITS file stores its pixels; an XISF image says
/// that in its own attributes. The range cards are among them: `bounds` is
/// the range, and the cards are in an XISF image only when its writer had to
/// widen `bounds` past it (see [`sample_range`]).
const STRUCTURAL: [&str; 12] = [
    "SIMPLE", "BITPIX", "NAXIS", "NAXIS1", "NAXIS2", "NAXIS3", "EXTEND", "BZERO", "BSCALE", "END",
    RANGE_LOW_CARD, RANGE_HIGH_CARD,
];

/// What an image's samples span, as [`XisfUnit::read_pixels`](super::XisfUnit::read_pixels)
/// returns them: the range cards when the image has them, else `bounds`
/// (which a float image must state), else the integer format's whole range.
pub(crate) fn sample_range(image: &XisfImageHeader) -> SampleRange {
    if image.sample_format == super::SampleFormat::UInt64 {
        // Read as Float64 normalized over the representable range.
        return SampleRange::UNIT;
    }
    let card = |name: &str| {
        image
            .fits_keywords
            .iter()
            .find(|k| k.name.trim().eq_ignore_ascii_case(name))
            .and_then(|k| k.value.trim().parse::<f64>().ok())
    };
    let declared = match (card(RANGE_LOW_CARD), card(RANGE_HIGH_CARD)) {
        (Some(low), Some(high)) if image.sample_format.is_float() => SampleRange::new(low, high),
        _ => None,
    };
    declared
        .or_else(|| {
            let (low, high) = image.representable_range()?;
            SampleRange::new(low, high)
        })
        .unwrap_or(SampleRange::UNIT)
}

/// State what a new image's samples span. `bounds` is the range; when float
/// samples fall outside it, `bounds` is widened to hold them, because
/// PixInsight truncates what lies outside, and the range itself goes into the
/// range cards so the app reads its own file back unchanged.
pub(crate) fn declare_range(image: &mut XisfImageHeader, range: SampleRange, data: SampleRange) {
    image
        .fits_keywords
        .retain(|k| !matches!(k.name.trim(), RANGE_LOW_CARD | RANGE_HIGH_CARD));
    if !image.sample_format.is_float() {
        image.bounds = None;
        return;
    }
    image.bounds = Some((data.low, data.high));
    if data != range {
        for (name, value, comment) in [
            (RANGE_LOW_CARD, range.low, "sample value of black"),
            (RANGE_HIGH_CARD, range.high, "sample value of full scale"),
        ] {
            image.fits_keywords.push(FitsKeyword {
                name: name.to_string(),
                value: format!("{value}"),
                comment: comment.to_string(),
            });
        }
    }
}

fn is_structural(name: &str) -> bool {
    STRUCTURAL.contains(&name) || name == crate::fits_layout::LAYOUT_KEYWORD
}

#[derive(Clone, Copy)]
enum Kind {
    Text,
    Time,
    /// A real property of this precision; the property is the card times the
    /// factor (card millimeters to property meters is 0.001).
    Float32(f64),
    Float64,
    Int32,
}

/// One card and the standard property that says the same thing.
struct Mapping {
    card: &'static str,
    property: &'static str,
    kind: Kind,
}

const fn map(card: &'static str, property: &'static str, kind: Kind) -> Mapping {
    Mapping {
        card,
        property,
        kind,
    }
}

const MAPPINGS: &[Mapping] = &[
    map("EXPTIME", "Instrument:ExposureTime", Kind::Float32(1.0)),
    map("DATE-OBS", "Observation:Time:Start", Kind::Time),
    map("DATE-END", "Observation:Time:End", Kind::Time),
    map("OBJECT", "Observation:Object:Name", Kind::Text),
    map("RA", "Observation:Object:RA", Kind::Float64),
    map("DEC", "Observation:Object:Dec", Kind::Float64),
    map("EQUINOX", "Observation:Equinox", Kind::Float64),
    map("RADESYS", "Observation:CelestialReferenceSystem", Kind::Text),
    map("SITELAT", "Observation:Location:Latitude", Kind::Float64),
    map("SITELONG", "Observation:Location:Longitude", Kind::Float64),
    map("SITEELEV", "Observation:Location:Elevation", Kind::Float64),
    map("OBSERVER", "Observer:Name", Kind::Text),
    map("TELESCOP", "Instrument:Telescope:Name", Kind::Text),
    map("INSTRUME", "Instrument:Camera:Name", Kind::Text),
    map("FOCALLEN", "Instrument:Telescope:FocalLength", Kind::Float32(0.001)),
    map("APTDIA", "Instrument:Telescope:Aperture", Kind::Float32(0.001)),
    map("XPIXSZ", "Instrument:Sensor:XPixelSize", Kind::Float32(1.0)),
    map("YPIXSZ", "Instrument:Sensor:YPixelSize", Kind::Float32(1.0)),
    map("XBINNING", "Instrument:Camera:XBinning", Kind::Int32),
    map("YBINNING", "Instrument:Camera:YBinning", Kind::Int32),
    map("EGAIN", "Instrument:Camera:Gain", Kind::Float32(1.0)),
    map("ISOSPEED", "Instrument:Camera:ISOSpeed", Kind::Int32),
    map("CCD-TEMP", "Instrument:Sensor:Temperature", Kind::Float32(1.0)),
    map("SET-TEMP", "Instrument:Sensor:TargetTemperature", Kind::Float32(1.0)),
    map("FILTER", "Instrument:Filter:Name", Kind::Text),
    map("AMBTEMP", "Observation:Meteorology:AmbientTemperature", Kind::Float32(1.0)),
    map("HUMIDITY", "Observation:Meteorology:RelativeHumidity", Kind::Float32(1.0)),
    map("PRESSURE", "Observation:Meteorology:AtmosphericPressure", Kind::Float32(1.0)),
    map("WINDSPD", "Observation:Meteorology:WindSpeed", Kind::Float32(1.0)),
    map("WINDDIR", "Observation:Meteorology:WindDirection", Kind::Float32(1.0)),
];

const SOLUTION: &str = "AstrometricSolution:";
const LEGACY_SOLUTION: &str = "PCL:AstrometricSolution:";
/// XISF image coordinates put the center of the first stored pixel at
/// (0.5, 0.5), where FITS puts it at (1, 1).
const FITS_TO_XISF_PIXEL: f64 = -0.5;

/// WCS projection codes and the XISF projection vocabulary (Table 16).
const PROJECTIONS: [(&str, &str); 7] = [
    ("TAN", "Gnomonic"),
    ("STG", "Stereographic"),
    ("ZEA", "ZenithalEqualArea"),
    ("SIN", "Orthographic"),
    ("CAR", "PlateCarree"),
    ("MER", "Mercator"),
    ("AIT", "HammerAitoff"),
];

/// The app's metadata for an image read from a unit.
pub(crate) fn header_from_image(image: &XisfImageHeader) -> FitsHeader {
    let mut header = FitsHeader::new();
    let dimension = |n: u64| u32::try_from(n).unwrap_or(u32::MAX);
    header.set_image_size(
        dimension(image.width()),
        dimension(image.height()),
        dimension(image.channels),
    );
    for keyword in &image.fits_keywords {
        let name = keyword.name.trim().to_ascii_uppercase();
        match name.as_str() {
            "COMMENT" => header.add_comment(&keyword.comment),
            "HISTORY" => header.add_history(&keyword.comment),
            "" => {}
            _ if is_structural(&name) => {}
            _ => {
                set_card(&mut header, &name, parse_value_card_text(&keyword.value));
                if !keyword.comment.trim().is_empty() {
                    header.set_comment(&name, keyword.comment.trim());
                }
            }
        }
    }

    for m in MAPPINGS {
        if header.get(m.card).is_some() {
            continue;
        }
        if m.card == "EXPTIME" && header.get("EXPOSURE").is_some() {
            continue;
        }
        let Some(value) = image.property(m.property) else {
            continue;
        };
        match m.kind {
            Kind::Text => {
                if let Some(text) = value.as_str() {
                    header.set_string(m.card, text);
                }
            }
            Kind::Time => {
                if let Some(time) = value.as_str().and_then(fits_time) {
                    header.set_string(m.card, &time);
                }
            }
            Kind::Float32(factor) => {
                if let Some(v) = value.as_f64() {
                    header.set_float(m.card, decimal_f32(v) / factor);
                }
            }
            Kind::Float64 => {
                if let Some(v) = value.as_f64() {
                    header.set_float(m.card, v);
                }
            }
            Kind::Int32 => {
                if let Some(v) = value.as_f64() {
                    header.set_int(m.card, v as i64);
                }
            }
        }
    }

    if header.get("IMAGETYP").is_none() {
        if let Some(kind) = &image.image_type {
            header.set_string("IMAGETYP", &frame_type_card(kind));
        }
    }
    if header.get("BAYERPAT").is_none() {
        if let Some(cfa) = &image.color_filter_array {
            if cfa.width == 2 && cfa.height == 2 && crate::BayerPattern::from_str(&cfa.pattern).is_some()
            {
                header.set_string("BAYERPAT", &cfa.pattern);
            }
        }
    }
    if header.get("CTYPE1").is_none() {
        solution_to_cards(image, &mut header);
    }
    header
}

/// Build the header of a new XISF image from the app's metadata.
pub(crate) fn image_header_from_fits(
    header: &FitsHeader,
    pixels: &crate::ImageData,
) -> XisfImageHeader {
    let mut image = XisfImageHeader::new(
        vec![pixels.width as u64, pixels.height as u64],
        pixels.channels as u64,
        super::SampleFormat::of(pixels.pixel_type),
    );
    apply_header(&mut image, &FitsHeader::new(), header);
    image
}

/// Bring an image's keywords and standard properties in line with `new`,
/// the app's edited metadata for it; `old` is what `header_from_image` gave
/// for the image before the edit. Properties the edit has no say over stay.
pub(crate) fn apply_header(image: &mut XisfImageHeader, old: &FitsHeader, new: &FitsHeader) {
    let structural: Vec<FitsKeyword> = image
        .fits_keywords
        .iter()
        .filter(|k| is_structural(k.name.trim()))
        .cloned()
        .collect();
    image.fits_keywords = structural;
    for (name, value, comment) in new.cards() {
        if is_structural(name) {
            continue;
        }
        image.fits_keywords.push(FitsKeyword {
            name: name.to_string(),
            value: value_card_text(value),
            comment: comment.unwrap_or_default().to_string(),
        });
    }
    for text in &new.comments {
        image.fits_keywords.push(FitsKeyword {
            name: "COMMENT".into(),
            value: String::new(),
            comment: text.clone(),
        });
    }
    for text in &new.history {
        image.fits_keywords.push(FitsKeyword {
            name: "HISTORY".into(),
            value: String::new(),
            comment: text.clone(),
        });
    }

    for m in MAPPINGS {
        let source = new
            .get(m.card)
            .or_else(|| (m.card == "EXPTIME").then(|| new.get("EXPOSURE")).flatten());
        match source.and_then(|v| property_value(m.kind, v)) {
            Some(value) => set_property(&mut image.properties, m.property, value),
            None if old.get(m.card).is_some() => image.properties.retain(|p| p.id != m.property),
            None => {}
        }
    }
    if let Some(kind) = new.get_string("IMAGETYP").and_then(image_type_of) {
        image.image_type = Some(kind.to_string());
    } else if old.get("IMAGETYP").is_some() {
        image.image_type = None;
    }

    match crate::read_bayer_geometry(new) {
        Some(geometry) if image.channels == 1 => {
            let pattern = format!("{:?}", geometry.effective);
            image.color_filter_array = Some(ColorFilterArray {
                name: Some(format!("{pattern} Bayer Filter")),
                pattern,
                width: 2,
                height: 2,
            });
        }
        _ if old.get("BAYERPAT").is_some() => image.color_filter_array = None,
        _ => {}
    }

    let wcs_changed = old
        .cards()
        .chain(new.cards())
        .map(|(card, _, _)| card)
        .filter(|card| crate::fits::is_astrometry_keyword(card))
        .any(|card| old.get(card).map(value_card_text) != new.get(card).map(value_card_text));
    if wcs_changed {
        // A changed solution invalidates every layer of the old one,
        // including distortion layers this writer cannot regenerate.
        image
            .properties
            .retain(|p| !p.id.starts_with(SOLUTION) && !p.id.starts_with(LEGACY_SOLUTION));
        image
            .properties
            .retain(|p| !p.id.starts_with("Observation:Center:"));
        cards_to_solution(new, &mut image.properties);
    }
}

fn set_property(properties: &mut Vec<XisfProperty>, id: &str, value: PropertyValue) {
    match properties.iter_mut().find(|p| p.id == id) {
        Some(existing) => existing.value = value,
        None => properties.push(XisfProperty::new(id, value)),
    }
}

fn property_value(kind: Kind, value: &FitsValue) -> Option<PropertyValue> {
    Some(match kind {
        Kind::Text => PropertyValue::String(value.as_string()?.to_string()),
        Kind::Time => PropertyValue::TimePoint(xisf_time(value.as_string()?)?),
        Kind::Float32(factor) => PropertyValue::Float32((value.as_f64()? * factor) as f32),
        Kind::Float64 => PropertyValue::Float64(value.as_f64()?),
        Kind::Int32 => PropertyValue::Int32(i32::try_from(value.as_i64()?).ok()?),
    })
}

fn set_card(header: &mut FitsHeader, name: &str, value: FitsValue) {
    match value {
        FitsValue::String(s) | FitsValue::Comment(s) => header.set_string(name, &s),
        FitsValue::Integer(i) => header.set_int(name, i),
        FitsValue::Float(f) => header.set_float(name, f),
        FitsValue::Boolean(b) => header.set_bool(name, b),
    }
}

/// A Float32 value as the decimal it was written from, not its binary
/// expansion: 1.016, not 1.01600003242. Scaling the expansion instead turns a
/// 1016 mm focal length into 1016.00003.
fn decimal_f32(v: f64) -> f64 {
    format!("{}", v as f32).parse().unwrap_or(v)
}

fn chrono_utc(text: &str) -> Option<chrono::DateTime<chrono::Utc>> {
    let t = text.trim();
    if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(t) {
        return Some(dt.with_timezone(&chrono::Utc));
    }
    let naive = t.trim_end_matches('Z');
    ["%Y-%m-%dT%H:%M:%S%.f", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d"]
        .iter()
        .find_map(|f| {
            chrono::NaiveDateTime::parse_from_str(naive, f)
                .ok()
                .or_else(|| {
                    chrono::NaiveDate::parse_from_str(naive, f)
                        .ok()
                        .and_then(|d| d.and_hms_opt(0, 0, 0))
                })
        })
        .map(|n| n.and_utc())
}

/// A FITS date (UTC, no zone) as a TimePoint, which names its zone.
fn xisf_time(card: &str) -> Option<String> {
    let t = card.trim();
    chrono_utc(t)?;
    Some(if t.ends_with('Z') || t.contains('+') || t.matches('-').count() > 2 {
        t.to_string()
    } else {
        format!("{t}Z")
    })
}

/// A TimePoint as a FITS date: UTC, written without a zone.
fn fits_time(time: &str) -> Option<String> {
    let t = time.trim();
    if let Some(utc) = t.strip_suffix('Z') {
        return Some(utc.to_string());
    }
    let dt = chrono_utc(t)?;
    Some(dt.format("%Y-%m-%dT%H:%M:%S%.f").to_string())
}

/// The `imageType` literal for an `IMAGETYP` card, which writers spell many
/// ways ("Light", "LIGHT", "Light Frame", "Master Dark", "MASTER_LIGHT").
fn image_type_of(card: &str) -> Option<&'static str> {
    let t = card.to_ascii_lowercase();
    let master = t.contains("master");
    let base = if t.contains("bias") || t.contains("offset") {
        "Bias"
    } else if t.contains("dark") {
        "Dark"
    } else if t.contains("flat") {
        "Flat"
    } else if t.contains("light") || t.contains("science") || t.contains("object") {
        "Light"
    } else {
        return None;
    };
    Some(match (master, base) {
        (false, base) => base,
        (true, "Bias") => "MasterBias",
        (true, "Dark") => "MasterDark",
        (true, "Flat") => "MasterFlat",
        (true, _) => "MasterLight",
    })
}

fn frame_type_card(image_type: &str) -> String {
    match image_type.strip_prefix("Master") {
        Some(base) if !base.is_empty() => format!("Master {base}"),
        _ => image_type.to_string(),
    }
}

/// The header's WCS, as the first layer of an XISF astrometric solution.
///
/// The geometry is written under the standard ids and again under
/// PixInsight's earlier `PCL:` ids: PixInsight 1.9.4 reads only the latter,
/// and without them falls back to the FITS keywords, which it reads right
/// only in CD form. A newer reader takes the standard block first.
///
/// SIP distortion has no place in that layer (the standard's distortion
/// layer is a spline model), so a distorted solution is written as its
/// linear part, which is what PixInsight then uses; the SIP cards stay
/// among the keywords for readers that take them from there.
fn cards_to_solution(header: &FitsHeader, properties: &mut Vec<XisfProperty>) {
    let Some(projection) = header
        .get_string("CTYPE1")
        .and_then(|ctype1| ctype1.get(5..8))
        .and_then(|code| PROJECTIONS.iter().find(|(c, _)| *c == code))
        .map(|(_, name)| *name)
    else {
        return;
    };
    let Some(wcs) = crate::SipWcs::from_header(header) else {
        return;
    };
    let reference = [
        wcs.crpix1 + FITS_TO_XISF_PIXEL,
        wcs.crpix2 + FITS_TO_XISF_PIXEL,
    ];
    let mut geometry = vec![
        ("ProjectionSystem", PropertyValue::String(projection.into())),
        (
            "ReferenceCelestialCoordinates",
            PropertyValue::f64_vector(&[wcs.crval1, wcs.crval2]),
        ),
        ("ReferenceImageCoordinates", PropertyValue::f64_vector(&reference)),
        (
            "LinearTransformationMatrix",
            PropertyValue::f64_matrix(2, 2, &[wcs.cd1_1, wcs.cd1_2, wcs.cd2_1, wcs.cd2_2]),
        ),
    ];
    if let (Some(lon), Some(lat)) = (header.get_float("LONPOLE"), header.get_float("LATPOLE")) {
        geometry.push((
            "CelestialPoleNativeCoordinates",
            PropertyValue::f64_vector(&[lon, lat]),
        ));
    }
    let system = header
        .get_string("RADESYS")
        .map(str::trim)
        .filter(|s| *s == "ICRS" || *s == "GCRS");

    let standard = std::iter::once(("Version", PropertyValue::String("1.0".into())))
        .chain(geometry.iter().cloned())
        .chain(system.map(|s| ("CelestialReferenceSystem", PropertyValue::String(s.into()))));
    for (id, value) in standard {
        properties.push(XisfProperty::new(format!("{SOLUTION}{id}"), value));
    }
    for (id, value) in geometry {
        properties.push(XisfProperty::new(format!("{LEGACY_SOLUTION}{id}"), value));
    }
    properties.push(XisfProperty::new(
        "Observation:Center:RA",
        PropertyValue::Float64(wcs.crval1),
    ));
    properties.push(XisfProperty::new(
        "Observation:Center:Dec",
        PropertyValue::Float64(wcs.crval2),
    ));
    properties.push(XisfProperty::new(
        "Observation:Center:X",
        PropertyValue::Float64(reference[0]),
    ));
    properties.push(XisfProperty::new(
        "Observation:Center:Y",
        PropertyValue::Float64(reference[1]),
    ));
}

/// The cards of a linear WCS from the first layer of the image's solution,
/// standard properties first, PixInsight's earlier `PCL:` ones otherwise.
fn solution_to_cards(image: &XisfImageHeader, header: &mut FitsHeader) {
    let standard = image
        .property(&format!("{SOLUTION}Version"))
        .and_then(PropertyValue::as_str)
        .is_some_and(|v| v.trim().split('.').next() == Some("1"));
    let prefix = if standard { SOLUTION } else { LEGACY_SOLUTION };
    let get = |id: &str| image.property(&format!("{prefix}{id}"));
    let Some(code) = get("ProjectionSystem")
        .and_then(PropertyValue::as_str)
        .and_then(|name| PROJECTIONS.iter().find(|(_, n)| *n == name.trim()))
        .map(|(code, _)| *code)
    else {
        return;
    };
    let vector = |id: &str, n: usize| {
        get(id)
            .and_then(PropertyValue::as_f64_values)
            .filter(|v| v.len() == n)
    };
    let (Some(sky), Some(reference), Some(matrix)) = (
        vector("ReferenceCelestialCoordinates", 2),
        vector("ReferenceImageCoordinates", 2),
        vector("LinearTransformationMatrix", 4),
    ) else {
        return;
    };
    // A reference system or equinox the observation properties already gave
    // the header stands; the solution's own system fills a header without one.
    let radesys = header
        .get_string("RADESYS")
        .or_else(|| get("CelestialReferenceSystem").and_then(PropertyValue::as_str))
        .map(|system| system.trim().to_string());
    let equinox = header.get_float("EQUINOX");
    crate::SipWcs::tan_only(
        sky[0],
        sky[1],
        reference[0] - FITS_TO_XISF_PIXEL,
        reference[1] - FITS_TO_XISF_PIXEL,
        matrix[0],
        matrix[1],
        matrix[2],
        matrix[3],
    )
    .write_to_header(header);
    header.set_string("CTYPE1", &format!("RA---{code}"));
    header.set_string("CTYPE2", &format!("DEC--{code}"));
    if let Some(pole) = vector("CelestialPoleNativeCoordinates", 2) {
        header.set_float("LONPOLE", pole[0]);
        header.set_float("LATPOLE", pole[1]);
    }
    if let Some(system) = radesys {
        header.set_string("RADESYS", &system);
    }
    if let Some(equinox) = equinox {
        header.set_float("EQUINOX", equinox);
    }
}
