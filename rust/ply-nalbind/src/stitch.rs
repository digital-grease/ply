//! The nalbinding stitch model. A stitch TYPE is the path of the needle through the loops (a list of
//! under/over passes, in Hansen's flat-viewed convention) plus how it connects into the previous
//! round. Identity is the (passes, connections) pair TOGETHER — Mammen and Korgen share the skeleton
//! `UOO/UUOO` and differ only by their connection (F2 vs F1). The Hansen STRING is derived from this
//! model (see `notation`), never the other way around: it is lossy and non-unique, so it is a view,
//! not a key.

use serde::{Deserialize, Serialize};

use crate::error::NalbindError;

/// One step of a needle pass.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Step {
    /// Needle passes UNDER a loop (`U`).
    Under,
    /// Needle passes OVER a loop (`O`).
    Over,
    /// A SKIPPED loop the needle passes under but does not engage (`(U)`).
    SkippedUnder,
    /// A SKIPPED loop the needle passes over but does not engage (`(O)`).
    SkippedOver,
    /// No over/under engagement on this step (`-`), used by looping stitches like Coptic.
    NoEngage,
}

/// One pass of the needle between turns. A simple stitch has two passes (split by `/`); multi-turn
/// stitches (Åsle, Omani) have three or more (further `:` turns).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Pass {
    pub steps: Vec<Step>,
}

impl Pass {
    pub fn new(steps: Vec<Step>) -> Self {
        Pass { steps }
    }
}

/// Which face of the previous round the connection pierces.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ConnSide {
    /// `F` — needle enters the previous-round loop from the front (front→back).
    Front,
    /// `B` — needle enters from the back (back→front).
    Back,
    /// `M`/`Mid` — a middle/center connection (less standardized).
    Middle,
}

/// How a new loop anchors into the previous round. `F2` = front, count 2 (one new loop + one old
/// connection loop → a denser join). Hansen captures only the common case; the academic survey
/// documents 150+ real connection types, so [`extra`](Connection::extra) is an escape hatch for ones
/// the `side + count` form cannot express.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Connection {
    pub side: ConnSide,
    pub count: u8,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub extra: Option<String>,
}

impl Connection {
    pub fn new(side: ConnSide, count: u8) -> Self {
        Connection { side, count, extra: None }
    }
}

/// Loops can be crossed/twisted; the flat Hansen string does not record chirality, so it is a
/// separate attribute.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum Twist {
    #[default]
    Untwisted,
    Twisted,
}

/// A published Hansen code for a stitch, with its source. Sources DISAGREE (York is given as `F1` or
/// `F2`; Dalby strings vary), so a stitch carries several attributed strings rather than asserting one
/// canonical code.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PublishedCode {
    pub code: String,
    pub source: String,
}

/// A nalbinding stitch type — the unit of the stitch dictionary and the notation playground.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StitchType {
    /// Display name, e.g. "Oslo". Empty for an anonymous parsed-from-notation stitch.
    pub name: String,
    /// The needle path: one [`Pass`] per segment between turns.
    pub passes: Vec<Pass>,
    /// Zero or more connections into the previous round (Åsle has two: `B1 F1`).
    #[serde(default)]
    pub connections: Vec<Connection>,
    /// The `a+b(+c)` thumb-loop-group alias the community also uses (Oslo = 1+1), if known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thumb_loops: Option<(u8, u8)>,
    #[serde(default)]
    pub twist: Twist,
    #[serde(default)]
    pub also_known_as: Vec<String>,
    /// Source-attributed published Hansen strings (sources disagree; we keep them all).
    #[serde(default)]
    pub codes: Vec<PublishedCode>,
    /// Free text — a one-line description, or the whole definition for a stitch that resists Hansen.
    #[serde(default)]
    pub note: String,
}

impl StitchType {
    /// An anonymous stitch from parsed passes + connections (the notation playground's output).
    pub fn anonymous(passes: Vec<Pass>, connections: Vec<Connection>) -> Self {
        StitchType {
            name: String::new(),
            passes,
            connections,
            thumb_loops: None,
            twist: Twist::default(),
            also_known_as: Vec::new(),
            codes: Vec::new(),
            note: String::new(),
        }
    }

    pub fn to_json(&self) -> Result<String, NalbindError> {
        Ok(serde_json::to_string_pretty(self)?)
    }

    pub fn from_json(s: &str) -> Result<Self, NalbindError> {
        Ok(serde_json::from_str(s)?)
    }
}
