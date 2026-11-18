//! The version a `.plynal` project file states, read from its text alone (ADR 0002). The app owns
//! the document: the Dart `NalbindProject` reads and writes it, and decides which versions this build
//! opens. The engine reads only the two version keys, so the app never decodes a whole file just to
//! learn its version (a file in a backup can be tens of megabytes).
//!
//! A `.plynal` is one JSON object with the project's fields at the top level beside `format`
//! ([`NALBIND_FORMAT`]) and `schemaVersion` (a positive integer). An object without a `format` key
//! is a legacy version-1 file (releases v0.1.0 to v0.1.7 wrote no version keys). This is the rule
//! `NalbindProject.schemaVersionOf` applies to a decoded object; the shared probe
//! ([`ply_common::envelope`]) applies it to the text, skipping every other value unread. A version
//! past the largest integer Dart reads (`i64::MAX`; Dart's `jsonDecode` makes a larger one a
//! fraction) is a bad version, as it is to the app.
//!
//! **A guard for untrusted files.** The app decodes the whole project in Dart, into a tree that can
//! take far more memory than the text (a few megabytes of `{},{},...` decode to hundreds of
//! megabytes). [`within_value_limit`] counts a file's values without decoding it; the backup restore
//! refuses a project past [`MAX_VALUES`] before it decodes it. Opening and saving do not ask.

use ply_common::envelope::{envelope_version, EnvelopeError, EnvelopeRule};
use ply_common::json_count::count_values;

/// The `format` value of a `.plynal` file.
pub const NALBIND_FORMAT: &str = "ply.nalbind";

/// The key that holds a `.plynal` file's schema version (beside the fields, not in an envelope).
pub const NALBIND_VERSION_KEY: &str = "schemaVersion";

const NALBIND_ENVELOPE: EnvelopeRule = EnvelopeRule {
    format: NALBIND_FORMAT,
    version_key: NALBIND_VERSION_KEY,
    legacy_without_format: true,
};

/// The most JSON values (objects, lists, strings, numbers, `true`, `false`, `null` and object
/// keys, as [`ply_common::json_count::count_values`] counts them) a project from a backup may
/// have: past it, the restore refuses the project as too complex to check, without decoding it.
///
/// Sized from the largest project the app can make, from the format's limits: a recipe of 1,000
/// segments with every field filled, 100 fit measurements and every segment ticked. It has about
/// 47,000 values; this is over four times that. The guard bounds decode memory only roughly: a file
/// at the limit decodes, at worst (a list of empty objects), to about 65 MiB of Dart's resident
/// memory, measured. Notes and text of any length are one value each and are not bounded by it: a
/// long text decodes to a few times its length, as it always has.
pub const MAX_VALUES: u64 = 200_000;

/// The schema version a `.plynal` file's text states, by the rule above, building nothing in
/// proportion to the file: 1 for a legacy file, otherwise the positive integer it states, however
/// large up to `i64::MAX` (whether this build reads it is the app's decision). An error when the
/// text is not a `.plynal` at all: not JSON, not an object, another format, or a bad version.
pub fn schema_version(text: &str) -> Result<u64, EnvelopeError> {
    match envelope_version(text, &NALBIND_ENVELOPE)? {
        v if v > i64::MAX as u64 => Err(EnvelopeError::BadVersion),
        v => Ok(v),
    }
}

/// Whether `text` has at most [`MAX_VALUES`] JSON values, counted in one pass without decoding it
/// or allocating anything. The backup restore asks before it decodes a project; nothing else does.
pub fn within_value_limit(text: &str) -> bool {
    count_values(text) <= MAX_VALUES
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(rel: &str) -> String {
        let path = format!("{}/../../fixtures/{rel}", env!("CARGO_MANIFEST_DIR"));
        std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}"))
    }

    #[test]
    fn the_released_and_current_fixtures_state_their_versions() {
        for (rel, want) in [
            ("migrations/plynal/v0.1.7/oslo-mittens.plynal", 1),
            ("migrations/plynal/v0.1.7/typed-notation.plynal", 1),
            ("migrations/plynal/schema-v2/mitten-notes.plynal", 2),
            ("migrations/plynal/schema-v2/typed-notation.plynal", 2),
            ("migrations/plynal/schema-v2/untitled-empty.plynal", 2),
            ("nalbinding/recipes/mitten-cuff-up.plynal", 3),
            ("nalbinding/recipes/recipe-empty.plynal", 3),
        ] {
            assert_eq!(schema_version(&fixture(rel)).unwrap(), want, "{rel}");
        }
    }

    #[test]
    fn a_newer_foreign_or_unreadable_file_says_so() {
        assert_eq!(
            schema_version(r#"{"format":"ply.nalbind","schemaVersion":4,"name":"x"}"#).unwrap(),
            4
        );
        assert!(matches!(
            schema_version(r#"{"format":"ply.knit","schema_version":2,"document":{}}"#),
            Err(EnvelopeError::WrongFormat { .. })
        ));
        // The knit key is not the nalbinding one.
        assert!(matches!(
            schema_version(r#"{"format":"ply.nalbind","schema_version":3}"#),
            Err(EnvelopeError::BadVersion)
        ));
        for bad in [
            r#"{"format":"ply.nalbind","schemaVersion":"2"}"#,
            r#"{"format":"ply.nalbind","schemaVersion":0}"#,
            r#"{"format":"ply.nalbind"}"#,
        ] {
            assert!(
                matches!(schema_version(bad), Err(EnvelopeError::BadVersion)),
                "{bad}"
            );
        }
        assert!(matches!(
            schema_version("[]"),
            Err(EnvelopeError::NotAnObject)
        ));
        assert!(matches!(
            schema_version("{nope"),
            Err(EnvelopeError::Json(_))
        ));
    }

    #[test]
    fn a_version_dart_cannot_read_as_an_integer_is_a_bad_version() {
        let v = |n: &str| {
            schema_version(&format!(
                r#"{{"format":"ply.nalbind","schemaVersion":{n}}}"#
            ))
        };
        assert_eq!(v("9223372036854775807").unwrap(), i64::MAX as u64);
        for past in ["9223372036854775808", "18446744073709551615"] {
            assert!(matches!(v(past), Err(EnvelopeError::BadVersion)), "{past}");
        }
    }

    /// The largest project the app can make, as JSON, the way `NalbindProject.toJson` writes it:
    /// every recipe count at its limit and every field filled.
    fn largest() -> String {
        let text = |n: usize| "Ab\"\n".repeat(n / 4 + 1)[..n].to_string();
        let per = 200_000 / 1000 / 3;
        let measure = || serde_json::json!({"label": text(200), "value": 123456.789, "unit": "in"});
        let segments: Vec<_> = (1..=1000)
            .map(|i| {
                serde_json::json!({
                    "id": format!("segment-{i}"), "title": text(per),
                    "work": {"kind": "increase", "perRound": 4294967295u64, "method": "between",
                        "extent": {"type": "until", "measure": measure()}},
                    "stitch": {"notation": text(200), "name": text(200), "reading": "lenient"},
                    "target": measure(), "notes": text(per), "caution": text(per),
                })
            })
            .collect();
        let done: Vec<_> = (1..=1000).map(|i| format!("segment-{i}")).collect();
        serde_json::json!({
            "format": NALBIND_FORMAT, "schemaVersion": 3, "name": text(200),
            "notation": text(200), "stitchName": text(200), "notes": "a\n".repeat(1_000_000),
            "recipe": {"fit": (0..100).map(|_| measure()).collect::<Vec<_>>(),
                "segments": segments, "done": done, "lastSegmentNumber": 999_999_999},
        })
        .to_string()
    }

    #[test]
    fn the_largest_project_is_well_within_the_value_limit() {
        let text = largest();
        let values = count_values(&text);
        assert!(values * 4 <= MAX_VALUES, "{values} values");
        assert!(within_value_limit(&text));
    }

    #[test]
    fn a_project_of_many_small_values_is_past_the_limit() {
        let at = |n: u64| {
            format!(
                "{{\"format\":\"ply.nalbind\",\"schemaVersion\":3,\"junk\":[{}]}}",
                vec!["{}"; (n - 7) as usize].join(",")
            )
        };
        assert_eq!(count_values(&at(MAX_VALUES)), MAX_VALUES);
        assert!(within_value_limit(&at(MAX_VALUES)));
        assert!(!within_value_limit(&at(MAX_VALUES + 1)));
        assert!(within_value_limit(r#"{"name":"Mitten"}"#));
        // A lone surrogate, as Dart's jsonEncode writes one, is just text to the count.
        assert!(within_value_limit(
            r#"{"name":"\ud83d","notes":"a\udc00b"}"#
        ));
        assert_eq!(count_values(r#"{"name":"\ud83d","notes":"a\udc00b"}"#), 5);
    }

    #[test]
    fn a_huge_project_under_small_keys_is_read_by_its_keys() {
        let mut text = String::from(r#"{"format":"ply.nalbind","schemaVersion":9,"notes":["#);
        while text.len() < 8 * 1024 * 1024 {
            text.push_str("{},");
        }
        text.push_str("{}]}");
        assert_eq!(schema_version(&text).unwrap(), 9);
    }
}
