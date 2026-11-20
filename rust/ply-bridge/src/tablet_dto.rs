//! Transparently mirrored TABLET WEAVING DTOs (M10-02, ADR 0018) and the coarse calls behind the
//! `tablet_*` functions in `api.rs`.
//!
//! The editor holds a [`TabletDocumentDto`] (the `.plytab` document: name, notes, palette, cards,
//! packs, turning, settings) and hands the whole of it to every call, which works out one whole
//! result: the validation report, a simulated window of picks, a band face or turning chart as one
//! RGBA buffer, the state after a pick, the working instructions. Never per card or per cell
//! (`docs/FFI_BOUNDARY.md`). Every enum is flat, so no freezed rebuild is needed for this module.
//!
//! **Bounded results.** A document from a file is untrusted, and so is a DTO from the app. The
//! document reader refuses one past the engine's count limits before it becomes a DTO; a window DTO
//! holds at most [`MAX_BRIDGE_WINDOW_CELLS`] cells (larger views page through windows); the report
//! lists at most [`BRIDGE_DIAGNOSTICS_PER_CODE`] diagnostics of each code (the rest counted), each
//! bounded by the engine; instructions at most [`MAX_INSTRUCTION_LINES`] lines; and a raster is held
//! to the engine's raster budget, checked before anything is drawn.
//!
//! **Checkpoints** cross as opaque bytes ([`TabletCheckpointDto`]): the app keeps the ones
//! [`checkpoints`] made for the band it is showing and hands the nearest one back with a window
//! request. A checkpoint that does not decode, or that belongs to another version of the band, is
//! ignored and the window is folded from pick 1, so the result is always the same.
//!
//! Every result that shows computed faces or twist carries `review_pending` (the engine's
//! `PRACTITIONER_REVIEW_PENDING`): while it is true the app says the rules await a tablet weaver's
//! review.

use std::collections::BTreeMap;

use ply_tablet as tab;
use tab::{
    Arrangement, CardId, Face, FaceThread, Hole, HoleThreads, NoteKind, Pack, PickNote, PickSpec,
    Segment, Severity, Tablet, TabletBand, TabletDocument, TabletLimits, TabletLocation,
    ThreadingDirection, Turn, TurnSequence, Twining,
};

/// Most cells (cards times picks) in one window DTO. The editor's stepper asks for one pick; a view
/// of many picks is drawn by the engine ([`render_face`]) and never crosses cell by cell.
pub const MAX_BRIDGE_WINDOW_CELLS: usize = 50_000;

/// Most diagnostics of one code in a report DTO (the engine counts the rest in one
/// `tablet.list_capped` note per code).
pub const BRIDGE_DIAGNOSTICS_PER_CODE: usize = 200;

/// Most lines of working instructions one call returns.
pub const MAX_INSTRUCTION_LINES: u32 = 5_000;

// --- enums (flat; frb mirrors them as plain Dart enums) -------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TabletHoleKind {
    A,
    B,
    C,
    D,
}

/// Threading in the thread-path meaning (ADR 0018 section 3).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TabletThreadingKind {
    S,
    Z,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TabletTwiningKind {
    S,
    Z,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TabletTurnKind {
    Forward,
    Backward,
    Idle,
    Unsupported,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TabletFaceKind {
    Top,
    Back,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TabletNoteKind {
    Brocade,
    Other,
}

/// What one face of one card shows (see `ply_tablet::FaceThread`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TabletFaceThreadKind {
    /// The thread in `hole` crossed the edge in this pick's turn.
    Thread,
    /// The card idled: the thread in `hole` carries on as a longer float.
    Continued,
    /// Either `hole` or `second_hole` may show (an idle with no earlier turn, or right after a flip).
    Ambiguous,
    /// `hole` is empty: the face there is not modelled.
    Empty,
    /// After an action Ply does not model.
    Unknown,
}

/// A diagnostic's severity, in the engine's four levels.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TabletSeverityKind {
    Error,
    Warning,
    Unsupported,
    Info,
}

/// Which of a [`TabletLocationDto`]'s fields are set (see `ply_tablet::TabletLocation`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TabletLocationKind {
    Band,
    Card,
    Hole,
    Cards,
    Pack,
    PackCard,
    Segment,
    Step,
    Pick,
    Omitted,
    Run,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TabletRunEndKind {
    Ended,
    BandEnd,
    StateUnknown,
}

/// Why a `.plytab` file could not be opened.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TabletFormatFailureKind {
    /// Saved by a newer Ply. The file must not be written to.
    NewerVersion,
    /// A Ply file of another kind, or JSON that is not a tablet band.
    WrongFormat,
    /// Not readable as this version: malformed, an unknown field, or past a size limit.
    Unreadable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TabletInstructionKind {
    Pick,
    Block,
    Step,
    Ledger,
}

/// Why a simulation, render or state could not be worked out.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TabletRunFailureKind {
    /// The DTO does not convert to a band (a card's words given twice).
    InvalidDocument,
    /// The band has structural errors (the report lists them); fix them, then simulate.
    HasErrors,
    /// The picks asked for are not a window of the band.
    InvalidWindow,
    /// The window or raster is past its budget; ask for a smaller one.
    TooLarge,
}

// --- the document ---------------------------------------------------------------------------------

/// An sRGB palette colour.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TabletColorDto {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

/// Which hole is at each corner, seen from the weaver's right.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TabletArrangementDto {
    pub near_top: TabletHoleKind,
    pub far_top: TabletHoleKind,
    pub far_bottom: TabletHoleKind,
    pub near_bottom: TabletHoleKind,
}

/// One card: its stable id, a palette index per hole (`None`: empty), threading and start.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabletCardDto {
    pub id: String,
    pub a: Option<u32>,
    pub b: Option<u32>,
    pub c: Option<u32>,
    pub d: Option<u32>,
    pub threading: TabletThreadingKind,
    pub start: TabletArrangementDto,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabletPackDto {
    pub id: String,
    pub name: String,
    pub cards: Vec<String>,
}

/// The pattern's own words for a card marked `?`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabletWordsDto {
    pub card: String,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabletNoteDto {
    pub kind: TabletNoteKind,
    pub text: String,
}

/// One written pick: a turn letter per card (`F`, `B`, `I`, `?`) and the events before it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabletPickDto {
    pub turns: String,
    pub release_twist: Vec<String>,
    pub flip: Vec<String>,
    /// In card id order (as the file keeps them); each card at most once.
    pub unsupported: Vec<TabletWordsDto>,
    pub note: Option<TabletNoteDto>,
    pub weft: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabletSegmentDto {
    pub repeat: u32,
    pub picks: Vec<TabletPickDto>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TabletSettingsDto {
    pub twist_warning_quarters: u32,
    pub float_warning_picks: u32,
}

/// The whole `.plytab` document.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabletDocumentDto {
    pub name: String,
    pub notes: String,
    pub palette: Vec<TabletColorDto>,
    pub weft: Option<u32>,
    pub cards: Vec<TabletCardDto>,
    pub packs: Vec<TabletPackDto>,
    pub turning: Vec<TabletSegmentDto>,
    pub settings: TabletSettingsDto,
}

/// The typed error `tablet_parse` returns, thrown as an exception on the Dart side.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabletFormatFailure {
    pub kind: TabletFormatFailureKind,
    /// The reader's words (versions found and supported, or the parse error), for logs.
    pub message: String,
}

/// The typed error of the simulation, render and state calls.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabletRunFailure {
    pub kind: TabletRunFailureKind,
    pub message: String,
}

// --- results --------------------------------------------------------------------------------------

/// Where a diagnostic applies, flattened: `kind` says which fields are set. Cards, packs, segments
/// and steps are 1-based positions; picks are 1-based expanded picks.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabletLocationDto {
    pub kind: TabletLocationKind,
    pub card: Option<u32>,
    pub hole: Option<TabletHoleKind>,
    /// At most 32 card numbers; `cards_total` counts them all.
    pub cards: Vec<u32>,
    pub cards_total: u32,
    pub pack: Option<u32>,
    pub packs: Vec<u32>,
    pub packs_total: u32,
    pub listings: u32,
    pub segment: Option<u32>,
    pub step: Option<u32>,
    pub pick: Option<u32>,
    pub face: Option<TabletFaceKind>,
    pub first_pick: Option<u32>,
    pub last_pick: Option<u32>,
    pub run_end: Option<TabletRunEndKind>,
    pub omitted_code: Option<String>,
    pub omitted_count: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabletDiagnosticDto {
    /// The stable code, e.g. `tablet.long_float`.
    pub code: String,
    pub severity: TabletSeverityKind,
    pub location: TabletLocationDto,
    pub message: String,
    pub remediation: Option<String>,
}

/// The validation of a band (ADR 0018 section 13): its diagnostics in the engine's order (errors,
/// warnings, unsupported, information), the expanded pick count when the turning can be counted,
/// and the counts by severity.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabletReportDto {
    pub diagnostics: Vec<TabletDiagnosticDto>,
    pub expanded_picks: Option<u32>,
    pub errors: u32,
    pub warnings: u32,
    pub unsupported: u32,
    pub infos: u32,
    pub review_pending: bool,
    pub rules_version: u32,
}

/// One face of one card at one pick, with the palette colours of its hole(s).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TabletFaceThreadDto {
    pub kind: TabletFaceThreadKind,
    pub hole: Option<TabletHoleKind>,
    /// The second candidate of an ambiguous idle (named so, not `other`, which the generated Dart
    /// equality uses for the value compared).
    pub second_hole: Option<TabletHoleKind>,
    pub color: Option<u32>,
    pub second_color: Option<u32>,
}

/// One card at one pick, after the pick's events and turn.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TabletCardPickDto {
    pub turn: TabletTurnKind,
    pub released: bool,
    pub flipped: bool,
    /// `None` once unknown.
    pub position: Option<TabletArrangementDto>,
    pub threading: Option<TabletThreadingKind>,
    pub top: TabletFaceThreadDto,
    pub back: TabletFaceThreadDto,
    pub twining: Option<TabletTwiningKind>,
    pub reversal: bool,
    /// Quarter turns, Z positive; `None` once unknown.
    pub twist: Option<i32>,
    pub woven: Option<i32>,
    pub top_run: Option<u32>,
    pub back_run: Option<u32>,
}

/// Where a pick comes from in the written turning (1-based), and what is recorded with it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TabletPickInfoDto {
    pub pick: u32,
    pub segment: u32,
    pub step: u32,
    pub repeat: u32,
    pub all_idle: bool,
    pub note: Option<TabletNoteKind>,
    pub weft: Option<u32>,
}

/// Simulated picks `first_pick` to `last_pick`: one info per pick and `cards` cells per pick,
/// pick-major (card 1 first).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabletWindowDto {
    pub first_pick: u32,
    pub last_pick: u32,
    pub cards: u32,
    pub rows: Vec<TabletPickInfoDto>,
    pub cells: Vec<TabletCardPickDto>,
    pub review_pending: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TabletCardStateDto {
    pub position: Option<TabletArrangementDto>,
    pub threading: Option<TabletThreadingKind>,
    pub twist: Option<i32>,
    pub woven: Option<i32>,
}

/// Every card's state after `pick` picks (0: as set up).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabletBandStateDto {
    pub pick: u32,
    pub cards: Vec<TabletCardStateDto>,
    pub review_pending: bool,
}

/// A checkpoint as opaque bytes, for the app to hand back with a window request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabletCheckpointDto {
    /// The pick after which it is the state.
    pub pick: u32,
    pub bytes: Vec<u8>,
}

/// A drawn band face or turning chart: RGBA8, row-major, top row first (the window's LAST pick at
/// the top: pick 1 at the bottom), `cell_px` pixels per cell.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabletRasterDto {
    pub width: u32,
    pub height: u32,
    pub cell_px: u32,
    pub first_pick: u32,
    pub last_pick: u32,
    pub cards: u32,
    pub rgba: Vec<u8>,
    pub review_pending: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabletInstructionLineDto {
    pub kind: TabletInstructionKind,
    pub label: String,
    pub text: String,
    pub segment: u32,
    pub first_pick: u32,
    pub last_pick: u32,
}

/// Working instructions: the lines kept and how many more there are.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabletInstructionsDto {
    pub lines: Vec<TabletInstructionLineDto>,
    pub omitted: u32,
    pub review_pending: bool,
}

// --- conversions ----------------------------------------------------------------------------------

fn hole_in(h: TabletHoleKind) -> Hole {
    match h {
        TabletHoleKind::A => Hole::A,
        TabletHoleKind::B => Hole::B,
        TabletHoleKind::C => Hole::C,
        TabletHoleKind::D => Hole::D,
    }
}

fn hole_out(h: Hole) -> TabletHoleKind {
    match h {
        Hole::A => TabletHoleKind::A,
        Hole::B => TabletHoleKind::B,
        Hole::C => TabletHoleKind::C,
        Hole::D => TabletHoleKind::D,
    }
}

fn threading_in(t: TabletThreadingKind) -> ThreadingDirection {
    match t {
        TabletThreadingKind::S => ThreadingDirection::S,
        TabletThreadingKind::Z => ThreadingDirection::Z,
    }
}

fn threading_out(t: ThreadingDirection) -> TabletThreadingKind {
    match t {
        ThreadingDirection::S => TabletThreadingKind::S,
        ThreadingDirection::Z => TabletThreadingKind::Z,
    }
}

fn twining_out(t: Twining) -> TabletTwiningKind {
    match t {
        Twining::S => TabletTwiningKind::S,
        Twining::Z => TabletTwiningKind::Z,
    }
}

fn turn_out(t: Turn) -> TabletTurnKind {
    match t {
        Turn::Forward => TabletTurnKind::Forward,
        Turn::Backward => TabletTurnKind::Backward,
        Turn::Idle => TabletTurnKind::Idle,
        Turn::Unsupported => TabletTurnKind::Unsupported,
    }
}

fn face_out(f: Face) -> TabletFaceKind {
    match f {
        Face::Top => TabletFaceKind::Top,
        Face::Back => TabletFaceKind::Back,
    }
}

fn face_in(f: TabletFaceKind) -> Face {
    match f {
        TabletFaceKind::Top => Face::Top,
        TabletFaceKind::Back => Face::Back,
    }
}

pub(crate) fn note_kind_out(k: NoteKind) -> TabletNoteKind {
    match k {
        NoteKind::Brocade => TabletNoteKind::Brocade,
        NoteKind::Other => TabletNoteKind::Other,
    }
}

fn note_kind_in(k: TabletNoteKind) -> NoteKind {
    match k {
        TabletNoteKind::Brocade => NoteKind::Brocade,
        TabletNoteKind::Other => NoteKind::Other,
    }
}

impl From<Arrangement> for TabletArrangementDto {
    fn from(a: Arrangement) -> Self {
        TabletArrangementDto {
            near_top: hole_out(a.near_top),
            far_top: hole_out(a.far_top),
            far_bottom: hole_out(a.far_bottom),
            near_bottom: hole_out(a.near_bottom),
        }
    }
}

impl From<TabletArrangementDto> for Arrangement {
    fn from(a: TabletArrangementDto) -> Self {
        Arrangement::new(
            hole_in(a.near_top),
            hole_in(a.far_top),
            hole_in(a.far_bottom),
            hole_in(a.near_bottom),
        )
    }
}

impl From<&TabletDocument> for TabletDocumentDto {
    fn from(doc: &TabletDocument) -> Self {
        let b = &doc.band;
        TabletDocumentDto {
            name: doc.name.clone(),
            notes: doc.notes.clone(),
            palette: b
                .palette
                .iter()
                .map(|c| TabletColorDto {
                    r: c.r,
                    g: c.g,
                    b: c.b,
                })
                .collect(),
            weft: b.weft,
            cards: b
                .cards
                .iter()
                .map(|c| TabletCardDto {
                    id: c.id.as_str().to_string(),
                    a: c.threads.a,
                    b: c.threads.b,
                    c: c.threads.c,
                    d: c.threads.d,
                    threading: threading_out(c.threading),
                    start: c.start.into(),
                })
                .collect(),
            packs: b
                .packs
                .iter()
                .map(|p| TabletPackDto {
                    id: p.id.clone(),
                    name: p.name.clone(),
                    cards: p.cards.iter().map(|c| c.as_str().to_string()).collect(),
                })
                .collect(),
            turning: b
                .turning
                .segments
                .iter()
                .map(|s| TabletSegmentDto {
                    repeat: s.repeat,
                    picks: s
                        .picks
                        .iter()
                        .map(|p| TabletPickDto {
                            turns: p.turns.clone(),
                            release_twist: ids_out(&p.release_twist),
                            flip: ids_out(&p.flip),
                            unsupported: p
                                .unsupported
                                .iter()
                                .map(|(card, text)| TabletWordsDto {
                                    card: card.as_str().to_string(),
                                    text: text.clone(),
                                })
                                .collect(),
                            note: p.note.as_ref().map(|n| TabletNoteDto {
                                kind: note_kind_out(n.kind),
                                text: n.text.clone(),
                            }),
                            weft: p.weft,
                        })
                        .collect(),
                })
                .collect(),
            settings: TabletSettingsDto {
                twist_warning_quarters: b.settings.twist_warning_quarters,
                float_warning_picks: b.settings.float_warning_picks,
            },
        }
    }
}

fn ids_out(ids: &[CardId]) -> Vec<String> {
    ids.iter().map(|c| c.as_str().to_string()).collect()
}

fn ids_in(ids: Vec<String>) -> Vec<CardId> {
    ids.into_iter().map(CardId).collect()
}

/// The DTO as a document. Fails only when a pick gives one card's words twice (the file keeps them
/// in a map, so one would be lost).
impl TryFrom<TabletDocumentDto> for TabletDocument {
    type Error = String;

    fn try_from(d: TabletDocumentDto) -> Result<Self, String> {
        let mut segments = Vec::with_capacity(d.turning.len());
        for (s, seg) in d.turning.into_iter().enumerate() {
            let mut picks = Vec::with_capacity(seg.picks.len());
            for (k, p) in seg.picks.into_iter().enumerate() {
                let mut unsupported = BTreeMap::new();
                for w in p.unsupported {
                    if unsupported.insert(CardId(w.card.clone()), w.text).is_some() {
                        return Err(format!(
                            "segment {}, pick {} gives the words for card {:?} twice",
                            s + 1,
                            k + 1,
                            w.card
                        ));
                    }
                }
                picks.push(PickSpec {
                    turns: p.turns,
                    release_twist: ids_in(p.release_twist),
                    flip: ids_in(p.flip),
                    unsupported,
                    note: p.note.map(|n| PickNote {
                        kind: note_kind_in(n.kind),
                        text: n.text,
                    }),
                    weft: p.weft,
                });
            }
            segments.push(Segment {
                repeat: seg.repeat,
                picks,
            });
        }
        Ok(TabletDocument {
            name: d.name,
            notes: d.notes,
            band: TabletBand {
                palette: d
                    .palette
                    .into_iter()
                    .map(|c| ply_common::Color::rgb(c.r, c.g, c.b))
                    .collect(),
                weft: d.weft,
                cards: d
                    .cards
                    .into_iter()
                    .map(|c| Tablet {
                        id: CardId(c.id),
                        threads: HoleThreads {
                            a: c.a,
                            b: c.b,
                            c: c.c,
                            d: c.d,
                        },
                        threading: threading_in(c.threading),
                        start: c.start.into(),
                    })
                    .collect(),
                packs: d
                    .packs
                    .into_iter()
                    .map(|p| Pack {
                        id: p.id,
                        name: p.name,
                        cards: ids_in(p.cards),
                    })
                    .collect(),
                turning: TurnSequence::new(segments),
                settings: tab::BandSettings {
                    twist_warning_quarters: d.settings.twist_warning_quarters,
                    float_warning_picks: d.settings.float_warning_picks,
                },
            },
        })
    }
}

fn severity_out(s: Severity) -> TabletSeverityKind {
    match s {
        Severity::Error => TabletSeverityKind::Error,
        Severity::Warning => TabletSeverityKind::Warning,
        Severity::Unsupported => TabletSeverityKind::Unsupported,
        Severity::Info => TabletSeverityKind::Info,
    }
}

fn location_out(l: &TabletLocation) -> TabletLocationDto {
    let mut out = TabletLocationDto {
        kind: TabletLocationKind::Band,
        card: None,
        hole: None,
        cards: Vec::new(),
        cards_total: 0,
        pack: None,
        packs: Vec::new(),
        packs_total: 0,
        listings: 0,
        segment: None,
        step: None,
        pick: None,
        face: None,
        first_pick: None,
        last_pick: None,
        run_end: None,
        omitted_code: None,
        omitted_count: 0,
    };
    match l {
        TabletLocation::Band => {}
        TabletLocation::Card { card } => {
            out.kind = TabletLocationKind::Card;
            out.card = Some(*card);
        }
        TabletLocation::Hole { card, hole } => {
            out.kind = TabletLocationKind::Hole;
            out.card = Some(*card);
            out.hole = Some(hole_out(*hole));
        }
        TabletLocation::Cards { cards } => {
            out.kind = TabletLocationKind::Cards;
            out.cards = cards.cards.clone();
            out.cards_total = cards.total;
        }
        TabletLocation::Pack { pack } => {
            out.kind = TabletLocationKind::Pack;
            out.pack = Some(*pack);
        }
        TabletLocation::PackCard {
            card,
            packs,
            listings,
        } => {
            out.kind = TabletLocationKind::PackCard;
            out.card = Some(*card);
            out.packs = packs.packs.clone();
            out.packs_total = packs.total;
            out.listings = *listings;
        }
        TabletLocation::Segment { segment } => {
            out.kind = TabletLocationKind::Segment;
            out.segment = Some(*segment);
        }
        TabletLocation::Step {
            segment,
            step,
            card,
        } => {
            out.kind = TabletLocationKind::Step;
            out.segment = Some(*segment);
            out.step = Some(*step);
            out.card = *card;
        }
        TabletLocation::Pick { pick, cards, face } => {
            out.kind = TabletLocationKind::Pick;
            out.pick = Some(*pick);
            out.cards = cards.cards.clone();
            out.cards_total = cards.total;
            out.face = face.map(face_out);
        }
        TabletLocation::Omitted { code, count } => {
            out.kind = TabletLocationKind::Omitted;
            out.omitted_code = Some(code.as_str().to_string());
            out.omitted_count = u32::try_from(*count).unwrap_or(u32::MAX);
        }
        TabletLocation::Run {
            card,
            hole,
            face,
            first_pick,
            last_pick,
            end,
        } => {
            out.kind = TabletLocationKind::Run;
            out.card = Some(*card);
            out.hole = Some(hole_out(*hole));
            out.face = Some(face_out(*face));
            out.first_pick = Some(*first_pick);
            out.last_pick = Some(*last_pick);
            out.run_end = Some(match end {
                tab::RunEnd::Ended => TabletRunEndKind::Ended,
                tab::RunEnd::BandEnd => TabletRunEndKind::BandEnd,
                tab::RunEnd::StateUnknown => TabletRunEndKind::StateUnknown,
            });
        }
    }
    out
}

fn diagnostic_out(d: &tab::Diagnostic) -> TabletDiagnosticDto {
    TabletDiagnosticDto {
        code: d.code.as_str().to_string(),
        severity: severity_out(d.severity),
        location: location_out(&d.location),
        message: d.message.clone(),
        remediation: d.remediation.clone(),
    }
}

fn face_thread_out(band: &TabletBand, card: usize, f: FaceThread) -> TabletFaceThreadDto {
    let color = |h: Hole| band.thread_color(card, h);
    let (kind, hole, other) = match f {
        FaceThread::Thread(h) => (TabletFaceThreadKind::Thread, Some(h), None),
        FaceThread::Continued(h) => (TabletFaceThreadKind::Continued, Some(h), None),
        FaceThread::Ambiguous(a, b) => (TabletFaceThreadKind::Ambiguous, Some(a), Some(b)),
        FaceThread::Empty(h) => (TabletFaceThreadKind::Empty, Some(h), None),
        FaceThread::Unknown => (TabletFaceThreadKind::Unknown, None, None),
    };
    TabletFaceThreadDto {
        kind,
        hole: hole.map(hole_out),
        second_hole: other.map(hole_out),
        color: hole.and_then(color),
        second_color: other.and_then(color),
    }
}

pub(crate) fn card_pick_out(
    band: &TabletBand,
    card: usize,
    cp: &tab::CardPick,
) -> TabletCardPickDto {
    TabletCardPickDto {
        turn: turn_out(cp.turn),
        released: cp.released,
        flipped: cp.flipped,
        position: cp.position.map(|p| p.arrangement().into()),
        threading: cp.threading.map(threading_out),
        top: face_thread_out(band, card, cp.top),
        back: face_thread_out(band, card, cp.back),
        twining: cp.twining.map(twining_out),
        reversal: cp.reversal,
        twist: cp.twist.twist,
        woven: cp.twist.woven,
        top_run: cp.top_run,
        back_run: cp.back_run,
    }
}

pub(crate) fn card_state_out(c: &tab::CardState) -> TabletCardStateDto {
    TabletCardStateDto {
        position: c.position.map(|p| p.arrangement().into()),
        threading: c.threading.map(threading_out),
        twist: c.twist.twist,
        woven: c.twist.woven,
    }
}

fn pick_info_out(i: &tab::PickInfo) -> TabletPickInfoDto {
    TabletPickInfoDto {
        pick: i.pick,
        segment: i.segment,
        step: i.step,
        repeat: i.repeat,
        all_idle: i.all_idle,
        note: i.note.map(note_kind_out),
        weft: i.weft,
    }
}

fn failure(kind: TabletRunFailureKind, message: impl Into<String>) -> TabletRunFailure {
    TabletRunFailure {
        kind,
        message: message.into(),
    }
}

pub(crate) fn run_failure(e: tab::TabletError) -> TabletRunFailure {
    let kind = match &e {
        tab::TabletError::Invalid(_) => TabletRunFailureKind::HasErrors,
        tab::TabletError::InvalidWindow { .. }
        | tab::TabletError::PickOutOfRange { .. }
        | tab::TabletError::InvalidTime => TabletRunFailureKind::InvalidWindow,
        tab::TabletError::WindowTooLarge { .. } | tab::TabletError::AllocFailed { .. } => {
            TabletRunFailureKind::TooLarge
        }
    };
    failure(kind, e.to_string())
}

pub(crate) fn document(dto: TabletDocumentDto) -> Result<TabletDocument, TabletRunFailure> {
    TabletDocument::try_from(dto).map_err(|m| failure(TabletRunFailureKind::InvalidDocument, m))
}

fn decode_checkpoint(
    cp: Option<TabletCheckpointDto>,
    band: &TabletBand,
) -> Option<tab::Checkpoint> {
    cp.and_then(|cp| tab::Checkpoint::decode(&cp.bytes, band).ok())
}

// --- the calls (each a whole result; `api.rs` exposes them) --------------------------------------

pub(crate) fn parse(text: &str) -> Result<TabletDocumentDto, TabletFormatFailure> {
    let loaded = tab::read_document(text).map_err(|e| TabletFormatFailure {
        kind: match e {
            tab::DocumentError::NewerVersion { .. } => TabletFormatFailureKind::NewerVersion,
            tab::DocumentError::WrongFormat { .. } => TabletFormatFailureKind::WrongFormat,
            tab::DocumentError::TooLarge(_) | tab::DocumentError::Malformed(_) => {
                TabletFormatFailureKind::Unreadable
            }
        },
        message: e.to_string(),
    })?;
    Ok(TabletDocumentDto::from(&loaded.document))
}

/// The schema version a `.plytab` file says it has, read from its envelope alone (nothing else in
/// the file is built, however large it is): `None` when it is not a `.plytab` envelope at all; a
/// newer version than this build reads is returned as found (at most `u32::MAX`), for the caller to
/// refuse.
pub(crate) fn document_version(text: &str) -> Option<u32> {
    match tab::document_schema_version(text) {
        Ok(v) => Some(v),
        Err(tab::DocumentError::NewerVersion { found, .. }) => {
            Some(u32::try_from(found).unwrap_or(u32::MAX))
        }
        Err(_) => None,
    }
}

pub(crate) fn write(dto: TabletDocumentDto) -> Result<String, String> {
    let doc = TabletDocument::try_from(dto)?;
    tab::write_document(&doc).map_err(|e| match e {
        tab::DocumentError::TooLarge(why) => format!(
            "the band is too large to save: {why}. Your changes are still here; make it smaller \
             and save again"
        ),
        other => other.to_string(),
    })
}

pub(crate) fn validate(dto: TabletDocumentDto) -> Result<TabletReportDto, TabletRunFailure> {
    let doc = document(dto)?;
    let limits = TabletLimits {
        max_diagnostics_per_code: BRIDGE_DIAGNOSTICS_PER_CODE,
        ..TabletLimits::DEFAULT
    };
    let diagnostics = tab::validate_with(&doc.band, &limits);
    let count = |s: Severity| {
        let n = diagnostics
            .iter()
            .map(|d| match d.location {
                // A capped list counts the diagnostics it left out, under their own severity.
                TabletLocation::Omitted { code, count } if code.severity() == s => count,
                TabletLocation::Omitted { .. } => 0,
                _ => u64::from(d.severity == s),
            })
            .sum::<u64>();
        u32::try_from(n).unwrap_or(u32::MAX)
    };
    // Every count includes the diagnostics past the per-code cap (a capped list counts them under
    // the severity of the code it left out).
    let (errors, warnings, unsupported, infos) = (
        count(Severity::Error),
        count(Severity::Warning),
        count(Severity::Unsupported),
        count(Severity::Info),
    );
    Ok(TabletReportDto {
        expanded_picks: tab::expanded_picks(&doc.band.turning, &limits).ok(),
        diagnostics: diagnostics.iter().map(diagnostic_out).collect(),
        errors,
        warnings,
        unsupported,
        infos,
        review_pending: tab::PRACTITIONER_REVIEW_PENDING,
        rules_version: tab::RULES_VERSION,
    })
}

pub(crate) fn checkpoints(
    dto: TabletDocumentDto,
) -> Result<Vec<TabletCheckpointDto>, TabletRunFailure> {
    let doc = document(dto)?;
    let cps = tab::checkpoints(&doc.band, 0, &TabletLimits::DEFAULT).map_err(run_failure)?;
    Ok(cps
        .iter()
        .map(|c| TabletCheckpointDto {
            pick: c.pick(),
            bytes: c.encode(),
        })
        .collect())
}

/// The cells a window of `first` to `last` would hold, refused past `max` before anything runs.
fn window_cells(cards: usize, first: u32, last: u32, max: usize) -> Result<(), TabletRunFailure> {
    let picks = (last as usize)
        .saturating_sub(first as usize)
        .saturating_add(1);
    let cells = cards.saturating_mul(picks);
    if cells > max {
        return Err(failure(
            TabletRunFailureKind::TooLarge,
            format!(
                "a window of {cards} cards by {picks} picks has {cells} cells; ask for at most {max}"
            ),
        ));
    }
    Ok(())
}

pub(crate) fn simulate_window(
    dto: TabletDocumentDto,
    first: u32,
    last: u32,
    checkpoint: Option<TabletCheckpointDto>,
) -> Result<TabletWindowDto, TabletRunFailure> {
    let doc = document(dto)?;
    let band = &doc.band;
    window_cells(band.cards.len(), first, last, MAX_BRIDGE_WINDOW_CELLS)?;
    let cp = decode_checkpoint(checkpoint, band);
    let w = tab::try_simulate_from(band, cp.as_ref(), first..=last, &TabletLimits::DEFAULT)
        .map_err(run_failure)?;
    let cards = w.cards;
    Ok(TabletWindowDto {
        first_pick: w.first_pick,
        last_pick: w.last_pick,
        cards: u32::try_from(cards).unwrap_or(u32::MAX),
        rows: w.rows.iter().map(pick_info_out).collect(),
        cells: w
            .cells
            .iter()
            .enumerate()
            .map(|(i, cp)| card_pick_out(band, i % cards.max(1), cp))
            .collect(),
        review_pending: tab::PRACTITIONER_REVIEW_PENDING,
    })
}

pub(crate) fn state_after(
    dto: TabletDocumentDto,
    pick: u32,
    checkpoint: Option<TabletCheckpointDto>,
) -> Result<TabletBandStateDto, TabletRunFailure> {
    let doc = document(dto)?;
    let cp = decode_checkpoint(checkpoint, &doc.band);
    let s = tab::state_after_from(&doc.band, cp.as_ref(), pick, &TabletLimits::DEFAULT)
        .map_err(run_failure)?;
    Ok(TabletBandStateDto {
        pick: s.pick,
        cards: s.cards.iter().map(card_state_out).collect(),
        review_pending: tab::PRACTITIONER_REVIEW_PENDING,
    })
}

/// What to draw.
#[derive(Clone, Copy)]
pub(crate) enum Drawing {
    Face(TabletFaceKind),
    Turning,
}

pub(crate) fn render(
    dto: TabletDocumentDto,
    first: u32,
    last: u32,
    drawing: Drawing,
    cell_px: u32,
    letters: bool,
    checkpoint: Option<TabletCheckpointDto>,
    limits: &tab::RasterLimits,
) -> Result<TabletRasterDto, TabletRunFailure> {
    let doc = document(dto)?;
    let band = &doc.band;
    // The raster budget's cell cap, before the window is simulated (a window is 48 bytes a cell).
    window_cells(band.cards.len(), first, last, limits.max_cells)?;
    let cp = decode_checkpoint(checkpoint, band);
    let w = tab::try_simulate_from(band, cp.as_ref(), first..=last, &TabletLimits::DEFAULT)
        .map_err(run_failure)?;
    let opts = tab::RenderOptions {
        cell_px,
        letters,
        grid: true,
    };
    let raster = match drawing {
        Drawing::Face(f) => tab::try_render_face(band, &w, face_in(f), &opts, limits),
        Drawing::Turning => tab::try_render_turning(&w, &opts, limits),
    }
    .map_err(|e| failure(TabletRunFailureKind::TooLarge, e.to_string()))?;
    Ok(TabletRasterDto {
        width: raster.width,
        height: raster.height,
        cell_px: raster.cell_px,
        first_pick: w.first_pick,
        last_pick: w.last_pick,
        cards: u32::try_from(w.cards).unwrap_or(u32::MAX),
        rgba: raster.pixels,
        review_pending: tab::PRACTITIONER_REVIEW_PENDING,
    })
}

pub(crate) fn instructions(
    dto: TabletDocumentDto,
    max_lines: u32,
) -> Result<TabletInstructionsDto, TabletRunFailure> {
    let doc = document(dto)?;
    let max = max_lines.min(MAX_INSTRUCTION_LINES) as usize;
    let ins =
        tab::working_instructions(&doc.band, &TabletLimits::DEFAULT, max).map_err(run_failure)?;
    Ok(TabletInstructionsDto {
        lines: ins
            .lines
            .into_iter()
            .map(|l| TabletInstructionLineDto {
                kind: match l.kind {
                    tab::InstructionKind::Pick => TabletInstructionKind::Pick,
                    tab::InstructionKind::Block => TabletInstructionKind::Block,
                    tab::InstructionKind::Step => TabletInstructionKind::Step,
                    tab::InstructionKind::Ledger => TabletInstructionKind::Ledger,
                },
                label: l.label,
                text: l.text,
                segment: l.segment,
                first_pick: l.first_pick,
                last_pick: l.last_pick,
            })
            .collect(),
        omitted: u32::try_from(ins.omitted).unwrap_or(u32::MAX),
        review_pending: tab::PRACTITIONER_REVIEW_PENDING,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(rel: &str) -> String {
        let path = format!("{}/../../fixtures/tablet/{rel}", env!("CARGO_MANIFEST_DIR"));
        std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}"))
    }

    fn band_1() -> TabletDocumentDto {
        parse(&fixture("documents/band-1-threaded-in.plytab")).unwrap()
    }

    /// A rough upper bound of the bytes a diagnostics list holds (its strings and fixed fields).
    fn report_bytes(r: &TabletReportDto) -> usize {
        r.diagnostics
            .iter()
            .map(|d| {
                d.code.len()
                    + d.message.len()
                    + d.remediation.as_ref().map_or(0, String::len)
                    + d.location.cards.len() * 4
                    + d.location.packs.len() * 4
                    + d.location.omitted_code.as_ref().map_or(0, String::len)
                    + 128
            })
            .sum()
    }

    #[test]
    fn the_document_crosses_and_comes_back_byte_for_byte() {
        for name in [
            "band-1-threaded-in",
            "sampler-2-starts-idles-flip",
            "sampler-3-flip-then-opposite",
        ] {
            let text = fixture(&format!("documents/{name}.plytab"));
            let dto = parse(&text).unwrap();
            assert_eq!(write(dto).unwrap(), text, "{name}");
        }
    }

    #[test]
    fn format_problems_are_typed() {
        let newer = fixture("documents/invalid/newer-version.plytab");
        assert_eq!(
            parse(&newer).unwrap_err().kind,
            TabletFormatFailureKind::NewerVersion
        );
        let knit = fixture("documents/invalid/wrong-format-knit.plytab");
        assert_eq!(
            parse(&knit).unwrap_err().kind,
            TabletFormatFailureKind::WrongFormat
        );
        let unknown = fixture("documents/invalid/unknown-card-field.plytab");
        assert_eq!(
            parse(&unknown).unwrap_err().kind,
            TabletFormatFailureKind::Unreadable
        );
        let long = fixture("documents/invalid/turns-past-card-limit.plytab");
        assert_eq!(
            parse(&long).unwrap_err().kind,
            TabletFormatFailureKind::Unreadable
        );
    }

    #[test]
    fn the_version_of_a_large_hostile_file_comes_from_its_envelope() {
        // 20 MB of document the probe skips unread; the reader would refuse it as too large.
        let mut text =
            String::from(r#"{"format": "ply.tablet", "schema_version": 1, "document": ["#);
        while text.len() < 20 * 1024 * 1024 {
            text.push_str("{},");
        }
        text.push_str("{}]}");
        assert_eq!(document_version(&text), Some(1));
        assert_eq!(
            parse(&text).unwrap_err().kind,
            TabletFormatFailureKind::Unreadable
        );
        let newer = text.replacen("\"schema_version\": 1", "\"schema_version\": 9000000000", 1);
        assert_eq!(document_version(&newer), Some(u32::MAX));
        assert_eq!(
            document_version(&fixture("documents/invalid/newer-version.plytab")),
            Some(2)
        );
        assert_eq!(
            document_version(&fixture("documents/invalid/not-json.plytab")),
            None
        );
        assert_eq!(
            document_version(&fixture("documents/invalid/wrong-format-knit.plytab")),
            None
        );
        assert_eq!(
            document_version(&fixture("documents/band-1-threaded-in.plytab")),
            Some(1)
        );
    }

    #[test]
    fn notes_past_the_cap_are_counted() {
        // 1,000 picks with a reversal on each: 200 listed, 800 counted beyond the cap.
        let mut dto = band_1();
        dto.turning = vec![TabletSegmentDto {
            repeat: 500,
            picks: vec![
                TabletPickDto {
                    turns: "FFFFFFFF".into(),
                    release_twist: vec![],
                    flip: vec![],
                    unsupported: vec![],
                    note: None,
                    weft: None,
                },
                TabletPickDto {
                    turns: "BBBBBBBB".into(),
                    release_twist: vec![],
                    flip: vec![],
                    unsupported: vec![],
                    note: None,
                    weft: None,
                },
            ],
        }];
        let r = validate(dto).unwrap();
        let listed = r
            .diagnostics
            .iter()
            .filter(|d| d.code == "tablet.reversal")
            .count();
        assert_eq!(listed, BRIDGE_DIAGNOSTICS_PER_CODE);
        assert_eq!(
            r.infos, 999,
            "every reversal counted, not only those listed"
        );
    }

    #[test]
    fn duplicate_words_for_a_card_are_refused_not_dropped() {
        let mut dto = band_1();
        dto.turning[0].picks[0].turns = "?FFFFFFF".into();
        let words = TabletWordsDto {
            card: "card-1".into(),
            text: "half turn".into(),
        };
        dto.turning[0].picks[0].unsupported = vec![words.clone(), words];
        assert!(write(dto.clone()).is_err());
        assert_eq!(
            validate(dto).unwrap_err().kind,
            TabletRunFailureKind::InvalidDocument
        );
    }

    #[test]
    fn the_report_counts_by_severity_and_says_review_is_pending() {
        let r = validate(band_1()).unwrap();
        assert_eq!((r.errors, r.warnings, r.unsupported, r.infos), (0, 0, 0, 2));
        assert_eq!(r.expanded_picks, Some(12));
        assert!(r.review_pending);
        assert_eq!(r.diagnostics[0].code, "tablet.reversal");
        assert_eq!(r.diagnostics[0].location.kind, TabletLocationKind::Pick);
        assert_eq!(r.diagnostics[0].location.pick, Some(5));
        assert_eq!(r.diagnostics[0].location.cards_total, 8);
    }

    #[test]
    fn a_window_and_the_state_after_a_pick_match_the_oracle() {
        let dto = band_1();
        let w = simulate_window(dto.clone(), 9, 9, None).unwrap();
        assert_eq!((w.first_pick, w.last_pick, w.cards), (9, 9, 8));
        // ADR 0018 section 11, step 4: pick 9 top holes A (Left) and D (Right); twist +1 everywhere.
        assert_eq!(w.cells[0].top.hole, Some(TabletHoleKind::A));
        assert_eq!(w.cells[4].top.hole, Some(TabletHoleKind::D));
        assert!(w.cells.iter().all(|c| c.twist == Some(1)));
        assert!(w.cells[0].reversal && !w.cells[4].reversal);
        assert!(w.review_pending);
        let s = state_after(dto, 12, None).unwrap();
        assert!(s.cards.iter().all(
            |c| c.twist == Some(4) && c.position.map(|p| p.near_top) == Some(TabletHoleKind::A)
        ));
    }

    #[test]
    fn checkpoints_resume_and_a_stale_or_broken_one_is_ignored() {
        // Band 1 made long: 600 forward picks, so it has checkpoints.
        let mut dto = band_1();
        dto.turning[0].repeat = 600;
        let cps = checkpoints(dto.clone()).unwrap();
        assert!(!cps.is_empty());
        let cp = cps[0].clone();
        let want = simulate_window(dto.clone(), 590, 600, None).unwrap();
        assert_eq!(
            simulate_window(dto.clone(), 590, 600, Some(cp.clone())).unwrap(),
            want
        );
        // Bytes that do not decode, or that belong to another version of the band: same window.
        let mut broken = cp.clone();
        broken.bytes.truncate(10);
        assert_eq!(
            simulate_window(dto.clone(), 590, 600, Some(broken)).unwrap(),
            want
        );
        let mut other = dto.clone();
        other.cards[0].threading = TabletThreadingKind::Z;
        let want_other = simulate_window(other.clone(), 590, 600, None).unwrap();
        assert_eq!(
            simulate_window(other, 590, 600, Some(cp)).unwrap(),
            want_other
        );
    }

    #[test]
    fn windows_past_the_bridge_cap_are_refused_before_simulating() {
        let mut dto = band_1();
        dto.turning[0].repeat = 10_000;
        // 8 cards by 6,251 picks is 50,008 cells.
        let e = simulate_window(dto.clone(), 1, 6_251, None).unwrap_err();
        assert_eq!(e.kind, TabletRunFailureKind::TooLarge);
        assert!(simulate_window(dto, 1, 6_250, None).is_ok());
    }

    #[test]
    fn rasters_keep_to_their_budget() {
        let dto = band_1();
        let r = render(
            dto.clone(),
            1,
            12,
            Drawing::Face(TabletFaceKind::Top),
            16,
            true,
            None,
            &tab::RasterLimits::DEFAULT,
        )
        .unwrap();
        assert_eq!((r.width, r.height, r.cell_px), (8 * 16, 12 * 16, 16));
        assert_eq!(r.rgba.len(), (r.width * r.height * 4) as usize);
        let small = tab::RasterLimits {
            max_cells: 1_000,
            max_raster_bytes: 8 * 12 * 16,
            max_side: 1_000,
        };
        let r = render(
            dto.clone(),
            1,
            12,
            Drawing::Turning,
            16,
            false,
            None,
            &small,
        )
        .unwrap();
        assert_eq!(r.cell_px, 2);
        let tiny = tab::RasterLimits {
            max_cells: 95,
            ..tab::RasterLimits::DEFAULT
        };
        let e = render(dto, 1, 12, Drawing::Turning, 16, false, None, &tiny).unwrap_err();
        assert_eq!(e.kind, TabletRunFailureKind::TooLarge);
    }

    /// The class of bug where one hostile file makes a report of gigabytes: a band that trips every
    /// per-pick and per-run diagnostic tens of thousands of times, with long words, ids and names at
    /// the limits, gives a report of bounded size and a refused raster, never an allocation in
    /// proportion to the band's expanded size.
    #[test]
    fn a_hostile_band_gives_a_bounded_report_and_raster() {
        let cards = 1_000;
        let long_words = "w".repeat(tab::MAX_TEXT_BYTES);
        let mut turns = String::new();
        for i in 0..cards {
            turns.push(['F', 'I', '?', 'B'][i % 4]);
        }
        let dto = TabletDocumentDto {
            name: "n".repeat(tab::MAX_TEXT_BYTES),
            notes: String::new(),
            palette: vec![TabletColorDto { r: 0, g: 0, b: 0 }],
            weft: None,
            cards: (0..cards)
                .map(|i| TabletCardDto {
                    id: format!("c{i:0>60}"),
                    a: Some(0),
                    b: None,
                    c: Some(0),
                    d: None,
                    threading: TabletThreadingKind::S,
                    start: TabletArrangementDto {
                        near_top: TabletHoleKind::A,
                        far_top: TabletHoleKind::D,
                        far_bottom: TabletHoleKind::C,
                        near_bottom: TabletHoleKind::B,
                    },
                })
                .collect(),
            packs: vec![
                TabletPackDto {
                    id: "p1".into(),
                    name: "x".repeat(tab::MAX_TEXT_BYTES),
                    cards: (0..cards).map(|i| format!("c{i:0>60}")).collect(),
                },
                TabletPackDto {
                    id: "p2".into(),
                    name: "y".repeat(tab::MAX_TEXT_BYTES),
                    cards: (0..cards).map(|i| format!("c{i:0>60}")).collect(),
                },
            ],
            turning: vec![TabletSegmentDto {
                repeat: 2_000,
                picks: vec![TabletPickDto {
                    turns: turns.clone(),
                    release_twist: (0..cards).map(|i| format!("c{i:0>60}")).collect(),
                    flip: (0..cards).map(|i| format!("c{i:0>60}")).collect(),
                    unsupported: (0..cards)
                        .filter(|i| i % 4 == 2)
                        .map(|i| TabletWordsDto {
                            card: format!("c{i:0>60}"),
                            text: long_words.clone(),
                        })
                        .collect(),
                    note: Some(TabletNoteDto {
                        kind: TabletNoteKind::Other,
                        text: long_words.clone(),
                    }),
                    weft: None,
                }],
            }],
            settings: TabletSettingsDto {
                twist_warning_quarters: 0,
                float_warning_picks: 0,
            },
        };
        // As a hostile file: written out (it is within every count limit, so the writer keeps it)
        // and read back through the same parser the app opens files with.
        let text = write(dto).unwrap();
        assert!(text.len() < tab::MAX_DOCUMENT_BYTES, "{} bytes", text.len());
        let dto = parse(&text).unwrap();
        let r = validate(dto.clone()).unwrap();
        // Tens of thousands of findings, listed at most 200 of each code and counted beyond.
        assert!(
            r.diagnostics.len() <= 22 * BRIDGE_DIAGNOSTICS_PER_CODE + 22,
            "{}",
            r.diagnostics.len()
        );
        assert!(r.warnings > 100_000 || r.unsupported > 100_000, "{r:?}");
        let bytes = report_bytes(&r);
        assert!(bytes < 4 * 1024 * 1024, "report of {bytes} bytes");
        for d in &r.diagnostics {
            assert!(d.message.len() < 1_000, "{}", d.message);
            assert!(d.location.cards.len() <= 32);
        }
        // The whole band is 2,000,000 cells: refused by the raster budget before simulating.
        let e = render(
            dto.clone(),
            1,
            2_000,
            Drawing::Face(TabletFaceKind::Top),
            4,
            false,
            None,
            &tab::RasterLimits::DEFAULT,
        )
        .unwrap_err();
        assert_eq!(e.kind, TabletRunFailureKind::TooLarge);
        // Instructions stay within their line cap, each line bounded.
        let ins = instructions(dto, 10_000_000).unwrap();
        assert!(ins.lines.len() <= MAX_INSTRUCTION_LINES as usize);
        assert!(
            ins.lines.iter().all(|l| l.text.len() < 4_000),
            "{}",
            ins.lines[0].text.len()
        );
    }
}
