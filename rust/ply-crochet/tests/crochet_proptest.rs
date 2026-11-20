//! Property-based hardening of the crochet engine (ADR 0022). Over generated patterns:
//!
//! * arbitrary patterns (wrong starts, misplaced chains and joins, markers and use-site targets in
//!   the wrong place, zero and huge counts, legends with cycles and colliding words, tight limits):
//!   `validate` and `try_resolve_all` never panic and are deterministic;
//! * on patterns that resolve:
//!   - counts after each layer equal what validation checks: stating every derived count gives no
//!     `crochet.count_mismatch`, and stating one wrongly gives exactly one, at that layer, with the
//!     derived count in its detail;
//!   - every anchor that names a base position names one the layer worked;
//!   - the positions a layer leaves not reached are exactly what `crochet.base_unfinished` reports;
//!   - an opaque instruction never contributes counted stitches it does not state: a layer's
//!     "not checked" positions are its opaque items, each opaque instruction makes exactly its
//!     `makes`, and one that states neither leaves its layer and every later one unknown;
//!   - a window is the same layers as the whole piece;
//! * label sets never change an operation: the count phrase in US terms and in UK terms read back,
//!   each with its own set, to the same identities and numbers, and each set names every identity
//!   once.
//!
//! Run: `cargo test -p ply-crochet --test crochet_proptest`

mod common;

use common::*;
use ply_crochet::*;
use proptest::prelude::*;

fn arb_basic() -> impl Strategy<Value = Basic> {
    prop::sample::select(Basic::ALL.to_vec())
}

fn arb_kind() -> impl Strategy<Value = PosKind> {
    prop::sample::select(vec![
        PosKind::Stitch,
        PosKind::Stitch,
        PosKind::Space,
        PosKind::Chain,
        PosKind::Any,
    ])
}

fn arb_part() -> impl Strategy<Value = Option<PartSpec>> {
    prop_oneof![
        8 => Just(None),
        1 => Just(Some(PartSpec::Top(Part::FrontLoop))),
        1 => Just(Some(PartSpec::Top(Part::BackLoop))),
        1 => Just(Some(PartSpec::Top(Part::Both))),
        1 => Just(Some(PartSpec::Chain(ChainPart::TopLoop))),
        1 => Just(Some(PartSpec::Chain(ChainPart::BackBump))),
    ]
}

/// A target; `wild` adds the targets the structural check refuses outside their place.
fn arb_target(wild: bool) -> BoxedStrategy<Target> {
    let tame = prop_oneof![
        6 => (arb_kind(), arb_part()).prop_map(|(kind, part)| Target::Next { kind, part }),
        2 => arb_part().prop_map(|part| Target::Same { part }),
        1 => Just(Target::Ring),
        1 => (0u32..3).prop_map(|c| Target::unmodelled("around the post", c)),
    ];
    if wild {
        prop_oneof![
            8 => tame,
            1 => Just(Target::RoundStart),
            1 => Just(Target::marker("A")),
            1 => Just(Target::UseSite),
        ]
        .boxed()
    } else {
        tame.boxed()
    }
}

/// A count: small and valid, or (when wild) 0 or huge.
fn arb_n(wild: bool, max: u32) -> BoxedStrategy<u32> {
    if wild {
        prop_oneof![
            8 => 1..=max,
            1 => Just(0u32),
            1 => Just(u32::MAX),
            1 => Just(100_000u32),
        ]
        .boxed()
    } else {
        (1..=max).boxed()
    }
}

fn arb_leaf(wild: bool) -> BoxedStrategy<Instr> {
    prop_oneof![
        6 => (arb_basic(), arb_target(wild), arb_n(wild, 3))
            .prop_map(|(b, t, n)| Instr::stitches(b, t, n)),
        2 => arb_n(wild, 3).prop_map(Instr::chain),
        2 => (arb_n(wild, 2), arb_kind()).prop_map(|(n, k)| Instr::skip(n, k)),
        2 => (arb_basic(), prop::collection::vec(arb_target(wild), if wild { 0..10 } else { 2..4 }))
            .prop_map(|(b, legs)| Instr::tog(b, legs)),
        1 => (prop::option::of(0u32..3), prop::option::of(0u32..3))
            .prop_map(|(c, m)| Instr::opaque("popcorn", c, m)),
        1 => (prop::sample::select(vec!["inc", "pc"]), arb_target(wild))
            .prop_map(|(id, t)| Instr::named(id, Some(t))),
        1 => arb_target(wild).prop_map(Instr::slip),
        1 => arb_target(wild).prop_map(Instr::travel),
        1 => (arb_basic(), arb_target(wild)).prop_map(|(b, t)| Instr::stitch(b, t).marked("M")),
    ]
    .boxed()
}

fn arb_count(wild: bool) -> BoxedStrategy<RepeatCount> {
    if wild {
        prop_oneof![
            3 => (1u32..4).prop_map(RepeatCount::Times),
            1 => Just(RepeatCount::Times(0)),
            1 => Just(RepeatCount::Times(u32::MAX)),
            2 => Just(RepeatCount::ToEnd),
            1 => (0u32..4).prop_map(RepeatCount::ToLast),
        ]
        .boxed()
    } else {
        prop_oneof![
            3 => (1u32..4).prop_map(RepeatCount::Times),
            2 => Just(RepeatCount::ToEnd),
            1 => (0u32..3).prop_map(RepeatCount::ToLast),
        ]
        .boxed()
    }
}

fn arb_list(wild: bool) -> BoxedStrategy<Vec<Instr>> {
    let leaf = arb_leaf(wild);
    let tree = leaf.prop_recursive(3, 24, 3, move |inner| {
        prop_oneof![
            3 => arb_leaf(wild),
            1 => (arb_count(wild), prop::collection::vec(inner, 1..3))
                .prop_map(|(count, body)| Instr::Repeat { body, count }),
        ]
    });
    prop::collection::vec(tree, 0..5).boxed()
}

fn arb_start_chain(wild: bool) -> BoxedStrategy<Option<Instr>> {
    let counts = prop_oneof![
        3 => Just(CountsAs::Nothing),
        2 => arb_basic().prop_map(CountsAs::Stitch),
        1 => (arb_basic(), 1u32..3).prop_map(|(stitch, chains)| CountsAs::StitchAndSpace { stitch, chains }),
    ];
    let max = if wild { 0u32 } else { 1 };
    prop::option::of(
        (max..5, counts, any::<bool>()).prop_map(move |(c, ca, ff)| {
            Instr::Start(StartChain {
                chains: c,
                counts_as: ca,
                from_foundation: ff && wild,
            })
        }),
    )
    .boxed()
}

/// One layer's instructions: an optional starting chain, a list, then an optional leave or join.
fn arb_work(wild: bool, joined: bool) -> BoxedStrategy<Vec<Instr>> {
    (
        arb_start_chain(wild),
        arb_list(wild),
        any::<bool>(),
        prop::option::of(Just("A")),
    )
        .prop_map(move |(start, mut list, leave, marker)| {
            let mut work: Vec<Instr> = start.into_iter().collect();
            work.append(&mut list);
            if joined {
                match marker {
                    Some(m) if wild => work.push(Instr::join_marker(m)),
                    _ => work.push(Instr::join()),
                }
            } else if leave {
                work.push(Instr::LeaveUnworked);
            }
            work
        })
        .boxed()
}

fn arb_stated() -> impl Strategy<Value = Option<StatedCount>> {
    prop::option::of(
        (prop::option::of(0u32..40), prop::option::of(0u32..10)).prop_map(|(s, sp)| StatedCount {
            stitches: s,
            spaces: sp,
            ..StatedCount::default()
        }),
    )
}

/// A named stitch whose body holds an opaque instruction, so the whole named stitch is opaque.
fn opaque_entry() -> LegendEntry {
    LegendEntry {
        id: LegendId::new("pc"),
        name: "popcorn shell".into(),
        abbreviation: "pc-shell".into(),
        body: vec![
            Instr::stitch(Basic::B1, Target::UseSite),
            Instr::opaque("popcorn", Some(0), Some(1)),
            Instr::stitch(Basic::B1, Target::SAME),
        ],
    }
}

fn inc_entry() -> LegendEntry {
    LegendEntry {
        id: LegendId::new("inc"),
        name: "increase".into(),
        abbreviation: "inc".into(),
        body: vec![Instr::stitches(Basic::B0, Target::UseSite, 2)],
    }
}

/// A pattern whose starts and layer kinds agree (rows on a chain or foundation stitches, rounds in a
/// ring), so most of them resolve.
fn arb_tame() -> impl Strategy<Value = CrochetPattern> {
    let start = prop_oneof![
        3 => (2u32..14).prop_map(PieceStart::FoundationChain),
        1 => Just(PieceStart::FoundationStitches),
        2 => Just(PieceStart::MagicRing),
        1 => (1u32..5).prop_map(PieceStart::ChainRing),
    ];
    (start, 1usize..5).prop_flat_map(|(start, n)| {
        let rounds = matches!(start, PieceStart::MagicRing | PieceStart::ChainRing(_));
        let layer = if rounds {
            prop_oneof![
                2 => (arb_work(false, true), any::<bool>())
                    .prop_map(|(work, turn)| LayerKind::Round { close: Close::Join, turn, work }),
                1 => arb_work(false, false)
                    .prop_map(|work| LayerKind::Round { close: Close::Spiral, turn: false, work }),
            ]
            .boxed()
        } else {
            arb_work(false, false)
                .prop_map(|work| LayerKind::Row { work })
                .boxed()
        };
        let first_work = match start {
            PieceStart::FoundationChain(_) => prop_oneof![
                Just(vec![
                    Instr::start_from_foundation(1, CountsAs::Nothing),
                    Instr::to_end(vec![Instr::stitch(Basic::B0, Target::NEXT_CHAIN)]),
                ]),
                Just(vec![
                    Instr::start(3, CountsAs::Stitch(Basic::B1)),
                    Instr::to_end(vec![Instr::stitch(Basic::B1, Target::NEXT_CHAIN)]),
                ]),
            ]
            .boxed(),
            _ => Just(Vec::new()).boxed(),
        };
        (
            Just(start),
            first_work,
            prop::collection::vec((layer, arb_stated()), n),
            1u32..8,
        )
            .prop_map(|(start, first_work, layers, f)| {
                let mut p = CrochetPattern::new(start);
                p.legend.push(inc_entry());
                p.legend.push(opaque_entry());
                match start {
                    PieceStart::FoundationStitches => {
                        p.push(
                            LayerKind::Foundation {
                                stitch: Basic::B0,
                                stitches: f,
                            },
                            None,
                        );
                    }
                    PieceStart::FoundationChain(_) => {
                        p.push(LayerKind::Row { work: first_work }, None);
                    }
                    _ => {}
                }
                for (mut kind, stated) in layers {
                    // Round 1 cannot turn, and a round after a spiral cannot either.
                    if let LayerKind::Round { turn, close, .. } = &mut kind {
                        let after_spiral = matches!(
                            p.layers.last().map(|l| &l.kind),
                            Some(LayerKind::Round {
                                close: Close::Spiral,
                                ..
                            })
                        );
                        if p.layers.is_empty() || after_spiral || *close == Close::Spiral {
                            *turn = false;
                        }
                    }
                    p.push(kind, stated);
                }
                p
            })
    })
}

/// Anything: kinds and starts that disagree, wild instructions, a legend that may cycle or collide.
fn arb_wild() -> impl Strategy<Value = CrochetPattern> {
    let start = prop_oneof![
        Just(PieceStart::FoundationChain(0)),
        (1u32..14).prop_map(PieceStart::FoundationChain),
        Just(PieceStart::FoundationStitches),
        Just(PieceStart::MagicRing),
        (0u32..5).prop_map(PieceStart::ChainRing),
        Just(PieceStart::FoundationChain(u32::MAX)),
    ];
    let layer = prop_oneof![
        3 => arb_work(true, false).prop_map(|work| LayerKind::Row { work }),
        2 => (arb_work(true, true), any::<bool>())
            .prop_map(|(work, turn)| LayerKind::Round { close: Close::Join, turn, work }),
        1 => (arb_work(true, false), any::<bool>())
            .prop_map(|(work, turn)| LayerKind::Round { close: Close::Spiral, turn, work }),
        1 => (arb_basic(), prop_oneof![Just(0u32), 1u32..6, Just(u32::MAX)])
            .prop_map(|(stitch, stitches)| LayerKind::Foundation { stitch, stitches }),
        1 => Just(LayerKind::Opaque { text: "work in pattern".into() }),
    ];
    let legend_body = arb_list(true);
    (
        start,
        prop::collection::vec((layer, arb_stated()), 0..5),
        prop::collection::vec(
            (
                prop::sample::select(vec!["inc", "inc", "dc", "b0", "shell"]),
                legend_body,
            ),
            0..3,
        ),
    )
        .prop_map(|(start, layers, legend)| {
            let mut p = CrochetPattern::new(start);
            for (kind, stated) in layers {
                p.push(kind, stated);
            }
            for (id, body) in legend {
                p.legend.push(LegendEntry {
                    id: LegendId::new(id),
                    name: id.to_string(),
                    abbreviation: id.to_string(),
                    body,
                });
            }
            p
        })
}

fn arb_limits() -> impl Strategy<Value = CrochetLimits> {
    prop_oneof![
        3 => Just(CrochetLimits::DEFAULT),
        1 => (1u32..30, 1u64..60, 1u64..200, 1usize..4, 1usize..3).prop_map(
            |(items, total, steps, depth, per_code)| CrochetLimits {
                max_items_per_layer: items,
                max_items: total,
                max_steps_per_layer: steps,
                max_repeat_depth: depth,
                max_diagnostics_per_code: per_code,
                ..CrochetLimits::DEFAULT
            }
        ),
    ]
}

/// Every instruction at `path` in a list (through repeat bodies).
fn instr_at<'a>(list: &'a [Instr], path: &[u32]) -> Option<&'a Instr> {
    let (first, rest) = path.split_first()?;
    let ins = list.get(*first as usize)?;
    if rest.is_empty() {
        return Some(ins);
    }
    match ins {
        Instr::Repeat { body, .. } => instr_at(body, rest),
        _ => None,
    }
}

/// Read a W17 count phrase back with one label set: (identity, n) pairs, spaces, not checked.
type Reading = (Vec<(Identity, u32)>, Vec<(u32, u32)>, u32);

fn read_count(set: LabelSet, text: &str) -> Option<Reading> {
    let inner = text.strip_prefix('(')?.strip_suffix(')')?;
    if inner == "count unknown" || inner == "0 sts" {
        return Some((Vec::new(), Vec::new(), 0));
    }
    let mut ids = Vec::new();
    let mut spaces = Vec::new();
    let mut not_checked = 0;
    for part in inner.split(", ") {
        let (n, word) = part.split_once(' ')?;
        let n: u32 = n.parse().ok()?;
        if word == "not checked" {
            not_checked = n;
        } else if let Some(rest) = word.strip_prefix("ch-") {
            let (m, _) = rest.split_once(' ')?;
            spaces.push((m.parse().ok()?, n));
        } else {
            ids.push((set.read_abbreviation(word)?, n));
        }
    }
    Some((ids, spaces, not_checked))
}

proptest! {
    // 384 cases by default; `PROPTEST_CASES` overrides it for a longer run.
    #![proptest_config(ProptestConfig::with_cases(
        std::env::var("PROPTEST_CASES").ok().and_then(|v| v.parse().ok()).unwrap_or(384)
    ))]

    #[test]
    fn arbitrary_patterns_never_panic_and_are_deterministic(p in arb_wild(), limits in arb_limits()) {
        let a = validate_with(&p, &limits);
        let b = validate_with(&p, &limits);
        prop_assert_eq!(&a, &b);
        let r1 = try_resolve_all(&p, &limits);
        let r2 = try_resolve_all(&p, &limits);
        prop_assert_eq!(&r1, &r2);
        // A refusal lists only errors (and, past the per-code cap, how many more of an error code).
        if let Err(CrochetError::Invalid(ds)) = &r1 {
            prop_assert!(!ds.is_empty());
            let only_errors = ds.iter().all(|d| {
                d.severity == Severity::Error
                    || matches!(d.detail, Detail::Omitted { code, .. } if code.severity() == Severity::Error)
            });
            prop_assert!(only_errors);
        }
        // Every listed code has its one severity, and the per-code cap holds.
        for d in &a {
            prop_assert_eq!(d.severity, d.code.severity());
        }
        for code in CrochetCode::ALL {
            let n = a.iter().filter(|d| d.code == code).count();
            prop_assert!(code == CrochetCode::ListCapped || n <= limits.max_diagnostics_per_code.max(1));
        }
        let _ = try_resolve(&p, 1..=1, &limits);
    }

    #[test]
    fn tame_patterns_never_panic(p in arb_tame(), limits in arb_limits()) {
        let _ = validate_with(&p, &limits);
        let _ = try_resolve_all(&p, &limits);
    }

    #[test]
    fn resolved_patterns_keep_their_invariants(p in arb_tame()) {
        let limits = CrochetLimits::DEFAULT;
        let Ok(all) = try_resolve_all(&p, &limits) else { return Ok(()); };
        let ds = validate(&p);
        let mut unknown_seen = false;
        for (idx, l) in all.layers.iter().enumerate() {
            let layer = &p.layers[idx];
            // Unknown stays unknown.
            if unknown_seen {
                prop_assert!(l.count.is_none());
                prop_assert!(l.made.is_empty());
            }
            if l.count.is_none() && !matches!(layer.kind, LayerKind::Opaque { .. }) {
                unknown_seen = true;
            }
            // Every positional anchor names a position this layer worked.
            for m in &l.made {
                for a in &m.anchors {
                    let Some(at) = a.position() else { continue };
                    if let PosRef::Chain(ChainAt::Run { of, .. }) = at {
                        let slot = l.base_slots().iter().find(|s| s.position.at == PosRef::Space(of));
                        prop_assert!(slot.is_some_and(|s| s.chains.as_ref()
                            .is_some_and(|c| c.visited.contains(&BaseUse::Worked))), "{} in {:?}", a, l.layer);
                    } else {
                        let slot = l.base_slots().iter().find(|s| s.position.at == at);
                        prop_assert_eq!(slot.map(|s| s.used), Some(BaseUse::Worked), "{} in layer {}", a, l.layer);
                    }
                }
            }
            let Some(count) = &l.count else { continue };
            // The count is the items' count; opaque positions are exactly the opaque items.
            let opaque = l.made.iter().filter(|m| m.made == Made::Opaque).count() as u32;
            prop_assert_eq!(count.not_checked, opaque);
            for &(c, n) in &count.stitches {
                let from_items = l.made.iter().filter(|m| m.made.counted() == Some(c)).count() as u32;
                prop_assert_eq!(n, from_items);
            }
            // An opaque named stitch makes only opaque items (its body's b1 are never counted).
            for m in l.made.iter().filter(|m| m.named == Some(1)) {
                prop_assert_eq!(m.made, Made::Opaque);
                prop_assert!(m.unverified);
            }
            // Each opaque instruction made exactly what it states, and only then.
            let mut groups: std::collections::BTreeMap<(Vec<u32>, Vec<u32>), u32> = Default::default();
            for m in l.made.iter().filter(|m| m.made == Made::Opaque && m.named.is_none()) {
                *groups.entry((m.source.clone(), m.repetition.clone())).or_default() += 1;
            }
            for ((source, _), n) in groups {
                match instr_at(layer.work(), &source) {
                    Some(Instr::Opaque { makes: Some(k), consumes: Some(_), .. }) => prop_assert_eq!(n, *k),
                    other => prop_assert!(false, "opaque items from {:?}", other),
                }
            }
            // Not reached is exactly what base_unfinished reports.
            let not_reached: u64 = l.base_slots().iter().map(|s| {
                let own = u64::from(s.used == BaseUse::NotReached);
                let chains = s.chains.as_ref().map_or(0, |c| {
                    c.visited.iter().filter(|u| **u == BaseUse::NotReached).count() as u64
                        + if c.rest == BaseUse::NotReached { u64::from(c.rest_count) } else { 0 }
                });
                own + chains
            }).sum();
            let unfinished: u64 = ds.iter()
                .filter(|d| d.code == CrochetCode::BaseUnfinished && d.location.layer == Some(l.layer))
                .map(|d| match &d.detail { Detail::Positions { total, .. } => *total, _ => 0 })
                .sum();
            let excused = ds.iter().any(|d| d.code == CrochetCode::RepeatDoesNotFit && d.location.layer == Some(l.layer));
            if excused {
                prop_assert_eq!(unfinished, 0);
            } else {
                prop_assert_eq!(not_reached, unfinished, "layer {}", l.layer);
            }
            // Label sets never change an operation.
            let us = read_count(LabelSet::US, &LabelSet::US.count_text(Some(count)));
            let uk = read_count(LabelSet::UK, &LabelSet::UK.count_text(Some(count)));
            prop_assert!(us.is_some());
            prop_assert_eq!(&us, &uk);
            let ids: Vec<_> = count.stitches.iter().map(|&(c, n)| (c.identity(), n)).collect();
            prop_assert_eq!(us.map(|r| r.0), Some(ids));
        }
        // A window is the same layers as the whole.
        let n = all.layers.len() as u32;
        if n > 0 {
            let first = 1 + n / 2;
            let w = try_resolve(&p, first..=n, &limits).unwrap();
            prop_assert_eq!(&w.layers[..], &all.layers[(first - 1) as usize..]);
        }
    }

    #[test]
    fn counts_after_each_layer_are_what_validation_checks(p in arb_tame(), pick in any::<prop::sample::Index>()) {
        let limits = CrochetLimits::DEFAULT;
        let Ok(all) = try_resolve_all(&p, &limits) else { return Ok(()); };
        // State every derived count: no mismatch anywhere.
        let mut stated = p.clone();
        let mut known = Vec::new();
        for (i, l) in all.layers.iter().enumerate() {
            stated.layers[i].stated = l.count.as_ref().map(|c| StatedCount {
                stitches: Some(c.total_stitches() as u32),
                spaces: Some(c.total_spaces() as u32),
                by_identity: c.stitches.iter().copied().collect(),
            });
            if let Some(c) = &l.count {
                known.push((i, c.total_stitches() as u32));
            }
        }
        let ds = validate(&stated);
        prop_assert!(!ds.iter().any(|d| d.code == CrochetCode::CountMismatch), "{:?}", keys(&ds));
        prop_assert_eq!(try_resolve_all(&stated, &limits).map(|w| w.layers.iter().map(|l| l.count.clone()).collect::<Vec<_>>()),
            Ok(all.layers.iter().map(|l| l.count.clone()).collect::<Vec<_>>()), "a stated count never changes the resolution");
        // State one wrongly: exactly one mismatch, there, showing the derived count.
        if known.is_empty() { return Ok(()); }
        let (i, derived) = known[pick.index(known.len())];
        let mut wrong = stated.clone();
        if let Some(s) = wrong.layers[i].stated.as_mut() {
            s.stitches = Some(derived + 1);
        }
        let ds = validate(&wrong);
        let mismatches: Vec<_> = ds.iter().filter(|d| d.code == CrochetCode::CountMismatch).collect();
        prop_assert_eq!(mismatches.len(), 1);
        prop_assert_eq!(mismatches[0].location.layer, Some(i as u32 + 1));
        prop_assert_eq!(&mismatches[0].detail, &Detail::Counts(vec![CountDiff {
            what: CountWhat::Stitches,
            stated: derived + 1,
            derived,
        }]));
    }

    #[test]
    fn an_opaque_item_without_counts_leaves_everything_after_unknown(p in arb_tame(), at in any::<prop::sample::Index>()) {
        // Put an opaque instruction that states nothing into one layer with instructions.
        let mut q = p.clone();
        let candidates: Vec<usize> = q.layers.iter().enumerate()
            .filter(|(_, l)| matches!(l.kind, LayerKind::Row { .. } | LayerKind::Round { .. }))
            .map(|(i, _)| i).collect();
        if candidates.is_empty() { return Ok(()); }
        let i = candidates[at.index(candidates.len())];
        let work = match &mut q.layers[i].kind {
            LayerKind::Row { work } | LayerKind::Round { work, .. } => work,
            _ => unreachable!(),
        };
        // Before a final join or leave, so the structure stays as it was.
        let end = match work.last() {
            Some(Instr::LeaveUnworked) | Some(Instr::Work { op: Op::Slip { role: SlipRole::Join, .. }, .. }) => work.len() - 1,
            _ => work.len(),
        };
        work.insert(end, Instr::opaque("popcorn", None, None));
        let Ok(w) = try_resolve_all(&q, &CrochetLimits::DEFAULT) else { return Ok(()); };
        let first_unknown = w.layers.iter().position(|l| l.count.is_none());
        prop_assert!(first_unknown.is_some_and(|u| u <= i));
        for l in &w.layers[first_unknown.unwrap()..] {
            prop_assert!(l.count.is_none());
        }
        let ds = validate(&q);
        let unknown: Vec<_> = ds.iter().filter(|d| d.code == CrochetCode::CountUnknown).collect();
        prop_assert_eq!(unknown.len(), 1, "one count_unknown");
        let first = first_unknown.unwrap() as u32 + 1;
        prop_assert_eq!(&unknown[0].detail, &Detail::Layers { first, last: q.layers.len() as u32 });
        // Nothing that depends on where the work is, after it.
        for d in &ds {
            if d.location.layer.is_some_and(|l| l > first) {
                prop_assert!(matches!(d.code,
                    CrochetCode::UnsupportedOp | CrochetCode::UnsupportedTarget | CrochetCode::RingMissing
                    | CrochetCode::SpiralStartChain), "{}", d.code.as_str());
            }
        }
    }
}

#[test]
fn each_label_set_names_every_identity_once() {
    let mut identities = vec![Identity::Chain, Identity::Slip];
    for b in Basic::ALL {
        identities.push(Identity::Basic(b));
        for legs in 2..=MAX_LEGS {
            identities.push(Identity::Together { stitch: b, legs });
        }
    }
    for set in LabelSet::ALL {
        for &i in &identities {
            let abbr = set.abbreviation(i);
            assert_eq!(
                set.read_abbreviation(&abbr),
                Some(i),
                "{abbr} in {}",
                set.heading()
            );
            assert!(
                is_reserved_word(&abbr),
                "{abbr} is reserved for the legend check"
            );
        }
        let mut abbrs: Vec<String> = identities.iter().map(|&i| set.abbreviation(i)).collect();
        abbrs.sort();
        abbrs.dedup();
        assert_eq!(
            abbrs.len(),
            identities.len(),
            "no two identities share a label in {}",
            set.heading()
        );
    }
}

/// The invariant tests above mean something only if most tame patterns resolve and make work in
/// more than one layer: sample them and check.
#[test]
fn the_tame_generator_mostly_resolves() {
    use proptest::strategy::ValueTree;
    use proptest::test_runner::TestRunner;
    let mut runner = TestRunner::deterministic();
    let strategy = arb_tame();
    let (mut resolved, mut deep, mut opaque, mut unfit, mut passed) = (0, 0, 0, 0, 0);
    const N: usize = 2_000;
    for _ in 0..N {
        let p = strategy.new_tree(&mut runner).unwrap().current();
        if let Ok(w) = try_resolve_all(&p, &CrochetLimits::DEFAULT) {
            resolved += 1;
            if w.layers.iter().filter(|l| l.made.len() > 1).count() >= 2 {
                deep += 1;
            }
            if w.layers
                .iter()
                .any(|l| l.made.iter().any(|m| m.made == Made::Opaque))
            {
                opaque += 1;
            }
            let ds = validate(&p);
            if ds.iter().any(|d| d.code == CrochetCode::RepeatDoesNotFit) {
                unfit += 1;
            }
            if ds.iter().any(|d| d.code == CrochetCode::PassedOver) {
                passed += 1;
            }
        }
    }
    eprintln!(
        "resolved {resolved}, deep {deep}, opaque {opaque}, unfit {unfit}, passed {passed} of {N}"
    );
    assert!(
        resolved * 2 > N,
        "most tame patterns resolve: {resolved} of {N}"
    );
    assert!(
        deep * 5 > N,
        "many make work in two or more layers: {deep} of {N}"
    );
    assert!(opaque > 20 && unfit > 20 && passed > 20);
}
