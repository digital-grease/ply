//! Where a number came from (roadmap contract 10.3, ADR 0016). Every value Ply stores in a material
//! or swatch record, and every input to a planning estimate, carries a [`Source`]: the crafter
//! **measured** it, **entered** it from somewhere else (a ball band, a pattern, their own setup), or
//! it is Ply's **default** (a rule of thumb). An estimate lists each input with its source in plain
//! words ([`TracedInput`]), so the crafter can see exactly which numbers are theirs and which were
//! assumed.
//!
//! A stored record never holds a default: defaults are filled in when an estimate is worked out and
//! are never written back over a measurement.

use serde::{Deserialize, Serialize};

/// Where a value came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Source {
    /// The crafter measured it (counted, wrapped, weighed, measured with a ruler).
    Measured,
    /// The crafter typed it from somewhere else: a ball band, a pattern, their own loom setup.
    Entered,
    /// Ply's default or rule of thumb, used because nothing better was given.
    Default,
}

impl Source {
    /// "measured", "entered", "default".
    pub fn as_str(self) -> &'static str {
        match self {
            Source::Measured => "measured",
            Source::Entered => "entered",
            Source::Default => "default",
        }
    }
}

/// A stored value with its source.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Recorded<T> {
    pub value: T,
    pub source: Source,
}

impl<T> Recorded<T> {
    pub const fn measured(value: T) -> Recorded<T> {
        Recorded {
            value,
            source: Source::Measured,
        }
    }

    pub const fn entered(value: T) -> Recorded<T> {
        Recorded {
            value,
            source: Source::Entered,
        }
    }
}

/// One input of a planning estimate, as the estimate shows it: "Stitch gauge: 20 sts over 10 cm,
/// measured after finishing (washed, dried flat), swatch Grey wool 2026-11-10".
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct TracedInput {
    /// A stable key for tests and the UI ("stitch_gauge", "sett", "length_allowance", ...).
    pub key: String,
    /// What the input is, for the list ("Stitch gauge").
    pub label: String,
    /// The value as used, with its unit ("20 sts over 10 cm").
    pub value: String,
    pub source: Source,
    /// Where it came from, in words ("measured after finishing, swatch Grey wool 2026-11-10",
    /// "you entered it", "Ply's default for DK").
    pub basis: String,
    /// The swatch it came from, when it came from one.
    pub swatch_id: Option<String>,
    /// The material it came from, when it came from one.
    pub material_id: Option<String>,
}

impl TracedInput {
    /// An input the crafter typed.
    pub fn entered(key: &str, label: &str, value: String) -> TracedInput {
        TracedInput {
            key: key.to_string(),
            label: label.to_string(),
            value,
            source: Source::Entered,
            basis: "you entered it".to_string(),
            swatch_id: None,
            material_id: None,
        }
    }

    /// One of Ply's defaults, with what it is a default for ("for DK, from 11 wraps per inch").
    pub fn default(key: &str, label: &str, value: String, detail: &str) -> TracedInput {
        let detail = detail.trim();
        TracedInput {
            key: key.to_string(),
            label: label.to_string(),
            value,
            source: Source::Default,
            basis: if detail.is_empty() {
                "Ply's default".to_string()
            } else {
                format!("Ply's default {detail}")
            },
            swatch_id: None,
            material_id: None,
        }
    }

    /// "20 sts over 10 cm, measured after finishing, swatch Grey wool 2026-11-10".
    pub fn sentence(&self) -> String {
        format!("{}, {}", self.value, self.basis)
    }
}

/// A planning result with every input it used and how it was worked out.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Traced<T> {
    pub value: T,
    /// Each input with its source, in the order the working uses them.
    pub inputs: Vec<TracedInput>,
    /// The arithmetic in words, one step per line ("(20 in + 2 in) x 5 sts per in = 110 sts").
    pub working: Vec<String>,
    /// Caveats the crafter should know ("measured before finishing: the finished size may differ").
    pub notes: Vec<String>,
}

impl<T> Traced<T> {
    /// Whether any input is one of Ply's defaults (the estimate then says so).
    pub fn has_defaults(&self) -> bool {
        self.inputs.iter().any(|i| i.source == Source::Default)
    }
}

/// Where one input of a planning request comes from. The estimate reads a [`Origin::Swatch`] input
/// from the swatch itself (never from a number the UI rounded), and words every other origin from
/// what the caller says.
#[derive(Debug, Clone, PartialEq)]
pub enum Origin<T> {
    /// Taken from the request's swatch (its own measurement, at the stage the estimate chooses).
    Swatch,
    /// Typed by the crafter.
    Entered(T),
    /// One of Ply's defaults or rules of thumb; the text says what for ("for DK, from 11 wraps per
    /// inch").
    Default(T, String),
    /// Read from the open pattern or draft (its ends, its gauge); the text says what it is ("this
    /// draft's ends").
    Pattern(T, String),
}

impl<T: Copy> Origin<T> {
    /// The value and its traced input, for every origin but [`Origin::Swatch`] (which the estimate
    /// resolves itself). `describe` writes the value with its unit.
    pub fn traced(
        &self,
        key: &str,
        label: &str,
        describe: impl Fn(T) -> String,
    ) -> Option<(T, TracedInput)> {
        match self {
            Origin::Swatch => None,
            Origin::Entered(v) => Some((*v, TracedInput::entered(key, label, describe(*v)))),
            Origin::Default(v, detail) => {
                Some((*v, TracedInput::default(key, label, describe(*v), detail)))
            }
            Origin::Pattern(v, what) => Some((
                *v,
                TracedInput {
                    key: key.to_string(),
                    label: label.to_string(),
                    value: describe(*v),
                    source: Source::Entered,
                    basis: if what.trim().is_empty() {
                        "from the pattern".to_string()
                    } else {
                        format!("from {}", what.trim())
                    },
                    swatch_id: None,
                    material_id: None,
                },
            )),
        }
    }
}

/// Why a planning estimate cannot be worked out: a missing or unusable input, named in plain words.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlanProblem(pub String);

impl std::fmt::Display for PlanProblem {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for PlanProblem {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sentences_name_the_source() {
        let i = TracedInput::default(
            "stitch_gauge",
            "Stitch gauge",
            "22 sts over 10 cm".into(),
            "for DK",
        );
        assert_eq!(i.sentence(), "22 sts over 10 cm, Ply's default for DK");
        assert_eq!(i.source, Source::Default);
        let e = TracedInput::entered("width", "Finished width", "20 in".into());
        assert_eq!(e.sentence(), "20 in, you entered it");
        let t = Traced {
            value: 1,
            inputs: vec![i, e],
            working: vec![],
            notes: vec![],
        };
        assert!(t.has_defaults());
    }

    #[test]
    fn sources_serialize_in_lowercase() {
        assert_eq!(
            serde_json::to_string(&Source::Measured).unwrap(),
            "\"measured\""
        );
        let r: Recorded<f64> = serde_json::from_str(r#"{"value":2.5,"source":"entered"}"#).unwrap();
        assert_eq!(r, Recorded::entered(2.5));
        assert!(
            serde_json::from_str::<Recorded<f64>>(r#"{"value":2.5,"source":"guess"}"#).is_err()
        );
    }
}
