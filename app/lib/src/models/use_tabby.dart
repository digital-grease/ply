// Pick roles in the Book view (roadmap M8-06 and M8-08): the traditional "Use tabby" shorthand for
// overshot-style drafts, and the "Mark tabby picks" proposal.
//
// The per-pick draft (one shed, weft color, thickness, and role per pick) stays the source of truth.
// "Use tabby" is a PRESENTATION of it, available only under a precise, reversible policy:
//
//   * every pick has a known role, and every role is pattern or tabby;
//   * pattern and tabby picks strictly alternate (an optional tabby before the first pattern pick and
//     after the last one, exactly one tabby between any two pattern picks);
//   * every tabby pick raises a plain-weave (tabby) shed of THIS draft's threading, and consecutive
//     tabby picks use opposite tabby sheds, always the same two recorded sheds (treadles, or shaft
//     sets for a liftplan);
//   * every tabby pick has the same weft color (and thickness, when the draft records thickness),
//     and the same shuttle and strands (M8-06: one tabby weft, carried the same way every time);
//   * no shot group: the shorthand lists one pass per shed, so a double shot falls back to the full
//     listing with its own reason.
//
// Under that policy the draft is exactly: which tabby comes first, whether a tabby opens and closes
// the sequence, the tabby weft, and the list of pattern picks. [readUseTabby] derives that and then
// EXPANDS it again and compares it with the draft pick by pick; only an exact match is shown as Use
// tabby. Anything else falls back to the full listing with the first reason in plain words.
//
// Edits made in the Use tabby view are edits of the pattern list. The result is expanded into picks
// and read back; it is committed only when the read-back gives the same pattern list, otherwise it is
// refused with a reason. So book mode and full mode always prescribe the same working sequence.

import 'package:collection/collection.dart';

import 'double_weave_layers.dart' show raisedShafts;
import 'draft_doc.dart';
import 'treadling_entries.dart' show sameShed;
import 'weft_work.dart' show shotGroupPhrase;

const ListEquality<int> _ids = ListEquality<int>();

// ---------------------------------------------------------------------------
// Words
// ---------------------------------------------------------------------------

/// The role as a label: "Unknown", "Pattern", "Tabby", "Top layer", "Bottom layer".
String pickRoleLabel(PickRole role) => switch (role) {
      PickRole.unknown => 'Unknown',
      PickRole.pattern => 'Pattern',
      PickRole.tabby => 'Tabby',
      PickRole.topLayer => 'Top layer',
      PickRole.bottomLayer => 'Bottom layer',
    };

/// The role inside a sentence: "unknown", "pattern", "tabby", "top layer", "bottom layer".
String pickRoleWord(PickRole role) => pickRoleLabel(role).toLowerCase();

/// "Treadle 3", "Treadles 1 + 3", "No treadle" (treadled), or "Shaft 2", "Shafts 1 + 3",
/// "No shafts raised" (liftplan).
String shedLabel(List<int> shed, {required bool treadled}) {
  final ids = [...shed]..sort();
  if (treadled) {
    if (ids.isEmpty) return 'No treadle';
    return ids.length == 1 ? 'Treadle ${ids.single}' : 'Treadles ${ids.join(' + ')}';
  }
  if (ids.isEmpty) return 'No shafts raised';
  return ids.length == 1 ? 'Shaft ${ids.single}' : 'Shafts ${ids.join(' + ')}';
}

/// [shedLabel] inside a sentence ("treadle 3").
String shedWord(List<int> shed, {required bool treadled}) {
  final l = shedLabel(shed, treadled: treadled);
  return l[0].toLowerCase() + l.substring(1);
}

/// 0-based [picks] as words, 1-based: "pick 3", "picks 3 to 9", "picks 1, 3 to 5 and 9", or for many
/// stretches "picks 1, 3, 5, 7 and 12 more". [sentenceStart] capitalizes the first word.
String describePicks(List<int> picks, {bool sentenceStart = false}) {
  final sorted = picks.toSet().toList()..sort();
  final noun = sorted.length == 1 ? 'pick' : 'picks';
  final word = sentenceStart ? noun[0].toUpperCase() + noun.substring(1) : noun;
  if (sorted.isEmpty) return sentenceStart ? 'No picks' : 'no picks';
  final ranges = <(int, int)>[];
  for (final p in sorted) {
    if (ranges.isNotEmpty && ranges.last.$2 == p - 1) {
      ranges[ranges.length - 1] = (ranges.last.$1, p);
    } else {
      ranges.add((p, p));
    }
  }
  String r((int, int) x) => x.$1 == x.$2 ? '${x.$1 + 1}' : '${x.$1 + 1} to ${x.$2 + 1}';
  const shown = 4;
  final String body;
  if (ranges.length <= shown) {
    final parts = ranges.map(r).toList();
    body = parts.length == 1
        ? parts.single
        : '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
  } else {
    final rest = ranges.sublist(shown).fold<int>(0, (n, x) => n + x.$2 - x.$1 + 1);
    body = '${ranges.take(shown).map(r).join(', ')} and $rest more';
  }
  return '$word $body';
}

String _count(int n, String noun) => n == 1 ? '1 $noun' : '$n ${noun}s';

// ---------------------------------------------------------------------------
// Tabby sheds
// ---------------------------------------------------------------------------

/// [doc]'s two plain-weave (tabby) sheds, precomputed from its threading. A raised-shaft set is a
/// tabby shed when, over the THREADED warp ends in warp order (unthreaded ends skipped), it lifts
/// exactly every other end; "tabby a" lifts the first threaded end, "tabby b" the second. An end on
/// several shafts is up when any of them is raised, and two threaded ends are needed to tell. Built
/// in one pass over the threading; checking a pick then costs its raised shafts, not the warp width.
/// The Dart twin of the engine's `TabbyRule`; both suites test the same cases.
class TabbyRule {
  TabbyRule._(this._a, this._b);

  factory TabbyRule.of(DraftDoc doc) {
    final ends = [
      for (final e in doc.threading)
        if (e.isNotEmpty) e,
    ];
    if (ends.length < 2) return TabbyRule._(null, null);
    return TabbyRule._(
        _PhaseRule.build(ends, firstUp: true), _PhaseRule.build(ends, firstUp: false));
  }

  final _PhaseRule? _a;
  final _PhaseRule? _b;

  /// True = [raised] is tabby a, false = tabby b, null = not a plain-weave shed.
  bool? phase(Set<int> raised) {
    if (_a?.matches(raised) ?? false) return true;
    if (_b?.matches(raised) ?? false) return false;
    return null;
  }
}

/// One tabby shed as constraints: lift no [down] shaft, every [must] shaft, one of each [choices].
class _PhaseRule {
  _PhaseRule(this.down, this.must, this.choices);

  static _PhaseRule? build(List<List<int>> ends, {required bool firstUp}) {
    bool up(int k) => k.isEven == firstUp;
    final down = <int>{
      for (var k = 0; k < ends.length; k++)
        if (!up(k)) ...ends[k],
    };
    final must = <int>{};
    final choices = <String, Set<int>>{};
    for (var k = 0; k < ends.length; k++) {
      if (!up(k)) continue;
      final lift = {
        for (final s in ends[k])
          if (!down.contains(s)) s
      };
      if (lift.isEmpty) return null; // this end cannot rise while its neighbours stay down
      if (lift.length == 1) {
        must.add(lift.single);
      } else {
        choices[(lift.toList()..sort()).join(',')] = lift;
      }
    }
    return _PhaseRule(down, must, [
      for (final c in choices.values)
        if (!c.any(must.contains)) c
    ]);
  }

  final Set<int> down;
  final Set<int> must;
  final List<Set<int>> choices;

  bool matches(Set<int> r) =>
      !r.any(down.contains) && must.every(r.contains) && choices.every((c) => c.any(r.contains));
}

/// Whether [raised] is one of [doc]'s two plain-weave (tabby) sheds (see [TabbyRule]): true = tabby
/// a, false = tabby b, null = neither. Builds the rule each call; reuse a [TabbyRule] for many picks.
bool? plainWeavePhase(DraftDoc doc, Set<int> raised) => TabbyRule.of(doc).phase(raised);

/// [plainWeavePhase] of the shed [pick] (0-based) raises.
bool? pickTabbyPhase(DraftDoc doc, int pick) => plainWeavePhase(doc, raisedShafts(doc, pick));

/// What "Mark tabby picks" would change: a PROPOSAL, applied only after the weaver confirms.
class TabbyProposal {
  const TabbyProposal({
    required this.toTabby,
    required this.replacing,
    required this.alreadyTabby,
    required this.otherUnknown,
    required this.sheds,
  });

  /// Picks (0-based) whose shed is a tabby shed and whose role is not tabby yet: they would become
  /// tabby.
  final List<int> toTabby;

  /// The picks of [toTabby] that have another known role now (it would be replaced).
  final List<int> replacing;

  /// Picks on a tabby shed already marked tabby.
  final List<int> alreadyTabby;

  /// Picks NOT on a tabby shed whose role is unknown: offered, as an opt-in, to become pattern.
  final List<int> otherUnknown;

  /// The recorded sheds (treadle ids, or shaft ids for a liftplan) the tabby-shed picks use, in order
  /// of first use.
  final List<List<int>> sheds;

  /// True when no pick of the draft raises a tabby shed.
  bool get noTabbySheds => toTabby.isEmpty && alreadyTabby.isEmpty;

  /// The roles to write: [toTabby] as tabby and, when [othersAsPattern], [otherUnknown] as pattern.
  Map<int, PickRole> roles({bool othersAsPattern = false}) => {
        for (final p in toTabby) p: PickRole.tabby,
        if (othersAsPattern)
          for (final p in otherUnknown) p: PickRole.pattern,
      };
}

/// Propose tabby roles for [doc]: every pick whose shed is one of the draft's two plain-weave (tabby)
/// sheds. Pure; it never writes a role.
TabbyProposal proposeTabbyRoles(DraftDoc doc) {
  final rows = doc.drive.rows;
  final toTabby = <int>[];
  final replacing = <int>[];
  final already = <int>[];
  final other = <int>[];
  final sheds = <List<int>>[];
  final rule = TabbyRule.of(doc);
  for (var p = 0; p < doc.picks; p++) {
    final role = doc.roleAt(p);
    if (rule.phase(raisedShafts(doc, p)) != null) {
      if (!sheds.any((s) => sameShed(s, rows[p]))) sheds.add(List<int>.unmodifiable(rows[p]));
      if (role == PickRole.tabby) {
        already.add(p);
      } else {
        toTabby.add(p);
        if (role != PickRole.unknown) replacing.add(p);
      }
    } else if (role == PickRole.unknown) {
      other.add(p);
    }
  }
  return TabbyProposal(
      toTabby: toTabby,
      replacing: replacing,
      alreadyTabby: already,
      otherUnknown: other,
      sheds: sheds);
}

// ---------------------------------------------------------------------------
// The Use tabby reading
// ---------------------------------------------------------------------------

/// The result of [readUseTabby]: the shorthand, or why it is not available.
sealed class UseTabbyReading {
  const UseTabbyReading();
}

/// Use tabby is not available for this draft; [reason] says why in plain words.
final class UseTabbyUnavailable extends UseTabbyReading {
  const UseTabbyUnavailable(this.reason);
  final String reason;
}

/// One pattern pick of the shorthand: its shed (as recorded), weft color, weft thickness (null when
/// the draft records no thickness), shuttle (null when unknown), and strands.
class UseTabbyPick {
  const UseTabbyPick(
      {required this.shed, required this.color, this.thickness, this.shuttle, this.strands = 1});
  final List<int> shed;
  final int color;
  final double? thickness;
  final int? shuttle;
  final int strands;

  @override
  bool operator ==(Object other) =>
      other is UseTabbyPick &&
      _ids.equals(shed, other.shed) &&
      color == other.color &&
      thickness == other.thickness &&
      shuttle == other.shuttle &&
      strands == other.strands;

  @override
  int get hashCode => Object.hash(_ids.hash(shed), color, thickness, shuttle, strands);
}

/// One Use tabby row: consecutive pattern picks with the same shed.
class UseTabbyRow {
  const UseTabbyRow({
    required this.shed,
    required this.firstPattern,
    required this.count,
    required this.firstPick,
    required this.lastPick,
  });

  /// The recorded shed every pattern pick of the row uses.
  final List<int> shed;

  /// Index of the row's first pattern pick in [UseTabbyBook.pattern].
  final int firstPattern;

  /// How many pattern picks the row holds (>= 1).
  final int count;

  /// 0-based pick (in the full draft) of the row's first and last pattern pick. The tabby picks
  /// between them belong to the row too.
  final int firstPick;
  final int lastPick;

  /// Index just past the row's last pattern pick in [UseTabbyBook.pattern].
  int get endPattern => firstPattern + count;
}

/// The full per-pick data a shorthand expands to.
class ExpandedPicks {
  const ExpandedPicks({
    required this.sheds,
    required this.roles,
    required this.colors,
    required this.thickness,
    this.shuttles = const [],
    this.strands = const [],
  });
  final List<List<int>> sheds;
  final List<PickRole> roles;
  final List<int> colors;

  /// Empty when the draft records no weft thickness.
  final List<double> thickness;

  /// Per pick, the shuttle (null = unknown), and the strands.
  final List<int?> shuttles;
  final List<int> strands;

  /// True when [doc]'s picks are exactly these: the same recorded shed (as a list), role, weft color,
  /// shuttle, strands, and (when recorded) thickness for every pick, the same number of picks, and no
  /// shot group (the shorthand has none).
  bool matches(DraftDoc doc) {
    if (doc.picks != sheds.length || doc.shotGroups.isNotEmpty) return false;
    final rows = doc.drive.rows;
    for (var p = 0; p < sheds.length; p++) {
      if (!_ids.equals(rows[p], sheds[p])) return false;
      if (doc.roleAt(p) != roles[p]) return false;
      if (_colorAt(doc, p) != colors[p]) return false;
      if (thickness.isNotEmpty && _thicknessAt(doc, p) != thickness[p]) return false;
      if (doc.shuttleAt(p) != (p < shuttles.length ? shuttles[p] : null)) return false;
      if (doc.strandsAt(p) != (p < strands.length ? strands[p] : 1)) return false;
    }
    return thickness.isEmpty == doc.weftThickness.isEmpty;
  }
}

/// The "Use tabby" shorthand of a draft: everything needed to write it down AND to expand it back.
final class UseTabbyBook extends UseTabbyReading {
  const UseTabbyBook({
    required this.treadled,
    required this.leadingTabby,
    required this.trailingTabby,
    required this.tabbySheds,
    required this.firstIsA,
    required this.tabbyColor,
    required this.tabbyThickness,
    required this.tracksThickness,
    required this.pattern,
    this.tabbyShuttle,
    this.tabbyStrands = 1,
  });

  /// Whether sheds are treadle ids (else raised shaft ids of a liftplan), for labels.
  final bool treadled;

  /// A tabby pick before the first pattern pick.
  final bool leadingTabby;

  /// A tabby pick after the last pattern pick.
  final bool trailingTabby;

  /// The recorded tabby sheds in order of use: the first tabby pick uses `tabbySheds[0]`, the next
  /// `tabbySheds[1]`, and so on alternating. One entry only when the draft has a single tabby pick.
  final List<List<int>> tabbySheds;

  /// Whether the first tabby pick is tabby a (lifts the first threaded warp end).
  final bool firstIsA;

  /// The weft color (palette index) and thickness of every tabby pick.
  final int tabbyColor;
  final double? tabbyThickness;

  /// Whether the draft records per-pick weft thickness.
  final bool tracksThickness;

  /// The shuttle (null = unknown) and strands of every tabby pick.
  final int? tabbyShuttle;
  final int tabbyStrands;

  /// The pattern picks, in weaving order.
  final List<UseTabbyPick> pattern;

  /// How many tabby picks the expansion has: one between every two pattern picks, plus the optional
  /// first and last.
  int get tabbyCount =>
      pattern.isEmpty ? 0 : pattern.length - 1 + (leadingTabby ? 1 : 0) + (trailingTabby ? 1 : 0);

  int get pickCount => pattern.length + tabbyCount;

  /// The 0-based pick (in the full draft) of pattern pick [k].
  int pickOfPattern(int k) => (leadingTabby ? 1 : 0) + 2 * k;

  /// The tabby shed labelled a or b, or null when the draft never uses it.
  List<int>? tabbyShed({required bool a}) {
    final i = a == firstIsA ? 0 : 1;
    return i < tabbySheds.length ? tabbySheds[i] : null;
  }

  /// The pattern picks grouped into rows of consecutive identical sheds.
  List<UseTabbyRow> get rows {
    final out = <UseTabbyRow>[];
    var k = 0;
    while (k < pattern.length) {
      var n = 1;
      while (k + n < pattern.length && sameShed(pattern[k + n].shed, pattern[k].shed)) {
        n++;
      }
      out.add(UseTabbyRow(
        shed: pattern[k].shed,
        firstPattern: k,
        count: n,
        firstPick: pickOfPattern(k),
        lastPick: pickOfPattern(k + n - 1),
      ));
      k += n;
    }
    return out;
  }

  /// A copy with a different pattern list (same tabby policy).
  UseTabbyBook withPattern(List<UseTabbyPick> next) => UseTabbyBook(
        treadled: treadled,
        leadingTabby: leadingTabby,
        trailingTabby: trailingTabby,
        tabbySheds: tabbySheds,
        firstIsA: firstIsA,
        tabbyColor: tabbyColor,
        tabbyThickness: tabbyThickness,
        tracksThickness: tracksThickness,
        tabbyShuttle: tabbyShuttle,
        tabbyStrands: tabbyStrands,
        pattern: List<UseTabbyPick>.unmodifiable(next),
      );

  /// Expand the shorthand into every pick, in weaving order.
  ExpandedPicks expand() {
    final sheds = <List<int>>[];
    final roles = <PickRole>[];
    final colors = <int>[];
    final thick = <double>[];
    final shuttles = <int?>[];
    final strands = <int>[];
    var t = 0;
    void tabby() {
      sheds.add(tabbySheds[t % tabbySheds.length]);
      roles.add(PickRole.tabby);
      colors.add(tabbyColor);
      thick.add(tabbyThickness ?? 1.0);
      shuttles.add(tabbyShuttle);
      strands.add(tabbyStrands);
      t++;
    }

    if (pattern.isNotEmpty && leadingTabby) tabby();
    for (var k = 0; k < pattern.length; k++) {
      if (k > 0) tabby();
      sheds.add(pattern[k].shed);
      roles.add(PickRole.pattern);
      colors.add(pattern[k].color);
      thick.add(pattern[k].thickness ?? 1.0);
      shuttles.add(pattern[k].shuttle);
      strands.add(pattern[k].strands);
    }
    if (pattern.isNotEmpty && trailingTabby) tabby();
    return ExpandedPicks(
        sheds: sheds,
        roles: roles,
        colors: colors,
        thickness: tracksThickness ? thick : const [],
        shuttles: shuttles,
        strands: strands);
  }
}

int _colorAt(DraftDoc doc, int pick) => pick < doc.weftColors.length ? doc.weftColors[pick] : 0;

double _thicknessAt(DraftDoc doc, int pick) =>
    pick < doc.weftThickness.length ? doc.weftThickness[pick] : 1.0;

/// Shown when the derived shorthand does not expand back to exactly the draft's picks. It should never
/// appear (the derivation is built to round-trip), but the check runs on every read regardless.
const String kUseTabbyRebuildFailed =
    'Ply could not rebuild every pick from the shorthand, so it lists every pick.';

/// Read [doc] as Use tabby shorthand, or say why it cannot be. See the file header for the policy.
/// The result is verified: a [UseTabbyBook] is returned only when it expands to exactly [doc]'s picks.
UseTabbyReading readUseTabby(DraftDoc doc) {
  final n = doc.picks;
  final treadled = doc.drive is DraftTreadled;
  String shed(List<int> s) => shedWord(s, treadled: treadled);
  if (n == 0) return const UseTabbyUnavailable('This draft has no picks yet.');
  if (doc.pickRoles.isNotEmpty && doc.pickRoles.length != n) {
    return UseTabbyUnavailable('Use tabby shorthand needs one role per pick, but this draft has '
        '${_count(doc.pickRoles.length, 'role')} for ${_count(n, 'pick')}.');
  }
  final unknown = [
    for (var p = 0; p < n; p++)
      if (doc.roleAt(p) == PickRole.unknown) p,
  ];
  if (unknown.isNotEmpty) {
    return UseTabbyUnavailable('Use tabby shorthand needs every pick to have a role. Roles are '
        'unknown for ${describePicks(unknown)}.');
  }
  for (var p = 0; p < n; p++) {
    final r = doc.roleAt(p);
    if (r != PickRole.pattern && r != PickRole.tabby) {
      return UseTabbyUnavailable('Use tabby shorthand needs only pattern and tabby picks. '
          'Pick ${p + 1} is marked ${pickRoleWord(r)}.');
    }
  }
  // A shot group is several passes in one shed; the shorthand lists one pass per shed.
  if (doc.shotGroups.isNotEmpty) {
    final g = doc.shotGroups.first;
    return UseTabbyUnavailable('Use tabby shorthand needs one pass in each shed, but '
        '${describePicks([for (var p = g.start; p < g.end; p++) p])} are grouped as '
        '${shotGroupPhrase(g.count)}.');
  }
  for (var p = 1; p < n; p++) {
    final r = doc.roleAt(p);
    if (r == doc.roleAt(p - 1)) {
      return UseTabbyUnavailable('Use tabby shorthand needs pattern and tabby picks to alternate. '
          'Picks $p and ${p + 1} are both ${pickRoleWord(r)} picks.');
    }
  }
  final patternPicks = [
    for (var p = 0; p < n; p++)
      if (doc.roleAt(p) == PickRole.pattern) p,
  ];
  final tabbyPicks = [
    for (var p = 0; p < n; p++)
      if (doc.roleAt(p) == PickRole.tabby) p,
  ];
  if (patternPicks.isEmpty) {
    return const UseTabbyUnavailable('Use tabby shorthand needs at least one pattern pick.');
  }
  if (tabbyPicks.isEmpty) {
    return const UseTabbyUnavailable('Use tabby shorthand needs at least one tabby pick.');
  }

  final rows = doc.drive.rows;
  // Every tabby pick weaves plain weave on this threading...
  final phases = <bool>[];
  final rule = TabbyRule.of(doc);
  for (final p in tabbyPicks) {
    final phase = rule.phase(raisedShafts(doc, p));
    if (phase == null) {
      return UseTabbyUnavailable('Use tabby shorthand needs the tabby picks to weave plain weave. '
          'Pick ${p + 1} is marked tabby, but its shed (${shed(rows[p])}) does not lift every other '
          'warp end.');
    }
    phases.add(phase);
  }
  // ...the tabby alternates between the two plain-weave sheds...
  for (var i = 1; i < tabbyPicks.length; i++) {
    if (phases[i] == phases[i - 1]) {
      final a = tabbyPicks[i - 1];
      final b = tabbyPicks[i];
      final names =
          sameShed(rows[a], rows[b]) ? shed(rows[a]) : '${shed(rows[a])} and ${shed(rows[b])}';
      return UseTabbyUnavailable('Use tabby shorthand needs the tabby to alternate between its two '
          'sheds. Tabby picks ${a + 1} and ${b + 1} both lift the same warp ends ($names).');
    }
  }
  // ...always on the same two recorded sheds (treadles, or shaft sets).
  final first = rows[tabbyPicks[0]];
  final second = tabbyPicks.length > 1 ? rows[tabbyPicks[1]] : null;
  for (var i = 2; i < tabbyPicks.length; i++) {
    final p = tabbyPicks[i];
    final expected = i.isEven ? first : second!;
    if (!sameShed(rows[p], expected)) {
      return UseTabbyUnavailable('Use tabby shorthand needs every tabby pick to use one of the two '
          'tabby sheds. Pick ${p + 1} uses ${shed(rows[p])}, but the tabby picks before it use '
          '${shed(first)} and ${shed(second!)}.');
    }
  }
  // One tabby weft.
  final t0 = tabbyPicks.first;
  final color = _colorAt(doc, t0);
  final tracks = doc.weftThickness.isNotEmpty;
  for (final p in tabbyPicks) {
    final c = _colorAt(doc, p);
    if (c != color) {
      return UseTabbyUnavailable(
          'Use tabby shorthand needs one tabby weft. Pick ${p + 1} is a tabby '
          'pick in weft color ${c + 1}, but pick ${t0 + 1} is in color ${color + 1}.');
    }
    if (tracks && _thicknessAt(doc, p) != _thicknessAt(doc, t0)) {
      return UseTabbyUnavailable(
          'Use tabby shorthand needs one tabby weft. Pick ${p + 1} is a tabby '
          'pick with a different weft thickness from pick ${t0 + 1}.');
    }
    if (doc.shuttleAt(p) != doc.shuttleAt(t0)) {
      String on(int? s) => s == null ? 'with no shuttle' : 'on shuttle $s';
      return UseTabbyUnavailable(
          'Use tabby shorthand needs one tabby weft. Pick ${p + 1} is a tabby pick '
          '${on(doc.shuttleAt(p))}, but pick ${t0 + 1} is ${on(doc.shuttleAt(t0))}.');
    }
    if (doc.strandsAt(p) != doc.strandsAt(t0)) {
      String strands(int k) => k == 1 ? '1 strand' : '$k strands';
      return UseTabbyUnavailable(
          'Use tabby shorthand needs one tabby weft. Pick ${p + 1} is a tabby pick with '
          '${strands(doc.strandsAt(p))}, but pick ${t0 + 1} has ${strands(doc.strandsAt(t0))}.');
    }
  }

  final book = UseTabbyBook(
    treadled: treadled,
    leadingTabby: doc.roleAt(0) == PickRole.tabby,
    trailingTabby: doc.roleAt(n - 1) == PickRole.tabby,
    tabbySheds: List<List<int>>.unmodifiable([
      List<int>.unmodifiable(first),
      if (second != null) List<int>.unmodifiable(second),
    ]),
    firstIsA: phases.first,
    tabbyColor: color,
    tabbyThickness: tracks ? _thicknessAt(doc, t0) : null,
    tracksThickness: tracks,
    tabbyShuttle: doc.shuttleAt(t0),
    tabbyStrands: doc.strandsAt(t0),
    pattern: List<UseTabbyPick>.unmodifiable([
      for (final p in patternPicks)
        UseTabbyPick(
          shed: List<int>.unmodifiable(rows[p]),
          color: _colorAt(doc, p),
          thickness: tracks ? _thicknessAt(doc, p) : null,
          shuttle: doc.shuttleAt(p),
          strands: doc.strandsAt(p),
        ),
    ]),
  );
  // The shorthand is shown only when it reproduces the draft exactly.
  if (!book.expand().matches(doc)) return const UseTabbyUnavailable(kUseTabbyRebuildFailed);
  return book;
}

// ---------------------------------------------------------------------------
// Texts
// ---------------------------------------------------------------------------

/// The "Use tabby" instruction for [book]: where the tabby picks go, and which tabby comes first.
String useTabbyInstruction(UseTabbyBook book) {
  final where = switch ((book.leadingTabby, book.trailingTabby)) {
    (false, true) => 'Weave one tabby pick after every pattern pick.',
    (false, false) => 'Weave one tabby pick after every pattern pick except the last.',
    (true, true) => 'Weave one tabby pick first, then one after every pattern pick.',
    (true, false) =>
      'Weave one tabby pick first, then one after every pattern pick except the last.',
  };
  String named(bool a) {
    final s = book.tabbyShed(a: a);
    return 'tabby ${a ? 'a' : 'b'} (${shedWord(s!, treadled: book.treadled)})';
  }

  final first = book.firstIsA;
  final which = book.tabbySheds.length > 1
      ? 'The tabby alternates between ${named(true)} and ${named(false)}, starting with tabby '
          '${first ? 'a' : 'b'}.'
      : 'The tabby pick is ${named(first)}.';
  return '$where $which Tabby a is the tabby shed that lifts the first threaded warp end.';
}

/// "16 picks: 8 pattern picks in 4 rows and 8 tabby picks".
String useTabbySummary(UseTabbyBook book) =>
    '${_count(book.pickCount, 'pick')}: ${_count(book.pattern.length, 'pattern pick')} in '
    '${_count(book.rows.length, 'row')} and ${_count(book.tabbyCount, 'tabby pick')}';

// ---------------------------------------------------------------------------
// Edits in the Use tabby view
// ---------------------------------------------------------------------------

/// The result of a Use tabby edit: the edited draft, or why the edit was refused.
sealed class UseTabbyEditResult {
  const UseTabbyEditResult();
}

final class UseTabbyEdited extends UseTabbyEditResult {
  const UseTabbyEdited(this.doc);
  final DraftDoc doc;
}

final class UseTabbyRefused extends UseTabbyEditResult {
  const UseTabbyRefused(this.reason);
  final String reason;
}

const String kUseTabbyLastRow = 'This is the only pattern row, and Use tabby needs at least one '
    'pattern pick. Turn off Use tabby shorthand to delete every pick.';
const String kUseTabbyNoTabbyLeft = 'That would leave no tabby picks. Turn off Use tabby shorthand '
    'to edit these picks one by one.';
const String kUseTabbyOneShedKnown = 'This draft has only one tabby pick, so Ply does not know the '
    'second tabby shed. Turn off Use tabby shorthand and add a tabby pick first.';
const String kUseTabbyEditNotExact = 'Ply could not make this edit without changing picks it does '
    'not show here, so it was not made.';

/// Set every pattern pick of Use tabby row [row] to the shed [ids] (canonicalized ascending).
UseTabbyEditResult editUseTabbyRowShed(DraftDoc doc, int row, List<int> ids) =>
    _editPattern(doc, row, (book, r) {
      final shed = List<int>.unmodifiable(List<int>.of(ids)..sort());
      return [
        for (var k = 0; k < book.pattern.length; k++)
          (k >= r.firstPattern && k < r.endPattern)
              ? UseTabbyPick(
                  shed: shed,
                  color: book.pattern[k].color,
                  thickness: book.pattern[k].thickness,
                  shuttle: book.pattern[k].shuttle,
                  strands: book.pattern[k].strands)
              : book.pattern[k],
      ];
    });

/// Set Use tabby row [row]'s pattern pick count (>= 1) by adding or removing pattern picks at the END
/// of the row; an added pattern pick copies the row's last one (shed, weft color, thickness, shuttle,
/// strands). The tabby picks follow from the policy: one between every two pattern picks, still
/// alternating.
UseTabbyEditResult editUseTabbyRowCount(DraftDoc doc, int row, int count) {
  if (count < 1) throw RangeError.range(count, 1, null, 'count');
  return _editPattern(doc, row, (book, r) {
    final p = List<UseTabbyPick>.of(book.pattern);
    if (count > r.count) {
      final last = p[r.endPattern - 1];
      p.insertAll(r.endPattern, List<UseTabbyPick>.filled(count - r.count, last));
    } else {
      p.removeRange(r.firstPattern + count, r.endPattern);
    }
    return p;
  });
}

/// Delete Use tabby row [row]'s pattern picks (and the tabby picks the policy no longer needs).
UseTabbyEditResult removeUseTabbyRow(DraftDoc doc, int row) => _editPattern(doc, row, (book, r) {
      return [
        for (var k = 0; k < book.pattern.length; k++)
          if (k < r.firstPattern || k >= r.endPattern) book.pattern[k],
      ];
    });

UseTabbyEditResult _editPattern(
  DraftDoc doc,
  int row,
  List<UseTabbyPick> Function(UseTabbyBook book, UseTabbyRow row) edit,
) {
  final reading = readUseTabby(doc);
  final UseTabbyBook book;
  switch (reading) {
    case UseTabbyUnavailable(:final reason):
      return UseTabbyRefused(reason);
    case UseTabbyBook():
      book = reading;
  }
  final rows = book.rows;
  if (row < 0 || row >= rows.length) throw RangeError.range(row, 0, rows.length - 1, 'row');
  final next = book.withPattern(edit(book, rows[row]));
  if (next.pattern.isEmpty) return const UseTabbyRefused(kUseTabbyLastRow);
  if (next.tabbyCount == 0) return const UseTabbyRefused(kUseTabbyNoTabbyLeft);
  if (next.tabbyCount > 1 && next.tabbySheds.length < 2) {
    return const UseTabbyRefused(kUseTabbyOneShedKnown);
  }
  final e = next.expand();
  final drive = switch (doc.drive) {
    DraftTreadled() && final d => d.copyWith(treadling: e.sheds),
    DraftLiftplan() && final d => d.copyWith(liftplan: e.sheds),
  };
  final edited = doc.copyWith(
    drive: drive,
    weftColors: e.colors,
    weftThickness: next.tracksThickness ? e.thickness : null,
    pickRoles: e.roles,
    pickShuttles: e.shuttles,
    pickStrands: e.strands,
    retained: retainedForPickCount(doc, e.sheds.length),
  );
  // Read the result back: it must be Use tabby again with exactly the edited pattern list and the
  // same tabby policy, so the shorthand the weaver edited is the sequence now stored.
  final back = readUseTabby(edited);
  if (back is! UseTabbyBook ||
      back.leadingTabby != next.leadingTabby ||
      back.trailingTabby != next.trailingTabby ||
      back.firstIsA != next.firstIsA ||
      back.tabbyColor != next.tabbyColor ||
      back.tabbyShuttle != next.tabbyShuttle ||
      back.tabbyStrands != next.tabbyStrands ||
      !const ListEquality<UseTabbyPick>().equals(back.pattern, next.pattern)) {
    return const UseTabbyRefused(kUseTabbyEditNotExact);
  }
  return UseTabbyEdited(edited);
}
