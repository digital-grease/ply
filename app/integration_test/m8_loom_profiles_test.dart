// M8-02 device proof: loom profiles against the REAL engine and filesystem (ADR 0014). A loom is
// created in My looms (the engine writes looms.json), a structurally valid eight-shaft draft is saved
// planned for it, and on reopening the editor's loom group says it is not feasible on four shafts,
// through the engine's check, while the structural validation stays clean. The WIF on disk carries
// no loom data; the plan lives in the sidecar. The real looms.json is put back as it was.
//
//   flutter test integration_test/m8_loom_profiles_test.dart -d emulator-5554

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/data/loom_repository.dart';
import 'package:ply/src/models/draft_doc.dart' show MeasureUnit;
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/loom_check.dart';
import 'package:ply/src/screens/editor_screen.dart';
import 'package:ply/src/screens/looms_screen.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/state/loom_providers.dart';
import 'package:ply/src/rust/frb_generated.dart';

/// A third-party eight-shaft 4/4 twill, 16 ends at 20 ends per inch ([WARP] Spacing=0.05).
String eightShaftTwill() {
  final b = StringBuffer('''[WIF]
Version=1.1
Source Program=Elsewhere
[WEAVING]
Shafts=8
Treadles=8
Rising Shed=true
[WARP]
Threads=16
Units=Inches
Spacing=0.05
[WEFT]
Threads=16
[COLOR TABLE]
1=255,255,255
2=0,0,0
[THREADING]
''');
  for (var e = 1; e <= 16; e++) {
    b.writeln('$e=${(e - 1) % 8 + 1}');
  }
  b.writeln('[TIEUP]');
  for (var t = 1; t <= 8; t++) {
    b.writeln('$t=${[for (var k = 0; k < 4; k++) (t - 1 + k) % 8 + 1].join(',')}');
  }
  b.writeln('[TREADLING]');
  for (var p = 1; p <= 16; p++) {
    b.writeln('$p=${(p - 1) % 8 + 1}');
  }
  b.writeln('[WARP COLORS]');
  for (var e = 1; e <= 16; e++) {
    b.writeln('$e=1');
  }
  b.writeln('[WEFT COLORS]');
  for (var p = 1; p <= 16; p++) {
    b.writeln('$p=2');
  }
  return b.toString();
}

Future<void> settle(WidgetTester tester, {int frames = 20}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('a loom made in My looms marks an eight-shaft draft not feasible after a reopen',
      (tester) async {
    final looms = LoomRepository();
    final drafts = DraftRepository();
    // Keep the device's own looms.json and put it back afterwards.
    final file = await looms.file();
    final before = await file.exists() ? await file.readAsBytes() : null;
    addTearDown(() async {
      if (before == null) {
        if (await file.exists()) await file.delete();
      } else {
        await file.writeAsBytes(before, flush: true);
      }
    });
    if (before != null) await file.delete();

    // 1. My looms: add a four-shaft jack loom through the form; the engine writes looms.json.
    // The app's root scope, as main.dart builds it: the draft repository is supplied, not defaulted.
    final overrides = [repositoryProvider.overrideWithValue(drafts)];
    await tester.pumpWidget(
        ProviderScope(overrides: overrides, child: const MaterialApp(home: LoomsScreen())));
    await settle(tester);
    await tester.tap(find.text('Add loom'));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('loom-name')), 'Test four-shaft loom');
    await tester.enterText(find.byKey(const ValueKey('loom-shafts')), '4');
    await tester.enterText(find.byKey(const ValueKey('loom-treadles')), '6');
    await tester.enterText(find.byKey(const ValueKey('loom-width')), '24');
    await tester.tap(find.text('Save'));
    await settle(tester);
    expect(find.text('Test four-shaft loom'), findsOneWidget);

    final saved = await looms.load();
    expect(saved.status, LoomFileStatus.ok);
    final loom = saved.looms.single;
    expect(loom.shafts, 4);
    expect(loom.reeds, isEmpty, reason: 'nothing entered, nothing invented');
    expect(loomsFileVersion(await file.readAsString()), kLoomsSchemaVersion);

    // 2. Save a structurally valid eight-shaft draft planned for that loom (the sidecar records the
    //    loom's id and name; the WIF is saved verbatim).
    final wif = eightShaftTwill();
    final doc = await drafts.parseDoc(wif);
    expect((await drafts.validateDto(doc)).where((i) => i.isError), isEmpty);
    final id = await drafts.saveDto(
      doc,
      meta: DraftMeta(
        name: 'Loom check twill',
        savedAt: DateTime.now(),
        lastOpened: DateTime.now(),
        loomPlan: LoomPlan(loomId: loom.id, loomName: loom.name),
      ),
      sourceWif: wif,
    );
    addTearDown(() => drafts.delete(id));
    final onDisk = await drafts.readWif(id);
    expect(onDisk, wif, reason: 'no loom data is added to the WIF');
    expect(onDisk.contains('Test four-shaft loom'), isFalse);

    // The engine's check, directly: structurally valid, yet not feasible, with the exact requirement.
    final report = await looms.check(doc, loom);
    expect(report.diagnostics.first.code, 'loom.shafts_exceeded');
    expect(report.diagnostics.first.message,
        'This draft threads 8 shafts; Test four-shaft loom has 4.');
    expect(report.fileSett, const Sett(20, MeasureUnit.inches));

    // 3. Reopen it in the editor: the loom group says it is not feasible.
    final entry = await drafts.open(id);
    expect(entry.meta.loomPlan!.loomId, loom.id);
    await tester.pumpWidget(ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        home: EditorScreen(
          wifText: await drafts.readWif(id),
          title: entry.meta.name,
          id: id,
          meta: entry.meta,
        ),
      ),
    ));
    await settle(tester, frames: 40);
    // Both the shafts (8 on 4) and the treadles (8 on 6) are not feasible: the header names the
    // first and counts the other.
    const headline = 'On Test four-shaft loom: not feasible, needs 8 shafts, has 4 (and 1 more)';
    final shown = [
      for (final t in tester.widgetList<Text>(find.descendant(
          of: find.byKey(const ValueKey('loom-check-panel')), matching: find.byType(Text))))
        t.data,
    ];
    final container = ProviderScope.containerOf(tester.element(find.byType(EditorScreen)));
    expect(find.text(headline), findsOneWidget,
        reason: 'the loom group shows $shown; plan ${container.read(draftLoomPlanProvider)}; '
            'looms ${container.read(loomLibraryProvider)}; check ${container.read(loomCheckProvider)}; '
            'loading ${find.byType(CircularProgressIndicator).evaluate().length}; '
            'texts ${[
          for (final t in tester.widgetList<Text>(find.byType(Text))) t.data
        ].take(30)}');
    await tester.tap(find.text(headline));
    await settle(tester);
    expect(find.text('This draft threads 8 shafts; Test four-shaft loom has 4.'), findsOneWidget);
    expect(find.text('This draft uses 8 treadles; Test four-shaft loom has 6.'), findsOneWidget);
    // The expanded group is a bounded, scrolling list: the width check is further down it.
    final width = find.textContaining('0.8 in wide in the reed');
    await tester.scrollUntilVisible(width, 60,
        scrollable: find.descendant(
            of: find.byKey(const ValueKey('loom-check-panel')), matching: find.byType(Scrollable)));
    expect(width, findsOneWidget);
    expect(File(file.path).existsSync(), isTrue);
  });
}
