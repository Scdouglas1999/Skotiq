//! Template tokenizer.
//!
//! Splits a raw template string like `"sub_${frame:04}.fits"` into a sequence
//! of [`TemplatePart::Literal`] and [`TemplatePart::Variable`] parts. The
//! resolver walks the resulting parts and produces the final rendered string.
//!
//! Escape rules:
//! * `$${` is the literal `${` (a doubled `$` escapes the interpolation
//!   start).
//! * A single `$` not followed by `{` is a literal `$`.
//! * Inside `${ ... }`, an optional `:spec` introduces a format specifier.
//!   The spec text up to the next unescaped `}` is captured verbatim — the
//!   resolver is responsible for parsing the spec, not the tokenizer.
//! * Nested `{` / `}` inside a placeholder are NOT supported (this keeps the
//!   tokenizer simple and matches the simple-string-interpolation contract).

use super::errors::InterpolationError;

/// One piece of a parsed template.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TemplatePart {
    /// Literal text — output verbatim.
    Literal(String),
    /// A variable reference. `name` is the dotted path (e.g. `target.name`);
    /// `format_spec` is `None` when the placeholder had no `:spec`.
    Variable {
        name: String,
        format_spec: Option<String>,
        /// Byte offset of the opening `$` in the source template. Surfaced
        /// in error messages so the user can locate the problem.
        offset: usize,
    },
}

/// Tokenize a template string. The returned parts collapse adjacent literals.
pub fn parse_template(template: &str) -> Result<Vec<TemplatePart>, InterpolationError> {
    let mut parts: Vec<TemplatePart> = Vec::new();
    let mut buf = String::new();
    let bytes = template.as_bytes();
    let mut i = 0usize;

    while i < bytes.len() {
        let c = bytes[i];
        // Escape: `$${` → literal `${`. We consume two `$` characters and one
        // `{`, emit the two-char literal `${`, then continue scanning.
        if c == b'$' && i + 2 < bytes.len() && bytes[i + 1] == b'$' && bytes[i + 2] == b'{' {
            buf.push('$');
            buf.push('{');
            i += 3;
            continue;
        }
        // Interpolation start: `${`. Scan for the matching `}`.
        if c == b'$' && i + 1 < bytes.len() && bytes[i + 1] == b'{' {
            // Flush any accumulated literal before emitting the variable.
            if !buf.is_empty() {
                parts.push(TemplatePart::Literal(std::mem::take(&mut buf)));
            }
            let start = i;
            // Skip past `${`.
            let body_start = i + 2;
            // Find the closing `}` — scan forward, no nesting support.
            let mut j = body_start;
            while j < bytes.len() && bytes[j] != b'}' {
                // Reject newlines inside a placeholder so a missing `}` on
                // line N doesn't silently swallow line N+1.
                if bytes[j] == b'\n' || bytes[j] == b'\r' {
                    return Err(InterpolationError::Malformed {
                        offset: start,
                        reason: "newline inside `${...}` placeholder".to_string(),
                    });
                }
                j += 1;
            }
            if j >= bytes.len() {
                return Err(InterpolationError::Malformed {
                    offset: start,
                    reason: "unterminated `${...}` placeholder".to_string(),
                });
            }
            // Body is the slice between `${` and `}`.
            // Why: the template is UTF-8 and we only scanned past ASCII bytes
            // (`$`, `{`, `:`, `}`, `\n`, `\r`). The body slice is therefore
            // guaranteed to start and end on UTF-8 boundaries.
            let body = &template[body_start..j];
            if body.is_empty() {
                return Err(InterpolationError::Malformed {
                    offset: start,
                    reason: "empty `${}` placeholder".to_string(),
                });
            }
            // Split into `name` and optional `format_spec` on the first `:`.
            let (name, format_spec) = match body.split_once(':') {
                Some((n, s)) => (n.trim().to_string(), Some(s.trim().to_string())),
                None => (body.trim().to_string(), None),
            };
            if name.is_empty() {
                return Err(InterpolationError::Malformed {
                    offset: start,
                    reason: "missing variable name before `:`".to_string(),
                });
            }
            // Reject names with whitespace — early signal that the user
            // mistyped the template, instead of silently treating
            // `${target name}` as a variable lookup of "target name".
            if name.chars().any(char::is_whitespace) {
                return Err(InterpolationError::Malformed {
                    offset: start,
                    reason: format!("variable name `{name}` contains whitespace"),
                });
            }
            parts.push(TemplatePart::Variable {
                name,
                format_spec,
                offset: start,
            });
            i = j + 1;
            continue;
        }
        // Default: copy the byte (or full UTF-8 codepoint) into the buffer.
        // Casting a non-ASCII byte to char would corrupt the encoding
        // (multi-byte codepoints would become individual U+00xx Latin-1
        // chars). Instead, dispatch on the leading byte to find the
        // codepoint length and copy via string slicing.
        if c < 0x80 {
            buf.push(c as char);
            i += 1;
        } else {
            // UTF-8 leading-byte length lookup:
            // 0xC0..=0xDF → 2 bytes, 0xE0..=0xEF → 3, 0xF0..=0xF7 → 4.
            let len = if c < 0xE0 {
                2
            } else if c < 0xF0 {
                3
            } else {
                4
            };
            let end = (i + len).min(bytes.len());
            // `template` is `&str` so it's guaranteed valid UTF-8; `end` is
            // always on a codepoint boundary because the leading-byte table
            // above gives the correct length for every legal codepoint.
            buf.push_str(&template[i..end]);
            i = end;
        }
    }

    if !buf.is_empty() {
        parts.push(TemplatePart::Literal(buf));
    }
    Ok(parts)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_plain_literal() {
        let parts = parse_template("hello world").expect("plain literal must parse");
        assert_eq!(
            parts,
            vec![TemplatePart::Literal("hello world".to_string())]
        );
    }

    #[test]
    fn parses_simple_variable() {
        let parts = parse_template("${target.name}").expect("simple variable must parse");
        assert_eq!(
            parts,
            vec![TemplatePart::Variable {
                name: "target.name".to_string(),
                format_spec: None,
                offset: 0,
            }]
        );
    }

    #[test]
    fn parses_variable_with_format_spec() {
        let parts = parse_template("${frame:04}").expect("formatted variable must parse");
        assert_eq!(
            parts,
            vec![TemplatePart::Variable {
                name: "frame".to_string(),
                format_spec: Some("04".to_string()),
                offset: 0,
            }]
        );
    }

    #[test]
    fn parses_mixed_template() {
        // "sub_${frame:04}_${exposure.duration:.0f}s.fits"
        //  0123456789012345678901234567890123456
        //  0    5   ^11  ^15^17
        // `${frame:04}` starts at byte 4, closes at byte 14 (`}`),
        // then `_` is at byte 15, and the next `${` starts at byte 16.
        let parts =
            parse_template("sub_${frame:04}_${exposure.duration:.0f}s.fits").expect("mixed");
        assert_eq!(
            parts,
            vec![
                TemplatePart::Literal("sub_".to_string()),
                TemplatePart::Variable {
                    name: "frame".to_string(),
                    format_spec: Some("04".to_string()),
                    offset: 4,
                },
                TemplatePart::Literal("_".to_string()),
                TemplatePart::Variable {
                    name: "exposure.duration".to_string(),
                    format_spec: Some(".0f".to_string()),
                    offset: 16,
                },
                TemplatePart::Literal("s.fits".to_string()),
            ]
        );
    }

    #[test]
    fn doubled_dollar_escapes_placeholder() {
        let parts = parse_template("price is $${100}").expect("escape must parse");
        // Note: `$${` becomes a literal `${`, then `100}` is literal text.
        assert_eq!(
            parts,
            vec![TemplatePart::Literal("price is ${100}".to_string())]
        );
    }

    #[test]
    fn bare_dollar_is_literal() {
        let parts = parse_template("$100 saved").expect("bare $ must be literal");
        assert_eq!(parts, vec![TemplatePart::Literal("$100 saved".to_string())]);
    }

    #[test]
    fn unterminated_placeholder_is_error() {
        let err = parse_template("hello ${target.name").expect_err("must error");
        match err {
            InterpolationError::Malformed { offset, .. } => assert_eq!(offset, 6),
            other => panic!("expected Malformed, got {other:?}"),
        }
    }

    #[test]
    fn empty_placeholder_is_error() {
        let err = parse_template("a${}b").expect_err("must error");
        match err {
            InterpolationError::Malformed { reason, .. } => {
                assert!(reason.contains("empty"), "got {reason}")
            }
            other => panic!("expected Malformed, got {other:?}"),
        }
    }

    #[test]
    fn whitespace_in_name_is_error() {
        let err = parse_template("${target name}").expect_err("must error");
        match err {
            InterpolationError::Malformed { reason, .. } => {
                assert!(reason.contains("whitespace"), "got {reason}")
            }
            other => panic!("expected Malformed, got {other:?}"),
        }
    }

    #[test]
    fn newline_in_placeholder_is_error() {
        let err = parse_template("${target.\nname}").expect_err("must error");
        match err {
            InterpolationError::Malformed { reason, .. } => {
                assert!(reason.contains("newline"), "got {reason}")
            }
            other => panic!("expected Malformed, got {other:?}"),
        }
    }

    #[test]
    fn trims_whitespace_around_name_and_spec() {
        // Permissiveness only on either side of the body; whitespace inside
        // the name itself is still an error (covered above).
        let parts = parse_template("${ target.name : .1f }").expect("trim");
        assert_eq!(
            parts,
            vec![TemplatePart::Variable {
                name: "target.name".to_string(),
                format_spec: Some(".1f".to_string()),
                offset: 0,
            }]
        );
    }

    #[test]
    fn utf8_literals_pass_through() {
        // Multibyte characters in literals must not be corrupted.
        // "M42 ★ " is 8 bytes: M(1) + 4(1) + 2(1) + space(1) + ★(3) + space(1).
        let parts = parse_template("M42 ★ ${target.name}").expect("utf8 must parse");
        assert_eq!(
            parts,
            vec![
                TemplatePart::Literal("M42 ★ ".to_string()),
                TemplatePart::Variable {
                    name: "target.name".to_string(),
                    format_spec: None,
                    offset: 8,
                },
            ]
        );
    }
}
