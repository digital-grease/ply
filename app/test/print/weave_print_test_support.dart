import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/double_weave_layers.dart' show raisedShafts;
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/draft_issue.dart';
import 'package:ply/src/models/drawdown_region.dart';
import 'package:ply/src/print/print_document.dart';
import 'package:ply/src/rust/api.dart' show PreviewImage;

// Shared helpers for the weaving print tests: a stand-in for the engine (host tests cannot load the
// Rust library) and the drafts the tests print, built in Dart or read from the tracked fixtures'
// oracles (fixtures/weaving/).

/// The interlacement a test expects, as the ENGINE computes it: `picks * ends`, 1 = warp on top. A
/// test oracle only (the app never computes this in Dart): the warp is on top where the pick raises a
/// shaft the end is threaded on, using the Dart twin of `Draft::raised_shafts`, which is tested against
/// the engine.
Uint8List referenceInterlacement(DraftDoc doc) {
  final out = Uint8List(doc.ends * doc.picks);
  for (var p = 0; p < doc.picks; p++) {
    final up = raisedShafts(doc, p);
    for (var e = 0; e < doc.ends; e++) {
      if (doc.threading[e].any(up.contains)) out[p * doc.ends + e] = 1;
    }
  }
  return out;
}

/// Stands in for the engine: canned validation, and `renderRegionPixels` drawing the region exactly as
/// the engine lays it out (one pixel per crossing at cellPx 1, the highest end in the left column,
/// the region's first pick in the top row), warp color where the warp is on top, else weft color.
class FakeWeaveRepo extends DraftRepository {
  FakeWeaveRepo({this.issues = const [], this.failRender = false, this.interlacement});

  final List<DraftIssue> issues;

  /// When true, every render throws (an engine failure).
  final bool failRender;

  /// The interlacement to draw instead of [referenceInterlacement] (a fixture's own oracle).
  final Uint8List? interlacement;

  final renders = <(int, int, int)>[]; // (ends, picks, cellPx)
  int validations = 0;

  @override
  Future<List<DraftIssue>> validateDto(DraftDoc doc) async {
    validations++;
    return issues;
  }

  @override
  Future<PreviewImage> renderRegionPixels(DraftDoc doc, DrawdownRegion region,
      {required int cellPx}) async {
    renders.add((region.endCount, region.pickCount, cellPx));
    if (failRender) throw StateError('engine down');
    return fakeEnginePixels(doc, region, interlacement: interlacement);
  }
}

/// [region] of [doc] drawn as the engine lays it out at one pixel per crossing: the region's highest
/// end in the left column and its first pick in the top row, the warp color where the warp is on top
/// ([interlacement], by default [referenceInterlacement]) and the weft color elsewhere; a color index
/// past the palette is white.
PreviewImage fakeEnginePixels(DraftDoc doc, DrawdownRegion region, {Uint8List? interlacement}) {
  final up = interlacement ?? referenceInterlacement(doc);
  final w = region.endCount, h = region.pickCount;
  final rgba = Uint8List(w * h * 4);
  DraftColor color(int index) => index >= 0 && index < doc.palette.length
      ? doc.palette[index]
      : const DraftColor(r: 255, g: 255, b: 255);
  for (var y = 0; y < h; y++) {
    final p = region.pickStart + y;
    for (var x = 0; x < w; x++) {
      final e = region.endStart + region.endCount - 1 - x;
      final warp = up[p * doc.ends + e] == 1;
      final c = warp
          ? color(e < doc.warpColors.length ? doc.warpColors[e] : 0)
          : color(p < doc.weftColors.length ? doc.weftColors[p] : 0);
      final i = (y * w + x) * 4;
      rgba
        ..[i] = c.r
        ..[i + 1] = c.g
        ..[i + 2] = c.b
        ..[i + 3] = 255;
    }
  }
  return PreviewImage(width: w, height: h, rgba: rgba);
}

Map<String, dynamic> fixtureOracle(String path) =>
    jsonDecode(File('../fixtures/weaving/$path.expect.json').readAsStringSync())
        as Map<String, dynamic>;

String fixtureWif(String path) => File('../fixtures/weaving/$path.wif').readAsStringSync();

/// A fixture's interlacement oracle ("X" = warp on top, end 1 first in each string) as `picks * ends`.
Uint8List oracleInterlacement(Map<String, dynamic> o) {
  final rows = [for (final r in o['interlacement'] as List) r as String];
  final ends = rows.first.length;
  final out = Uint8List(ends * rows.length);
  for (var p = 0; p < rows.length; p++) {
    for (var e = 0; e < ends; e++) {
      if (rows[p][e] == 'X') out[p * ends + e] = 1;
    }
  }
  return out;
}

List<int> _ints(Object? list) => [for (final n in list as List) n as int];

/// The AW-2 Atwater shadow weave, from its fixture (the same draft as the .wif): 22 ends x 22 picks,
/// dark and light alternating in warp and weft, both starting dark.
DraftDoc aw2Doc() {
  final o = fixtureOracle('shadow/aw2-atwater-4-point');
  final warp = o['warp_roles'] as String, weft = o['weft_roles'] as String;
  return DraftDoc.blank(shafts: 4, treadles: 4, name: 'Shadow weave (Atwater)').copyWith(
    threading: [
      for (final s in _ints(o['threading'])) [s],
    ],
    drive: DraftTreadled(
      tieup: [
        for (final row in o['tieup'] as List) _ints(row),
      ],
      treadling: [
        for (final t in _ints(o['treadling'])) [t],
      ],
    ),
    palette: const [DraftColor(r: 219, g: 219, b: 219), DraftColor(r: 45, g: 45, b: 45)],
    warpColors: [for (final c in warp.split('')) c == 'D' ? 1 : 0],
    weftColors: [for (final c in weft.split('')) c == 'D' ? 1 : 0],
    notes: 'Atwater shadow weave on 4 shafts.',
  );
}

/// A double-weave fixture (independent-layers, tube, double-width-fold-left/right) with its roles,
/// shuttle, starting side and declared [construction].
DraftDoc doubleWeaveDoc(String name, LayerConstruction construction) {
  final o = fixtureOracle('doubleweave/$name');
  return DraftDoc.blank(shafts: 4, treadles: 4, name: name).copyWith(
    threading: [
      for (final s in _ints(o['threading'])) [s],
    ],
    drive: DraftTreadled(
      tieup: [
        for (final row in o['tieup'] as List) _ints(row),
      ],
      treadling: [
        for (final t in _ints(o['treadling'])) [t],
      ],
    ),
    palette: const [DraftColor(r: 40, g: 70, b: 130), DraftColor(r: 205, g: 130, b: 60)],
    warpColors: [for (var e = 0; e < (o['ends'] as int); e++) e.isEven ? 0 : 1],
    weftColors: List.filled(o['picks'] as int, 0),
    pickRoles: [
      for (final c in (o['roles'] as String).split(''))
        c == 'T' ? PickRole.topLayer : PickRole.bottomLayer,
    ],
    pickShuttles: _ints(o['shuttles']),
    shuttleStarts: {
      for (final e in (o['shuttle_starts'] as Map<String, dynamic>).entries)
        int.parse(e.key): e.value == 'left' ? ShuttleSide.left : ShuttleSide.right,
    },
    construction: construction,
  );
}

/// An original two-block overshot on 4 shafts, 16 ends: blocks on shafts 1-2, 2-3, 3-4 and 4-1 (each
/// threaded odd, even, odd, even so plain weave holds), treadles 1-4 the blocks, 5 and 6 the two tabby
/// sheds. [pattern] lists the pattern treadles in order; a tabby pick follows each one, starting with
/// tabby a (treadle 5, shafts 1 and 3, which lifts end 1).
DraftDoc overshotDoc({
  List<int> pattern = const [1, 1, 2, 2, 3, 3, 4, 4],
  Shed shed = Shed.rising,
}) {
  final treadling = <List<int>>[];
  final roles = <PickRole>[];
  final weft = <int>[];
  for (var k = 0; k < pattern.length; k++) {
    treadling
      ..add([pattern[k]])
      ..add([k.isEven ? 5 : 6]);
    roles.addAll(const [PickRole.pattern, PickRole.tabby]);
    weft.addAll(const [1, 0]);
  }
  return DraftDoc.blank(shafts: 4, treadles: 6, name: 'Two-block overshot').copyWith(
    shed: shed,
    threading: [
      for (final s in const [1, 2, 1, 2, 3, 2, 3, 2, 3, 4, 3, 4, 1, 4, 1, 4]) [s],
    ],
    drive: DraftTreadled(
      tieup: shed == Shed.rising
          ? const [
              [1, 2],
              [2, 3],
              [3, 4],
              [1, 4],
              [1, 3],
              [2, 4],
            ]
          : const [
              [3, 4],
              [1, 4],
              [1, 2],
              [2, 3],
              [2, 4],
              [1, 3],
            ],
      treadling: treadling,
    ),
    palette: const [DraftColor(r: 245, g: 240, b: 225), DraftColor(r: 120, g: 30, b: 40)],
    warpColors: List.filled(16, 0),
    weftColors: weft,
    pickRoles: roles,
  );
}

/// A large treadled draft: [ends] x [picks] on [shafts] shafts and treadles, a straight draw and a
/// broken twill tie-up, two colors.
DraftDoc largeDoc({int ends = 400, int picks = 1000, int shafts = 16}) =>
    DraftDoc.blank(shafts: shafts, treadles: shafts, name: 'Large twill').copyWith(
      threading: [
        for (var e = 0; e < ends; e++) [e % shafts + 1],
      ],
      drive: DraftTreadled(
        tieup: [
          for (var t = 0; t < shafts; t++)
            [
              for (var k = 0; k < shafts ~/ 2; k++) (t + k) % shafts + 1,
            ],
        ],
        treadling: [
          for (var p = 0; p < picks; p++) [(p * 3) % shafts + 1],
        ],
      ),
      warpColors: [for (var e = 0; e < ends; e++) (e ~/ 8).isEven ? 0 : 1],
      weftColors: [for (var p = 0; p < picks; p++) (p ~/ 6).isEven ? 1 : 0],
    );

/// Expand the printed treadling directions back into one shed per pick. Full listing: each row is
/// "<shed>[ ×n], ...". Use tabby: the rows list pattern picks and the intro carries the instruction.
List<List<int>> expandPrintedTreadling(PrintSection treadling, {required bool treadled}) {
  final intro = (treadling.blocks.first as PrintParagraph).text;
  final lines = treadling.blocks.whereType<PrintLines>().single.lines;
  final shedRe = RegExp(r'^(No treadle|No shafts raised|Treadles? ([\d + ]+?)|Shafts? ([\d + ]+?))'
      r'( ×(\d+))?, ');
  List<int> ids(Match m) {
    final s = m[2] ?? m[3];
    if (s == null) return const [];
    return [for (final t in s.split('+')) int.parse(t.trim())];
  }

  final rows = <(List<int>, int)>[];
  for (final l in lines) {
    final m = shedRe.firstMatch(l.text);
    if (m == null) throw StateError('not a treadling row: ${l.text}');
    rows.add((ids(m), int.parse(m[5] ?? '1')));
  }
  if (!intro.startsWith('Use tabby:')) {
    return [
      for (final (shed, n) in rows) ...List.filled(n, shed),
    ];
  }
  // The Use tabby instruction, in its printed words.
  final leading = intro.contains('Weave one tabby pick first');
  final trailing = !intro.contains('except the last');
  final noun = treadled ? 'treadles?' : 'shafts?';
  List<int> named(String which) {
    final m = RegExp('tabby $which \\($noun ([\\d + ]+)\\)').firstMatch(intro)!;
    return [for (final t in m[1]!.split('+')) int.parse(t.trim())];
  }

  final first = RegExp(r'starting with tabby (a|b)').firstMatch(intro)?[1] ??
      RegExp(r'The tabby pick is tabby (a|b)').firstMatch(intro)![1]!;
  final second = first == 'a' ? 'b' : 'a';
  final sheds = [
    named(first),
    if (intro.contains('alternates')) named(second),
  ];
  final out = <List<int>>[];
  var t = 0;
  void tabby() => out.add(sheds[t++ % sheds.length]);
  final pattern = [
    for (final (shed, n) in rows) ...List.filled(n, shed),
  ];
  if (leading) tabby();
  for (var k = 0; k < pattern.length; k++) {
    if (k > 0) tabby();
    out.add(pattern[k]);
  }
  if (trailing) tabby();
  return out;
}
