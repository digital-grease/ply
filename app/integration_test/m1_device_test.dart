// On-device verification for M1 (persistence + Library).
//
// Runs the REAL DraftRepository on a connected Android device/emulator, exercising
// the layers that unit tests on the host cannot: path_provider's real documents dir,
// the Rust engine over the FFI bridge (JNI), real-filesystem atomic writes, PNG
// thumbnails, and a real widget render of the Library + Preview screens.
//
// It deliberately bypasses the native file picker (an OS surface that can't be driven
// here, and whose call already shipped in M1 first-light) and drives the repository
// directly with a known fixture — the same code path the picker feeds into.
//
//   flutter test integration_test/m1_device_test.dart -d emulator-5554

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/screens/library_screen.dart';
import 'package:ply/src/screens/preview_screen.dart';
import 'package:ply/src/rust/frb_generated.dart';

/// A 4x4, 2/2 twill (straight threading + straight treadling), black warp / white weft.
const String kTwillWif = '''[WIF]
Version=1.1
[WEAVING]
Shafts=4
Treadles=4
Rising Shed=true
[WARP]
Threads=4
Units=Inches
[WEFT]
Threads=4
[COLOR TABLE]
1=0,0,0
2=255,255,255
[THREADING]
1=1
2=2
3=3
4=4
[TIEUP]
1=1,2
2=2,3
3=3,4
4=1,4
[TREADLING]
1=1
2=2
3=3
4=4
[WARP COLORS]
1=1
2=1
3=1
4=1
[WEFT COLORS]
1=2
2=2
3=2
4=2
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('M1: full persistence loop over the real engine + filesystem',
      (tester) async {
    final repo = DraftRepository();

    // Clean slate (idempotent across re-runs).
    for (final e in await repo.list()) {
      await repo.delete(e.id);
    }
    expect(await repo.list(), isEmpty, reason: 'library should start empty');

    // 1. Render works over the real FFI engine.
    final img = await repo.renderDrawdown(kTwillWif, cellPx: 16);
    expect(img.width, 64, reason: '4 warp threads * 16 px');
    expect(img.height, 64, reason: '4 picks * 16 px');
    img.dispose();

    // 2. Save persists the <id>.{wif,json,png} triplet atomically.
    final t0 = DateTime.now();
    final id = await repo.save(
      wifText: kTwillWif,
      meta: DraftMeta(
        name: 'Twill 2/2',
        author: 'integration-test',
        notes: 'device verification',
        savedAt: t0,
        lastOpened: t0,
      ),
    );

    var entries = await repo.list();
    expect(entries, hasLength(1));
    final entry = entries.single;
    expect(entry.id, id);
    expect(entry.meta.name, 'Twill 2/2');
    expect(entry.meta.craft, 'Weaving');
    expect(entry.thumbPath, isNotNull, reason: 'thumbnail PNG should be written');

    final draftsDir = p.dirname(entry.wifPath);
    expect(File(entry.wifPath).existsSync(), isTrue, reason: '.wif present');
    expect(File(p.join(draftsDir, '$id.json')).existsSync(), isTrue,
        reason: '.json sidecar present');
    expect(File(entry.thumbPath!).existsSync(), isTrue, reason: '.png present');
    // No torn .tmp files left behind.
    final leftovers = Directory(draftsDir)
        .listSync()
        .where((f) => f.path.endsWith('.tmp'))
        .toList();
    expect(leftovers, isEmpty, reason: 'no .tmp files after atomic writes');

    // 3. The persisted WIF text is byte-identical (lossless verbatim save).
    expect(await repo.readWif(id), kTwillWif);

    // 4. Opening bumps lastOpened.
    final opened = await repo.open(id);
    expect(opened.meta.lastOpened.isBefore(t0), isFalse,
        reason: 'lastOpened should advance on open');

    // 5. Persistence survives a fresh repository instance (relaunch at the data layer).
    final repo2 = DraftRepository();
    final reloaded = await repo2.list();
    expect(reloaded, hasLength(1));
    expect(reloaded.single.meta.name, 'Twill 2/2');

    // 6. Rename rewrites only the sidecar (filename/id unchanged).
    await repo.rename(id, 'Renamed twill');
    entries = await repo.list();
    expect(entries.single.meta.name, 'Renamed twill');
    expect(entries.single.id, id);

    // 7. Write a larger preview PNG to the drafts dir for an out-of-band visual check
    //    (pulled via `adb run-as` after the run to confirm the twill diagonal).
    final big = await repo.renderDrawdown(kTwillWif, cellPx: 24);
    final bigPng = await big.toByteData(format: ui.ImageByteFormat.png);
    big.dispose();
    expect(bigPng, isNotNull);
    final verifyPath = p.join(draftsDir, 'verify_twill.png');
    await File(verifyPath)
        .writeAsBytes(bigPng!.buffer.asUint8List(bigPng.offsetInBytes, bigPng.lengthInBytes));
    expect(File(verifyPath).existsSync(), isTrue);

    // 8. The Library widget renders the saved tile on the real device.
    await tester.pumpWidget(MaterialApp(home: LibraryScreen(repository: repo)));
    await tester.pumpAndSettle();
    expect(find.text('Renamed twill'), findsOneWidget,
        reason: 'tile should show the renamed draft');
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // 9. The Preview widget renders the drawdown without error.
    await tester.pumpWidget(
      MaterialApp(home: PreviewScreen.saved(repository: repo, id: id)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Renamed twill'), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets,
        reason: 'drawdown CustomPaint should be in the tree');

    // 10. Delete removes the whole triplet.
    await repo.delete(id);
    expect(await repo.list(), isEmpty, reason: 'library empty after delete');
    expect(File(entry.wifPath).existsSync(), isFalse);
    expect(File(p.join(draftsDir, '$id.json')).existsSync(), isFalse);
    expect(File(entry.thumbPath!).existsSync(), isFalse);
  });
}
