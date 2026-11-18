// Pure helpers over the tablet weaving document (M10-02, ADR 0018): the start presets, the card
// geometry the editor needs to offer them, the expanded pick count and where a pick comes from in the
// written turning, and every edit the editor makes, each returning a NEW document (the generated DTOs
// are immutable). No FFI: the engine works out faces, twist and diagnostics; these only shape the
// document the weaver writes, so they are host-testable.
//
// Conventions (ADR 0018 sections 1 to 4): cards are numbered from the weaver's left; a card's
// corners are NT, FT, FB, NB seen from the weaver's right; a forward turn moves every hole NT to FT
// to FB to NB to NT. The arrangement stored per card is authoritative; presets are only shortcuts.

import 'dart:math' as math;

import '../rust/tablet_dto.dart';

/// The two named start positions the editor offers (ADR 0018 section 2).
enum TabletPreset {
  /// Ply home: A at the near top. Forward turns bring A, B, C, D across the top.
  plyHome(
    'A at the near top',
    'Ply home: A at the near top, D at the far top, C at the far bottom, B at the near bottom. '
        'Forward turns bring A, B, C, D across the top.',
  ),

  /// How most commercial cards are set: printed face to the right, A and D on top, D nearest the
  /// weaver. Forward turns bring D, C, B, A across the top.
  printedFaceRight(
    'Printed face to the right, D at the near top',
    'Cards lettered clockwise on their printed face, held printed face to the right with A and D '
        'on top and D nearest the weaver: D at the near top, A at the far top, B at the far bottom, '
        'C at the near bottom. Forward turns bring D, C, B, A across the top.',
  );

  const TabletPreset(this.label, this.description);

  /// The preset's name in the editor.
  final String label;

  /// What it means, in words.
  final String description;

  /// The arrangement this preset names.
  TabletArrangementDto get arrangement => switch (this) {
        TabletPreset.plyHome => kPlyHome,
        TabletPreset.printedFaceRight => kPrintedFaceRight,
      };
}

/// The preset the editor offers FIRST and gives every new band: Ply home, A at the near top (ADR 0018
/// open question 2, settled 2026-11-17). It is the engine's canonical frame, so forward turns bring
/// A, B, C, D across the top and the threading chart reads as the first four forward picks; the
/// hand-worked oracle bands use it; and the printed-face-right preset is one tap away, with every
/// card storing its own arrangement, so the choice loses nothing.
const TabletPreset kFirstTabletPreset = TabletPreset.plyHome;

/// The presets in the order the editor lists them: [kFirstTabletPreset] first.
List<TabletPreset> get tabletPresetsInOrder =>
    [kFirstTabletPreset, ...TabletPreset.values.where((p) => p != kFirstTabletPreset)];

/// Said with every computed face, chart and twist while the engine reports the review as pending
/// (`ply_tablet::PRACTITIONER_REVIEW_PENDING`, carried on every result).
const String kTabletReviewNote =
    'The rules Ply uses to work out the faces and twist await a tablet weaver\'s review. Check the '
    'first picks on your own cards before relying on them.';

const TabletArrangementDto kPlyHome = TabletArrangementDto(
  nearTop: TabletHoleKind.a,
  farTop: TabletHoleKind.d,
  farBottom: TabletHoleKind.c,
  nearBottom: TabletHoleKind.b,
);

const TabletArrangementDto kPrintedFaceRight = TabletArrangementDto(
  nearTop: TabletHoleKind.d,
  farTop: TabletHoleKind.a,
  farBottom: TabletHoleKind.b,
  nearBottom: TabletHoleKind.c,
);

/// The most picks a band may expand to (`ply_tablet::MAX_PICKS`).
const int kMaxTabletPicks = 200000;

/// The most cards a band may have (`ply_tablet::MAX_CARDS`).
const int kMaxTabletCards = 1000;

/// The most times a segment can be worked: more always expands past [kMaxTabletPicks]. Every number
/// the editor takes in is clamped to its limit before it reaches the engine, whose fields are 32-bit
/// (a larger Dart integer would otherwise be cut short at the boundary, 2^32 + 1 becoming 1).
const int kMaxTabletRepeat = kMaxTabletPicks;

/// The most a warning threshold can usefully be: twist never passes the pick count, nor a float the
/// band's length.
const int kMaxTabletThreshold = kMaxTabletPicks;

/// The most bytes of a name, a pack name, a pick note or the words for a `?`
/// (`ply_tablet::MAX_TEXT_BYTES`), and of a band's notes (`ply_tablet::MAX_NOTES_BYTES`). A longer
/// text is refused by the writer, so inputs stop at these.
const int kMaxTabletTextBytes = 10000;
const int kMaxTabletNotesBytes = 100000;

/// The defaults of a band's warning thresholds (`ply_tablet` defaults).
const TabletSettingsDto kDefaultTabletSettings =
    TabletSettingsDto(twistWarningQuarters: 32, floatWarningPicks: 3);

// --- holes and arrangements ------------------------------------------------------------------------

/// The hole's letter.
String holeLetter(TabletHoleKind h) => switch (h) {
      TabletHoleKind.a => 'A',
      TabletHoleKind.b => 'B',
      TabletHoleKind.c => 'C',
      TabletHoleKind.d => 'D',
    };

/// The holes NT, FT, FB, NB.
List<TabletHoleKind> cornersOf(TabletArrangementDto a) =>
    [a.nearTop, a.farTop, a.farBottom, a.nearBottom];

TabletArrangementDto _arr(List<TabletHoleKind> c) =>
    TabletArrangementDto(nearTop: c[0], farTop: c[1], farBottom: c[2], nearBottom: c[3]);

/// One quarter turn forward: NT to FT, FT to FB, FB to NB, NB to NT.
TabletArrangementDto turnedForward(TabletArrangementDto a) =>
    _arr([a.nearBottom, a.nearTop, a.farTop, a.farBottom]);

/// One quarter turn backward: NT to NB, NB to FB, FB to FT, FT to NT.
TabletArrangementDto turnedBackward(TabletArrangementDto a) =>
    _arr([a.farTop, a.farBottom, a.nearBottom, a.nearTop]);

/// [preset]'s arrangement turned [quarters] quarter turns forward (negative: backward).
TabletArrangementDto presetArrangement(TabletPreset preset, int quarters) {
  var a = preset.arrangement;
  for (var i = 0; i < quarters % 4; i++) {
    a = turnedForward(a);
  }
  return a;
}

bool sameArrangement(TabletArrangementDto a, TabletArrangementDto b) =>
    a.nearTop == b.nearTop &&
    a.farTop == b.farTop &&
    a.farBottom == b.farBottom &&
    a.nearBottom == b.nearBottom;

/// Which preset, turned how many quarter turns forward (0 to 3), gives [a]; null for an illegal
/// arrangement.
({TabletPreset preset, int quarters})? presetOf(TabletArrangementDto a) {
  for (final preset in TabletPreset.values) {
    for (var q = 0; q < 4; q++) {
      if (sameArrangement(presetArrangement(preset, q), a)) return (preset: preset, quarters: q);
    }
  }
  return null;
}

/// Whether [a] is one of the 8 arrangements a real card can take (ADR 0018 section 2).
bool isLegalArrangement(TabletArrangementDto a) => presetOf(a) != null;

/// "A D C B" (NT FT FB NB).
String arrangementText(TabletArrangementDto a) => cornersOf(a).map(holeLetter).join(' ');

/// "A at the near top, D at the far top, C at the far bottom, B at the near bottom".
String arrangementWords(TabletArrangementDto a) => '${holeLetter(a.nearTop)} at the near top, '
    '${holeLetter(a.farTop)} at the far top, ${holeLetter(a.farBottom)} at the far bottom, '
    '${holeLetter(a.nearBottom)} at the near bottom';

/// A start in words: the preset's name, or "turned k quarter turns from" it.
String startWords(TabletArrangementDto a) {
  final p = presetOf(a);
  if (p == null) return 'not a position a card can take (${arrangementText(a)})';
  if (p.quarters == 0) return p.preset.label;
  final n = p.quarters == 1 ? '1 quarter turn' : '${p.quarters} quarter turns';
  return '$n forward from "${p.preset.label}"';
}

/// The start most cards have, or null for a band with no cards. When several are equally common,
/// the one met first from card 1 on. The editor's threading chart and the printed one both star the
/// cards not at this start, so they always agree.
TabletArrangementDto? usualStart(TabletDocumentDto d) {
  if (d.cards.isEmpty) return null;
  final counts = <String, int>{};
  final first = <String, TabletArrangementDto>{};
  for (final c in d.cards) {
    final key = arrangementText(c.start);
    counts[key] = (counts[key] ?? 0) + 1;
    first.putIfAbsent(key, () => c.start);
  }
  var best = arrangementText(d.cards.first.start);
  for (final MapEntry(:key, :value) in counts.entries) {
    if (value > counts[best]!) best = key;
  }
  return first[best];
}

/// The thread colour (palette index) in [hole] of [card], or null when empty.
int? holeColor(TabletCardDto card, TabletHoleKind hole) => switch (hole) {
      TabletHoleKind.a => card.a,
      TabletHoleKind.b => card.b,
      TabletHoleKind.c => card.c,
      TabletHoleKind.d => card.d,
    };

String threadingLetter(TabletThreadingKind t) => t == TabletThreadingKind.s ? 'S' : 'Z';

/// The chart letter of a turn.
String turnLetter(TabletTurnKind t) => switch (t) {
      TabletTurnKind.forward => 'F',
      TabletTurnKind.backward => 'B',
      TabletTurnKind.idle => 'I',
      TabletTurnKind.unsupported => '?',
    };

/// The turn letters, in the order the turning chart cycles them on a tap.
const List<String> kTurnCycle = ['F', 'B', 'I'];

/// "+4", "-4", "0", or "unknown".
String twistText(int? twist) => twist == null ? 'unknown' : (twist > 0 ? '+$twist' : '$twist');

/// [quarters] of twist in full turns and quarters: "2 full turns", "1 full turn and 1 quarter".
String twistTurnsText(int quarters) {
  final q = quarters.abs();
  final full = q ~/ 4, rest = q % 4;
  final parts = [
    if (full > 0) '$full full ${full == 1 ? 'turn' : 'turns'}',
    if (rest > 0 || full == 0) '$rest ${rest == 1 ? 'quarter turn' : 'quarter turns'}',
  ];
  return parts.join(' and ');
}

// --- the turning ------------------------------------------------------------------------------------

/// The picks the turning expands to, capped at [kMaxTabletPicks] + 1 (past the cap the engine
/// refuses the band, and the editor says so).
int expandedPicks(TabletDocumentDto d) {
  var total = 0;
  for (final s in d.turning) {
    if (s.picks.isEmpty) continue;
    // Over the cap before multiplying: neither factor can make the product overflow after this.
    if (s.repeat > kMaxTabletPicks || s.picks.length > kMaxTabletPicks) return kMaxTabletPicks + 1;
    total += s.picks.length * s.repeat;
    if (total > kMaxTabletPicks) return kMaxTabletPicks + 1;
  }
  return total;
}

/// The first expanded pick of segment [segment] (0-based), 1-based.
int firstPickOfSegment(TabletDocumentDto d, int segment) {
  var pick = 1;
  for (var s = 0; s < segment && s < d.turning.length; s++) {
    final seg = d.turning[s];
    if (seg.picks.isEmpty) continue;
    if (seg.repeat > kMaxTabletPicks) return kMaxTabletPicks + 1;
    pick += seg.picks.length * seg.repeat;
    if (pick > kMaxTabletPicks + 1) return kMaxTabletPicks + 1;
  }
  return pick;
}

/// Where expanded pick [pick] (1-based) comes from: its segment and written step (0-based) and which
/// time through the segment (0-based); null past the end.
({int segment, int step, int repeat})? placeOfPick(TabletDocumentDto d, int pick) {
  if (pick < 1) return null;
  var before = 0;
  for (var s = 0; s < d.turning.length; s++) {
    final seg = d.turning[s];
    if (before > kMaxTabletPicks) return null;
    // A repeat past the cap counts as just past it: no product can overflow.
    final n = seg.picks.isEmpty
        ? 0
        : (seg.repeat > kMaxTabletPicks ? kMaxTabletPicks + 1 : seg.picks.length * seg.repeat);
    if (pick <= before + n && seg.picks.isNotEmpty) {
      final within = pick - before - 1;
      return (segment: s, step: within % seg.picks.length, repeat: within ~/ seg.picks.length);
    }
    before += n;
  }
  return null;
}

/// The letter of card [card] (0-based) in [turns] ('' past its end).
String letterAt(String turns, int card) {
  final r = turns.runes.toList();
  return card < r.length ? String.fromCharCode(r[card]) : '';
}

String _withLetter(String turns, int card, String letter) {
  final r = turns.runes.map(String.fromCharCode).toList();
  while (r.length <= card) {
    r.add('I');
  }
  r[card] = letter;
  return r.join();
}

// --- building documents -----------------------------------------------------------------------------

/// Rebuild [d] with some parts replaced.
TabletDocumentDto copyDoc(
  TabletDocumentDto d, {
  String? name,
  String? notes,
  List<TabletColorDto>? palette,
  int? weft,
  bool clearWeft = false,
  List<TabletCardDto>? cards,
  List<TabletPackDto>? packs,
  List<TabletSegmentDto>? turning,
  TabletSettingsDto? settings,
}) =>
    TabletDocumentDto(
      name: name ?? d.name,
      notes: notes ?? d.notes,
      palette: palette ?? d.palette,
      weft: clearWeft ? null : (weft ?? d.weft),
      cards: cards ?? d.cards,
      packs: packs ?? d.packs,
      turning: turning ?? d.turning,
      settings: settings ?? d.settings,
    );

TabletCardDto copyCard(
  TabletCardDto c, {
  String? id,
  TabletThreadingKind? threading,
  TabletArrangementDto? start,
}) =>
    TabletCardDto(
      id: id ?? c.id,
      a: c.a,
      b: c.b,
      c: c.c,
      d: c.d,
      threading: threading ?? c.threading,
      start: start ?? c.start,
    );

TabletPickDto copyPick(
  TabletPickDto p, {
  String? turns,
  List<String>? releaseTwist,
  List<String>? flip,
  List<TabletWordsDto>? unsupported,
  TabletNoteDto? note,
  bool clearNote = false,
}) =>
    TabletPickDto(
      turns: turns ?? p.turns,
      releaseTwist: releaseTwist ?? p.releaseTwist,
      flip: flip ?? p.flip,
      unsupported: unsupported ?? p.unsupported,
      note: clearNote ? null : (note ?? p.note),
      weft: p.weft,
    );

/// A pick where every one of [cards] cards does [letter], with no events.
TabletPickDto uniformPick(int cards, String letter) => TabletPickDto(
    turns: letter * cards, releaseTwist: const [], flip: const [], unsupported: const []);

/// A new band to start from: [cards] cards, every hole in the first of two colours, cards in the
/// left half S-threaded and the right half Z-threaded (a symmetrical start), every card at
/// [preset], and one segment of four forward picks.
TabletDocumentDto blankTabletDocument({
  int cards = 8,
  TabletPreset preset = kFirstTabletPreset,
  String name = '',
}) {
  final n = cards.clamp(1, kMaxTabletCards);
  return TabletDocumentDto(
    name: name,
    notes: '',
    palette: const [
      TabletColorDto(r: 0x1a, g: 0x1a, b: 0x1a),
      TabletColorDto(r: 0xf2, g: 0xef, b: 0xe6),
    ],
    weft: 0,
    cards: [
      for (var i = 0; i < n; i++)
        TabletCardDto(
          id: 'card-${i + 1}',
          a: 0,
          b: 0,
          c: 0,
          d: 0,
          threading: i < (n + 1) ~/ 2 ? TabletThreadingKind.s : TabletThreadingKind.z,
          start: preset.arrangement,
        ),
    ],
    packs: const [],
    turning: [
      TabletSegmentDto(repeat: 4, picks: [uniformPick(n, 'F')]),
    ],
    settings: kDefaultTabletSettings,
  );
}

/// An id `<prefix>-<n>` not yet used by any of [taken].
String freshId(String prefix, Iterable<String> taken) {
  final used = taken.toSet();
  var n = used.length + 1;
  while (used.contains('$prefix-$n')) {
    n++;
  }
  return '$prefix-$n';
}

// --- card edits -------------------------------------------------------------------------------------

/// Set [hole] of card [card] to palette colour [color] (null: empty).
TabletDocumentDto setHole(TabletDocumentDto d, int card, TabletHoleKind hole, int? color) {
  if (card < 0 || card >= d.cards.length) return d;
  final c = d.cards[card];
  if (holeColor(c, hole) == color) return d;
  final next = TabletCardDto(
    id: c.id,
    a: hole == TabletHoleKind.a ? color : c.a,
    b: hole == TabletHoleKind.b ? color : c.b,
    c: hole == TabletHoleKind.c ? color : c.c,
    d: hole == TabletHoleKind.d ? color : c.d,
    threading: c.threading,
    start: c.start,
  );
  return copyDoc(d, cards: [...d.cards]..[card] = next);
}

TabletDocumentDto setThreading(TabletDocumentDto d, int card, TabletThreadingKind t) {
  if (card < 0 || card >= d.cards.length || d.cards[card].threading == t) return d;
  return copyDoc(d, cards: [...d.cards]..[card] = copyCard(d.cards[card], threading: t));
}

TabletDocumentDto setStart(TabletDocumentDto d, int card, TabletArrangementDto start) {
  if (card < 0 || card >= d.cards.length || sameArrangement(d.cards[card].start, start)) return d;
  return copyDoc(d, cards: [...d.cards]..[card] = copyCard(d.cards[card], start: start));
}

/// Every card to [start] (one edit).
TabletDocumentDto setAllStarts(TabletDocumentDto d, TabletArrangementDto start) {
  if (d.cards.every((c) => sameArrangement(c.start, start))) return d;
  return copyDoc(d, cards: [for (final c in d.cards) copyCard(c, start: start)]);
}

/// Insert a card at [index] (0-based; the end when past it): a copy of the card before it (or after
/// it, for the first), with a new id, in no pack. Every pick gains a letter at that index, the same
/// as the neighbour's (F where the neighbour's is ?, which needs its own words).
TabletDocumentDto insertCard(TabletDocumentDto d, int index) {
  if (d.cards.length >= kMaxTabletCards) return d;
  final at = index.clamp(0, d.cards.length);
  final neighbour = d.cards.isEmpty ? null : d.cards[at == 0 ? 0 : at - 1];
  final id = freshId('card', d.cards.map((c) => c.id));
  final card = neighbour == null
      ? TabletCardDto(
          id: id,
          a: 0,
          b: 0,
          c: 0,
          d: 0,
          threading: TabletThreadingKind.s,
          start: kFirstTabletPreset.arrangement)
      : copyCard(neighbour, id: id);
  final turning = [
    for (final s in d.turning)
      TabletSegmentDto(repeat: s.repeat, picks: [
        for (final p in s.picks)
          () {
            final r = p.turns.runes.map(String.fromCharCode).toList();
            final from = neighbour == null ? 'F' : letterAt(p.turns, at == 0 ? 0 : at - 1);
            final letter = (from == '?' || from.isEmpty) ? 'F' : from;
            r.insert(math.min(at, r.length), letter);
            return copyPick(p, turns: r.join());
          }(),
      ]),
  ];
  return copyDoc(d, cards: [...d.cards]..insert(at, card), turning: turning);
}

/// Remove card [index]: its letter from every pick, and its id from every pack, release, flip and
/// words list.
TabletDocumentDto removeCard(TabletDocumentDto d, int index) {
  if (index < 0 || index >= d.cards.length) return d;
  final id = d.cards[index].id;
  final turning = [
    for (final s in d.turning)
      TabletSegmentDto(repeat: s.repeat, picks: [
        for (final p in s.picks)
          () {
            final r = p.turns.runes.map(String.fromCharCode).toList();
            if (index < r.length) r.removeAt(index);
            return TabletPickDto(
              turns: r.join(),
              releaseTwist: [
                for (final c in p.releaseTwist)
                  if (c != id) c
              ],
              flip: [
                for (final c in p.flip)
                  if (c != id) c
              ],
              unsupported: [
                for (final w in p.unsupported)
                  if (w.card != id) w
              ],
              note: p.note,
              weft: p.weft,
            );
          }(),
      ]),
  ];
  return copyDoc(
    d,
    cards: [...d.cards]..removeAt(index),
    packs: [
      for (final pk in d.packs)
        TabletPackDto(id: pk.id, name: pk.name, cards: [
          for (final c in pk.cards)
            if (c != id) c
        ]),
    ],
    turning: turning,
  );
}

/// Grow or shrink the band to [count] cards, at the right-hand end.
TabletDocumentDto setCardCount(TabletDocumentDto d, int count) {
  final n = count.clamp(1, kMaxTabletCards);
  var next = d;
  while (next.cards.length < n) {
    next = insertCard(next, next.cards.length);
  }
  while (next.cards.length > n) {
    next = removeCard(next, next.cards.length - 1);
  }
  return next;
}

// --- palette edits ----------------------------------------------------------------------------------

TabletDocumentDto addColor(TabletDocumentDto d, TabletColorDto color) =>
    copyDoc(d, palette: [...d.palette, color]);

TabletDocumentDto setColor(TabletDocumentDto d, int index, TabletColorDto color) {
  if (index < 0 || index >= d.palette.length) return d;
  final old = d.palette[index];
  if (old.r == color.r && old.g == color.g && old.b == color.b) return d;
  return copyDoc(d, palette: [...d.palette]..[index] = color);
}

/// Whether palette colour [index] is used by a hole, the band's weft or a pick's weft.
bool colorInUse(TabletDocumentDto d, int index) =>
    d.weft == index ||
    d.cards.any((c) => c.a == index || c.b == index || c.c == index || c.d == index) ||
    d.turning.any((s) => s.picks.any((p) => p.weft == index));

/// Remove an unused palette colour, renumbering the colours after it. A colour in use is kept.
TabletDocumentDto removeColor(TabletDocumentDto d, int index) {
  if (index < 0 || index >= d.palette.length || colorInUse(d, index)) return d;
  int? shift(int? i) => i == null ? null : (i > index ? i - 1 : i);
  return TabletDocumentDto(
    name: d.name,
    notes: d.notes,
    palette: [...d.palette]..removeAt(index),
    weft: shift(d.weft),
    cards: [
      for (final c in d.cards)
        TabletCardDto(
            id: c.id,
            a: shift(c.a),
            b: shift(c.b),
            c: shift(c.c),
            d: shift(c.d),
            threading: c.threading,
            start: c.start),
    ],
    packs: d.packs,
    turning: [
      for (final s in d.turning)
        TabletSegmentDto(repeat: s.repeat, picks: [
          for (final p in s.picks)
            TabletPickDto(
                turns: p.turns,
                releaseTwist: p.releaseTwist,
                flip: p.flip,
                unsupported: p.unsupported,
                note: p.note,
                weft: shift(p.weft)),
        ]),
    ],
    settings: d.settings,
  );
}

// --- pack edits -------------------------------------------------------------------------------------

TabletDocumentDto addPack(TabletDocumentDto d, String name) => copyDoc(d, packs: [
      ...d.packs,
      TabletPackDto(id: freshId('pack', d.packs.map((p) => p.id)), name: name, cards: const []),
    ]);

TabletDocumentDto renamePack(TabletDocumentDto d, int pack, String name) {
  if (pack < 0 || pack >= d.packs.length || d.packs[pack].name == name) return d;
  final p = d.packs[pack];
  return copyDoc(d,
      packs: [...d.packs]..[pack] = TabletPackDto(id: p.id, name: name, cards: p.cards));
}

TabletDocumentDto removePack(TabletDocumentDto d, int pack) {
  if (pack < 0 || pack >= d.packs.length) return d;
  return copyDoc(d, packs: [...d.packs]..removeAt(pack));
}

/// The index of the pack card [card] is in (the first, if a file put it in several), or null.
int? packOf(TabletDocumentDto d, int card) {
  if (card < 0 || card >= d.cards.length) return null;
  final id = d.cards[card].id;
  for (var i = 0; i < d.packs.length; i++) {
    if (d.packs[i].cards.contains(id)) return i;
  }
  return null;
}

/// Put card [card] in pack [pack] (null: in none), taking it out of every other pack: a card is in
/// at most one pack at a time. A pack keeps its cards in card order.
TabletDocumentDto setCardPack(TabletDocumentDto d, int card, int? pack) {
  if (card < 0 || card >= d.cards.length) return d;
  final id = d.cards[card].id;
  final order = {for (var i = 0; i < d.cards.length; i++) d.cards[i].id: i};
  final packs = <TabletPackDto>[];
  var changed = false;
  for (var i = 0; i < d.packs.length; i++) {
    final p = d.packs[i];
    final has = p.cards.contains(id);
    final wants = i == pack;
    if (has == wants && p.cards.where((c) => c == id).length <= 1) {
      packs.add(p);
      continue;
    }
    changed = true;
    final cards = [
      for (final c in p.cards)
        if (c != id) c
    ];
    if (wants) cards.add(id);
    cards.sort((a, b) => (order[a] ?? 1 << 30).compareTo(order[b] ?? 1 << 30));
    packs.add(TabletPackDto(id: p.id, name: p.name, cards: cards));
  }
  return changed ? copyDoc(d, packs: packs) : d;
}

/// The card indices (0-based) of pack [pack] that are in the band, in card order.
List<int> packCards(TabletDocumentDto d, int pack) {
  if (pack < 0 || pack >= d.packs.length) return const [];
  final ids = d.packs[pack].cards.toSet();
  return [
    for (var i = 0; i < d.cards.length; i++)
      if (ids.contains(d.cards[i].id)) i
  ];
}

// --- turning edits ----------------------------------------------------------------------------------

TabletDocumentDto _withPick(TabletDocumentDto d, int segment, int step, TabletPickDto pick) {
  final seg = d.turning[segment];
  final picks = [...seg.picks]..[step] = pick;
  return copyDoc(d,
      turning: [...d.turning]..[segment] = TabletSegmentDto(repeat: seg.repeat, picks: picks));
}

bool _validStep(TabletDocumentDto d, int segment, int step) =>
    segment >= 0 &&
    segment < d.turning.length &&
    step >= 0 &&
    step < d.turning[segment].picks.length;

/// Set card [card]'s letter on written pick ([segment], [step]) to [letter] (`F`, `B`, `I`, or `?`
/// with the pattern's [words]). Changing away from `?` drops its words.
TabletDocumentDto setTurn(TabletDocumentDto d, int segment, int step, int card, String letter,
    {String? words}) {
  if (!_validStep(d, segment, step) || card < 0 || card >= d.cards.length) return d;
  final p = d.turning[segment].picks[step];
  final id = d.cards[card].id;
  final unsupported = [
    for (final w in p.unsupported)
      if (w.card != id) w
  ];
  if (letter == '?') {
    final text = (words ?? '').trim();
    if (text.isEmpty) return d; // a ? always carries the pattern's words
    unsupported.add(TabletWordsDto(card: id, text: text));
    unsupported.sort((a, b) => a.card.compareTo(b.card));
  }
  final turns = _withLetter(p.turns, card, letter);
  if (turns == p.turns && unsupported.length == p.unsupported.length && letter != '?') {
    return d;
  }
  return _withPick(d, segment, step, copyPick(p, turns: turns, unsupported: unsupported));
}

/// The words for card [card]'s `?` on a written pick, or null.
String? wordsFor(TabletDocumentDto d, int segment, int step, int card) {
  if (!_validStep(d, segment, step) || card < 0 || card >= d.cards.length) return null;
  final id = d.cards[card].id;
  for (final w in d.turning[segment].picks[step].unsupported) {
    if (w.card == id) return w.text;
  }
  return null;
}

/// Set every card of [cards] (0-based) to [letter] on a written pick (`F`, `B` or `I`).
TabletDocumentDto setTurns(
    TabletDocumentDto d, int segment, int step, Iterable<int> cards, String letter) {
  var next = d;
  for (final c in cards) {
    next = setTurn(next, segment, step, c, letter);
  }
  return next;
}

/// Flip card [card] before a written pick, or stop flipping it.
TabletDocumentDto toggleFlip(TabletDocumentDto d, int segment, int step, int card) {
  if (!_validStep(d, segment, step) || card < 0 || card >= d.cards.length) return d;
  final p = d.turning[segment].picks[step];
  final id = d.cards[card].id;
  final flip = p.flip.contains(id)
      ? [
          for (final c in p.flip)
            if (c != id) c
        ]
      : [...p.flip, id];
  return _withPick(d, segment, step, copyPick(p, flip: flip));
}

/// Record a twist release for card [card] before a written pick, or remove it.
TabletDocumentDto toggleRelease(TabletDocumentDto d, int segment, int step, int card) {
  if (!_validStep(d, segment, step) || card < 0 || card >= d.cards.length) return d;
  final p = d.turning[segment].picks[step];
  final id = d.cards[card].id;
  final release = p.releaseTwist.contains(id)
      ? [
          for (final c in p.releaseTwist)
            if (c != id) c
        ]
      : [...p.releaseTwist, id];
  return _withPick(d, segment, step, copyPick(p, releaseTwist: release));
}

/// Set (or with null, clear) a written pick's note.
TabletDocumentDto setNote(TabletDocumentDto d, int segment, int step, TabletNoteDto? note) {
  if (!_validStep(d, segment, step)) return d;
  final p = d.turning[segment].picks[step];
  return _withPick(d, segment, step, copyPick(p, note: note, clearNote: note == null));
}

/// Insert [pick] (default: a copy of the step's turns without its events, or every card forward)
/// into segment [segment] at [at].
TabletDocumentDto insertPick(TabletDocumentDto d, int segment, int at, {TabletPickDto? pick}) {
  if (segment < 0 || segment >= d.turning.length) return d;
  final seg = d.turning[segment];
  final i = at.clamp(0, seg.picks.length);
  final like = seg.picks.isEmpty ? null : seg.picks[math.min(i, seg.picks.length - 1)];
  final p = pick ??
      (like == null
          ? uniformPick(d.cards.length, 'F')
          : TabletPickDto(
              turns: like.turns,
              releaseTwist: const [],
              flip: const [],
              unsupported: like.unsupported,
            ));
  return copyDoc(d,
      turning: [...d.turning]..[segment] =
          TabletSegmentDto(repeat: seg.repeat, picks: [...seg.picks]..insert(i, p)));
}

/// Remove a written pick; a segment left with no picks is removed too.
TabletDocumentDto removePick(TabletDocumentDto d, int segment, int step) {
  if (!_validStep(d, segment, step)) return d;
  final seg = d.turning[segment];
  if (seg.picks.length == 1) return removeSegment(d, segment);
  return copyDoc(d,
      turning: [...d.turning]..[segment] =
          TabletSegmentDto(repeat: seg.repeat, picks: [...seg.picks]..removeAt(step)));
}

/// Add a segment at [at] (the end by default) of one written pick, every card forward, worked
/// [repeat] times.
TabletDocumentDto addSegment(TabletDocumentDto d, {int? at, int repeat = 1, TabletPickDto? pick}) {
  final i = (at ?? d.turning.length).clamp(0, d.turning.length);
  final seg = TabletSegmentDto(
      repeat: repeat.clamp(1, kMaxTabletRepeat), picks: [pick ?? uniformPick(d.cards.length, 'F')]);
  return copyDoc(d, turning: [...d.turning]..insert(i, seg));
}

TabletDocumentDto removeSegment(TabletDocumentDto d, int segment) {
  if (segment < 0 || segment >= d.turning.length) return d;
  return copyDoc(d, turning: [...d.turning]..removeAt(segment));
}

/// Work segment [segment] [repeat] times (at least once).
TabletDocumentDto setRepeat(TabletDocumentDto d, int segment, int repeat) {
  if (segment < 0 || segment >= d.turning.length) return d;
  final seg = d.turning[segment];
  final r = repeat.clamp(1, kMaxTabletRepeat);
  if (seg.repeat == r) return d;
  return copyDoc(d,
      turning: [...d.turning]..[segment] = TabletSegmentDto(repeat: r, picks: seg.picks));
}

/// Set the warning thresholds, each clamped to 0 to [kMaxTabletThreshold].
TabletDocumentDto setSettings(TabletDocumentDto d, TabletSettingsDto settings) {
  final s = TabletSettingsDto(
    twistWarningQuarters: settings.twistWarningQuarters.clamp(0, kMaxTabletThreshold),
    floatWarningPicks: settings.floatWarningPicks.clamp(0, kMaxTabletThreshold),
  );
  return _setSettings(d, s);
}

TabletDocumentDto _setSettings(TabletDocumentDto d, TabletSettingsDto s) =>
    (d.settings.twistWarningQuarters == s.twistWarningQuarters &&
            d.settings.floatWarningPicks == s.floatWarningPicks)
        ? d
        : copyDoc(d, settings: s);
