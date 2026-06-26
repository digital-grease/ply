// Release smoke proof through the REAL engine (RustLib) on a device — the host `flutter test` suite
// fakes the FFI, so this exercises the actual Rust paths added this release:
//   1. a [LIFTPLAN]-only WIF factors into a tie-up + treadling on import (and reads compressed);
//   2. (pure-Dart, host-tested) the compressed treadling view over the real parsed treadling;
//   3. a left cable vs a right cable render to DIFFERENT chart bitmaps;
//   4. written instructions include colorwork (MC / CC).
//
//   flutter test integration_test/smoke_release_test.dart -d linux

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show debugPrint, listEquals;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/data/knit_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/knit_stitches.dart';
import 'package:ply/src/models/treadling_entries.dart';
import 'package:ply/src/rust/dto.dart' show ColorDto;
import 'package:ply/src/rust/knit_dto.dart';
import 'package:ply/src/state/knit_editor_state.dart';
import 'package:ply/src/rust/frb_generated.dart';

// A 4-shaft DOBBY-style WIF: a [LIFTPLAN] with NO tie-up/treadling. Lift {1,2} thrown 3x, then {3,4}.
const String kLiftplanWif = '''[WIF]
Version=1.1
[WEAVING]
Shafts=4
Treadles=0
Rising Shed=true
[WARP]
Threads=4
Units=Inches
[WEFT]
Threads=4
[THREADING]
1=1
2=2
3=3
4=4
[LIFTPLAN]
1=1,2
2=1,2
3=1,2
4=3,4
''';

Future<Uint8List> _rgba(ui.Image img) async =>
    (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('1+2: a liftplan-only WIF imports as a TIE-UP + compressed treadling (not pattern-in-treadling)',
      (tester) async {
    final doc = await DraftRepository().parseDoc(kLiftplanWif);
    expect(doc.drive, isA<DraftTreadled>(),
        reason: 'a simple liftplan must factor to a treadled draft, not stay a liftplan');
    final t = doc.drive as DraftTreadled;
    expect(t.tieup.where((r) => r.isNotEmpty), isNotEmpty, reason: 'it gained a real tie-up');
    // The treadling reads COMPRESSED: lift {1,2} x3 then {3,4} x1 -> two runs.
    final entries = treadlingEntries(t.treadling);
    debugPrint('SMOKE[1+2] drive=DraftTreadled tieup=${t.tieup} treadling=${t.treadling} '
        'entries=${entries.map((e) => '${e.shed}x${e.count}').toList()}');
    expect(entries.length, 2, reason: '4 picks collapse to 2 numbered rows');
    expect(entries.first.count, 3);
  });

  testWidgets('3: a left cable vs a right cable render to DIFFERENT bitmaps', (tester) async {
    final repo = KnitRepository();
    Future<Uint8List> renderCable(CrossKind dir, String symbol) async {
      var st = KnitEditorState(pattern: await repo.blank()).resizeChart(4, 1);
      final cable = CableDefDto(front: 2, back: 2, direction: dir, frontPurl: false, backPurl: false);
      st = st.addCable(cable, symbol);
      final cableId = st.pattern.legend.stitches.length - 1;
      st = st.paintCell(0, 0, cableId, null); // place the 4-wide cable
      return _rgba(await repo.render(st.pattern, cellPx: 12));
    }

    final rc = await renderCable(CrossKind.right, '2/2RC');
    final lc = await renderCable(CrossKind.left, '2/2LC');
    expect(rc.length, lc.length, reason: 'same chart size');
    final differ = !listEquals(rc, lc);
    debugPrint('SMOKE[3] cable render bytes=${rc.length}; RC != LC = $differ');
    expect(differ, isTrue, reason: 'a right cross must not render identically to a left cross');
  });

  testWidgets('4: written instructions include colorwork (MC / CC)', (tester) async {
    final repo = KnitRepository();
    // A 3-st RS row: two knit cells in the main color, one in a contrast color.
    var st = KnitEditorState(pattern: await repo.blank()).resizeChart(3, 1);
    st = st.addPaletteColor(const ColorDto(r: 200, g: 0, b: 0)); // CC = palette index 1
    st = st.paintCell(0, 2, KnitStitch.knit, 1); // rightmost cell in CC
    final lines = await repo.written(st.pattern);
    debugPrint('SMOKE[4] written=$lines');
    expect(lines.any((l) => l.contains('MC')), isTrue, reason: 'main color labelled');
    expect(lines.any((l) => l.contains('CC')), isTrue, reason: 'contrast color labelled');
  });

  testWidgets('5: an OLDER saved knit legend re-upgrades to the current builtins on parse (real FFI)',
      (tester) async {
    final repo = KnitRepository();
    final blank = await repo.blank();
    final fullLen = blank.legend.stitches.length; // the current full builtin count
    // Round-trip to native JSON, then SIMULATE a pattern saved before the shaping stitches existed by
    // dropping the legend back to the original 12 builtins, and parse THAT through the real FFI.
    final map = jsonDecode(await repo.write(blank)) as Map<String, dynamic>;
    (map['legend'] as Map<String, dynamic>)['stitches'] =
        (map['legend']['stitches'] as List).sublist(0, 12);
    final reloaded = await repo.parse(jsonEncode(map));
    debugPrint('SMOKE[5] builtins on save=$fullLen, truncated=12, reloaded='
        '${reloaded.legend.stitches.length}');
    expect(fullLen, 20, reason: 'a fresh pattern carries the full current builtin set');
    expect(reloaded.legend.stitches.length, 20,
        reason: 'parse migrates an old 12-builtin legend back to the full set (the tester\'s patterns)');
  });

  testWidgets('6: the thread-texture render option changes the drawdown bitmap (real FFI)',
      (tester) async {
    final repo = DraftRepository();
    final doc = await repo.parseDoc(kLiftplanWif); // a real 4x4 cloth
    final flat = await _rgba(await repo.renderDto(doc, cellPx: 12));
    final textured = await _rgba(await repo.renderDto(doc, cellPx: 12, threadTexture: true));
    final differ = !listEquals(flat, textured);
    debugPrint('SMOKE[6] flat bytes=${flat.length}; textured differs=$differ');
    expect(flat.length, textured.length, reason: 'same drawdown dimensions either way');
    expect(differ, isTrue, reason: 'thread texture must shade the cloth, not leave it a flat fill');
  });

  // --- probes: off the happy path ---

  testWidgets('PROBE: a WIF with BOTH a liftplan AND a tie-up+treadling keeps the AUTHORED tie-up',
      (tester) async {
    const wif = '''[WIF]
Version=1.1
[WEAVING]
Shafts=4
Treadles=2
Rising Shed=true
[WARP]
Threads=4
Units=Inches
[WEFT]
Threads=2
[THREADING]
1=1
2=2
3=3
4=4
[TIEUP]
1=1
2=2
[TREADLING]
1=1
2=2
[LIFTPLAN]
1=1,2,3
2=2,3,4
''';
    final doc = await DraftRepository().parseDoc(wif);
    expect(doc.drive, isA<DraftTreadled>());
    final t = doc.drive as DraftTreadled;
    debugPrint('SMOKE[probe-both] tieup=${t.tieup} treadling=${t.treadling}');
    // The AUTHORED tie-up (single shafts) survives — not one derived from the liftplan's 3-shaft lifts.
    expect(t.tieup.take(2).toList(), [
      [1],
      [2],
    ], reason: 'the present liftplan must NOT override the authored tie-up');
  });

  testWidgets('PROBE: a SINGLE-color chart gets NO MC/CC labels (colorwork only when there is contrast)',
      (tester) async {
    final repo = KnitRepository();
    final st = KnitEditorState(pattern: await repo.blank()).resizeChart(3, 1); // all default color
    final lines = await repo.written(st.pattern);
    debugPrint('SMOKE[probe-1color] written=$lines');
    expect(lines.any((l) => l.contains('MC') || l.contains('CC')), isFalse,
        reason: 'no colorwork labels on a one-color chart');
  });
}
