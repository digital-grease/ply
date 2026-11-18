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

use serde::de::{DeserializeSeed, Deserializer, IgnoredAny, MapAccess, SeqAccess, Visitor};
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
}
