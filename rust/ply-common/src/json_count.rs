//! How many values a JSON text holds, counted without decoding it.
//!
//! Decoding JSON into a generic tree (a `serde_json::Value`, Dart's `jsonDecode`) takes memory for
//! every value, and many small values take far more than their text: a few megabytes of `{},{},...`
//! decode to hundreds of megabytes. A reader that decodes untrusted files into such a tree can ask
//! [`count_values`] first and refuse a file with more values than any honest one has. The count
//! bounds decode memory only roughly (a value's cost depends on its kind), so a limit built on it is
//! a guard against the blowup, not an exact budget.
//!
//! **What it counts:** every object, list, string, number, `true`, `false` and `null`, and every
//! object key (a key is a string). `{"a": [1, 2]}` has five: the object, the key, the list, and two
//! numbers.
//!
//! **How:** one pass over the bytes, allocating nothing and never recursing, so a file nested
//! however deep is counted like any other. String contents are skipped (an escape is two bytes, so a
//! `\"` never ends a string, and nothing is decoded: a lone surrogate escape such as `\ud83d`, which
//! Dart's `jsonEncode` writes, is skipped like any other); a number or a literal is skipped as one
//! run of characters, however long. The text is not checked: a malformed one gets a count too, and
//! the reader that decodes it refuses it.

/// The number of JSON values in `text` (see the module docs).
pub fn count_values(text: &str) -> u64 {
    let b = text.as_bytes();
    let mut count = 0u64;
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'"' => {
                count += 1;
                i += 1;
                while i < b.len() {
                    match b[i] {
                        b'\\' => i += 2,
                        b'"' => {
                            i += 1;
                            break;
                        }
                        _ => i += 1,
                    }
                }
            }
            b'{' | b'[' => {
                count += 1;
                i += 1;
            }
            c if c == b'-' || c.is_ascii_alphanumeric() => {
                // A number, `true`, `false` or `null`: one value however long.
                count += 1;
                i += 1;
                while i < b.len()
                    && (b[i].is_ascii_alphanumeric() || matches!(b[i], b'.' | b'+' | b'-'))
                {
                    i += 1;
                }
            }
            _ => i += 1,
        }
    }
    count
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_value_and_key_counts_once() {
        assert_eq!(count_values(""), 0);
        assert_eq!(count_values("0"), 1);
        assert_eq!(count_values("[]"), 1);
        assert_eq!(count_values("{}"), 1);
        assert_eq!(count_values(r#"{"a": [1, 2]}"#), 5);
        assert_eq!(count_values(r#"[true, false, null, -1.5e+10, 0]"#), 6);
        assert_eq!(count_values(r#"{"a":{},"b":[],"c":"x"}"#), 7);
        assert_eq!(count_values(" [ {} , {} ] \n"), 3);
        // A list of n empty objects is n + 1 values.
        assert_eq!(count_values(&format!("[{}{{}}]", "{},".repeat(999))), 1001);
    }

    #[test]
    fn string_contents_and_long_tokens_count_as_one() {
        // Brackets, quotes and digits inside a string are text, not values.
        assert_eq!(count_values(r#"["a, [b], {c}: 1 \"2\" 3"]"#), 2);
        assert_eq!(count_values(r#"["\\", "x"]"#), 3); // an escaped backslash ends with the string
        assert_eq!(count_values(r#"["é\n\t\/"]"#), 2);
        // A lone surrogate, as Dart's jsonEncode writes it, is skipped like any escape.
        assert_eq!(count_values(r#"{"notes":"\ud83d","name":"x\udc00y"}"#), 5);
        // Non-ASCII text in a string.
        assert_eq!(count_values("[\"caf\u{e9} \u{4e2d}\u{1f600}\"]"), 2);
        // A number of any length is one value, read without copying it.
        let long = format!("[{}, 1]", "9".repeat(100_000));
        assert_eq!(count_values(&long), 3);
    }

    #[test]
    fn nesting_of_any_depth_is_counted_without_recursion() {
        let deep = format!("{}{}", "[".repeat(1_000_000), "]".repeat(1_000_000));
        assert_eq!(count_values(&deep), 1_000_000);
    }

    #[test]
    fn a_malformed_text_is_counted_without_complaint() {
        assert_eq!(count_values(r#"{"unterminated"#), 2);
        assert_eq!(count_values("not json"), 2);
        assert_eq!(count_values("\"\\"), 1); // an escape at the very end
    }
}
