//! Double-weave construction (roadmap M8-09, ADR 0010): what happens at each selvedge of a
//! two-layer cloth, DERIVED from the draft's explicit working data, and the construction a weaver
//! declares (two independent layers, a tube, or double width with a fold).
//!
//! The threading, tie-up and treadling cannot tell these apart: the same top, bottom, top, bottom
//! picks weave two separate layers with two shuttles and a tube with one (see the
//! double-weave research note). What decides it is the path of each weft, so the edges are derived from the pick
//! roles (top layer or bottom layer), the shuttles, and each shuttle's starting side, and from nothing
//! else. Missing data makes the edges unknown; nothing is inferred from sheds or colors.
//!
//! **The edge rule.** Every pass ends at one edge, where its shuttle turns (each shuttle alternates its
//! own direction, see [`Draft::pass_starts`]). If that shuttle's next pick is on the OTHER layer, the
//! weft carries from one layer into the other there, so the turn joins the layers at that edge (a fold,
//! or a closed edge). If the next pick is on the SAME layer, the weft turns back into its own layer:
//! that is the layer's own selvedge, open. A shuttle's last pick has no turn.

use crate::draft::{Draft, PickRole, ShuttleId, Side};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// How a two-layer cloth is constructed, as the weaver declares it (or a generator sets it). A label
/// that validation checks against the derived edges; never inferred from the draft on its own.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Construction {
    /// Two separate cloths, one above the other: every weft stays in its layer, so both edges are
    /// open (four selvedges). Each layer has its own shuttle.
    TwoLayers,
    /// One cloth woven round and round: every turn passes from one layer to the other, so both edges
    /// are joined.
    Tube,
    /// One cloth twice the width, folded on the loom: the layers join at the fold and are open
    /// (two selvedges) at the other edge.
    DoubleWidth {
        /// The edge where the layers join, as the weaver sits at the front of the loom.
        fold: Side,
    },
}

impl Construction {
    /// What this construction expects at `side`: [`EdgeBehavior::Joined`] or [`EdgeBehavior::Open`].
    pub fn expected(self, side: Side) -> EdgeBehavior {
        match self {
            Construction::TwoLayers => EdgeBehavior::Open,
            Construction::Tube => EdgeBehavior::Joined,
            Construction::DoubleWidth { fold } if fold == side => EdgeBehavior::Joined,
            Construction::DoubleWidth { .. } => EdgeBehavior::Open,
        }
    }

    /// The construction in a sentence: "two independent layers", "a tube", "double width with the
    /// fold on the left".
    pub fn describe(self) -> String {
        match self {
            Construction::TwoLayers => "two independent layers".to_string(),
            Construction::Tube => "a tube".to_string(),
            Construction::DoubleWidth { fold } => {
                format!("double width with the fold on the {}", side_word(fold))
            }
        }
    }
}

/// What the turns at one edge do, summarized.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum EdgeBehavior {
    /// No shuttle turns at this edge (too few picks to tell).
    NoTurns,
    /// Every turn here stays in its layer: each layer has its own selvedge.
    Open,
    /// Every turn here passes from one layer to the other: a fold or a closed edge.
    Joined,
    /// Some turns here join the layers and some do not.
    Mixed,
}

/// One turn of a shuttle: the pass of pick `from` ended at `side`, and the same shuttle's next pass is
/// pick `to` (0-based picks). `joins` when the two picks are on different layers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Turn {
    pub from: usize,
    pub to: usize,
    pub shuttle: ShuttleId,
    pub side: Side,
    pub joins: bool,
}

/// Why the edges cannot be derived. Checked in this order; the first that applies is reported.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MissingEdgeData {
    /// The draft has no picks.
    NoPicks,
    /// These 0-based picks are not marked top layer or bottom layer.
    NoLayerRole(Vec<usize>),
    /// These 0-based picks have no shuttle.
    NoShuttle(Vec<usize>),
    /// These shuttles carry picks but have no starting side, so their directions are unknown.
    NoStartingSide(Vec<ShuttleId>),
}

/// The derived edges of a two-layer draft.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Edges {
    pub left: EdgeBehavior,
    pub right: EdgeBehavior,
    /// Every turn, in the order of the pick that ends it.
    pub turns: Vec<Turn>,
    /// How many picks weave each layer.
    pub top_picks: usize,
    pub bottom_picks: usize,
}

impl Edges {
    /// The summary at `side`.
    pub fn at(&self, side: Side) -> EdgeBehavior {
        match side {
            Side::Left => self.left,
            Side::Right => self.right,
        }
    }

    /// The construction these edges are EXACTLY, or `None`: when either edge is mixed or has no turns,
    /// or every pick is on one layer. Two open edges are two independent layers, two joined edges a
    /// tube, one of each double width with the fold on the joined edge.
    pub fn construction(&self) -> Option<Construction> {
        if self.top_picks == 0 || self.bottom_picks == 0 {
            return None;
        }
        use EdgeBehavior::{Joined, Open};
        match (self.left, self.right) {
            (Open, Open) => Some(Construction::TwoLayers),
            (Joined, Joined) => Some(Construction::Tube),
            (Joined, Open) => Some(Construction::DoubleWidth { fold: Side::Left }),
            (Open, Joined) => Some(Construction::DoubleWidth { fold: Side::Right }),
            _ => None,
        }
    }
}

/// Derive what happens at each edge from the pick roles, shuttles, and starting sides (see the module
/// doc for the rule). `Err` names what is missing: every pick needs a top-layer or bottom-layer role
/// and a shuttle, and every shuttle a starting side.
pub fn derive_edges(draft: &Draft) -> Result<Edges, MissingEdgeData> {
    let picks = draft.picks();
    if picks == 0 {
        return Err(MissingEdgeData::NoPicks);
    }
    let layer = |p: usize| match draft.pick_role(p) {
        PickRole::TopLayer => Some(true),
        PickRole::BottomLayer => Some(false),
        _ => None,
    };
    let no_role: Vec<usize> = (0..picks).filter(|&p| layer(p).is_none()).collect();
    if !no_role.is_empty() {
        return Err(MissingEdgeData::NoLayerRole(no_role));
    }
    let no_shuttle: Vec<usize> = (0..picks).filter(|&p| draft.shuttle(p).is_none()).collect();
    if !no_shuttle.is_empty() {
        return Err(MissingEdgeData::NoShuttle(no_shuttle));
    }
    let unsided: Vec<ShuttleId> = (0..picks)
        .filter_map(|p| draft.shuttle(p))
        .collect::<BTreeSet<_>>()
        .into_iter()
        .filter(|s| !draft.weft_work.shuttle_starts.contains_key(s))
        .collect();
    if !unsided.is_empty() {
        return Err(MissingEdgeData::NoStartingSide(unsided));
    }

    // Every pick has a shuttle and every shuttle a starting side, so every pass has a direction.
    let starts = draft.pass_starts();
    let mut last: BTreeMap<ShuttleId, usize> = BTreeMap::new();
    let mut turns = Vec::new();
    for p in 0..picks {
        let Some(shuttle) = draft.shuttle(p) else {
            continue;
        };
        if let Some(&prev) = last.get(&shuttle) {
            if let Some(start) = starts[prev] {
                turns.push(Turn {
                    from: prev,
                    to: p,
                    shuttle,
                    side: start.other(),
                    joins: layer(prev) != layer(p),
                });
            }
        }
        last.insert(shuttle, p);
    }
    let summary = |side: Side| {
        let mut at = turns.iter().filter(|t| t.side == side).peekable();
        if at.peek().is_none() {
            return EdgeBehavior::NoTurns;
        }
        let (mut joins, mut opens) = (false, false);
        for t in at {
            joins |= t.joins;
            opens |= !t.joins;
        }
        match (joins, opens) {
            (true, false) => EdgeBehavior::Joined,
            (false, true) => EdgeBehavior::Open,
            _ => EdgeBehavior::Mixed,
        }
    };
    let top_picks = (0..picks).filter(|&p| layer(p) == Some(true)).count();
    Ok(Edges {
        left: summary(Side::Left),
        right: summary(Side::Right),
        turns,
        top_picks,
        bottom_picks: picks - top_picks,
    })
}

/// Where the declared construction and the derived edges disagree, in plain words; empty when there
/// is no declared construction or it matches. Validation reports each line as a warning.
pub fn construction_issues(draft: &Draft) -> Vec<String> {
    let Some(construction) = draft.weft_work.construction else {
        return Vec::new();
    };
    let edges = match derive_edges(draft) {
        Ok(edges) => edges,
        Err(missing) => {
            return vec![format!(
                "This draft is marked as {}, but Ply cannot check its edges because {}.",
                construction.describe(),
                missing_reason(&missing)
            )]
        }
    };
    if edges.top_picks == 0 || edges.bottom_picks == 0 {
        let layer = if edges.top_picks == 0 {
            "bottom"
        } else {
            "top"
        };
        return vec![format!(
            "This draft is marked as {}, but every pick is on the {layer} layer, so there is only \
             one layer.",
            construction.describe()
        )];
    }
    let intro = match construction {
        Construction::TwoLayers => {
            "Two independent layers should be open at both edges".to_string()
        }
        Construction::Tube => "A tube should join the layers at both edges".to_string(),
        Construction::DoubleWidth { fold } => {
            format!("The fold should be on the {}", side_word(fold))
        }
    };
    let mut out = Vec::new();
    for side in [Side::Left, Side::Right] {
        let expected = construction.expected(side);
        // The turns that go against the expectation at this edge. An edge with no turns yet (a very
        // short draft) has nothing to contradict the label, so it is not reported.
        let wrong: Vec<&Turn> = edges
            .turns
            .iter()
            .filter(|t| t.side == side && t.joins == (expected == EdgeBehavior::Open))
            .collect();
        let Some(first) = wrong.first() else {
            continue;
        };
        let more = match wrong.len() - 1 {
            0 => String::new(),
            1 => " (and at 1 more turn)".to_string(),
            n => format!(" (and at {n} more turns)"),
        };
        let verb = if expected == EdgeBehavior::Open {
            "join"
        } else {
            "do not join"
        };
        out.push(format!(
            "{intro}, but the layers {verb} on the {} between picks {} and {}{more}.",
            side_word(side),
            first.from + 1,
            first.to + 1
        ));
    }
    out
}

/// True when the derived edges agree with `construction`: both layers have picks and no turn goes
/// against it (an edge with no turns yet agrees). Weaker than [`Edges::construction`], which is the
/// exact match a construction is offered from.
pub fn agrees_with(edges: &Edges, construction: Construction) -> bool {
    edges.top_picks > 0
        && edges.bottom_picks > 0
        && edges
            .turns
            .iter()
            .all(|t| t.joins == (construction.expected(t.side) == EdgeBehavior::Joined))
}

/// The missing data in a clause: "picks 3 to 5 are not marked top layer or bottom layer".
fn missing_reason(missing: &MissingEdgeData) -> String {
    match missing {
        MissingEdgeData::NoPicks => "it has no picks".to_string(),
        MissingEdgeData::NoLayerRole(picks) => format!(
            "{} {} not marked top layer or bottom layer",
            describe_picks(picks),
            if picks.len() == 1 { "is" } else { "are" }
        ),
        MissingEdgeData::NoShuttle(picks) => format!(
            "{} {} no shuttle",
            describe_picks(picks),
            if picks.len() == 1 { "has" } else { "have" }
        ),
        MissingEdgeData::NoStartingSide(shuttles) => {
            let nums: Vec<String> = shuttles.iter().map(|s| s.0.to_string()).collect();
            match nums.split_last() {
                Some((last, rest)) if !rest.is_empty() => {
                    format!(
                        "shuttles {} and {last} have no starting side",
                        rest.join(", ")
                    )
                }
                _ => format!("shuttle {} has no starting side", nums.join("")),
            }
        }
    }
}

/// "left" or "right".
pub fn side_word(side: Side) -> &'static str {
    match side {
        Side::Left => "left",
        Side::Right => "right",
    }
}

/// 0-based picks in words, shown 1-based with runs collapsed: "pick 3", "picks 3 to 9", "picks 1, 3 to
/// 5 and 9", or "picks 1, 3, 5, 7 and 12 more" (the same reading as the Book view's pick lists).
pub fn describe_picks(picks: &[usize]) -> String {
    const SHOWN: usize = 4;
    let mut runs: Vec<(usize, usize)> = Vec::new();
    for &p in picks {
        match runs.last_mut() {
            Some(run) if run.1 + 1 == p => run.1 = p,
            _ => runs.push((p, p)),
        }
    }
    let part = |&(a, b): &(usize, usize)| {
        if a == b {
            (a + 1).to_string()
        } else {
            format!("{} to {}", a + 1, b + 1)
        }
    };
    let noun = if picks.len() == 1 { "pick" } else { "picks" };
    if runs.len() > SHOWN {
        let shown: Vec<String> = runs.iter().take(SHOWN).map(part).collect();
        let rest: usize = runs[SHOWN..].iter().map(|&(a, b)| b - a + 1).sum();
        return format!("{noun} {} and {rest} more", shown.join(", "));
    }
    let parts: Vec<String> = runs.iter().map(part).collect();
    match parts.split_last() {
        Some((last, rest)) if !rest.is_empty() => format!("{noun} {} and {last}", rest.join(", ")),
        _ => format!("{noun} {}", parts.join("")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn describe_picks_reads_naturally() {
        assert_eq!(describe_picks(&[2]), "pick 3");
        assert_eq!(describe_picks(&[2, 3, 4]), "picks 3 to 5");
        assert_eq!(describe_picks(&[0, 2, 3, 4, 8]), "picks 1, 3 to 5 and 9");
        assert_eq!(describe_picks(&[1, 3]), "picks 2 and 4");
        assert_eq!(
            describe_picks(&[0, 2, 4, 6, 8, 10, 12]),
            "picks 1, 3, 5, 7 and 3 more"
        );
    }

    #[test]
    fn expected_edges_per_construction() {
        use EdgeBehavior::{Joined, Open};
        let cases = [
            (Construction::TwoLayers, Open, Open),
            (Construction::Tube, Joined, Joined),
            (Construction::DoubleWidth { fold: Side::Left }, Joined, Open),
            (
                Construction::DoubleWidth { fold: Side::Right },
                Open,
                Joined,
            ),
        ];
        for (c, left, right) in cases {
            assert_eq!(c.expected(Side::Left), left, "{c:?}");
            assert_eq!(c.expected(Side::Right), right, "{c:?}");
        }
    }
}
