//! Shared helpers for the crochet engine's integration tests: short builders for patterns, and the
//! resolved model printed in ADR 0022's own notation (`F9`, `2.0^`, `sp 3.8`, `4.8/BL`), so expected
//! values can be transcribed from the ADR's hand-worked tables rather than from the engine.

#![allow(dead_code)]

use ply_crochet::*;

pub const B0: Basic = Basic::B0;
pub const B1H: Basic = Basic::B1H;
pub const B1: Basic = Basic::B1;
pub const B2: Basic = Basic::B2;
pub const B3: Basic = Basic::B3;

pub fn ns() -> Target {
    Target::NEXT_STITCH
}
pub fn nsp() -> Target {
    Target::NEXT_SPACE
}
pub fn nch() -> Target {
    Target::NEXT_CHAIN
}
pub fn same() -> Target {
    Target::SAME
}

pub fn st(b: Basic, t: Target) -> Instr {
    Instr::stitch(b, t)
}
pub fn sts(b: Basic, t: Target, n: u32) -> Instr {
    Instr::stitches(b, t, n)
}
pub fn ch(n: u32) -> Instr {
    Instr::chain(n)
}
pub fn sk(n: u32) -> Instr {
    Instr::skip(n, PosKind::Stitch)
}

/// A starting chain of new chains that does not count.
pub fn ch_none(n: u32) -> Instr {
    Instr::start(n, CountsAs::Nothing)
}
/// A starting chain of new chains that counts as `b`.
pub fn ch_as(n: u32, b: Basic) -> Instr {
    Instr::start(n, CountsAs::Stitch(b))
}

pub fn row(work: Vec<Instr>) -> LayerKind {
    LayerKind::Row { work }
}
pub fn joined(work: Vec<Instr>) -> LayerKind {
    LayerKind::Round {
        close: Close::Join,
        turn: false,
        work,
    }
}
pub fn joined_turned(work: Vec<Instr>) -> LayerKind {
    LayerKind::Round {
        close: Close::Join,
        turn: true,
        work,
    }
}
pub fn spiral(work: Vec<Instr>) -> LayerKind {
    LayerKind::Round {
        close: Close::Spiral,
        turn: false,
        work,
    }
}

/// A piece from its start and its layers (with their stated counts), US source terms.
pub fn piece(start: PieceStart, layers: Vec<(LayerKind, Option<StatedCount>)>) -> CrochetPattern {
    let mut p = CrochetPattern::new(start);
    p.source_terms = Terms::Us;
    for (kind, stated) in layers {
        p.push(kind, stated);
    }
    p
}

pub fn stitches(n: u32) -> Option<StatedCount> {
    Some(StatedCount::stitches(n))
}

pub fn resolve_all(p: &CrochetPattern) -> ResolvedWindow {
    match try_resolve_all(p, &CrochetLimits::DEFAULT) {
        Ok(w) => w,
        Err(e) => panic!("the pattern should resolve: {e}\n{e:?}"),
    }
}

/// An item's identity in a compact form: `b0`, `fb0` (foundation), `tog(b0x2)`, `sl`, `ch2` (a run),
/// `opaque`, and for a starting chain `ch3=b1`, `ch4=b1+sp1`, `ch1=none`, with `@F9-F11` for the
/// foundation chains a form (a) chain is made of.
pub fn what(m: &Made) -> String {
    match *m {
        Made::StartChain {
            chains,
            counts,
            space,
            taken,
            ..
        } => {
            let mut s = format!("ch{chains}=");
            match counts {
                None => s.push_str("none"),
                Some(Counted::Basic(b)) => s.push_str(b.word()),
                Some(Counted::Slip) => s.push_str("sl"),
            }
            if let Some(m) = space {
                s.push_str(&format!("+sp{m}"));
            }
            if let Some((a, b)) = taken {
                s.push_str(&format!("@F{a}-F{b}"));
            }
            s
        }
        Made::Foundation(b) => format!("f{}", b.word()),
        Made::Stitch(b) => b.word().to_string(),
        Made::Together { stitch, legs } => format!("tog({}x{legs})", stitch.word()),
        Made::Slip => "sl".to_string(),
        Made::ChainRun { chains } => format!("ch{chains}"),
        Made::Opaque => "opaque".to_string(),
    }
}

/// An item's anchors in the ADR's notation, joined with ", ".
pub fn anchors(m: &MadeItem) -> String {
    m.anchors
        .iter()
        .map(|a| a.to_string())
        .collect::<Vec<_>>()
        .join(", ")
}

/// Every item of a layer as (item number, identity, anchors).
pub fn items(l: &ResolvedLayer) -> Vec<(u32, String, String)> {
    l.made
        .iter()
        .map(|m| (m.id.item, what(&m.made), anchors(m)))
        .collect()
}

/// Build an expected item row.
pub fn it(n: u32, w: &str, a: &str) -> (u32, String, String) {
    (n, w.to_string(), a.to_string())
}

/// A layer's base as (position, use), in the order met.
pub fn base(l: &ResolvedLayer) -> Vec<(String, BaseUse)> {
    l.base_slots()
        .iter()
        .map(|s| (s.position.at.to_string(), s.used))
        .collect()
}

/// A layer's base positions only.
pub fn base_order(l: &ResolvedLayer) -> Vec<String> {
    base(l).into_iter().map(|(p, _)| p).collect()
}

/// Every diagnostic as (code, layer, item).
pub fn keys(ds: &[Diagnostic]) -> Vec<(&'static str, Option<u32>, Option<u32>)> {
    ds.iter()
        .map(|d| (d.code.as_str(), d.location.layer, d.location.item))
        .collect()
}

/// Just the codes.
pub fn codes(ds: &[Diagnostic]) -> Vec<&'static str> {
    ds.iter().map(|d| d.code.as_str()).collect()
}

/// The derived count of a layer in both label sets (rule W17).
pub fn count_texts(l: &ResolvedLayer) -> (String, String) {
    (
        LabelSet::US.count_text(l.count.as_ref()),
        LabelSet::UK.count_text(l.count.as_ref()),
    )
}

/// A list of positions in the ADR's notation.
pub fn refs(ps: &[PosRef]) -> Vec<String> {
    ps.iter().map(|p| p.to_string()).collect()
}

/// The moves (joins, travels) of a layer as (role, anchor, items made before it).
pub fn moves(l: &ResolvedLayer) -> Vec<(SlipRole, String, u32)> {
    l.moves
        .iter()
        .map(|m| (m.role, m.anchor.to_string(), m.after))
        .collect()
}
