//! The request keys the app's argument builders are held to.
//!
//! Each `args_json` request type is read by serde with defaults for absent
//! keys, so a key the app misspells is dropped without an error and the step
//! runs on the default. Here each request type's keys are traced from its
//! `Deserialize` implementation into `test_fixtures/ffi_args/<name>.json`: an
//! object per struct, `[element]` per list, `{"*": value}` per map, and
//! `"string"`, `"number"`, `"bool"`, `"one of a|b"` or `"any"` per value. The
//! Dart builder tests check that every key a builder writes is one of these.
//! Regenerate after a deliberate change with
//! `SKOTIQ_WRITE_FIXTURES=1 cargo test -p skotiq_processing args_fixture`.

use serde::de::{self, DeserializeOwned, DeserializeSeed, IntoDeserializer, Visitor};
use serde_json::{Map, Value};

/// Nesting past which a struct is not traced further (a type that holds
/// itself).
const MAX_DEPTH: usize = 12;

/// Write the key schema of `T` as the fixture `name` (with
/// `SKOTIQ_WRITE_FIXTURES`), or check that the committed fixture is it.
pub(crate) fn check_or_write_args<T: DeserializeOwned>(name: &str) {
    skotiq_wire_fixtures::pin_json(
        &format!("ffi_args/{name}.json"),
        &key_schema::<T>(),
        &format!(
            "the {name} request keys changed; regenerate the fixture and update the app's builder"
        ),
    );
}

/// The keys `T` reads, as described in the module docs.
pub(crate) fn key_schema<T: DeserializeOwned>() -> Value {
    let mut out = Value::Null;
    T::deserialize(Tracer {
        out: &mut out,
        depth: 0,
    })
    .unwrap_or_else(|e| panic!("tracing {}: {e}", std::any::type_name::<T>()));
    out
}

#[derive(Debug)]
pub(crate) struct TraceError(String);

impl std::fmt::Display for TraceError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for TraceError {}

impl de::Error for TraceError {
    fn custom<T: std::fmt::Display>(msg: T) -> Self {
        Self(msg.to_string())
    }
}

/// A deserializer that answers every request with a placeholder value and
/// records what was asked for in `out`.
struct Tracer<'a> {
    out: &'a mut Value,
    depth: usize,
}

impl Tracer<'_> {
    fn mark(self, kind: &str) {
        *self.out = Value::String(kind.to_string());
    }
}

macro_rules! scalar {
    ($($method:ident => $kind:literal, $visit:ident($value:expr);)*) => {
        $(fn $method<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, TraceError> {
            self.mark($kind);
            visitor.$visit($value)
        })*
    };
}

impl<'de> de::Deserializer<'de> for Tracer<'_> {
    type Error = TraceError;

    scalar! {
        deserialize_bool => "bool", visit_bool(false);
        deserialize_i8 => "number", visit_i8(0);
        deserialize_i16 => "number", visit_i16(0);
        deserialize_i32 => "number", visit_i32(0);
        deserialize_i64 => "number", visit_i64(0);
        deserialize_u8 => "number", visit_u8(0);
        deserialize_u16 => "number", visit_u16(0);
        deserialize_u32 => "number", visit_u32(0);
        deserialize_u64 => "number", visit_u64(0);
        deserialize_f32 => "number", visit_f32(0.0);
        deserialize_f64 => "number", visit_f64(0.0);
        deserialize_char => "string", visit_char('a');
        deserialize_str => "string", visit_str("");
        deserialize_string => "string", visit_str("");
        deserialize_bytes => "string", visit_bytes(&[]);
        deserialize_byte_buf => "string", visit_bytes(&[]);
        deserialize_identifier => "string", visit_str("");
    }

    fn deserialize_any<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, TraceError> {
        self.mark("any");
        visitor.visit_unit()
    }

    fn deserialize_ignored_any<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, TraceError> {
        self.mark("any");
        visitor.visit_unit()
    }

    fn deserialize_unit<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, TraceError> {
        self.mark("any");
        visitor.visit_unit()
    }

    fn deserialize_unit_struct<V: Visitor<'de>>(
        self,
        _name: &'static str,
        visitor: V,
    ) -> Result<V::Value, TraceError> {
        self.mark("any");
        visitor.visit_unit()
    }

    fn deserialize_option<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, TraceError> {
        visitor.visit_some(self)
    }

    fn deserialize_newtype_struct<V: Visitor<'de>>(
        self,
        _name: &'static str,
        visitor: V,
    ) -> Result<V::Value, TraceError> {
        visitor.visit_newtype_struct(self)
    }

    fn deserialize_seq<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, TraceError> {
        self.deserialize_tuple(1, visitor)
    }

    fn deserialize_tuple<V: Visitor<'de>>(
        self,
        len: usize,
        visitor: V,
    ) -> Result<V::Value, TraceError> {
        *self.out = Value::Array(vec![Value::Null; len]);
        let Value::Array(items) = self.out else {
            unreachable!("just set")
        };
        visitor.visit_seq(Items {
            slots: items.iter_mut().collect(),
            depth: self.depth,
        })
    }

    fn deserialize_tuple_struct<V: Visitor<'de>>(
        self,
        _name: &'static str,
        len: usize,
        visitor: V,
    ) -> Result<V::Value, TraceError> {
        self.deserialize_tuple(len, visitor)
    }

    fn deserialize_map<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, TraceError> {
        self.fields(vec!["*"], visitor)
    }

    fn deserialize_struct<V: Visitor<'de>>(
        self,
        _name: &'static str,
        fields: &'static [&'static str],
        visitor: V,
    ) -> Result<V::Value, TraceError> {
        let keys = if self.depth >= MAX_DEPTH {
            Vec::new()
        } else {
            fields.to_vec()
        };
        self.fields(keys, visitor)
    }

    fn deserialize_enum<V: Visitor<'de>>(
        self,
        _name: &'static str,
        variants: &'static [&'static str],
        visitor: V,
    ) -> Result<V::Value, TraceError> {
        let depth = self.depth;
        let Some(&name) = variants.first() else {
            return Err(TraceError("an enum with no variants".to_string()));
        };
        self.mark(&format!("one of {}", variants.join("|")));
        let mut scratch = Value::Null;
        visitor.visit_enum(Variant {
            name,
            scratch: &mut scratch,
            depth,
        })
    }
}

impl Tracer<'_> {
    fn fields<'de, V: Visitor<'de>>(
        self,
        keys: Vec<&'static str>,
        visitor: V,
    ) -> Result<V::Value, TraceError> {
        *self.out = Value::Object(Map::new());
        let Value::Object(map) = self.out else {
            unreachable!("just set")
        };
        visitor.visit_map(Fields {
            keys: keys.into_iter(),
            map,
            current: None,
            depth: self.depth,
        })
    }
}

struct Items<'a> {
    slots: Vec<&'a mut Value>,
    depth: usize,
}

impl<'de> de::SeqAccess<'de> for Items<'_> {
    type Error = TraceError;

    fn next_element_seed<T: DeserializeSeed<'de>>(
        &mut self,
        seed: T,
    ) -> Result<Option<T::Value>, TraceError> {
        if self.slots.is_empty() {
            return Ok(None);
        }
        let slot = self.slots.remove(0);
        seed.deserialize(Tracer {
            out: slot,
            depth: self.depth + 1,
        })
        .map(Some)
    }
}

struct Fields<'a> {
    keys: std::vec::IntoIter<&'static str>,
    map: &'a mut Map<String, Value>,
    current: Option<&'static str>,
    depth: usize,
}

impl<'de> de::MapAccess<'de> for Fields<'_> {
    type Error = TraceError;

    fn next_key_seed<K: DeserializeSeed<'de>>(
        &mut self,
        seed: K,
    ) -> Result<Option<K::Value>, TraceError> {
        let Some(key) = self.keys.next() else {
            return Ok(None);
        };
        self.current = Some(key);
        seed.deserialize(key.into_deserializer()).map(Some)
    }

    fn next_value_seed<V: DeserializeSeed<'de>>(
        &mut self,
        seed: V,
    ) -> Result<V::Value, TraceError> {
        let key = self
            .current
            .take()
            .ok_or_else(|| TraceError("a value before its key".to_string()))?;
        let slot = self.map.entry(key.to_string()).or_insert(Value::Null);
        seed.deserialize(Tracer {
            out: slot,
            depth: self.depth + 1,
        })
    }
}

struct Variant<'a> {
    name: &'static str,
    scratch: &'a mut Value,
    depth: usize,
}

impl<'de, 'a> de::EnumAccess<'de> for Variant<'a> {
    type Error = TraceError;
    type Variant = Self;

    fn variant_seed<V: DeserializeSeed<'de>>(
        self,
        seed: V,
    ) -> Result<(V::Value, Self), TraceError> {
        let value = seed.deserialize(self.name.into_deserializer())?;
        Ok((value, self))
    }
}

impl<'de> de::VariantAccess<'de> for Variant<'_> {
    type Error = TraceError;

    fn unit_variant(self) -> Result<(), TraceError> {
        Ok(())
    }

    fn newtype_variant_seed<T: DeserializeSeed<'de>>(
        self,
        seed: T,
    ) -> Result<T::Value, TraceError> {
        seed.deserialize(Tracer {
            out: self.scratch,
            depth: self.depth + 1,
        })
    }

    fn tuple_variant<V: Visitor<'de>>(
        self,
        len: usize,
        visitor: V,
    ) -> Result<V::Value, TraceError> {
        de::Deserializer::deserialize_tuple(
            Tracer {
                out: self.scratch,
                depth: self.depth + 1,
            },
            len,
            visitor,
        )
    }

    fn struct_variant<V: Visitor<'de>>(
        self,
        fields: &'static [&'static str],
        visitor: V,
    ) -> Result<V::Value, TraceError> {
        de::Deserializer::deserialize_struct(
            Tracer {
                out: self.scratch,
                depth: self.depth + 1,
            },
            "",
            fields,
            visitor,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;

    #[derive(Deserialize)]
    #[serde(default, rename_all = "camelCase")]
    #[allow(dead_code)]
    struct Inner {
        poly_degree: u32,
        preserve_mean: bool,
    }

    impl Default for Inner {
        fn default() -> Self {
            Self {
                poly_degree: 2,
                preserve_mean: true,
            }
        }
    }

    #[derive(Deserialize, Default)]
    #[serde(rename_all = "camelCase")]
    #[allow(dead_code)]
    enum Mode {
        #[default]
        Fast,
        Slow,
    }

    #[derive(Deserialize, Default)]
    #[serde(default, rename_all = "camelCase")]
    #[allow(dead_code)]
    struct Outer {
        input_fits: String,
        light_paths: Vec<String>,
        frames: Vec<Inner>,
        config: Option<Inner>,
        weights: std::collections::BTreeMap<String, f64>,
        mode: Mode,
    }

    #[test]
    fn a_request_type_traces_to_its_keys() {
        assert_eq!(
            key_schema::<Outer>(),
            serde_json::json!({
                "inputFits": "string",
                "lightPaths": ["string"],
                "frames": [{"polyDegree": "number", "preserveMean": "bool"}],
                "config": {"polyDegree": "number", "preserveMean": "bool"},
                "weights": {"*": "number"},
                "mode": "one of fast|slow",
            })
        );
    }
}
