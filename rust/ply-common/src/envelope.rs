//! The version keys of Ply's own JSON documents, read from a file's text without decoding the
//! document (ADR 0002 rule 1). A `.plyknit` states its version in an envelope (`format` `ply.knit`
//! with `schema_version`, the pattern under `document`); a `.plynal` in two keys beside its fields
//! (`format` `ply.nalbind` with `schemaVersion`). For both, an object WITHOUT a `format` key is a
//! legacy version-1 file, written before the keys existed. [`EnvelopeRule`] says which of these a
//! document kind uses; [`envelope_version`] applies it.
//!
//! **Builds nothing in proportion to the file.** The probe makes one pass over the text. Every value
//! but those of the two keys is skipped unread ([`IgnoredAny`]), and so is a `format` or version
//! value that is a list or an object; only a short format name is copied. A hostile file of tens of
//! megabytes costs one scan and a few bytes, never the gigabytes its decoded tree can take.
//! (serde_json itself keeps one byte per list or object still open while it skips a value, and
//! copies a top-level key or a `format` text with escapes in it to read it, so only a file built
//! for that costs more, and never more than its own length.)
//!
//! **The verdict a whole decode would give on the keys.** The text must still be exactly one JSON
//! value: a syntax error or text after the value is [`EnvelopeError::Json`]. A repeated key counts
//! at its last occurrence, as it does when the text is decoded into a map (`serde_json::Value`,
//! Dart's `jsonDecode`), so the probe and the reader that later decodes the file agree on which keys
//! it has. `null` is a value: `"format": null` is a foreign format, not a missing key. A skipped
//! value is checked for its syntax only: one nested deeper than a decoder accepts is refused by the
//! reader that decodes the file, not here.
//!
//! **The top level as a tree holds it.** [`top_level`] is a stricter probe for readers that used to
//! decode a whole file into a `serde_json::Value` only to look at its top-level keys (`looms.json`,
//! `materials.json`). It accepts and refuses exactly the texts such a decode does, with the same
//! error at the same place (every value is walked as the decode walks it, so nesting past
//! serde_json's depth limit, a lone surrogate escape or a number out of range is refused), and
//! reports what the tree would hold under the keys asked for, still building nothing in proportion
//! to the file.

use serde::de::{DeserializeSeed, Deserializer, IgnoredAny, MapAccess, SeqAccess, Visitor};
use serde::Deserialize as _;
use std::fmt;

/// The top-level key that names a Ply document's format.
pub const FORMAT_KEY: &str = "format";

/// The longest `format` value kept as a name; a longer one is only "a long text" (a format name is
/// a few bytes, and nothing longer can match).
const MAX_FORMAT_NAME_BYTES: usize = 80;

/// How one kind of Ply document states its schema version.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EnvelopeRule {
    /// The `format` value of this kind, such as `ply.knit`.
    pub format: &'static str,
    /// The top-level key that holds the schema version (`schema_version` or `schemaVersion`).
    pub version_key: &'static str,
    /// Whether an object without a `format` key is a legacy version-1 file of this kind. When
    /// false, such an object is a foreign format.
    pub legacy_without_format: bool,
}

/// Why a text is not a document of the rule's kind.
#[derive(Debug)]
pub enum EnvelopeError {
    /// Not one JSON value: a syntax error, or text after the value.
    Json(serde_json::Error),
    /// JSON, but not an object.
    NotAnObject,
    /// An object whose `format` is another (or, without a legacy form, no) format. `found` is the
    /// JSON text of a short string, or the kind of value it was.
    WrongFormat { found: String },
    /// The format matches, but the version key is missing or not a positive integer.
    BadVersion,
}

impl fmt::Display for EnvelopeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            EnvelopeError::Json(e) => write!(f, "not JSON: {e}"),
            EnvelopeError::NotAnObject => f.write_str("not a JSON object"),
            EnvelopeError::WrongFormat { found } => write!(f, "another format ({found})"),
            EnvelopeError::BadVersion => {
                f.write_str("the schema version is not a positive integer")
            }
        }
    }
}

impl std::error::Error for EnvelopeError {}

/// The schema version `text` states by `rule`, read from its top-level keys alone: 1 for a legacy
/// file (when the rule has one), otherwise the positive integer under the version key, whatever its
/// size. Whether this build reads that version is the caller's decision.
pub fn envelope_version(text: &str, rule: &EnvelopeRule) -> Result<u64, EnvelopeError> {
    let mut de = serde_json::Deserializer::from_str(text);
    let top = (&mut de)
        .deserialize_any(TopVisitor(rule))
        .map_err(EnvelopeError::Json)?;
    de.end().map_err(EnvelopeError::Json)?;
    let Top::Object { format, version } = top else {
        return Err(EnvelopeError::NotAnObject);
    };
    match format {
        None if rule.legacy_without_format => return Ok(1),
        None => {
            return Err(EnvelopeError::WrongFormat {
                found: "none".into(),
            })
        }
        Some(Probed::Name(name)) if name == rule.format => {}
        Some(Probed::Name(name)) => {
            return Err(EnvelopeError::WrongFormat {
                found: serde_json::to_string(&name).unwrap_or(name),
            })
        }
        Some(Probed::Other(kind)) => {
            return Err(EnvelopeError::WrongFormat {
                found: kind.to_string(),
            })
        }
    }
    match version {
        Some(Version::Positive(v)) => Ok(v),
        _ => Err(EnvelopeError::BadVersion),
    }
}

/// The text's one value: an object with what its two keys held (None: the key is absent), or
/// anything else.
enum Top {
    Object {
        format: Option<Probed>,
        version: Option<Version>,
    },
    NotAnObject,
}

/// What a `format` value is: a short string, or only the kind of value it was.
enum Probed {
    Name(String),
    Other(&'static str),
}

/// What a version value is: a positive integer, or anything else.
enum Version {
    Positive(u64),
    Bad,
}

/// A top-level key: one of the rule's two, or another (whose value is skipped).
enum Key {
    Format,
    Version,
    Other,
}

/// Skip a list or object without building it.
fn drain_seq<'de, A: SeqAccess<'de>>(mut seq: A) -> Result<(), A::Error> {
    while seq.next_element::<IgnoredAny>()?.is_some() {}
    Ok(())
}

fn drain_map<'de, A: MapAccess<'de>>(mut map: A) -> Result<(), A::Error> {
    while map.next_entry::<IgnoredAny, IgnoredAny>()?.is_some() {}
    Ok(())
}

struct TopVisitor<'r>(&'r EnvelopeRule);

impl<'de> Visitor<'de> for TopVisitor<'_> {
    type Value = Top;
    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("a JSON value")
    }
    fn visit_bool<E: serde::de::Error>(self, _: bool) -> Result<Top, E> {
        Ok(Top::NotAnObject)
    }
    fn visit_i64<E: serde::de::Error>(self, _: i64) -> Result<Top, E> {
        Ok(Top::NotAnObject)
    }
    fn visit_u64<E: serde::de::Error>(self, _: u64) -> Result<Top, E> {
        Ok(Top::NotAnObject)
    }
    fn visit_f64<E: serde::de::Error>(self, _: f64) -> Result<Top, E> {
        Ok(Top::NotAnObject)
    }
    fn visit_str<E: serde::de::Error>(self, _: &str) -> Result<Top, E> {
        Ok(Top::NotAnObject)
    }
    fn visit_unit<E: serde::de::Error>(self) -> Result<Top, E> {
        Ok(Top::NotAnObject)
    }
    fn visit_seq<A: SeqAccess<'de>>(self, seq: A) -> Result<Top, A::Error> {
        drain_seq(seq)?;
        Ok(Top::NotAnObject)
    }
    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Top, A::Error> {
        let (mut format, mut version) = (None, None);
        // A repeated key overwrites: the last occurrence counts (see the module docs).
        while let Some(key) = map.next_key_seed(KeySeed(self.0))? {
            match key {
                Key::Format => format = Some(map.next_value::<Probed>()?),
                Key::Version => version = Some(map.next_value::<Version>()?),
                Key::Other => {
                    map.next_value::<IgnoredAny>()?;
                }
            }
        }
        Ok(Top::Object { format, version })
    }
}

/// Reads a key as one of the rule's two, or another, without keeping it.
struct KeySeed<'r>(&'r EnvelopeRule);

impl<'de> DeserializeSeed<'de> for KeySeed<'_> {
    type Value = Key;
    fn deserialize<D: Deserializer<'de>>(self, d: D) -> Result<Key, D::Error> {
        d.deserialize_str(self)
    }
}

impl<'de> Visitor<'de> for KeySeed<'_> {
    type Value = Key;
    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("an object key")
    }
    fn visit_str<E: serde::de::Error>(self, v: &str) -> Result<Key, E> {
        Ok(if v == FORMAT_KEY {
            Key::Format
        } else if v == self.0.version_key {
            Key::Version
        } else {
            Key::Other
        })
    }
}

impl<'de> serde::Deserialize<'de> for Probed {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct V;
        impl<'de> Visitor<'de> for V {
            type Value = Probed;
            fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str("a format name")
            }
            fn visit_str<E: serde::de::Error>(self, v: &str) -> Result<Probed, E> {
                Ok(if v.len() <= MAX_FORMAT_NAME_BYTES {
                    Probed::Name(v.to_string())
                } else {
                    Probed::Other("a long text")
                })
            }
            fn visit_bool<E: serde::de::Error>(self, _: bool) -> Result<Probed, E> {
                Ok(Probed::Other("true or false"))
            }
            fn visit_i64<E: serde::de::Error>(self, _: i64) -> Result<Probed, E> {
                Ok(Probed::Other("a number"))
            }
            fn visit_u64<E: serde::de::Error>(self, _: u64) -> Result<Probed, E> {
                Ok(Probed::Other("a number"))
            }
            fn visit_f64<E: serde::de::Error>(self, _: f64) -> Result<Probed, E> {
                Ok(Probed::Other("a number"))
            }
            fn visit_unit<E: serde::de::Error>(self) -> Result<Probed, E> {
                Ok(Probed::Other("null"))
            }
            fn visit_seq<A: SeqAccess<'de>>(self, s: A) -> Result<Probed, A::Error> {
                drain_seq(s)?;
                Ok(Probed::Other("a list"))
            }
            fn visit_map<A: MapAccess<'de>>(self, m: A) -> Result<Probed, A::Error> {
                drain_map(m)?;
                Ok(Probed::Other("an object"))
            }
        }
        d.deserialize_any(V)
    }
}

impl<'de> serde::Deserialize<'de> for Version {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct V;
        impl<'de> Visitor<'de> for V {
            type Value = Version;
            fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str("a positive integer")
            }
            fn visit_u64<E: serde::de::Error>(self, v: u64) -> Result<Version, E> {
                Ok(if v >= 1 {
                    Version::Positive(v)
                } else {
                    Version::Bad
                })
            }
            fn visit_i64<E: serde::de::Error>(self, v: i64) -> Result<Version, E> {
                Ok(u64::try_from(v)
                    .ok()
                    .filter(|&v| v >= 1)
                    .map_or(Version::Bad, Version::Positive))
            }
            fn visit_f64<E: serde::de::Error>(self, _: f64) -> Result<Version, E> {
                Ok(Version::Bad)
            }
            fn visit_bool<E: serde::de::Error>(self, _: bool) -> Result<Version, E> {
                Ok(Version::Bad)
            }
            fn visit_str<E: serde::de::Error>(self, _: &str) -> Result<Version, E> {
                Ok(Version::Bad)
            }
            fn visit_unit<E: serde::de::Error>(self) -> Result<Version, E> {
                Ok(Version::Bad)
            }
            fn visit_seq<A: SeqAccess<'de>>(self, s: A) -> Result<Version, A::Error> {
                drain_seq(s)?;
                Ok(Version::Bad)
            }
            fn visit_map<A: MapAccess<'de>>(self, m: A) -> Result<Version, A::Error> {
                drain_map(m)?;
                Ok(Version::Bad)
            }
        }
        d.deserialize_any(V)
    }
}

/// A top-level value as a whole decode into a `serde_json::Value` holds it: a scalar as it is, a
/// list by its length, an object by its kind alone (see [`top_level`]).
#[derive(Debug, Clone, PartialEq)]
pub enum TopValue {
    /// `null`, `true` or `false`, a number or a text, exactly as the tree holds it.
    Scalar(serde_json::Value),
    /// A list, with how many values it holds.
    List(usize),
    /// An object.
    Object,
}

/// A key of the top-level object at its last occurrence, the one a decoded tree keeps.
#[derive(Debug, Clone, PartialEq)]
pub struct TopEntry {
    /// Its place among the object's entries, counting from 0 and counting every repeat.
    pub index: usize,
    /// Its value.
    pub value: TopValue,
}

/// The top level of `text`, read as `serde_json::from_str::<serde_json::Value>` reads it, without
/// building the tree: `Ok(None)` when the text is JSON but not an object, otherwise what each of
/// `keys` holds at its last occurrence (`None` when absent), in the order asked. The text is
/// accepted or refused exactly as that decode accepts or refuses it, with the same error: every
/// value is walked as the decode walks it, and none is kept but a scalar under one of `keys` (a
/// text is copied once).
pub fn top_level(
    text: &str,
    keys: &[&str],
) -> Result<Option<Vec<Option<TopEntry>>>, serde_json::Error> {
    let mut de = serde_json::Deserializer::from_str(text);
    let top = (&mut de).deserialize_any(TopLevelVisitor(keys))?;
    de.end()?;
    Ok(top)
}

/// Walks one value as a decode into a tree does (`deserialize_any` at every level, so the depth
/// limit, string escapes and number ranges are checked alike) and keeps nothing.
struct Checked;

impl<'de> serde::Deserialize<'de> for Checked {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        d.deserialize_any(CheckedVisitor)
    }
}

struct CheckedVisitor;

impl<'de> Visitor<'de> for CheckedVisitor {
    type Value = Checked;
    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("any valid JSON value")
    }
    fn visit_bool<E: serde::de::Error>(self, _: bool) -> Result<Checked, E> {
        Ok(Checked)
    }
    fn visit_i64<E: serde::de::Error>(self, _: i64) -> Result<Checked, E> {
        Ok(Checked)
    }
    fn visit_u64<E: serde::de::Error>(self, _: u64) -> Result<Checked, E> {
        Ok(Checked)
    }
    fn visit_f64<E: serde::de::Error>(self, _: f64) -> Result<Checked, E> {
        Ok(Checked)
    }
    fn visit_str<E: serde::de::Error>(self, _: &str) -> Result<Checked, E> {
        Ok(Checked)
    }
    fn visit_unit<E: serde::de::Error>(self) -> Result<Checked, E> {
        Ok(Checked)
    }
    fn visit_none<E: serde::de::Error>(self) -> Result<Checked, E> {
        Ok(Checked)
    }
    fn visit_some<D: Deserializer<'de>>(self, d: D) -> Result<Checked, D::Error> {
        Checked::deserialize(d)
    }
    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Checked, A::Error> {
        while seq.next_element::<Checked>()?.is_some() {}
        Ok(Checked)
    }
    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Checked, A::Error> {
        while map.next_entry::<Checked, Checked>()?.is_some() {}
        Ok(Checked)
    }
}

struct TopLevelVisitor<'k>(&'k [&'k str]);

impl<'de> Visitor<'de> for TopLevelVisitor<'_> {
    type Value = Option<Vec<Option<TopEntry>>>;
    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("any valid JSON value")
    }
    fn visit_bool<E: serde::de::Error>(self, _: bool) -> Result<Self::Value, E> {
        Ok(None)
    }
    fn visit_i64<E: serde::de::Error>(self, _: i64) -> Result<Self::Value, E> {
        Ok(None)
    }
    fn visit_u64<E: serde::de::Error>(self, _: u64) -> Result<Self::Value, E> {
        Ok(None)
    }
    fn visit_f64<E: serde::de::Error>(self, _: f64) -> Result<Self::Value, E> {
        Ok(None)
    }
    fn visit_str<E: serde::de::Error>(self, _: &str) -> Result<Self::Value, E> {
        Ok(None)
    }
    fn visit_unit<E: serde::de::Error>(self) -> Result<Self::Value, E> {
        Ok(None)
    }
    fn visit_seq<A: SeqAccess<'de>>(self, seq: A) -> Result<Self::Value, A::Error> {
        CheckedVisitor.visit_seq(seq)?;
        Ok(None)
    }
    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
        let mut found = vec![None; self.0.len()];
        let mut index = 0;
        while let Some(key) = map.next_key_seed(WhichKey(self.0))? {
            match key {
                // A repeated key overwrites: the last occurrence counts, as in a decoded tree.
                Some(k) => {
                    found[k] = Some(TopEntry {
                        index,
                        value: map.next_value::<TopValue>()?,
                    })
                }
                None => {
                    map.next_value::<Checked>()?;
                }
            }
            index += 1;
        }
        Ok(Some(found))
    }
}

/// Reads an object's key as its place among `keys`, or (`Err`) as another key's name: for a reader
/// that decodes the keys it knows and refuses any other by name (`looms.json`, `materials.json`).
/// Only a key it does not know is copied.
pub struct KeyAmong<'k>(pub &'k [&'k str]);

impl<'de> DeserializeSeed<'de> for KeyAmong<'_> {
    type Value = Result<usize, String>;
    fn deserialize<D: Deserializer<'de>>(self, d: D) -> Result<Self::Value, D::Error> {
        d.deserialize_str(self)
    }
}

impl<'de> Visitor<'de> for KeyAmong<'_> {
    type Value = Result<usize, String>;
    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("a string key")
    }
    fn visit_str<E: serde::de::Error>(self, v: &str) -> Result<Self::Value, E> {
        Ok(self
            .0
            .iter()
            .position(|k| *k == v)
            .ok_or_else(|| v.to_string()))
    }
}

/// Reads a key as its place in the keys asked for (`None`: another key), keeping nothing.
struct WhichKey<'k>(&'k [&'k str]);

impl<'de> DeserializeSeed<'de> for WhichKey<'_> {
    type Value = Option<usize>;
    fn deserialize<D: Deserializer<'de>>(self, d: D) -> Result<Option<usize>, D::Error> {
        d.deserialize_str(self)
    }
}

impl<'de> Visitor<'de> for WhichKey<'_> {
    type Value = Option<usize>;
    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("a string key")
    }
    fn visit_str<E: serde::de::Error>(self, v: &str) -> Result<Option<usize>, E> {
        Ok(self.0.iter().position(|k| *k == v))
    }
}

impl<'de> serde::Deserialize<'de> for TopValue {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct V;
        impl<'de> Visitor<'de> for V {
            type Value = TopValue;
            fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str("any valid JSON value")
            }
            // Scalars are held as `serde_json::Value`'s own visitor holds them.
            fn visit_bool<E: serde::de::Error>(self, v: bool) -> Result<TopValue, E> {
                Ok(TopValue::Scalar(serde_json::Value::Bool(v)))
            }
            fn visit_i64<E: serde::de::Error>(self, v: i64) -> Result<TopValue, E> {
                Ok(TopValue::Scalar(serde_json::Value::Number(v.into())))
            }
            fn visit_u64<E: serde::de::Error>(self, v: u64) -> Result<TopValue, E> {
                Ok(TopValue::Scalar(serde_json::Value::Number(v.into())))
            }
            fn visit_f64<E: serde::de::Error>(self, v: f64) -> Result<TopValue, E> {
                Ok(TopValue::Scalar(serde_json::Number::from_f64(v).map_or(
                    serde_json::Value::Null,
                    serde_json::Value::Number,
                )))
            }
            fn visit_str<E: serde::de::Error>(self, v: &str) -> Result<TopValue, E> {
                Ok(TopValue::Scalar(serde_json::Value::String(v.to_string())))
            }
            fn visit_unit<E: serde::de::Error>(self) -> Result<TopValue, E> {
                Ok(TopValue::Scalar(serde_json::Value::Null))
            }
            fn visit_none<E: serde::de::Error>(self) -> Result<TopValue, E> {
                Ok(TopValue::Scalar(serde_json::Value::Null))
            }
            fn visit_some<D: Deserializer<'de>>(self, d: D) -> Result<TopValue, D::Error> {
                TopValue::deserialize(d)
            }
            fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<TopValue, A::Error> {
                let mut n = 0;
                while seq.next_element::<Checked>()?.is_some() {
                    n += 1;
                }
                Ok(TopValue::List(n))
            }
            fn visit_map<A: MapAccess<'de>>(self, map: A) -> Result<TopValue, A::Error> {
                CheckedVisitor.visit_map(map)?;
                Ok(TopValue::Object)
            }
        }
        d.deserialize_any(V)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const KNIT: EnvelopeRule = EnvelopeRule {
        format: "ply.knit",
        version_key: "schema_version",
        legacy_without_format: true,
    };
    const NAL: EnvelopeRule = EnvelopeRule {
        format: "ply.nalbind",
        version_key: "schemaVersion",
        legacy_without_format: true,
    };
    const NO_LEGACY: EnvelopeRule = EnvelopeRule {
        format: "ply.tablet",
        version_key: "schema_version",
        legacy_without_format: false,
    };

    fn kind(r: Result<u64, EnvelopeError>) -> String {
        match r {
            Ok(v) => format!("v{v}"),
            Err(EnvelopeError::Json(_)) => "json".into(),
            Err(EnvelopeError::NotAnObject) => "not an object".into(),
            Err(EnvelopeError::WrongFormat { found }) => format!("wrong {found}"),
            Err(EnvelopeError::BadVersion) => "bad version".into(),
        }
    }

    #[test]
    fn the_rule_reads_the_two_keys_and_nothing_else() {
        for (text, rule, want) in [
            (r#"{"name": "bare", "legend": []}"#, KNIT, "v1"),
            (r#"{}"#, KNIT, "v1"),
            (
                r#"{"format": "ply.knit", "schema_version": 6, "document": {}}"#,
                KNIT,
                "v6",
            ),
            // The version key of the rule, not another one.
            (
                r#"{"format": "ply.knit", "schemaVersion": 6}"#,
                KNIT,
                "bad version",
            ),
            (
                r#"{"format": "ply.nalbind", "schemaVersion": 3, "name": "x"}"#,
                NAL,
                "v3",
            ),
            (
                r#"{"format": "ply.nalbind", "schema_version": 3}"#,
                NAL,
                "bad version",
            ),
            // A newer version is returned as found.
            (
                r#"{"format": "ply.knit", "schema_version": 99}"#,
                KNIT,
                "v99",
            ),
            (
                r#"{"format": "ply.knit", "schema_version": 18446744073709551615}"#,
                KNIT,
                "v18446744073709551615",
            ),
            // Keys in any order; the document before the envelope keys.
            (
                r#"{"document": [1, {"a": []}], "schema_version": 2, "format": "ply.knit"}"#,
                KNIT,
                "v2",
            ),
            // A legacy file's stray version key is not looked at.
            (r#"{"schema_version": "x"}"#, KNIT, "v1"),
            (r#"{"schema_version": 1}"#, NO_LEGACY, "wrong none"),
            (
                r#"{"format": "ply.nalbind", "schemaVersion": 2}"#,
                KNIT,
                r#"wrong "ply.nalbind""#,
            ),
            (
                r#"{"format": null, "schema_version": 2}"#,
                KNIT,
                "wrong null",
            ),
            (r#"{"format": 7}"#, KNIT, "wrong a number"),
            (
                r#"{"format": [], "schema_version": 2}"#,
                KNIT,
                "wrong a list",
            ),
            (r#"{"format": {"a": 1}}"#, KNIT, "wrong an object"),
            (r#"{"format": true}"#, KNIT, "wrong true or false"),
            (r#"{"format": "ply.knit"}"#, KNIT, "bad version"),
            (
                r#"{"format": "ply.knit", "schema_version": 0}"#,
                KNIT,
                "bad version",
            ),
            (
                r#"{"format": "ply.knit", "schema_version": -3}"#,
                KNIT,
                "bad version",
            ),
            (
                r#"{"format": "ply.knit", "schema_version": 2.0}"#,
                KNIT,
                "bad version",
            ),
            (
                r#"{"format": "ply.knit", "schema_version": 1e400}"#,
                KNIT,
                "json",
            ),
            (
                r#"{"format": "ply.knit", "schema_version": "2"}"#,
                KNIT,
                "bad version",
            ),
            (
                r#"{"format": "ply.knit", "schema_version": null}"#,
                KNIT,
                "bad version",
            ),
            (
                r#"{"format": "ply.knit", "schema_version": [2]}"#,
                KNIT,
                "bad version",
            ),
            (r#"[1, 2, 3]"#, KNIT, "not an object"),
            (r#""ply.knit""#, KNIT, "not an object"),
            (r#"null"#, KNIT, "not an object"),
            (r#"6"#, KNIT, "not an object"),
            ("not json", KNIT, "json"),
            ("", KNIT, "json"),
            (
                r#"{"format": "ply.knit", "schema_version": 2"#,
                KNIT,
                "json",
            ),
            (
                r#"{"format": "ply.knit", "schema_version": 2} trailing"#,
                KNIT,
                "json",
            ),
            (
                r#"{"format": "ply.knit", "schema_version": 2, "document": [}"#,
                KNIT,
                "json",
            ),
            (r#"[1, 2"#, KNIT, "json"),
        ] {
            assert_eq!(kind(envelope_version(text, &rule)), want, "{text}");
        }
    }

    #[test]
    fn a_repeated_key_counts_at_its_last_occurrence_as_a_decode_keeps_it() {
        let twice = r#"{"format": "ply.knit", "schema_version": 2, "schema_version": 9}"#;
        assert_eq!(kind(envelope_version(twice, &KNIT)), "v9");
        let value: serde_json::Value = serde_json::from_str(twice).unwrap();
        assert_eq!(value["schema_version"], 9);
        let renamed = r#"{"format": "ply.knit", "format": "ply.other", "schema_version": 2}"#;
        assert_eq!(
            kind(envelope_version(renamed, &KNIT)),
            r#"wrong "ply.other""#
        );
    }

    #[test]
    fn a_long_format_is_not_kept_and_deep_nesting_is_skipped_without_recursion() {
        let long = format!(
            r#"{{"format": "{}", "schema_version": 1}}"#,
            "x".repeat(10_000)
        );
        assert_eq!(kind(envelope_version(&long, &KNIT)), "wrong a long text");
        // A skipped value is walked without recursion, so deep nesting is no stack overflow; the
        // reader that decodes the file refuses it (past serde_json's depth limit) instead.
        let deep = format!(
            r#"{{"format": "ply.knit", "schema_version": 1, "document": {}{}}}"#,
            "[".repeat(100_000),
            "]".repeat(100_000)
        );
        assert_eq!(kind(envelope_version(&deep, &KNIT)), "v1");
        assert!(serde_json::from_str::<serde_json::Value>(&deep).is_err());
        let deep_format = format!(
            r#"{{"format": {}{}, "schema_version": 1}}"#,
            "[".repeat(100_000),
            "]".repeat(100_000)
        );
        assert_eq!(kind(envelope_version(&deep_format, &KNIT)), "wrong a list");
        let unclosed = format!(
            r#"{{"format": "ply.knit", "document": {}"#,
            "[".repeat(1000)
        );
        assert_eq!(kind(envelope_version(&unclosed, &KNIT)), "json");
    }

    /// What a decoded tree holds under `keys` in `text`, worked out from the tree itself.
    fn from_tree(text: &str, keys: &[&str]) -> Result<Option<Vec<Option<TopValue>>>, String> {
        let v: serde_json::Value = serde_json::from_str(text).map_err(|e| e.to_string())?;
        let Some(obj) = v.as_object() else {
            return Ok(None);
        };
        Ok(Some(
            keys.iter()
                .map(|k| {
                    obj.get(*k).map(|v| match v {
                        serde_json::Value::Array(a) => TopValue::List(a.len()),
                        serde_json::Value::Object(_) => TopValue::Object,
                        other => TopValue::Scalar(other.clone()),
                    })
                })
                .collect(),
        ))
    }

    #[test]
    fn the_top_level_is_what_a_decoded_tree_holds() {
        let keys = ["format", "n", "list"];
        let deep = |n: usize| format!("{}{}", "[".repeat(n), "]".repeat(n));
        let deep_obj = |n: usize| format!("{}1{}", r#"{"a":"#.repeat(n), "}".repeat(n));
        let cases: Vec<String> = vec![
            r#"{"format":"x","n":1,"list":[1,[2],{"a":3}]}"#.into(),
            r#"{"list":[],"n":-0,"format":null}"#.into(),
            r#"{"n":1.5,"n":2,"list":{},"list":[1,2]}"#.into(),
            r#"{"format":"a","format":["b"],"n":true}"#.into(),
            r#"{"f\u006frmat":"esc\n\u00e9","n":18446744073709551615}"#.into(),
            r#"{"n":18446744073709551616,"list":-9223372036854775808}"#.into(),
            r#"{"n":1e308,"list":[1e-400]}"#.into(),
            r#"{}"#.into(),
            r#"[1,{"format":"x"}]"#.into(),
            r#""text""#.into(),
            "7".into(),
            "null".into(),
            "true".into(),
            // Refused by the decode, so by the probe, with the same error.
            "".into(),
            "{".into(),
            r#"{"format":"x"} {}"#.into(),
            r#"{"format":"x",}"#.into(),
            r#"{"n":1e400}"#.into(),
            r#"{"x":[-1e400]}"#.into(),
            r#"{"x":"\ud83d"}"#.into(),
            r#"{"\udc00":1}"#.into(),
            r#"{"format":"\ud83d\ude00"}"#.into(),
            "{\"x\":\"a\u{0001}\"}".into(),
            r#"{"x":tru}"#.into(),
            format!(r#"{{"x":{}}}"#, deep(126)),
            format!(r#"{{"x":{}}}"#, deep(127)),
            format!(r#"{{"x":{}}}"#, deep(128)),
            format!(r#"{{"list":{}}}"#, deep(127)),
            format!(r#"{{"list":{}}}"#, deep(128)),
            format!(r#"{{"x":{}}}"#, deep_obj(127)),
            format!(r#"{{"x":{}}}"#, deep_obj(128)),
            format!(r#"[{}]"#, deep(127)),
            deep(128),
            deep(129),
            format!(r#"{{"x":{}}}"#, deep(100_000)),
        ];
        for text in &cases {
            let probed = top_level(text, &keys).map(|top| {
                top.map(|found| found.into_iter().map(|e| e.map(|e| e.value)).collect())
            });
            match (probed, from_tree(text, &keys)) {
                (Ok(a), Ok(b)) => assert_eq!(a, b, "{text:.120}"),
                (Err(a), Err(b)) => assert_eq!(a.to_string(), b, "{text:.120}"),
                (a, b) => panic!("{text:.120}: probe {a:?}, tree {b:?}"),
            }
        }
    }

    #[test]
    fn a_top_level_entry_is_placed_at_its_last_occurrence() {
        let found = top_level(r#"{"a":1,"b":[],"a":[1,2],"c":{}}"#, &["a", "c", "d"])
            .unwrap()
            .unwrap();
        assert_eq!(
            found,
            vec![
                Some(TopEntry {
                    index: 2,
                    value: TopValue::List(2)
                }),
                Some(TopEntry {
                    index: 3,
                    value: TopValue::Object
                }),
                None,
            ]
        );
    }
}
