//! XISF properties (section 8.4): scalar, complex, string, time point, vector
//! and matrix values, their plain text forms (section 8.3) and their binary
//! forms in data blocks.

use super::XisfError;

/// One property: an identifier, a typed value, and the optional format
/// specifier and comment the element carried.
#[derive(Debug, Clone, PartialEq)]
pub struct XisfProperty {
    pub id: String,
    pub value: PropertyValue,
    pub format: Option<String>,
    pub comment: Option<String>,
}

impl XisfProperty {
    pub fn new(id: impl Into<String>, value: PropertyValue) -> Self {
        Self {
            id: id.into(),
            value,
            format: None,
            comment: None,
        }
    }
}

/// The component type of a vector or matrix (Tables 7 and 8).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Element {
    I8,
    U8,
    I16,
    U16,
    I32,
    U32,
    I64,
    U64,
    I128,
    U128,
    F32,
    F64,
    F128,
    C32,
    C64,
    C128,
}

impl Element {
    const ALL: [Element; 16] = [
        Element::I8,
        Element::U8,
        Element::I16,
        Element::U16,
        Element::I32,
        Element::U32,
        Element::I64,
        Element::U64,
        Element::I128,
        Element::U128,
        Element::F32,
        Element::F64,
        Element::F128,
        Element::C32,
        Element::C64,
        Element::C128,
    ];

    pub fn size(self) -> usize {
        match self {
            Element::I8 | Element::U8 => 1,
            Element::I16 | Element::U16 => 2,
            Element::I32 | Element::U32 | Element::F32 => 4,
            Element::I64 | Element::U64 | Element::F64 | Element::C32 => 8,
            Element::I128 | Element::U128 | Element::F128 | Element::C64 => 16,
            Element::C128 => 32,
        }
    }

    /// The prefix of the vector and matrix type names: `F64` in `F64Vector`.
    fn prefix(self) -> &'static str {
        match self {
            Element::I8 => "I8",
            Element::U8 => "UI8",
            Element::I16 => "I16",
            Element::U16 => "UI16",
            Element::I32 => "I32",
            Element::U32 => "UI32",
            Element::I64 => "I64",
            Element::U64 => "UI64",
            Element::I128 => "I128",
            Element::U128 => "UI128",
            Element::F32 => "F32",
            Element::F64 => "F64",
            Element::F128 => "F128",
            Element::C32 => "C32",
            Element::C64 => "C64",
            Element::C128 => "C128",
        }
    }

    pub fn vector_type(self) -> String {
        format!("{}Vector", self.prefix())
    }

    pub fn matrix_type(self) -> String {
        format!("{}Matrix", self.prefix())
    }

    /// The vector element type a type name names, with the alternate names.
    fn of_vector(type_name: &str) -> Option<Self> {
        match type_name {
            "ByteArray" => Some(Element::U8),
            "IVector" => Some(Element::I32),
            "UIVector" => Some(Element::U32),
            "Vector" => Some(Element::F64),
            _ => type_name
                .strip_suffix("Vector")
                .and_then(|p| Self::ALL.into_iter().find(|e| e.prefix() == p)),
        }
    }

    fn of_matrix(type_name: &str) -> Option<Self> {
        match type_name {
            "ByteMatrix" => Some(Element::U8),
            "IMatrix" => Some(Element::I32),
            "UIMatrix" => Some(Element::U32),
            "Matrix" => Some(Element::F64),
            _ => type_name
                .strip_suffix("Matrix")
                .and_then(|p| Self::ALL.into_iter().find(|e| e.prefix() == p)),
        }
    }

    /// The width in bytes of one scalar, which a byte swap reverses: complex
    /// numbers swap each part.
    pub(crate) fn scalar_size(self) -> usize {
        match self {
            Element::C32 => 4,
            Element::C64 => 8,
            Element::C128 => 16,
            other => other.size(),
        }
    }

    fn component_f64(self, bytes: &[u8]) -> Option<f64> {
        Some(match self {
            Element::I8 => bytes[0] as i8 as f64,
            Element::U8 => bytes[0] as f64,
            Element::I16 => i16::from_le_bytes(bytes.try_into().ok()?) as f64,
            Element::U16 => u16::from_le_bytes(bytes.try_into().ok()?) as f64,
            Element::I32 => i32::from_le_bytes(bytes.try_into().ok()?) as f64,
            Element::U32 => u32::from_le_bytes(bytes.try_into().ok()?) as f64,
            Element::I64 => i64::from_le_bytes(bytes.try_into().ok()?) as f64,
            Element::U64 => u64::from_le_bytes(bytes.try_into().ok()?) as f64,
            Element::I128 => i128::from_le_bytes(bytes.try_into().ok()?) as f64,
            Element::U128 => u128::from_le_bytes(bytes.try_into().ok()?) as f64,
            Element::F32 => f32::from_le_bytes(bytes.try_into().ok()?) as f64,
            Element::F64 => f64::from_le_bytes(bytes.try_into().ok()?),
            Element::F128 | Element::C32 | Element::C64 | Element::C128 => return None,
        })
    }
}

/// A property value. Vectors and matrices keep their components as
/// little-endian bytes, so every element type, including the optional 128-bit
/// ones, survives a rewrite unchanged.
#[derive(Debug, Clone, PartialEq)]
pub enum PropertyValue {
    Boolean(bool),
    Int8(i8),
    UInt8(u8),
    Int16(i16),
    UInt16(u16),
    Int32(i32),
    UInt32(u32),
    Int64(i64),
    UInt64(u64),
    Float32(f32),
    Float64(f64),
    Complex32(f32, f32),
    Complex64(f64, f64),
    /// A 128-bit scalar or complex value, kept as its type name and text.
    Wide {
        type_name: String,
        text: String,
    },
    String(String),
    /// An ISO 8601 time point, as written.
    TimePoint(String),
    Vector {
        element: Element,
        data: Vec<u8>,
    },
    Matrix {
        element: Element,
        rows: u64,
        columns: u64,
        data: Vec<u8>,
    },
}

/// How a property type is serialized.
pub(crate) enum PropertyKind {
    /// In the `value` attribute.
    Scalar,
    /// In character data or a data block.
    String,
    Vector(Element),
    Matrix(Element),
}

pub(crate) fn kind_of(type_name: &str) -> Option<PropertyKind> {
    match type_name {
        "String" => Some(PropertyKind::String),
        "Boolean" | "Int8" | "UInt8" | "Byte" | "Int16" | "Short" | "UInt16" | "UShort"
        | "Int32" | "Int" | "UInt32" | "UInt" | "Int64" | "UInt64" | "Float32" | "Float"
        | "Float64" | "Double" | "Complex32" | "Complex64" | "Complex" | "TimePoint" | "Int128"
        | "UInt128" | "Float128" | "Quad" | "Complex128" => Some(PropertyKind::Scalar),
        _ => Element::of_vector(type_name)
            .map(PropertyKind::Vector)
            .or_else(|| Element::of_matrix(type_name).map(PropertyKind::Matrix)),
    }
}

impl PropertyValue {
    /// The canonical type name this value is written with.
    pub fn type_name(&self) -> String {
        match self {
            PropertyValue::Boolean(_) => "Boolean".into(),
            PropertyValue::Int8(_) => "Int8".into(),
            PropertyValue::UInt8(_) => "UInt8".into(),
            PropertyValue::Int16(_) => "Int16".into(),
            PropertyValue::UInt16(_) => "UInt16".into(),
            PropertyValue::Int32(_) => "Int32".into(),
            PropertyValue::UInt32(_) => "UInt32".into(),
            PropertyValue::Int64(_) => "Int64".into(),
            PropertyValue::UInt64(_) => "UInt64".into(),
            PropertyValue::Float32(_) => "Float32".into(),
            PropertyValue::Float64(_) => "Float64".into(),
            PropertyValue::Complex32(..) => "Complex32".into(),
            PropertyValue::Complex64(..) => "Complex64".into(),
            PropertyValue::Wide { type_name, .. } => type_name.clone(),
            PropertyValue::String(_) => "String".into(),
            PropertyValue::TimePoint(_) => "TimePoint".into(),
            PropertyValue::Vector { element, .. } => element.vector_type(),
            PropertyValue::Matrix { element, .. } => element.matrix_type(),
        }
    }

    /// Parse the `value` attribute of a scalar, complex or time point
    /// property (section 8.3).
    pub(crate) fn parse_scalar(type_name: &str, text: &str) -> Result<Self, XisfError> {
        let t = text.trim();
        let bad =
            || XisfError::Malformed(format!("the value \"{text}\" is not a valid {type_name}"));
        Ok(match type_name {
            "Boolean" => match t {
                "true" | "1" => PropertyValue::Boolean(true),
                "false" | "0" => PropertyValue::Boolean(false),
                _ if t.eq_ignore_ascii_case("true") => PropertyValue::Boolean(true),
                _ if t.eq_ignore_ascii_case("false") => PropertyValue::Boolean(false),
                _ => return Err(bad()),
            },
            "Int8" => PropertyValue::Int8(parse_int(t, 8).ok_or_else(bad)? as i8),
            "UInt8" | "Byte" => PropertyValue::UInt8(parse_uint(t, 8).ok_or_else(bad)? as u8),
            "Int16" | "Short" => PropertyValue::Int16(parse_int(t, 16).ok_or_else(bad)? as i16),
            "UInt16" | "UShort" => PropertyValue::UInt16(parse_uint(t, 16).ok_or_else(bad)? as u16),
            "Int32" | "Int" => PropertyValue::Int32(parse_int(t, 32).ok_or_else(bad)? as i32),
            "UInt32" | "UInt" => PropertyValue::UInt32(parse_uint(t, 32).ok_or_else(bad)? as u32),
            "Int64" => PropertyValue::Int64(parse_int(t, 64).ok_or_else(bad)?),
            "UInt64" => PropertyValue::UInt64(parse_uint(t, 64).ok_or_else(bad)?),
            "Float32" | "Float" => PropertyValue::Float32(parse_float(t).ok_or_else(bad)? as f32),
            "Float64" | "Double" => PropertyValue::Float64(parse_float(t).ok_or_else(bad)?),
            "Complex32" => {
                let (re, im) = parse_complex(t).ok_or_else(bad)?;
                PropertyValue::Complex32(re as f32, im as f32)
            }
            "Complex64" | "Complex" => {
                let (re, im) = parse_complex(t).ok_or_else(bad)?;
                PropertyValue::Complex64(re, im)
            }
            "TimePoint" => PropertyValue::TimePoint(t.to_string()),
            "Int128" | "UInt128" | "Float128" | "Quad" | "Complex128" => PropertyValue::Wide {
                type_name: type_name.to_string(),
                text: t.to_string(),
            },
            _ => return Err(bad()),
        })
    }

    /// The `value` attribute text of a scalar value; `None` for strings,
    /// vectors and matrices.
    pub(crate) fn scalar_text(&self) -> Option<String> {
        Some(match self {
            PropertyValue::Boolean(b) => if *b { "true" } else { "false" }.to_string(),
            PropertyValue::Int8(v) => v.to_string(),
            PropertyValue::UInt8(v) => v.to_string(),
            PropertyValue::Int16(v) => v.to_string(),
            PropertyValue::UInt16(v) => v.to_string(),
            PropertyValue::Int32(v) => v.to_string(),
            PropertyValue::UInt32(v) => v.to_string(),
            PropertyValue::Int64(v) => v.to_string(),
            PropertyValue::UInt64(v) => v.to_string(),
            PropertyValue::Float32(v) => float_text(*v as f64, true),
            PropertyValue::Float64(v) => float_text(*v, false),
            PropertyValue::Complex32(re, im) => format!(
                "({},{})",
                float_text(*re as f64, true),
                float_text(*im as f64, true)
            ),
            PropertyValue::Complex64(re, im) => {
                format!("({},{})", float_text(*re, false), float_text(*im, false))
            }
            PropertyValue::Wide { text, .. } => text.clone(),
            PropertyValue::TimePoint(t) => t.clone(),
            PropertyValue::String(_)
            | PropertyValue::Vector { .. }
            | PropertyValue::Matrix { .. } => return None,
        })
    }

    /// Build a vector or matrix from the decoded little-endian bytes of its
    /// data block, checking the declared length.
    pub(crate) fn from_block(
        kind: &PropertyKind,
        shape: (u64, u64),
        data: Vec<u8>,
    ) -> Result<Self, XisfError> {
        let (rows, columns) = shape;
        match *kind {
            PropertyKind::Vector(element) => {
                check_len(rows, 1, element, data.len())?;
                Ok(PropertyValue::Vector { element, data })
            }
            PropertyKind::Matrix(element) => {
                check_len(rows, columns, element, data.len())?;
                Ok(PropertyValue::Matrix {
                    element,
                    rows,
                    columns,
                    data,
                })
            }
            PropertyKind::String => String::from_utf8(data)
                .map(PropertyValue::String)
                .map_err(|_| XisfError::Corrupt("a string property is not UTF-8".to_string())),
            PropertyKind::Scalar => Err(XisfError::Malformed(
                "a scalar property stored as a data block".to_string(),
            )),
        }
    }

    /// The byte length of a vector or matrix block of this shape, when it does
    /// not overflow.
    pub(crate) fn block_len(kind: &PropertyKind, shape: (u64, u64)) -> Option<u64> {
        match *kind {
            PropertyKind::Vector(e) => shape.0.checked_mul(e.size() as u64),
            PropertyKind::Matrix(e) => shape.0.checked_mul(shape.1)?.checked_mul(e.size() as u64),
            _ => None,
        }
    }

    pub fn as_f64(&self) -> Option<f64> {
        Some(match self {
            PropertyValue::Int8(v) => *v as f64,
            PropertyValue::UInt8(v) => *v as f64,
            PropertyValue::Int16(v) => *v as f64,
            PropertyValue::UInt16(v) => *v as f64,
            PropertyValue::Int32(v) => *v as f64,
            PropertyValue::UInt32(v) => *v as f64,
            PropertyValue::Int64(v) => *v as f64,
            PropertyValue::UInt64(v) => *v as f64,
            PropertyValue::Float32(v) => *v as f64,
            PropertyValue::Float64(v) => *v,
            _ => return None,
        })
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            PropertyValue::String(s) | PropertyValue::TimePoint(s) => Some(s),
            _ => None,
        }
    }

    /// The components of a real vector, or the elements of a real matrix in
    /// row order.
    pub fn as_f64_values(&self) -> Option<Vec<f64>> {
        let (element, data) = match self {
            PropertyValue::Vector { element, data } => (*element, data),
            PropertyValue::Matrix { element, data, .. } => (*element, data),
            _ => return None,
        };
        data.chunks_exact(element.size())
            .map(|c| element.component_f64(c))
            .collect()
    }

    pub fn f64_vector(values: &[f64]) -> Self {
        PropertyValue::Vector {
            element: Element::F64,
            data: values.iter().flat_map(|v| v.to_le_bytes()).collect(),
        }
    }

    pub fn f64_matrix(rows: u64, columns: u64, values: &[f64]) -> Self {
        PropertyValue::Matrix {
            element: Element::F64,
            rows,
            columns,
            data: values.iter().flat_map(|v| v.to_le_bytes()).collect(),
        }
    }

    /// The text a header viewer shows for this value.
    pub fn display_text(&self) -> String {
        match self {
            PropertyValue::String(s) | PropertyValue::TimePoint(s) => s.clone(),
            PropertyValue::Vector { element, data } => {
                summarize_components(*element, data, data.len() / element.size().max(1))
            }
            PropertyValue::Matrix {
                element,
                rows,
                columns,
                data,
            } => format!(
                "{rows}×{columns}: {}",
                summarize_components(*element, data, data.len() / element.size().max(1))
            ),
            other => other.scalar_text().unwrap_or_default(),
        }
    }
}

fn summarize_components(element: Element, data: &[u8], count: usize) -> String {
    const SHOWN: usize = 8;
    let shown: Vec<String> = data
        .chunks_exact(element.size())
        .take(SHOWN)
        .map(|c| match element.component_f64(c) {
            Some(v) => float_text(v, false),
            None => format!("0x{}", super::codec::encode_hex(c)),
        })
        .collect();
    let mut text = shown.join(", ");
    if count > SHOWN {
        text.push_str(&format!(", … ({count} values)"));
    }
    text
}

fn check_len(rows: u64, columns: u64, element: Element, actual: usize) -> Result<(), XisfError> {
    let expected = rows
        .checked_mul(columns)
        .and_then(|n| n.checked_mul(element.size() as u64));
    if expected != Some(actual as u64) {
        return Err(XisfError::Corrupt(format!(
            "a property block holds {actual} bytes, not the {rows}×{columns} {} its header declares",
            element.prefix()
        )));
    }
    Ok(())
}

/// Decimal, binary, octal or hexadecimal integer text (sections 8.3.1,
/// 8.3.2) for a signed integer of `bits` bits. Binary, octal and hexadecimal
/// text is the two's complement bit pattern.
fn parse_int(t: &str, bits: u32) -> Option<i64> {
    if let Some(pattern) = parse_radix(t) {
        if bits < 64 && pattern >= (1u64 << bits) {
            return None;
        }
        let shift = 64 - bits;
        return Some(((pattern << shift) as i64) >> shift);
    }
    let v = t.strip_prefix('+').unwrap_or(t).parse::<i64>().ok()?;
    let limit = 1i64.checked_shl(bits - 1).unwrap_or(i64::MAX);
    (bits == 64 || (-limit..limit).contains(&v)).then_some(v)
}

fn parse_uint(t: &str, bits: u32) -> Option<u64> {
    let v = match parse_radix(t) {
        Some(v) => v,
        None => t.strip_prefix('+').unwrap_or(t).parse::<u64>().ok()?,
    };
    (bits == 64 || v < (1u64 << bits)).then_some(v)
}

fn parse_radix(t: &str) -> Option<u64> {
    let (digits, radix) = [
        ("0x", 16),
        ("0X", 16),
        ("0b", 2),
        ("0B", 2),
        ("0o", 8),
        ("0O", 8),
    ]
    .into_iter()
    .find_map(|(prefix, radix)| t.strip_prefix(prefix).map(|d| (d, radix)))?;
    u64::from_str_radix(digits, radix).ok()
}

/// Floating point text, including the non-numeric forms of section 8.3.3.
fn parse_float(t: &str) -> Option<f64> {
    match t {
        "NaN" | "nan" | "-nan" => Some(f64::NAN),
        "+Inf" | "inf" => Some(f64::INFINITY),
        "-Inf" | "-inf" => Some(f64::NEG_INFINITY),
        _ => t.parse::<f64>().ok().filter(|v| v.is_finite()),
    }
}

fn parse_complex(t: &str) -> Option<(f64, f64)> {
    let inner = t.strip_prefix('(')?.strip_suffix(')')?;
    let (re, im) = inner.split_once(',')?;
    Some((parse_float(re.trim())?, parse_float(im.trim())?))
}

/// The shortest text that reads back as the same value, in the forms
/// section 8.3.3 allows.
fn float_text(v: f64, single: bool) -> String {
    if v.is_nan() {
        "NaN".to_string()
    } else if v.is_infinite() {
        if v > 0.0 { "+Inf" } else { "-Inf" }.to_string()
    } else if single {
        format!("{}", v as f32)
    } else {
        format!("{v}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scalar_text_forms_of_section_8_3() {
        let p = |t: &str, v: &str| PropertyValue::parse_scalar(t, v).unwrap();
        assert_eq!(
            p("UInt32", "0x8000FFA0"),
            PropertyValue::UInt32(0x8000_FFA0)
        );
        assert_eq!(
            p("Int32", "0x80E950AB"),
            PropertyValue::Int32(-2_132_193_109)
        );
        assert_eq!(p("UInt16", "0b101"), PropertyValue::UInt16(5));
        assert_eq!(p("Int64", " +45678 "), PropertyValue::Int64(45678));
        assert_eq!(p("UInt8", "0o17"), PropertyValue::UInt8(15));
        assert_eq!(p("Float64", "-0.123e+02"), PropertyValue::Float64(-12.3));
        assert_eq!(p("Double", ".123"), PropertyValue::Float64(0.123));
        assert_eq!(p("Boolean", "1"), PropertyValue::Boolean(true));
        assert_eq!(p("Boolean", "false"), PropertyValue::Boolean(false));
        assert_eq!(
            p("Complex32", "(0.123,-0.735e-02)"),
            PropertyValue::Complex32(0.123, -0.00735)
        );
        assert!(matches!(p("Float32", "NaN"), PropertyValue::Float32(v) if v.is_nan()));
        assert_eq!(
            p("Float64", "-Inf"),
            PropertyValue::Float64(f64::NEG_INFINITY)
        );
        assert!(PropertyValue::parse_scalar("UInt8", "256").is_err());
        assert!(PropertyValue::parse_scalar("Int8", "-129").is_err());
        assert!(PropertyValue::parse_scalar("Boolean", "maybe").is_err());
        assert!(PropertyValue::parse_scalar("Float64", "1.2.3").is_err());
    }

    #[test]
    fn scalar_text_round_trips() {
        for value in [
            PropertyValue::Float64(0.1 + 0.2),
            PropertyValue::Float32(1.0e-7),
            PropertyValue::Int8(-128),
            PropertyValue::UInt64(u64::MAX),
            PropertyValue::Complex64(1.5, -2.25),
            PropertyValue::Float64(f64::INFINITY),
        ] {
            let text = value.scalar_text().unwrap();
            assert_eq!(
                PropertyValue::parse_scalar(&value.type_name(), &text).unwrap(),
                value
            );
        }
    }

    #[test]
    fn type_names_and_alternates() {
        assert!(matches!(
            kind_of("ByteArray"),
            Some(PropertyKind::Vector(Element::U8))
        ));
        assert!(matches!(
            kind_of("Vector"),
            Some(PropertyKind::Vector(Element::F64))
        ));
        assert!(matches!(
            kind_of("UI16Vector"),
            Some(PropertyKind::Vector(Element::U16))
        ));
        assert!(matches!(
            kind_of("Matrix"),
            Some(PropertyKind::Matrix(Element::F64))
        ));
        assert!(matches!(
            kind_of("C128Matrix"),
            Some(PropertyKind::Matrix(Element::C128))
        ));
        assert!(matches!(kind_of("Short"), Some(PropertyKind::Scalar)));
        assert!(kind_of("Table").is_none());
        for element in Element::ALL {
            assert_eq!(Element::of_vector(&element.vector_type()), Some(element));
            assert_eq!(Element::of_matrix(&element.matrix_type()), Some(element));
        }
    }

    #[test]
    fn vectors_check_their_declared_length() {
        let kind = PropertyKind::Vector(Element::F64);
        assert!(PropertyValue::from_block(&kind, (2, 1), vec![0; 16]).is_ok());
        assert!(PropertyValue::from_block(&kind, (3, 1), vec![0; 16]).is_err());
        let m = PropertyValue::f64_matrix(2, 2, &[1.0, 2.0, 3.0, 4.0]);
        assert_eq!(m.as_f64_values().unwrap(), vec![1.0, 2.0, 3.0, 4.0]);
    }
}
