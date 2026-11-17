//! The recipe checks: what Ply can verify about a recipe's structure, with stable codes and plain
//! words, and the per-segment report the editor, the follow view and the PDF show.
//!
//! The walk is one pass over the segments in working order. A START segment begins a new PART (the
//! hand of a mitten, then its thumb); body and shaping segments belong to the part in progress; a
//! FINISH ends it. Within a part the stitch count is carried from the recipe's own numbers when they
//! are stated, and becomes unknown (never guessed) as soon as a step does not say. A step whose
//! numbers cannot be worked (removing more stitches than the round has) is an error and is NOT
//! applied, so later steps are still checked against the count before it.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use super::written;
use super::{
    Extent, Measurement, Phase, Reading, Recipe, Segment, SegmentKind, Work, MAX_FIT, MAX_NOTATION,
    MAX_NOTATION_ISSUES, MAX_SEGMENTS, MAX_STITCHES, MAX_TEXT, MAX_TOTAL_TEXT,
};
use crate::notation::{
    parse_lenient, parse_strict, Fidelity, NotationDiagnostic, NotationSeverity, ParsedNotation,
};
use crate::stitch::Connection;

/// How serious a recipe issue is. Ordered `Info < Warning < Error`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub enum RecipeSeverity {
    /// Something the maker should know (a count Ply can no longer follow).
    Info,
    /// Probably unfinished or unclear, but the recipe can still be followed.
    Warning,
    /// The recipe says something that cannot be worked as written.
    Error,
}

/// A stable machine code for one kind of recipe issue. The strings from [`RecipeCode::as_str`] are a
/// contract (tests and the UI key on them): never renamed or reused. New codes may be added.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum RecipeCode {
    TooLarge,
    EmptyRecipe,
    MissingId,
    DuplicateId,
    BeforeStart,
    PartNotFinished,
    NoStitch,
    NotationProblem,
    NotationTooLong,
    ProjectNotationProblem,
    NoConnection,
    CountNotPositive,
    CountTooLarge,
    CountUnknown,
    DecreaseTooMany,
    DecreaseToMore,
    IncreaseToFewer,
    OpeningTooWide,
    ExtentNotForKind,
    UnknownStep,
    NotAnOpening,
    OpeningLater,
    OpeningAlreadyUsed,
    OpeningNotUsed,
    MeasurementNoUnit,
    MeasurementNotPositive,
    MeasurementNoValue,
    UntilNotStated,
    EmptyFreeform,
}

impl RecipeCode {
    /// Every code, in declaration order.
    pub const ALL: [RecipeCode; 29] = [
        RecipeCode::TooLarge,
        RecipeCode::EmptyRecipe,
        RecipeCode::MissingId,
        RecipeCode::DuplicateId,
        RecipeCode::BeforeStart,
        RecipeCode::PartNotFinished,
        RecipeCode::NoStitch,
        RecipeCode::NotationProblem,
        RecipeCode::NotationTooLong,
        RecipeCode::ProjectNotationProblem,
        RecipeCode::NoConnection,
        RecipeCode::CountNotPositive,
        RecipeCode::CountTooLarge,
        RecipeCode::CountUnknown,
        RecipeCode::DecreaseTooMany,
        RecipeCode::DecreaseToMore,
        RecipeCode::IncreaseToFewer,
        RecipeCode::OpeningTooWide,
        RecipeCode::ExtentNotForKind,
        RecipeCode::UnknownStep,
        RecipeCode::NotAnOpening,
        RecipeCode::OpeningLater,
        RecipeCode::OpeningAlreadyUsed,
        RecipeCode::OpeningNotUsed,
        RecipeCode::MeasurementNoUnit,
        RecipeCode::MeasurementNotPositive,
        RecipeCode::MeasurementNoValue,
        RecipeCode::UntilNotStated,
        RecipeCode::EmptyFreeform,
    ];

    /// The stable kebab-case code (identical to the serde form).
    pub fn as_str(self) -> &'static str {
        match self {
            RecipeCode::TooLarge => "too-large",
            RecipeCode::EmptyRecipe => "empty-recipe",
            RecipeCode::MissingId => "missing-id",
            RecipeCode::DuplicateId => "duplicate-id",
            RecipeCode::BeforeStart => "before-start",
            RecipeCode::PartNotFinished => "part-not-finished",
            RecipeCode::NoStitch => "no-stitch",
            RecipeCode::NotationProblem => "notation-problem",
            RecipeCode::NotationTooLong => "notation-too-long",
            RecipeCode::ProjectNotationProblem => "project-notation-problem",
            RecipeCode::NoConnection => "no-connection",
            RecipeCode::CountNotPositive => "count-not-positive",
            RecipeCode::CountTooLarge => "count-too-large",
            RecipeCode::CountUnknown => "count-unknown",
            RecipeCode::DecreaseTooMany => "decrease-too-many",
            RecipeCode::DecreaseToMore => "decrease-to-more",
            RecipeCode::IncreaseToFewer => "increase-to-fewer",
            RecipeCode::OpeningTooWide => "opening-too-wide",
            RecipeCode::ExtentNotForKind => "extent-not-for-kind",
            RecipeCode::UnknownStep => "unknown-step",
            RecipeCode::NotAnOpening => "not-an-opening",
            RecipeCode::OpeningLater => "opening-later",
            RecipeCode::OpeningAlreadyUsed => "opening-already-used",
            RecipeCode::OpeningNotUsed => "opening-not-used",
            RecipeCode::MeasurementNoUnit => "measurement-no-unit",
            RecipeCode::MeasurementNotPositive => "measurement-not-positive",
            RecipeCode::MeasurementNoValue => "measurement-no-value",
            RecipeCode::UntilNotStated => "until-not-stated",
            RecipeCode::EmptyFreeform => "empty-freeform",
        }
    }
}

/// One finding about a recipe, located at a segment, a fit measurement, or the recipe as a whole.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RecipeIssue {
    pub code: RecipeCode,
    pub severity: RecipeSeverity,
    /// The segment's position (0-based), when the issue is about one segment.
    pub segment: Option<usize>,
    /// That segment's id (ids can repeat in a hand-edited file, so the position is the key).
    pub segment_id: Option<String>,
    /// The fit measurement's position (0-based), when the issue is about one.
    pub fit: Option<usize>,
    /// The finding without its place.
    pub message: String,
    /// The finding with its place: `Step 3 (Cuff): ...`, `Fit 1 (Hand around): ...`, or the
    /// message alone for the recipe as a whole.
    pub text: String,
}

/// The stitch count after a segment, from the recipe's own numbers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Count {
    /// The recipe's numbers give this many stitches in the round (or row).
    Known(u32),
    /// The recipe does not say enough to count.
    Unknown,
    /// This segment's numbers cannot be worked; it is not counted (see its problems) and later
    /// segments are checked against the count before it.
    Refused,
    /// Not a step of a part (a note, or a step before any start or after a finish).
    NotApplicable,
}

/// What Ply read of a notation, kept small: a report carries one of these per stitch, never the
/// reader's per-character diagnostics (its problems are the segment's issues, capped).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NotationSummary {
    /// Accepted in its mode: only formatting notes remain.
    pub accepted: bool,
    pub fidelity: Fidelity,
    /// The canonical print of the best-effort stitch.
    pub normalized: String,
    /// The connections into the previous round, as read.
    pub connections: Vec<Connection>,
    /// How many problems (findings above formatting notes) the reader found.
    pub problems: usize,
}

impl NotationSummary {
    /// True when the stitch IS what the text says (accepted and not lossy).
    pub fn is_exact(&self) -> bool {
        self.accepted && !self.fidelity.is_lossy()
    }
}

/// A stitch as written and how Ply read it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StitchReading {
    /// The notation exactly as written (never rewritten).
    pub notation: String,
    /// The display name, or empty.
    pub name: String,
    pub reading: Reading,
    /// What was read; `None` when the notation is longer than [`MAX_NOTATION`] (not read).
    pub read: Option<NotationSummary>,
}

/// The stitch a segment is worked in.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum StitchUse {
    /// The project's stitch: read once, in [`RecipeReport::project_stitch`].
    Project,
    /// The segment's own stitch.
    Own(StitchReading),
}

/// What the check says about one segment.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SegmentReport {
    pub index: usize,
    pub id: String,
    pub kind: SegmentKind,
    pub phase: Phase,
    /// The part (1-based) the segment belongs to, or `None` outside a part.
    pub part: Option<u32>,
    /// The stitch it is worked in, when it has one (its own, or the project's for a kind that uses a
    /// stitch). `None` when none is given.
    pub stitch: Option<StitchUse>,
    /// The stitch count after it.
    pub count: Count,
    /// The written instruction, from the structured fields only (notes are printed separately).
    pub written: String,
    /// The target as written (`Width across the crown: 18 cm`), when there is one.
    pub target: Option<String>,
    /// False for free text: Ply does not read it, so nothing in it is checked.
    pub checked: bool,
}

/// The whole check: one report per segment (in order) and every issue (in segment order, then the
/// recipe-wide ones).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RecipeReport {
    pub segments: Vec<SegmentReport>,
    pub issues: Vec<RecipeIssue>,
    /// The recipe's fit measurements as written, in order.
    pub fit: Vec<String>,
    /// The project's stitch as read (once, for every segment worked in it), or `None` when the
    /// project has no stitch.
    pub project_stitch: Option<StitchReading>,
}

impl RecipeReport {
    /// The issues about segment `index`.
    pub fn issues_at(&self, index: usize) -> impl Iterator<Item = &RecipeIssue> {
        self.issues.iter().filter(move |i| i.segment == Some(index))
    }

    pub fn has_errors(&self) -> bool {
        self.issues
            .iter()
            .any(|i| i.severity == RecipeSeverity::Error)
    }

    /// True when the recipe was past the limits and nothing in it was checked.
    pub fn too_large(&self) -> bool {
        self.issues.iter().any(|i| i.code == RecipeCode::TooLarge)
    }
}

/// Check `recipe`. `project_notation` is the project's own stitch (what a segment without a stitch
/// of its own is worked in), read strictly as the project screen reads it. Never fails and never
/// panics; a recipe past the limits gets one `too-large` error, placed where the limit was passed
/// when that is one segment or fit measurement, and no other checks.
///
/// The report is bounded by the input: the notations read are at most [`MAX_NOTATION`] long, each
/// stitch reports at most [`MAX_NOTATION_ISSUES`] notation problems plus one count of the rest,
/// places and references shorten titles and ids, and all the recipe's text together is at most
/// [`MAX_TOTAL_TEXT`].
pub fn check(recipe: &Recipe, project_notation: &str) -> RecipeReport {
    if let Some(big) = too_large(recipe) {
        return RecipeReport {
            segments: Vec::new(),
            issues: vec![RecipeIssue {
                code: RecipeCode::TooLarge,
                severity: RecipeSeverity::Error,
                segment: big.segment,
                segment_id: big.segment.map(|i| shorten(&recipe.segments[i].id)),
                fit: big.fit,
                message: big.message,
                text: big.text,
            }],
            fit: Vec::new(),
            project_stitch: None,
        };
    }
    Checker::new(recipe, project_notation).run()
}

fn utf16_len(s: &str) -> usize {
    s.encode_utf16().count()
}

/// Why a recipe is too large to check, and where.
struct TooLarge {
    segment: Option<usize>,
    fit: Option<usize>,
    message: String,
    text: String,
}

impl TooLarge {
    fn whole(message: String) -> Self {
        TooLarge {
            segment: None,
            fit: None,
            text: message.clone(),
            message,
        }
    }
}

/// The text fields of a segment, each with how a sentence names it. A notation is limited
/// separately (it is not read past [`MAX_NOTATION`]) but counts toward the total.
fn segment_texts(s: &Segment) -> Vec<(&'static str, &str)> {
    let mut texts = vec![
        ("its id is", s.id.as_str()),
        ("its label is", &s.title),
        ("its notes are", &s.notes),
        ("its warning is", &s.caution),
    ];
    if let Some(st) = &s.stitch {
        texts.push(("its stitch name is", &st.name));
    }
    if let Some(m) = &s.target {
        texts.push(("its target is", &m.label));
    }
    match &s.work {
        Work::PickUp { from: Some(r), .. } | Work::Join { closes: Some(r) } => {
            texts.push(("the step it names is", r))
        }
        Work::Freeform { text, .. } => texts.push(("its text is", text)),
        _ => {}
    }
    if let Some(Extent::Until { measure }) = extent_of(&s.work) {
        texts.push(("what it works until is", &measure.label));
    }
    texts
}

fn too_large(recipe: &Recipe) -> Option<TooLarge> {
    if recipe.segments.len() > MAX_SEGMENTS {
        return Some(TooLarge::whole(format!(
            "The recipe has more than {} steps, so Ply does not check it.",
            thousands(MAX_SEGMENTS as u64)
        )));
    }
    if recipe.fit.len() > MAX_FIT {
        return Some(TooLarge::whole(format!(
            "The recipe has more than {MAX_FIT} fit measurements, so Ply does not check it."
        )));
    }
    if recipe.done.len() > MAX_SEGMENTS {
        return Some(TooLarge::whole(format!(
            "The recipe has more than {} ticked steps, so Ply does not check it.",
            thousands(MAX_SEGMENTS as u64)
        )));
    }
    let limit = thousands(MAX_TEXT as u64);
    let mut total = 0usize;
    for (f, m) in recipe.fit.iter().enumerate() {
        let n = utf16_len(&m.label);
        total += n;
        if n > MAX_TEXT {
            let message = format!(
                "its label is longer than {limit} characters, so Ply does not check the recipe."
            );
            return Some(TooLarge {
                segment: None,
                fit: Some(f),
                text: format!("Fit {}: {message}", f + 1),
                message,
            });
        }
    }
    for d in &recipe.done {
        let n = utf16_len(d);
        total += n;
        if n > MAX_TEXT {
            return Some(TooLarge::whole(format!(
                "A ticked step's id is longer than {limit} characters, so Ply does not check the \
                 recipe."
            )));
        }
    }
    for (i, s) in recipe.segments.iter().enumerate() {
        for (what, t) in segment_texts(s) {
            let n = utf16_len(t);
            total += n;
            if n > MAX_TEXT {
                let message = format!(
                    "{what} longer than {limit} characters, so Ply does not check the recipe."
                );
                return Some(TooLarge {
                    segment: Some(i),
                    fit: None,
                    text: format!("{}: {message}", place_of(&recipe.segments[i], i)),
                    message,
                });
            }
        }
        if let Some(st) = &s.stitch {
            total += utf16_len(&st.notation);
        }
    }
    if total > MAX_TOTAL_TEXT {
        return Some(TooLarge::whole(format!(
            "The recipe's texts together (labels, notes, warnings, free text and the rest) are \
             longer than {} characters, so Ply does not check it.",
            thousands(MAX_TOTAL_TEXT as u64)
        )));
    }
    None
}

/// Longest title or id shown inside a place or a reference.
const SHORT: usize = 40;

/// [s] shortened for a place or a reference (a long title must not repeat in every message).
pub(super) fn shorten(s: &str) -> String {
    let mut chars = s.chars();
    let head: String = chars.by_ref().take(SHORT).collect();
    if chars.next().is_none() {
        head
    } else {
        let mut cut: String = head.chars().take(SHORT - 1).collect();
        cut.push('…');
        cut
    }
}

/// `Step 3 (Cuff)`, with the title shortened.
fn place_of(s: &Segment, i: usize) -> String {
    let title = s.title.trim();
    if title.is_empty() {
        format!("Step {}", i + 1)
    } else {
        format!("Step {} ({})", i + 1, shorten(title))
    }
}

/// The extent of a segment's work, for the kinds that have one.
pub(super) fn extent_of(work: &Work) -> Option<&Extent> {
    match work {
        Work::Rounds { extent, .. }
        | Work::Rows { extent }
        | Work::Increase { extent, .. }
        | Work::Decrease { extent, .. }
        | Work::ShortRows { extent } => extent.as_ref(),
        _ => None,
    }
}

/// `1000000` as `1,000,000`.
pub(super) fn thousands(n: u64) -> String {
    let digits = n.to_string();
    let mut out = String::new();
    for (i, ch) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(ch);
    }
    out
}

/// `n` with the singular or plural noun: `1 stitch`, `2 stitches`.
pub(super) fn count_of(n: u64, one: &str, many: &str) -> String {
    format!("{} {}", thousands(n), if n == 1 { one } else { many })
}

/// A list of step numbers in words: `step 2`, `steps 2 and 3`, `steps 2, 3 and 5`.
fn steps_list(indices: &[usize]) -> String {
    let nums: Vec<String> = indices.iter().map(|i| (i + 1).to_string()).collect();
    match nums.len() {
        0 => String::new(),
        1 => format!("step {}", nums[0]),
        n => format!("steps {} and {}", nums[..n - 1].join(", "), nums[n - 1]),
    }
}

/// A notation finding's quote, shortened like the project screen shortens it.
fn quote(text: &str) -> String {
    if text.trim().is_empty() {
        return String::new();
    }
    let chars: Vec<char> = text.chars().collect();
    if chars.len() <= 40 {
        text.to_string()
    } else {
        format!("{}…", chars[..39].iter().collect::<String>())
    }
}

/// Read `notation` in `reading`'s mode, never failing: a strict rejection keeps the lenient
/// best-effort structure with the rejection's diagnostics.
fn read_notation(notation: &str, reading: Reading) -> (ParsedNotation, bool) {
    match reading {
        Reading::Strict => match parse_strict(notation) {
            Ok(p) => (p, true),
            Err(rejection) => {
                let mut p = parse_lenient(notation);
                p.mode = crate::notation::ParseMode::Strict;
                p.diagnostics = rejection.diagnostics;
                (p, false)
            }
        },
        Reading::Lenient => {
            let p = parse_lenient(notation);
            let accepted = p
                .diagnostics
                .iter()
                .all(|d| d.severity == NotationSeverity::Info);
            (p, accepted)
        }
    }
}

/// True when the reading has at least one needle step.
fn has_path(p: &ParsedNotation) -> bool {
    p.passes.iter().any(|pass| !pass.steps.is_empty())
}

/// The problems of a reading (findings above formatting notes).
fn problems_of(p: &ParsedNotation) -> Vec<&NotationDiagnostic> {
    p.diagnostics
        .iter()
        .filter(|d| d.severity > NotationSeverity::Info)
        .collect()
}

fn summary(p: &ParsedNotation, accepted: bool) -> NotationSummary {
    NotationSummary {
        accepted,
        fidelity: p.fidelity,
        normalized: p.normalized(),
        connections: p.connections.clone(),
        problems: problems_of(p).len(),
    }
}

/// True when an accepted reading has a needle path but no connection to the previous round.
fn lacks_connection(p: &ParsedNotation, accepted: bool) -> bool {
    accepted && has_path(p) && p.connections.is_empty()
}

/// The project's stitch, read once.
struct ProjectStitch {
    reading: StitchReading,
    /// It has a needle path and no connection (and was accepted).
    lacks_connection: bool,
}

/// A part in progress: what the walk knows about it.
struct Part {
    number: u32,
    /// The stitch count, when the recipe's numbers give it.
    count: Option<u32>,
    finished: bool,
    /// The last segment of the part that is a step of the work (not a note).
    last: usize,
    /// Where it was finished, once it is.
    finished_at: Option<usize>,
}

struct Checker<'a> {
    recipe: &'a Recipe,
    /// The project's stitch read strictly, when it has one.
    project: Option<ProjectStitch>,
    issues: Vec<RecipeIssue>,
    reports: Vec<SegmentReport>,
    /// First position of each non-empty id.
    ids: HashMap<&'a str, usize>,
    /// Opening position -> the segment that worked or closed it.
    used: HashMap<usize, usize>,
    part: Option<Part>,
    parts: u32,
    /// Segments worked in the project's stitch.
    project_users: Vec<usize>,
    /// Of those, the ones that work into a previous round.
    project_connectors: Vec<usize>,
}

impl<'a> Checker<'a> {
    fn new(recipe: &'a Recipe, project_notation: &'a str) -> Self {
        let project = if project_notation.trim().is_empty() {
            None
        } else if utf16_len(project_notation) > MAX_NOTATION {
            Some(ProjectStitch {
                reading: StitchReading {
                    notation: project_notation.to_string(),
                    name: String::new(),
                    reading: Reading::Strict,
                    read: None,
                },
                lacks_connection: false,
            })
        } else {
            let (parsed, accepted) = read_notation(project_notation, Reading::Strict);
            Some(ProjectStitch {
                lacks_connection: lacks_connection(&parsed, accepted),
                reading: StitchReading {
                    notation: project_notation.to_string(),
                    name: String::new(),
                    reading: Reading::Strict,
                    read: Some(summary(&parsed, accepted)),
                },
            })
        };
        Checker {
            recipe,
            project,
            issues: Vec::new(),
            reports: Vec::new(),
            ids: HashMap::new(),
            used: HashMap::new(),
            part: None,
            parts: 0,
            project_users: Vec::new(),
            project_connectors: Vec::new(),
        }
    }

    fn place(&self, i: usize) -> String {
        place_of(&self.recipe.segments[i], i)
    }

    /// `step 4 (Thumb opening)` as it reads inside a sentence.
    fn step_ref(&self, i: usize) -> String {
        written::step_ref(self.recipe, i)
    }

    fn at(&mut self, i: usize, code: RecipeCode, severity: RecipeSeverity, message: String) {
        let text = format!("{}: {message}", self.place(i));
        self.issues.push(RecipeIssue {
            code,
            severity,
            segment: Some(i),
            segment_id: Some(shorten(&self.recipe.segments[i].id)),
            fit: None,
            message,
            text,
        });
    }

    fn at_fit(&mut self, f: usize, code: RecipeCode, severity: RecipeSeverity, message: String) {
        let label = self.recipe.fit[f].label.trim();
        let place = if label.is_empty() {
            format!("Fit {}", f + 1)
        } else {
            format!("Fit {} ({})", f + 1, shorten(label))
        };
        self.issues.push(RecipeIssue {
            code,
            severity,
            segment: None,
            segment_id: None,
            fit: Some(f),
            text: format!("{place}: {message}"),
            message,
        });
    }

    fn whole(&mut self, code: RecipeCode, severity: RecipeSeverity, message: String) {
        self.issues.push(RecipeIssue {
            code,
            severity,
            segment: None,
            segment_id: None,
            fit: None,
            text: message.clone(),
            message,
        });
    }

    fn run(mut self) -> RecipeReport {
        let recipe = self.recipe;
        if recipe.segments.is_empty() {
            self.whole(
                RecipeCode::EmptyRecipe,
                RecipeSeverity::Warning,
                "The recipe has no steps yet.".to_string(),
            );
        }
        for (f, m) in recipe.fit.iter().enumerate() {
            self.check_fit(f, m);
        }
        for (i, s) in recipe.segments.iter().enumerate() {
            self.check_id(i, s);
        }
        for i in 0..recipe.segments.len() {
            self.segment(i);
        }
        if let Some(part) = self.part.take() {
            self.close_part(&part);
        }
        for i in 0..recipe.segments.len() {
            if matches!(recipe.segments[i].work, Work::Opening { .. })
                && !self.used.contains_key(&i)
            {
                self.at(
                    i,
                    RecipeCode::OpeningNotUsed,
                    RecipeSeverity::Warning,
                    "this opening is never worked or closed: add a pick-up that starts from it, \
                     or a join that closes it"
                        .to_string(),
                );
            }
        }
        self.project_findings();
        // Segment issues in segment order (stable within a segment), then fit, then recipe-wide.
        self.issues.sort_by_key(|i| match (i.segment, i.fit) {
            (Some(s), _) => (0, s),
            (None, Some(f)) => (1, f),
            (None, None) => (2, 0),
        });
        let fit = recipe.fit.iter().map(written::measurement).collect();
        RecipeReport {
            segments: self.reports,
            issues: self.issues,
            fit,
            project_stitch: self.project.map(|p| p.reading),
        }
    }

    fn check_fit(&mut self, f: usize, m: &Measurement) {
        if let Some((code, severity, message)) = measurement_problem(m, "this measurement", true) {
            self.at_fit(f, code, severity, message);
        }
    }

    fn check_id(&mut self, i: usize, s: &'a Segment) {
        if s.id.trim().is_empty() {
            self.at(
                i,
                RecipeCode::MissingId,
                RecipeSeverity::Error,
                "has no id, so no other step can name it".to_string(),
            );
            return;
        }
        match self.ids.get(s.id.as_str()) {
            Some(&first) => {
                let message = format!(
                    "has the same id ({}) as {}, so a step that names it is ambiguous",
                    shorten(&s.id),
                    self.step_ref(first)
                );
                self.at(i, RecipeCode::DuplicateId, RecipeSeverity::Error, message);
            }
            None => {
                self.ids.insert(s.id.as_str(), i);
            }
        }
    }

    /// The part a step of `phase` at `i` works in: begins a part for a start, and reports a step
    /// outside any part.
    fn enter(&mut self, i: usize, phase: Phase) -> Option<u32> {
        match phase {
            Phase::Start => {
                if let Some(prev) = self.part.take() {
                    self.close_part(&prev);
                }
                self.parts += 1;
                self.part = Some(Part {
                    number: self.parts,
                    count: None,
                    finished: false,
                    last: i,
                    finished_at: None,
                });
                Some(self.parts)
            }
            Phase::Other => self.part.as_ref().filter(|p| !p.finished).map(|p| p.number),
            Phase::Body | Phase::Shaping | Phase::Finish => {
                if let Some(p) = self.part.as_mut().filter(|p| !p.finished) {
                    p.last = i;
                    if phase == Phase::Finish {
                        p.finished = true;
                        p.finished_at = Some(i);
                    }
                    return Some(p.number);
                }
                let message = match &self.part {
                    Some(p) => format!(
                        "comes after Part {} was finished in {}: begin the next part with a start \
                         (a foundation chain, a centre start, or loops picked up from earlier work)",
                        p.number,
                        self.step_ref(p.finished_at.unwrap_or(p.last))
                    ),
                    None => "comes before any start: begin the recipe with a start (a foundation \
                             chain, a centre start, or loops picked up from earlier work)"
                        .to_string(),
                };
                self.at(i, RecipeCode::BeforeStart, RecipeSeverity::Error, message);
                None
            }
        }
    }

    /// Report a part that ended (a new start, or the end of the recipe) without a finish.
    fn close_part(&mut self, part: &Part) {
        if part.finished {
            return;
        }
        let message = format!(
            "Part {} ends here without a finish: add a finish step after this one",
            part.number
        );
        self.at(
            part.last,
            RecipeCode::PartNotFinished,
            RecipeSeverity::Warning,
            message,
        );
    }

    fn segment(&mut self, i: usize) {
        let recipe = self.recipe;
        let s = &recipe.segments[i];
        let kind = s.work.kind();
        let phase = s.work.phase();
        let part = self.enter(i, phase);
        // A start begins a new count; anything else continues the part's.
        let before = match phase {
            Phase::Start => None,
            _ => self.part.as_ref().and_then(|p| p.count),
        };

        let stitch = self.stitch(i, s, kind);
        self.measurements(i, s);
        let count = self.count(i, s, part.is_some(), before);
        if let (Some(p), Count::Known(n)) = (self.part.as_mut(), count) {
            p.count = Some(n);
        } else if let (Some(p), Count::Unknown) = (self.part.as_mut(), count) {
            p.count = None;
        }
        if let Work::Freeform { text, .. } = &s.work {
            if text.trim().is_empty() {
                self.at(
                    i,
                    RecipeCode::EmptyFreeform,
                    RecipeSeverity::Warning,
                    "has no text".to_string(),
                );
            }
        }
        let written = written::segment(recipe, i, &self.ids);
        self.reports.push(SegmentReport {
            index: i,
            id: s.id.clone(),
            kind,
            phase,
            part,
            stitch,
            count,
            written,
            target: s.target.as_ref().map(written::measurement),
            checked: kind != SegmentKind::Freeform,
        });
    }

    /// The stitch of segment `i`, with its notation findings (at most [`MAX_NOTATION_ISSUES`] of
    /// them, then one count of the rest).
    fn stitch(&mut self, i: usize, s: &Segment, kind: SegmentKind) -> Option<StitchUse> {
        match &s.stitch {
            Some(own) if !own.notation.trim().is_empty() => {
                let mut reading = StitchReading {
                    notation: own.notation.clone(),
                    name: own.name.clone(),
                    reading: own.reading,
                    read: None,
                };
                if utf16_len(&own.notation) > MAX_NOTATION {
                    self.at(
                        i,
                        RecipeCode::NotationTooLong,
                        RecipeSeverity::Error,
                        format!(
                            "the stitch notation is longer than {MAX_NOTATION} characters, so Ply \
                             does not read it"
                        ),
                    );
                    return Some(StitchUse::Own(reading));
                }
                let (parsed, accepted) = read_notation(&own.notation, own.reading);
                let problems = problems_of(&parsed);
                for d in problems.iter().take(MAX_NOTATION_ISSUES) {
                    let severity = if d.severity == NotationSeverity::Error {
                        RecipeSeverity::Error
                    } else {
                        RecipeSeverity::Warning
                    };
                    let q = quote(d.span.text(&parsed.source));
                    let message = if q.is_empty() {
                        format!("the stitch notation has a problem: {}", d.message)
                    } else {
                        format!(
                            "the stitch notation has a problem at \"{q}\": {}",
                            d.message
                        )
                    };
                    self.at(i, RecipeCode::NotationProblem, severity, message);
                }
                if problems.len() > MAX_NOTATION_ISSUES {
                    let rest = &problems[MAX_NOTATION_ISSUES..];
                    let severity = if rest.iter().any(|d| d.severity == NotationSeverity::Error) {
                        RecipeSeverity::Error
                    } else {
                        RecipeSeverity::Warning
                    };
                    let message = format!(
                        "the stitch notation has {} more {}; fix the ones above first",
                        thousands(rest.len() as u64),
                        if rest.len() == 1 {
                            "problem"
                        } else {
                            "problems"
                        }
                    );
                    self.at(i, RecipeCode::NotationProblem, severity, message);
                }
                // Only an accepted reading: a rejected one would repeat its own problems.
                if kind.connects_to_previous_round() && lacks_connection(&parsed, accepted) {
                    self.at(
                        i,
                        RecipeCode::NoConnection,
                        RecipeSeverity::Warning,
                        "the stitch has no connection to the previous round (such as F1 or B1), \
                         so the recipe does not say how this step joins the round before"
                            .to_string(),
                    );
                }
                reading.read = Some(summary(&parsed, accepted));
                Some(StitchUse::Own(reading))
            }
            Some(_) => {
                if kind.uses_stitch() {
                    self.at(
                        i,
                        RecipeCode::NoStitch,
                        RecipeSeverity::Warning,
                        "is set to its own stitch, but no notation is given".to_string(),
                    );
                }
                None
            }
            None if kind.uses_stitch() => match &self.project {
                Some(p) => {
                    let lacks = p.lacks_connection;
                    self.project_users.push(i);
                    if kind.connects_to_previous_round() && lacks {
                        self.project_connectors.push(i);
                    }
                    Some(StitchUse::Project)
                }
                None => {
                    self.at(
                        i,
                        RecipeCode::NoStitch,
                        RecipeSeverity::Warning,
                        "does not say which stitch it is worked in: choose the project's stitch \
                         or give this step its own"
                            .to_string(),
                    );
                    None
                }
            },
            None => None,
        }
    }

    /// The recipe-wide findings about the project's stitch, once, naming the steps that use it.
    fn project_findings(&mut self) {
        let (problems, read) = match &self.project {
            Some(p) => (
                p.reading.read.as_ref().map_or(0, |r| r.problems),
                p.reading.read.is_some(),
            ),
            None => return,
        };
        let users = steps_list(&self.project_users);
        if !read && !self.project_users.is_empty() {
            let message = format!(
                "The project's stitch notation is longer than {MAX_NOTATION} characters, so Ply \
                 does not read it, and {} {} worked in it: see the project's Stitch field.",
                users,
                if self.project_users.len() == 1 {
                    "is"
                } else {
                    "are"
                }
            );
            self.whole(RecipeCode::NotationTooLong, RecipeSeverity::Error, message);
            return;
        }
        let connectors = steps_list(&self.project_connectors);
        if problems > 0 && !self.project_users.is_empty() {
            let message = format!(
                "The project's stitch notation has {}, and {} {} worked in it: see the project's \
                 Stitch field.",
                count_of(problems as u64, "problem", "problems"),
                users,
                if self.project_users.len() == 1 {
                    "is"
                } else {
                    "are"
                }
            );
            self.whole(
                RecipeCode::ProjectNotationProblem,
                RecipeSeverity::Error,
                message,
            );
        }
        if !self.project_connectors.is_empty() {
            let message = format!(
                "The project's stitch has no connection to the previous round (such as F1 or B1), \
                 and {connectors} {} into the round before, so the recipe does not say how.",
                if self.project_connectors.len() == 1 {
                    "works"
                } else {
                    "work"
                }
            );
            self.whole(RecipeCode::NoConnection, RecipeSeverity::Warning, message);
        }
    }

    fn measurements(&mut self, i: usize, s: &Segment) {
        if let Some(m) = &s.target {
            if let Some((code, severity, message)) =
                measurement_problem(m, "the target measurement", true)
            {
                self.at(i, code, severity, message);
            }
        }
        if let Some(Extent::Until { measure }) = extent_of(&s.work) {
            if measure.value.is_none() && measure.label.trim().is_empty() {
                self.at(
                    i,
                    RecipeCode::UntilNotStated,
                    RecipeSeverity::Warning,
                    "works until a point the recipe does not state: name a landmark (such as the \
                     base of the thumb) or give a measurement"
                        .to_string(),
                );
            } else if let Some((code, severity, message)) =
                measurement_problem(measure, "the measurement it works until", false)
            {
                self.at(i, code, severity, message);
            }
        }
    }

    /// Positive-count checks for one stated number; `true` when it can be used.
    fn positive(&mut self, i: usize, n: u32, what: impl FnOnce() -> String) -> bool {
        if n == 0 {
            self.at(
                i,
                RecipeCode::CountNotPositive,
                RecipeSeverity::Error,
                format!("{}: a count must be at least 1", what()),
            );
            false
        } else {
            true
        }
    }

    /// Cap check for a stitch number; `true` when it can be used.
    fn within_cap(&mut self, i: usize, n: u64, what: &str, noun: Noun) -> bool {
        if n > u64::from(MAX_STITCHES) {
            self.at(
                i,
                RecipeCode::CountTooLarge,
                RecipeSeverity::Error,
                format!(
                    "{what} {}, more than Ply counts ({})",
                    count_of(n, noun.0, noun.1),
                    thousands(u64::from(MAX_STITCHES))
                ),
            );
            false
        } else {
            true
        }
    }

    /// A stated stitch number that must be positive and within the cap.
    fn stitch_number(&mut self, i: usize, n: Option<u32>, what: &str, noun: Noun) -> Option<u32> {
        let n = n?;
        let ok = self.positive(i, n, || format!("{what} {}", count_of(0, noun.0, noun.1)));
        (ok && self.within_cap(i, u64::from(n), what, noun)).then_some(n)
    }

    /// Report a count that was known and is not any more.
    fn lost_count(&mut self, i: usize, before: Option<u32>, why: &str) -> Count {
        if before.is_some() {
            self.at(
                i,
                RecipeCode::CountUnknown,
                RecipeSeverity::Info,
                format!(
                    "{why}, so the stitches after it cannot be counted; later counts are not \
                     checked"
                ),
            );
        }
        Count::Unknown
    }

    /// The count after segment `i`, checking its numbers. `in_part` is false for a step outside any
    /// part (its numbers are still checked for sense, but nothing is counted).
    fn count(&mut self, i: usize, s: &Segment, in_part: bool, before: Option<u32>) -> Count {
        let kind = s.work.kind();
        // Rounds and rows: positive counts; "until N stitches" only makes sense for shaping.
        if let Some(ext) = extent_of(&s.work) {
            match ext {
                Extent::Rounds { count } => {
                    let unit = match kind {
                        SegmentKind::Rows | SegmentKind::ShortRows => ("row", "rows"),
                        _ => ("round", "rounds"),
                    };
                    self.positive(i, *count, || {
                        format!("works {}", count_of(0, unit.0, unit.1))
                    });
                }
                Extent::UntilStitches { count } => {
                    if !matches!(kind, SegmentKind::Increase | SegmentKind::Decrease) {
                        self.at(
                            i,
                            RecipeCode::ExtentNotForKind,
                            RecipeSeverity::Error,
                            "works until a number of stitches, but only an increase or a decrease \
                             changes the stitch count"
                                .to_string(),
                        );
                    } else {
                        let what = if kind == SegmentKind::Increase {
                            "increases until there are"
                        } else {
                            "decreases until there are"
                        };
                        self.positive(i, *count, || {
                            format!("{what} {}", count_of(0, "stitch", "stitches"))
                        });
                    }
                }
                Extent::Until { .. } => {}
            }
        }
        let phase = s.work.phase();
        if !in_part || phase == Phase::Other {
            // Still check the numbers for sense.
            self.numbers_only(i, &s.work);
            return Count::NotApplicable;
        }
        match &s.work {
            Work::FoundationChain { stitches, .. } => {
                let n = self.stitch_number(i, *stitches, "makes a foundation chain of", STITCHES);
                started(*stitches, n)
            }
            Work::CentreStart { stitches } => {
                let n = self.stitch_number(i, *stitches, "starts with", STITCHES);
                started(*stitches, n)
            }
            Work::PickUp { from, stitches } => {
                if let Some(id) = from {
                    self.reference(i, id, true);
                }
                let n = self.stitch_number(i, *stitches, "picks up", LOOPS);
                started(*stitches, n)
            }
            Work::Rounds { .. } | Work::Rows { .. } | Work::ShortRows { .. } => known(before),
            Work::Increase {
                per_round, extent, ..
            } => self.shaping(i, true, *per_round, extent.as_ref(), before),
            Work::Decrease {
                per_round, extent, ..
            } => self.shaping(i, false, *per_round, extent.as_ref(), before),
            Work::Opening { skip, stitches } => self.opening(i, *skip, *stitches, before),
            Work::Join { closes } => {
                if let Some(id) = closes {
                    self.reference(i, id, false);
                }
                known(before)
            }
            Work::Finish { .. } => known(before),
            // A free-text finish ends the part; its count no longer matters.
            Work::Freeform {
                role: Phase::Finish,
                ..
            } => Count::Unknown,
            Work::Freeform { .. } => self.lost_count(i, before, "Ply does not read free text"),
        }
    }

    /// The number checks of a step outside a part (nothing is counted there).
    fn numbers_only(&mut self, i: usize, work: &Work) {
        match work {
            Work::FoundationChain { stitches, .. } => {
                self.stitch_number(i, *stitches, "makes a foundation chain of", STITCHES);
            }
            Work::CentreStart { stitches } => {
                self.stitch_number(i, *stitches, "starts with", STITCHES);
            }
            Work::PickUp { from, stitches } => {
                if let Some(id) = from {
                    self.reference(i, id, true);
                }
                self.stitch_number(i, *stitches, "picks up", LOOPS);
            }
            Work::Increase { per_round, .. } => {
                self.stitch_number(i, *per_round, "increases by", STITCHES);
            }
            Work::Decrease { per_round, .. } => {
                self.stitch_number(i, *per_round, "decreases by", STITCHES);
            }
            Work::Opening { skip, stitches } => {
                self.stitch_number(i, *skip, "skips", LOOPS);
                self.stitch_number(i, *stitches, "works across the gap", STITCHES);
            }
            Work::Join { closes: Some(id) } => {
                self.reference(i, id, false);
            }
            _ => {}
        }
        if let Some(Extent::UntilStitches { count }) = extent_of(work) {
            self.within_cap(i, u64::from(*count), "works until there are", STITCHES);
        }
    }

    fn shaping(
        &mut self,
        i: usize,
        increase: bool,
        per_round: Option<u32>,
        extent: Option<&Extent>,
        before: Option<u32>,
    ) -> Count {
        let verb = if increase {
            "increases by"
        } else {
            "decreases by"
        };
        let per = self.stitch_number(i, per_round, verb, STITCHES);
        let noun = if increase { "adds" } else { "removes" };
        match extent {
            Some(Extent::UntilStitches { count }) => {
                let target = *count;
                if target == 0
                    || !self.within_cap(i, u64::from(target), "works until there are", STITCHES)
                {
                    return Count::Refused;
                }
                if per_round.is_some() && per.is_none() {
                    return Count::Refused;
                }
                match before {
                    Some(b) if increase && target <= b => {
                        self.at(
                            i,
                            RecipeCode::IncreaseToFewer,
                            RecipeSeverity::Error,
                            format!(
                                "increases until there are {}, but the round already has {b}",
                                count_of(u64::from(target), "stitch", "stitches")
                            ),
                        );
                        Count::Refused
                    }
                    Some(b) if !increase && target >= b => {
                        self.at(
                            i,
                            RecipeCode::DecreaseToMore,
                            RecipeSeverity::Error,
                            format!(
                                "decreases until there are {}, but the round has only {b}",
                                count_of(u64::from(target), "stitch", "stitches")
                            ),
                        );
                        Count::Refused
                    }
                    _ => Count::Known(target),
                }
            }
            Some(Extent::Rounds { count: rounds }) if per.is_some() && *rounds > 0 => {
                let p = per.expect("checked");
                let Some(b) = before else {
                    return Count::Unknown;
                };
                let change = u64::from(p) * u64::from(*rounds);
                if increase {
                    let after = u64::from(b) + change;
                    if !self.within_cap(i, after, "would have", STITCHES) {
                        return Count::Refused;
                    }
                    Count::Known(after as u32)
                } else if change >= u64::from(b) {
                    let removes = format!(
                        "{p} in each of {}",
                        count_of(u64::from(*rounds), "round", "rounds")
                    );
                    let message = if change == u64::from(b) {
                        format!(
                            "removes all {} of the round ({removes}): a decrease must leave some",
                            count_of(change, "stitch", "stitches")
                        )
                    } else {
                        format!(
                            "removes {} ({removes}), but the round has only {b}",
                            count_of(change, "stitch", "stitches")
                        )
                    };
                    self.at(
                        i,
                        RecipeCode::DecreaseTooMany,
                        RecipeSeverity::Error,
                        message,
                    );
                    Count::Refused
                } else {
                    Count::Known(b - change as u32)
                }
            }
            Some(Extent::Rounds { count: 0 }) => Count::Refused,
            _ if per_round.is_some() && per.is_none() => Count::Refused,
            _ => {
                let why = format!("this step does not say how many stitches it {noun} in all");
                self.lost_count(i, before, &why)
            }
        }
    }

    fn opening(
        &mut self,
        i: usize,
        skip: Option<u32>,
        stitches: Option<u32>,
        before: Option<u32>,
    ) -> Count {
        let skipped = self.stitch_number(i, skip, "skips", LOOPS);
        let across = self.stitch_number(i, stitches, "works across the gap", STITCHES);
        if (skip.is_some() && skipped.is_none()) || (stitches.is_some() && across.is_none()) {
            return Count::Refused;
        }
        if let (Some(k), Some(b)) = (skipped, before) {
            if k >= b {
                self.at(
                    i,
                    RecipeCode::OpeningTooWide,
                    RecipeSeverity::Error,
                    format!(
                        "skips {} of the previous round, but the round has only {b}: an opening \
                         must leave part of the round connected",
                        count_of(u64::from(k), "loop", "loops")
                    ),
                );
                return Count::Refused;
            }
        }
        match (skipped, across, before) {
            (Some(k), Some(n), Some(b)) => {
                let after = u64::from(b) - u64::from(k) + u64::from(n);
                if !self.within_cap(i, after, "would have", STITCHES) {
                    return Count::Refused;
                }
                Count::Known(after as u32)
            }
            _ => self.lost_count(
                i,
                before,
                "this step does not say both how many loops it skips and how many stitches it \
                 works across the gap",
            ),
        }
    }

    /// Check that segment `i` names an earlier, unused opening. `pick_up` picks the wording.
    fn reference(&mut self, i: usize, id: &str, pick_up: bool) {
        let verb = if pick_up { "starts from" } else { "closes" };
        let Some(&target) = self.ids.get(id) else {
            self.at(
                i,
                RecipeCode::UnknownStep,
                RecipeSeverity::Error,
                format!("{verb} a step that is not in the recipe ({})", shorten(id)),
            );
            return;
        };
        if !matches!(self.recipe.segments[target].work, Work::Opening { .. }) {
            let message = format!("{verb} {}, which is not an opening", self.step_ref(target));
            self.at(i, RecipeCode::NotAnOpening, RecipeSeverity::Error, message);
            return;
        }
        if target > i {
            let message = format!(
                "{verb} the opening in {}, which comes later: an opening can only be worked or \
                 closed after the step that makes it",
                self.step_ref(target)
            );
            self.at(i, RecipeCode::OpeningLater, RecipeSeverity::Error, message);
            return;
        }
        if let Some(&by) = self.used.get(&target) {
            let done = if matches!(self.recipe.segments[by].work, Work::PickUp { .. }) {
                "worked"
            } else {
                "closed"
            };
            let message = format!(
                "{verb} the opening in {}, but {} already {done} it",
                self.step_ref(target),
                self.step_ref(by)
            );
            self.at(
                i,
                RecipeCode::OpeningAlreadyUsed,
                RecipeSeverity::Error,
                message,
            );
            return;
        }
        self.used.insert(target, i);
    }
}

/// A singular and plural noun for counts.
type Noun = (&'static str, &'static str);
const STITCHES: Noun = ("stitch", "stitches");
const LOOPS: Noun = ("loop", "loops");

/// The count a start gives: its number when usable, refused when stated but unusable.
fn started(stated: Option<u32>, usable: Option<u32>) -> Count {
    match (stated, usable) {
        (_, Some(n)) => Count::Known(n),
        (Some(_), None) => Count::Refused,
        (None, _) => Count::Unknown,
    }
}

fn known(n: Option<u32>) -> Count {
    n.map_or(Count::Unknown, Count::Known)
}

/// The problem with a measurement, if any: a value that is not positive, a value without a unit,
/// or (when `require_value`) no value at all.
fn measurement_problem(
    m: &Measurement,
    what: &str,
    require_value: bool,
) -> Option<(RecipeCode, RecipeSeverity, String)> {
    match m.value {
        Some(v) if !v.is_finite() || v <= 0.0 => Some((
            RecipeCode::MeasurementNotPositive,
            RecipeSeverity::Error,
            format!(
                "{what} is {}, but a length must be more than 0",
                written::length(m).unwrap_or_else(|| "not a number".to_string())
            ),
        )),
        Some(v) if m.unit.is_none() => Some((
            RecipeCode::MeasurementNoUnit,
            RecipeSeverity::Error,
            format!(
                "{what} gives {} with no unit: choose mm, cm or in",
                written::number(v)
            ),
        )),
        None if require_value => Some((
            RecipeCode::MeasurementNoValue,
            RecipeSeverity::Warning,
            format!("{what} has no value yet"),
        )),
        _ => None,
    }
}
