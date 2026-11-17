// A nalbinding RECIPE (M8-04, ADR 0017): the optional structured part of a `.plynal` project. An
// ordered list of segments with stable ids, from the start (a foundation chain, a centre start,
// loops picked up around an opening) through the body (rounds, rows) and shaping (increases,
// decreases, short rows, an opening, a join) to the finish, plus FREE TEXT segments Ply never reads.
//
// Pure data, no FFI. The app writes and reads this as the `recipe` object of a schema version 3
// `.plynal` (see NalbindProject); the engine (`ply_nalbind::recipe`) mirrors the same JSON field for
// field so its tests read the same fixture files, and checks a recipe sent to it through the
// bridge. Reading is strict about shape: an unknown segment kind or value, a negative or
// fractional count, a length that is not a finite number, or more segments, fit measurements or
// ticks than the limits is refused (the whole file is unreadable), never loaded with a segment
// dropped. Missing optional fields read as "not stated". Keys this build does not know, anywhere in
// the recipe, are kept verbatim and written back. Text is not capped on reading (a saved file must
// always reopen); the editor's fields stop where the engine stops checking.
//
// Ids are never given twice: the recipe keeps the highest segment number ever given
// (`lastSegmentNumber`), so a deleted step's id is not reused and a tick can never land on another
// step.

/// Most segments a recipe may hold (mirrors the engine's `MAX_SEGMENTS`).
const int kMaxRecipeSegments = 1000;

/// Most fit measurements a recipe may hold (mirrors `MAX_FIT`).
const int kMaxRecipeFit = 100;

/// Longest text the editor's fields take, and the engine checks (its `MAX_TEXT`), in UTF-16 code
/// units: Dart's `String.length`, the engine's measure (an emoji counts as two).
const int kMaxRecipeText = 10000;

/// Longest notation the editor takes and the engine reads (its `MAX_NOTATION`), in UTF-16 units.
const int kMaxRecipeNotation = 200;

/// Most text a whole recipe holds before the engine stops checking it (its `MAX_TOTAL_TEXT`).
const int kMaxRecipeTotalText = 200000;

/// The largest count a file, the form and the bridge carry (u32). The engine reports a stitch
/// number above 1,000,000 as too large to count.
const int kMaxRecipeCount = 0xFFFFFFFF;

const int _maxCount = kMaxRecipeCount;

/// The stage of the work a segment belongs to.
enum RecipePhase {
  start('start', 'Start'),
  body('body', 'Body'),
  shaping('shaping', 'Shaping'),
  finish('finish', 'Finish'),
  other('other', 'Note');

  const RecipePhase(this.json, this.label);

  /// The value in the file.
  final String json;

  /// The heading the editor, follow view and PDF show.
  final String label;
}

/// What a segment does. Each kind has a name, its phase and one plain help line.
enum SegmentKind {
  foundationChain('foundationChain', 'Foundation chain', RecipePhase.start,
      'A chain of stitches with no round before it, joined into a ring or left open for rows.'),
  centreStart('centreStart', 'Centre start', RecipePhase.start,
      'A small ring of stitches at the centre: the crown of a hat, the tip of a mitten, a sock toe.'),
  pickUp('pickUp', 'Pick up loops', RecipePhase.start,
      'Start a new part from loops of earlier work, such as a thumb from around the thumb opening.'),
  rounds('rounds', 'Rounds', RecipePhase.body,
      'Rounds without shaping, in a spiral (the usual way) or joined.'),
  rows('rows', 'Rows', RecipePhase.body, 'Rows worked back and forth, for a flat panel.'),
  increase('increase', 'Increase', RecipePhase.shaping,
      'Add stitches each round, for example by working two stitches into one loop.'),
  decrease('decrease', 'Decrease', RecipePhase.shaping,
      'Take stitches away each round, by connecting through two loops at once or skipping one.'),
  shortRows('shortRows', 'Short rows', RecipePhase.shaping,
      'Rows worked back and forth over part of the round, to add height in one place.'),
  opening('opening', 'Opening', RecipePhase.shaping,
      'Leave a gap, such as a thumb opening, to be worked or closed later.'),
  join('join', 'Join', RecipePhase.shaping, 'Join edges, or close an opening.'),
  finish('finish', 'Finish', RecipePhase.finish,
      'End the part: draw the last loops together, or taper the end at an open edge.'),
  freeform('freeform', 'Free text', RecipePhase.other,
      'Your own words for anything the other kinds cannot say. Ply does not read or check them.');

  const SegmentKind(this.json, this.label, this.phase, this.help);

  final String json;
  final String label;

  /// The phase of every segment of this kind (free text: the segment's own role).
  final RecipePhase phase;

  /// One plain line shown in the kind chooser and the form.
  final String help;

  /// Whether this kind is worked in a stitch (so "no stitch of its own" means the project's).
  bool get usesStitch =>
      this != SegmentKind.join && this != SegmentKind.finish && this != SegmentKind.freeform;

  /// Whether this kind has a "how far" (rounds, rows, until).
  bool get hasExtent => const {
        SegmentKind.rounds,
        SegmentKind.rows,
        SegmentKind.increase,
        SegmentKind.decrease,
        SegmentKind.shortRows,
      }.contains(this);

  /// Whether "rows" is the word for its extent.
  bool get countsRows => this == SegmentKind.rows || this == SegmentKind.shortRows;
}

enum ChainJoin {
  ring('ring', 'Join into a ring (work in the round)'),
  flat('flat', 'Leave open (work in rows)');

  const ChainJoin(this.json, this.label);
  final String json;
  final String label;
}

enum RoundJoin {
  spiral('spiral', 'In a spiral'),
  joined('joined', 'Joined rounds');

  const RoundJoin(this.json, this.label);
  final String json;
  final String label;
}

enum IncreaseMethod {
  sameLoopTwice('sameLoopTwice', 'Two stitches into the same loop');

  const IncreaseMethod(this.json, this.label);
  final String json;
  final String label;
}

enum DecreaseMethod {
  twoLoopsAtOnce('twoLoopsAtOnce', 'Connect through two loops at once'),
  skipALoop('skipALoop', 'Skip a loop');

  const DecreaseMethod(this.json, this.label);
  final String json;
  final String label;
}

enum FinishMethod {
  closeTip('closeTip', 'Draw the last loops together (close a tip)'),
  taperEdge('taperEdge', 'Taper at an open edge (a cuff or brim)');

  const FinishMethod(this.json, this.label);
  final String json;
  final String label;
}

/// A length unit.
enum LengthUnit {
  mm('mm'),
  cm('cm'),
  inch('in');

  const LengthUnit(this.json);

  /// The value in the file, and the symbol after a number.
  final String json;
}

/// How a segment's own notation is read.
enum StitchReading {
  /// Written for this recipe: every problem is an error.
  strict('strict', 'Strictly (written for this recipe)'),

  /// Copied from a source in another dialect: kept verbatim, each problem at its own severity.
  lenient('lenient', 'As written in a source (another dialect)');

  const StitchReading(this.json, this.label);
  final String json;
  final String label;
}

/// How far a segment goes.
enum ExtentType {
  rounds('rounds'),
  untilStitches('untilStitches'),
  until('until');

  const ExtentType(this.json);
  final String json;
}

T _enumOf<T extends Enum>(List<T> values, String Function(T) json, Object? raw, String what) {
  if (raw is! String) throw FormatException('$what is not text: $raw');
  for (final v in values) {
    if (json(v) == raw) return v;
  }
  throw FormatException('unknown $what "$raw"');
}

T? _optEnum<T extends Enum>(List<T> values, String Function(T) json, Object? raw, String what) =>
    raw == null ? null : _enumOf(values, json, raw, what);

String _text(Map<String, dynamic> json, String key) {
  final v = json[key];
  if (v == null) return '';
  if (v is! String) throw FormatException('$key is not text');
  return v;
}

String? _optText(Map<String, dynamic> json, String key) {
  final v = json[key];
  if (v == null) return null;
  if (v is! String) throw FormatException('$key is not text');
  return v;
}

int? _optCount(Map<String, dynamic> json, String key) {
  final v = json[key];
  if (v == null) return null;
  if (v is! int || v < 0 || v > _maxCount) throw FormatException('$key is not a count: $v');
  return v;
}

Map<String, dynamic> _object(Object? raw, String what) {
  if (raw is! Map<String, dynamic>) throw FormatException('$what is not an object');
  return raw;
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Deep equality of decoded JSON values (the unknown keys a recipe keeps are compared this way).
bool jsonValueEquals(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (!b.containsKey(e.key) || !jsonValueEquals(e.value, b[e.key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!jsonValueEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// The keys of [json] this build does not know, in file order, kept verbatim.
Map<String, Object?> _extra(Map<String, dynamic> json, Set<String> known) => {
      for (final e in json.entries)
        if (!known.contains(e.key)) e.key: e.value,
    };

/// A number as a form shows it back: `20`, `12.5`, `1e+19`. A whole number goes through an integer
/// only below 2^53, so a large value is never changed by showing it.
String formatRecipeNumber(double v) {
  if (v.isFinite && v == v.truncateToDouble() && v.abs() < 9007199254740992) {
    return v.toInt().toString();
  }
  final t = v.toString();
  return t.endsWith('.0') ? t.substring(0, t.length - 2) : t;
}

/// A length with its unit and what it measures. A value without a unit is a problem the engine
/// reports, never guessed; a missing value is allowed (a landmark, or a partial recipe).
class Measurement {
  const Measurement({this.label = '', this.value, this.unit, this.extra = const {}});

  final String label;
  final double? value;
  final LengthUnit? unit;

  /// Keys this build does not know, kept verbatim and written back.
  final Map<String, Object?> extra;

  static const _known = {'label', 'value', 'unit'};

  Map<String, dynamic> toJson() => {'label': label, 'value': value, 'unit': unit?.json, ...extra};

  factory Measurement.fromJson(Object? raw) {
    final json = _object(raw, 'measurement');
    final v = json['value'];
    if (v != null && v is! num) throw const FormatException('value is not a number');
    final value = (v as num?)?.toDouble();
    // JSON has no infinity, but a huge literal (1e400) reads as one; the engine refuses it too.
    if (value != null && !value.isFinite) {
      throw const FormatException('value is not a finite number');
    }
    return Measurement(
      label: _text(json, 'label'),
      value: value,
      unit: _optEnum(LengthUnit.values, (u) => u.json, json['unit'], 'unit'),
      extra: _extra(json, _known),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Measurement &&
      label == other.label &&
      value == other.value &&
      unit == other.unit &&
      jsonValueEquals(extra, other.extra);

  @override
  int get hashCode => Object.hash(label, value, unit, extra.length);
}

/// How far a segment goes: [count] rounds (rows), until [count] stitches, or until [measure].
class Extent {
  const Extent.rounds(int this.count, {this.extra = const {}})
      : type = ExtentType.rounds,
        measure = null;
  const Extent.untilStitches(int this.count, {this.extra = const {}})
      : type = ExtentType.untilStitches,
        measure = null;
  const Extent.until(Measurement this.measure, {this.extra = const {}})
      : type = ExtentType.until,
        count = null;

  final ExtentType type;
  final int? count;
  final Measurement? measure;

  /// Keys this build does not know, kept verbatim and written back.
  final Map<String, Object?> extra;

  Map<String, dynamic> toJson() => switch (type) {
        ExtentType.rounds || ExtentType.untilStitches => {
            'type': type.json,
            'count': count,
            ...extra
          },
        ExtentType.until => {'type': type.json, 'measure': measure!.toJson(), ...extra},
      };

  factory Extent.fromJson(Object? raw) {
    final json = _object(raw, 'extent');
    final type = _enumOf(ExtentType.values, (t) => t.json, json['type'], 'extent');
    switch (type) {
      case ExtentType.rounds:
      case ExtentType.untilStitches:
        final count = _optCount(json, 'count');
        if (count == null) throw const FormatException('extent count is missing');
        final extra = _extra(json, const {'type', 'count'});
        return type == ExtentType.rounds
            ? Extent.rounds(count, extra: extra)
            : Extent.untilStitches(count, extra: extra);
      case ExtentType.until:
        return Extent.until(Measurement.fromJson(json['measure']),
            extra: _extra(json, const {'type', 'measure'}));
    }
  }

  @override
  bool operator ==(Object other) =>
      other is Extent &&
      type == other.type &&
      count == other.count &&
      measure == other.measure &&
      jsonValueEquals(extra, other.extra);

  @override
  int get hashCode => Object.hash(type, count, measure, extra.length);
}

/// A stitch given on a segment: the Hansen notation exactly as written, a display name, and how
/// the notation is read.
class SegmentStitch {
  const SegmentStitch({
    this.notation = '',
    this.name = '',
    this.reading = StitchReading.strict,
    this.extra = const {},
  });

  final String notation;
  final String name;
  final StitchReading reading;

  /// Keys this build does not know, kept verbatim and written back.
  final Map<String, Object?> extra;

  Map<String, dynamic> toJson() =>
      {'notation': notation, 'name': name, 'reading': reading.json, ...extra};

  factory SegmentStitch.fromJson(Object? raw) {
    final json = _object(raw, 'stitch');
    return SegmentStitch(
      notation: _text(json, 'notation'),
      name: _text(json, 'name'),
      reading: json['reading'] == null
          ? StitchReading.strict
          : _enumOf(StitchReading.values, (r) => r.json, json['reading'], 'reading'),
      extra: _extra(json, const {'notation', 'name', 'reading'}),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SegmentStitch &&
      notation == other.notation &&
      name == other.name &&
      reading == other.reading &&
      jsonValueEquals(extra, other.extra);

  @override
  int get hashCode => Object.hash(notation, name, reading, extra.length);
}

/// The keys of each kind's `work` object (anything else there is kept verbatim).
const Map<SegmentKind, Set<String>> _workKeys = {
  SegmentKind.foundationChain: {'kind', 'stitches', 'join'},
  SegmentKind.centreStart: {'kind', 'stitches'},
  SegmentKind.pickUp: {'kind', 'from', 'stitches'},
  SegmentKind.rounds: {'kind', 'worked', 'extent'},
  SegmentKind.rows: {'kind', 'extent'},
  SegmentKind.increase: {'kind', 'perRound', 'method', 'extent'},
  SegmentKind.decrease: {'kind', 'perRound', 'method', 'extent'},
  SegmentKind.shortRows: {'kind', 'extent'},
  SegmentKind.opening: {'kind', 'skip', 'stitches'},
  SegmentKind.join: {'kind', 'closes'},
  SegmentKind.finish: {'kind', 'method'},
  SegmentKind.freeform: {'kind', 'role', 'text'},
};

const Set<String> _segmentKeys = {'id', 'title', 'work', 'stitch', 'target', 'notes', 'caution'};

/// One segment. Only the fields its [kind] uses are written to the file; the rest stay null.
class RecipeSegment {
  const RecipeSegment({
    required this.id,
    required this.kind,
    this.title = '',
    this.stitch,
    this.stitches,
    this.skip,
    this.chainJoin,
    this.roundJoin,
    this.perRound,
    this.increaseMethod,
    this.decreaseMethod,
    this.finishMethod,
    this.extent,
    this.reference,
    this.role = RecipePhase.other,
    this.text = '',
    this.target,
    this.notes = '',
    this.caution = '',
    this.extra = const {},
    this.workExtra = const {},
  });

  /// Stable (`segment-N`): never changes on edit, rename or move, and never given twice.
  final String id;
  final SegmentKind kind;

  /// The maker's own label ("Cuff", "Thumb").
  final String title;

  /// The segment's own stitch; null means the project's stitch (for a kind that uses one).
  final SegmentStitch? stitch;

  /// Foundation chain, centre start, pick-up: the stitches (loops) it starts with. Opening: the
  /// stitches worked across the gap.
  final int? stitches;

  /// Opening: the loops of the previous round it skips.
  final int? skip;
  final ChainJoin? chainJoin;
  final RoundJoin? roundJoin;
  final int? perRound;
  final IncreaseMethod? increaseMethod;
  final DecreaseMethod? decreaseMethod;
  final FinishMethod? finishMethod;

  /// How far it goes (rounds, rows, increases, decreases, short rows); null = not stated.
  final Extent? extent;

  /// Pick-up: the opening it starts from. Join: the opening it closes. A segment id.
  final String? reference;

  /// Free text: where it belongs in the work.
  final RecipePhase role;

  /// Free text: the maker's words.
  final String text;

  /// What it aims for (recorded, not verified).
  final Measurement? target;

  /// Construction notes.
  final String notes;

  /// The author's own warning to the maker.
  final String caution;

  /// Keys of the segment this build does not know, kept verbatim and written back.
  final Map<String, Object?> extra;

  /// Keys of its `work` object this build does not know for its kind, kept verbatim.
  final Map<String, Object?> workExtra;

  /// The phase of this segment (a free-text segment's is its [role]).
  RecipePhase get phase => kind == SegmentKind.freeform ? role : kind.phase;

  /// The same segment under another id (duplicating).
  RecipeSegment withId(String newId) => RecipeSegment(
        id: newId,
        kind: kind,
        title: title,
        stitch: stitch,
        stitches: stitches,
        skip: skip,
        chainJoin: chainJoin,
        roundJoin: roundJoin,
        perRound: perRound,
        increaseMethod: increaseMethod,
        decreaseMethod: decreaseMethod,
        finishMethod: finishMethod,
        extent: extent,
        reference: reference,
        role: role,
        text: text,
        target: target,
        notes: notes,
        caution: caution,
        extra: extra,
        workExtra: workExtra,
      );

  Map<String, dynamic> _work() => {
        'kind': kind.json,
        ...switch (kind) {
          SegmentKind.foundationChain => {'stitches': stitches, 'join': chainJoin?.json},
          SegmentKind.centreStart => {'stitches': stitches},
          SegmentKind.pickUp => {'from': reference, 'stitches': stitches},
          SegmentKind.rounds => {'worked': roundJoin?.json, 'extent': extent?.toJson()},
          SegmentKind.rows || SegmentKind.shortRows => {'extent': extent?.toJson()},
          SegmentKind.increase => {
              'perRound': perRound,
              'method': increaseMethod?.json,
              'extent': extent?.toJson(),
            },
          SegmentKind.decrease => {
              'perRound': perRound,
              'method': decreaseMethod?.json,
              'extent': extent?.toJson(),
            },
          SegmentKind.opening => {'skip': skip, 'stitches': stitches},
          SegmentKind.join => {'closes': reference},
          SegmentKind.finish => {'method': finishMethod?.json},
          SegmentKind.freeform => {'role': role.json, 'text': text},
        },
        ...workExtra,
      };

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'work': _work(),
        'stitch': stitch?.toJson(),
        'target': target?.toJson(),
        'notes': notes,
        'caution': caution,
        ...extra,
      };

  factory RecipeSegment.fromJson(Object? raw) {
    final json = _object(raw, 'segment');
    final work = _object(json['work'], 'work');
    final kind = _enumOf(SegmentKind.values, (k) => k.json, work['kind'], 'segment kind');
    Extent? extent() => work['extent'] == null ? null : Extent.fromJson(work['extent']);
    final stitchRaw = json['stitch'];
    final targetRaw = json['target'];
    final common = (
      id: _text(json, 'id'),
      title: _text(json, 'title'),
      stitch: stitchRaw == null ? null : SegmentStitch.fromJson(stitchRaw),
      target: targetRaw == null ? null : Measurement.fromJson(targetRaw),
      notes: _text(json, 'notes'),
      caution: _text(json, 'caution'),
      extra: _extra(json, _segmentKeys),
      workExtra: _extra(work, _workKeys[kind]!),
    );
    RecipeSegment make({
      int? stitches,
      int? skip,
      ChainJoin? chainJoin,
      RoundJoin? roundJoin,
      int? perRound,
      IncreaseMethod? increaseMethod,
      DecreaseMethod? decreaseMethod,
      FinishMethod? finishMethod,
      Extent? extent,
      String? reference,
      RecipePhase role = RecipePhase.other,
      String text = '',
    }) =>
        RecipeSegment(
          id: common.id,
          kind: kind,
          title: common.title,
          stitch: common.stitch,
          stitches: stitches,
          skip: skip,
          chainJoin: chainJoin,
          roundJoin: roundJoin,
          perRound: perRound,
          increaseMethod: increaseMethod,
          decreaseMethod: decreaseMethod,
          finishMethod: finishMethod,
          extent: extent,
          reference: reference,
          role: role,
          text: text,
          target: common.target,
          notes: common.notes,
          caution: common.caution,
          extra: common.extra,
          workExtra: common.workExtra,
        );
    return switch (kind) {
      SegmentKind.foundationChain => make(
          stitches: _optCount(work, 'stitches'),
          chainJoin: _optEnum(ChainJoin.values, (j) => j.json, work['join'], 'chain join'),
        ),
      SegmentKind.centreStart => make(stitches: _optCount(work, 'stitches')),
      SegmentKind.pickUp =>
        make(reference: _optText(work, 'from'), stitches: _optCount(work, 'stitches')),
      SegmentKind.rounds => make(
          roundJoin: _optEnum(RoundJoin.values, (j) => j.json, work['worked'], 'round join'),
          extent: extent(),
        ),
      SegmentKind.rows || SegmentKind.shortRows => make(extent: extent()),
      SegmentKind.increase => make(
          perRound: _optCount(work, 'perRound'),
          increaseMethod:
              _optEnum(IncreaseMethod.values, (m) => m.json, work['method'], 'increase method'),
          extent: extent(),
        ),
      SegmentKind.decrease => make(
          perRound: _optCount(work, 'perRound'),
          decreaseMethod:
              _optEnum(DecreaseMethod.values, (m) => m.json, work['method'], 'decrease method'),
          extent: extent(),
        ),
      SegmentKind.opening =>
        make(skip: _optCount(work, 'skip'), stitches: _optCount(work, 'stitches')),
      SegmentKind.join => make(reference: _optText(work, 'closes')),
      SegmentKind.finish => make(
          finishMethod:
              _optEnum(FinishMethod.values, (m) => m.json, work['method'], 'finish method'),
        ),
      SegmentKind.freeform => make(
          role: _enumOf(RecipePhase.values, (p) => p.json, work['role'], 'role'),
          text: _text(work, 'text'),
        ),
    };
  }

  @override
  bool operator ==(Object other) =>
      other is RecipeSegment &&
      id == other.id &&
      kind == other.kind &&
      title == other.title &&
      stitch == other.stitch &&
      stitches == other.stitches &&
      skip == other.skip &&
      chainJoin == other.chainJoin &&
      roundJoin == other.roundJoin &&
      perRound == other.perRound &&
      increaseMethod == other.increaseMethod &&
      decreaseMethod == other.decreaseMethod &&
      finishMethod == other.finishMethod &&
      extent == other.extent &&
      reference == other.reference &&
      role == other.role &&
      text == other.text &&
      target == other.target &&
      notes == other.notes &&
      caution == other.caution &&
      jsonValueEquals(extra, other.extra) &&
      jsonValueEquals(workExtra, other.workExtra);

  @override
  int get hashCode => Object.hashAll([
        id,
        kind,
        title,
        stitch,
        stitches,
        skip,
        chainJoin,
        roundJoin,
        perRound,
        increaseMethod,
        decreaseMethod,
        finishMethod,
        extent,
        reference,
        role,
        text,
        target,
        notes,
        caution,
        extra.length,
        workExtra.length,
      ]);
}

final RegExp _segmentNumber = RegExp(r'^segment-(\d+)$');

const Set<String> _recipeKeys = {'fit', 'segments', 'done', 'lastSegmentNumber'};

/// A recipe: the fit it aims for, its segments in working order, the segments the maker has
/// ticked done in the follow view, and the highest segment number ever given.
class NalbindRecipe {
  const NalbindRecipe({
    this.fit = const [],
    this.segments = const [],
    this.done = const {},
    this.lastSegmentNumber = 0,
    this.extra = const {},
  });

  final List<Measurement> fit;
  final List<RecipeSegment> segments;

  /// Ids of the segments ticked done (working progress, not instructions).
  final Set<String> done;

  /// The highest `segment-N` ever given in this recipe, kept so an id is never given twice.
  final int lastSegmentNumber;

  /// Keys of the recipe this build does not know, kept verbatim and written back.
  final Map<String, Object?> extra;

  NalbindRecipe copyWith({
    List<Measurement>? fit,
    List<RecipeSegment>? segments,
    Set<String>? done,
    int? lastSegmentNumber,
  }) =>
      NalbindRecipe(
        fit: fit ?? this.fit,
        segments: segments ?? this.segments,
        done: done ?? this.done,
        lastSegmentNumber: lastSegmentNumber ?? this.lastSegmentNumber,
        extra: extra,
      );

  /// The highest segment number given so far: the counter, or a higher `segment-N` in use.
  int get highestNumber {
    var high = lastSegmentNumber;
    for (final s in segments) {
      final m = _segmentNumber.firstMatch(s.id);
      if (m != null) {
        final n = int.tryParse(m.group(1)!) ?? 0;
        if (n > high) high = n;
      }
    }
    return high;
  }

  /// The ticked ids that name a segment of this recipe, in segment order (what a save writes).
  List<String> get doneInOrder {
    final seen = <String>{};
    return [
      for (final s in segments)
        if (done.contains(s.id) && seen.add(s.id)) s.id,
    ];
  }

  /// This recipe with segment [id] ticked done (or not). Only a segment of this recipe can be
  /// ticked.
  NalbindRecipe withDone(String id, bool isDone) {
    if (isDone && !segments.any((s) => s.id == id)) return this;
    return copyWith(done: isDone ? {...done, id} : ({...done}..remove(id)));
  }

  /// The id the next new segment would get (one past the highest ever given).
  String nextId() => 'segment-${highestNumber + 1}';

  /// Give a new id: the id, and this recipe with its counter past it, so the id is never given
  /// again (not even after the segment is deleted).
  (NalbindRecipe, String) issueId() {
    final n = highestNumber + 1;
    return (copyWith(lastSegmentNumber: n), 'segment-$n');
  }

  Map<String, dynamic> toJson() => {
        'fit': [for (final m in fit) m.toJson()],
        'segments': [for (final s in segments) s.toJson()],
        'done': doneInOrder,
        'lastSegmentNumber': highestNumber,
        ...extra,
      };

  factory NalbindRecipe.fromJson(Object? raw) {
    final json = _object(raw, 'recipe');
    List<Object?> list(String key, int max) {
      final v = json[key];
      if (v == null) return const [];
      if (v is! List) throw FormatException('$key is not a list');
      if (v.length > max) throw FormatException('$key has more than $max entries');
      return v;
    }

    final segments = [
      for (final s in list('segments', kMaxRecipeSegments)) RecipeSegment.fromJson(s),
    ];
    final ids = {for (final s in segments) s.id};
    final done = <String>{};
    for (final d in list('done', kMaxRecipeSegments)) {
      if (d is! String) throw const FormatException('done is not a list of ids');
      // A tick for a step that is not in the recipe means nothing; it is not kept.
      if (ids.contains(d)) done.add(d);
    }
    final read = NalbindRecipe(
      fit: [for (final m in list('fit', kMaxRecipeFit)) Measurement.fromJson(m)],
      segments: segments,
      done: done,
      lastSegmentNumber: _optCount(json, 'lastSegmentNumber') ?? 0,
      extra: _extra(json, _recipeKeys),
    );
    // A file without the counter (or behind its own ids) starts it at the highest id it holds.
    return read.highestNumber == read.lastSegmentNumber
        ? read
        : read.copyWith(lastSegmentNumber: read.highestNumber);
  }

  @override
  bool operator ==(Object other) =>
      other is NalbindRecipe &&
      _listEquals(fit, other.fit) &&
      _listEquals(segments, other.segments) &&
      done.length == other.done.length &&
      done.containsAll(other.done) &&
      highestNumber == other.highestNumber &&
      jsonValueEquals(extra, other.extra);

  @override
  int get hashCode => Object.hash(
        Object.hashAll(fit),
        Object.hashAll(segments),
        Object.hashAllUnordered(done),
        highestNumber,
        extra.length,
      );
}
