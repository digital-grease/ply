import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/native_format.dart';
import 'package:ply/src/models/tablet_band.dart';
import 'package:ply/src/rust/tablet_dto.dart';
import 'package:ply/src/screens/tablet_editor_screen.dart';
import 'package:ply/src/state/tablet_editor_providers.dart';

import 'tablet_test_support.dart';

// Host coverage for the tablet weaving editor (M10-02), with no FFI: a fake repository serves the
// engine's results from oracle band 1's hand-worked tables (ADR 0018 section 11), so the stepper is
// checked against the ADR's own numbers. Card setup, the turning chart, the stepper, the checks and
// their jumps, saving, the leave prompt, a band that cannot be opened, and phone width.

Future<void> pumpFrames(WidgetTester tester, [int n = 20]) async {
  await tester.pump();
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

/// A home with one button that opens the editor (so back can be tried).
Future<ProviderContainer> pumpEditor(
  WidgetTester tester,
  FakeTabletRepo repo, {
  String? openId = 'b1',
  TabletDocumentDto? initialDoc,
  Size size = const Size(1200, 2600),
  double textScale = 1.0,
}) async {
  // A tall screen by default, so the whole setup list is built; the phone tests pass their own.
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  if (textScale != 1.0) {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }
  final c = ProviderContainer(overrides: [tabletRepositoryProvider.overrideWithValue(repo)]);
  addTearDown(c.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: c,
    child: MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => TabletEditorScreen(openId: openId, initialDoc: initialDoc),
              )),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await pumpFrames(tester);
  return c;
}

Finder semantics(Pattern label) => find.bySemanticsLabel(label);

void main() {
  late Oracle band1;
  setUpAll(() => band1 = Oracle('band-1-threaded-in'));

  testWidgets('a saved band opens on its card setup, with the threading chart in words',
      (tester) async {
    final handle = tester.ensureSemantics();
    final repo = FakeTabletRepo(oracle: band1);
    final c = await pumpEditor(tester, repo);
    expect(find.text('Saved band'), findsOneWidget);
    for (final t in ['Cards', 'Turning', 'Band', 'Checks']) {
      expect(find.text(t), findsWidgets);
    }
    expect(c.read(tabletDocProvider).cards.length, 8);
    // ADR 0018 section 11: card 2 has W in hole A and R in hole D; cards 1 to 4 are S-threaded.
    expect(semantics('Card 2, hole D: colour 3 (#b3262e)'), findsOneWidget);
    expect(semantics('Card 2, hole A: colour 2 (#f2efe6)'), findsOneWidget);
    expect(semantics(RegExp(r'^Card 1, S-threaded')), findsOneWidget);
    expect(semantics(RegExp(r'^Card 5, Z-threaded')), findsOneWidget);
    expect(semantics(RegExp('^Card 1 starts with A at the near top')), findsOneWidget);
    // Both presets, Ply home first, and the provisional note.
    final first = tester.getTopLeft(find.byKey(const ValueKey('tablet-preset-plyHome')));
    final second = tester.getTopLeft(find.byKey(const ValueKey('tablet-preset-printedFaceRight')));
    expect(first.dy, lessThan(second.dy));
    expect(find.text(kFirstPresetNote), findsOneWidget);
    handle.dispose();
  });

  testWidgets('painting a hole, changing the threading and a preset are undoable edits',
      (tester) async {
    final repo = FakeTabletRepo(oracle: band1);
    final c = await pumpEditor(tester, repo);
    await tester.tap(find.byKey(const ValueKey('tablet-brush-1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('tablet-hole-0-A')));
    await tester.pump();
    expect(c.read(tabletDocProvider).cards[0].a, 1);
    await tester.tap(find.byKey(const ValueKey('tablet-brush-empty')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('tablet-hole-0-B')));
    await tester.pump();
    expect(c.read(tabletDocProvider).cards[0].b, isNull);
    await tester.tap(find.byKey(const ValueKey('tablet-threading-0')));
    await tester.pump();
    expect(c.read(tabletDocProvider).cards[0].threading, TabletThreadingKind.z);
    await tester.tap(find.byKey(const ValueKey('tablet-preset-printedFaceRight')));
    await tester.pump();
    expect(
        c.read(tabletDocProvider).cards.every((x) => sameArrangement(x.start, kPrintedFaceRight)),
        isTrue);
    expect(c.read(tabletEditorProvider).isDirty, isTrue);
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.byTooltip('Undo'));
      await tester.pump();
    }
    expect(c.read(tabletEditorProvider).isDirty, isFalse);
    expect(c.read(tabletDocProvider).cards[0].a, 0);
  });

  testWidgets('leaving with unsaved edits asks first; Discard leaves without saving',
      (tester) async {
    final repo = FakeTabletRepo(oracle: band1);
    final c = await pumpEditor(tester, repo);
    await tester.tap(find.byKey(const ValueKey('tablet-threading-3')));
    await tester.pump();
    expect(c.read(tabletEditorProvider).isDirty, isTrue);
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.maybePop();
    await pumpFrames(tester);
    expect(find.text('Leave without saving?'), findsOneWidget);
    expect(find.textContaining('this band'), findsOneWidget);
    await tester.tap(find.text('Discard'));
    await pumpFrames(tester);
    expect(find.text('open'), findsOneWidget);
    expect(repo.saves, 0);
  });

  testWidgets('the turning chart cycles a card on a tap and shows pick 1 at the bottom',
      (tester) async {
    final repo = FakeTabletRepo(oracle: band1);
    final c = await pumpEditor(tester, repo);
    await tester.tap(find.text('Turning'));
    await pumpFrames(tester);
    expect(
        find.textContaining('12 picks from 3 written. Pick 1 is at the bottom.'), findsOneWidget);
    final s1 = tester.getTopLeft(find.text('Segment 1: picks 1 to 4, 1 pick worked 4 times'));
    final s3 = tester.getTopLeft(find.text('Segment 3: picks 9 to 12, 1 pick worked 4 times'));
    expect(s1.dy, greaterThan(s3.dy), reason: 'the first segment is drawn lowest');
    final row = find.byKey(const ValueKey('tablet-turns-0-0'));
    final cell = c.read(tabletCellPxProvider).clamp(24, 40).toDouble();
    await tester.tapAt(tester.getTopLeft(row) + Offset(cell * 1.5, cell / 2));
    await tester.pump();
    expect(c.read(tabletDocProvider).turning[0].picks[0].turns, 'FBFFFFFF');
    await tester.tapAt(tester.getTopLeft(row) + Offset(cell * 1.5, cell / 2));
    await tester.pump();
    expect(c.read(tabletDocProvider).turning[0].picks[0].turns, 'FIFFFFFF');
  });

  testWidgets('the pick editor sets a ? only with the pattern\'s words, and flips a card',
      (tester) async {
    final repo = FakeTabletRepo(oracle: band1);
    final c = await pumpEditor(tester, repo);
    await tester.tap(find.text('Turning'));
    await pumpFrames(tester);
    await tester.tap(find.byKey(const ValueKey('tablet-pick-menu-2-0')));
    await pumpFrames(tester);
    await tester.tap(find.text('Edit this pick...'));
    await pumpFrames(tester);
    expect(find.text('Segment 3, step 1'), findsOneWidget);
    // Card 2 to ?: Done waits for the words.
    final card2 = find.byKey(const ValueKey('tablet-pick-card-1'));
    await tester.tap(find.descendant(of: card2, matching: find.text('?')));
    await tester.pump();
    expect(find.textContaining('write the pattern\'s words'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'The pattern\'s words'), 'half turn');
    await tester.pump();
    await tester.tap(find.text('Flip before').first);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('tablet-pick-done')));
    await pumpFrames(tester);
    final pick = c.read(tabletDocProvider).turning[2].picks[0];
    expect(pick.turns, 'F?FFBBBB');
    expect(pick.unsupported.single.text, 'half turn');
    expect(pick.unsupported.single.card, 'card-2');
    expect(pick.flip, ['card-1']);
    // One undo entry for the whole pick.
    await tester.tap(find.byTooltip('Undo'));
    await tester.pump();
    expect(c.read(tabletDocProvider).turning[2].picks[0].turns, 'FFFFBBBB');
  });

  testWidgets('the stepper walks the picks and shows every card as ADR 0018 section 11 works it',
      (tester) async {
    final handle = tester.ensureSemantics();
    final repo = FakeTabletRepo(oracle: band1);
    final c = await pumpEditor(tester, repo);
    await tester.tap(find.text('Band'));
    await pumpFrames(tester);
    expect(find.byKey(const ValueKey('tablet-review-note')), findsOneWidget);
    expect(find.textContaining('Pick 1 is at the bottom'), findsOneWidget);
    expect(find.text('Pick 1 of 12'), findsOneWidget);
    // Pick 1: card 1 (S) turned forward from home: A across the top, C across the bottom, +1.
    expect(
        semantics(RegExp(r'^Card 1 at pick 1: F, forward\. Now: B A D C\. S-threaded\. '
            r'Twist \+1 \(1 quarter turn\)\. Top: A, colour 1 \(#1a1a1a\)\. '
            r'Back: C, colour 1 \(#1a1a1a\)')),
        findsOneWidget);
    // Card 5 is Z-threaded: the same turn twines S, twist -1.
    expect(semantics(RegExp(r'^Card 5 at pick 1: .*Twist -1 \(')), findsOneWidget);
    // Step to pick 9: Left forward, Right backward; a reversal on cards 1 to 4 only.
    c.read(tabletPickProvider.notifier).state = 8;
    await pumpFrames(tester);
    await tester.tap(find.byKey(const ValueKey('tablet-step-next')));
    await pumpFrames(tester);
    expect(find.text('Pick 9 of 12'), findsOneWidget);
    expect(semantics(RegExp(r'^Card 1 at pick 9: F, forward\. reversal\. .*Twist \+1')),
        findsOneWidget);
    expect(
        semantics(RegExp(r'^Card 5 at pick 9: B, backward\. Now: D C B A\. Z-threaded\. '
            r'Twist \+1 .*Top: D, colour 4 \(#d4a017\)\.')),
        findsOneWidget);
    // Pick 12: every card +4 (one full turn) and home again.
    await tester.tap(find.byTooltip('Last pick'));
    await pumpFrames(tester);
    expect(find.text('Pick 12 of 12'), findsOneWidget);
    for (var n = 1; n <= 8; n++) {
      expect(
          semantics(
              RegExp('^Card $n at pick 12: .*Now: A D C B\\. .*Twist \\+4 \\(1 full turn\\)')),
          findsOneWidget,
          reason: 'card $n');
    }
    expect(repo.windows.last, (12, 12));
    await tester.tap(find.byKey(const ValueKey('tablet-step-back')));
    await pumpFrames(tester);
    expect(find.text('Pick 11 of 12'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('the back face numbers cards from the right', (tester) async {
    final repo = FakeTabletRepo(oracle: band1);
    final c = await pumpEditor(tester, repo);
    // The chart's image decodes outside the test's fake clock.
    Future<void> settle() async {
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await pumpFrames(tester);
      }
    }

    await tester.tap(find.text('Band'));
    await settle();
    expect(find.byKey(const ValueKey('tablet-band-chart')), findsOneWidget);
    expect(find.byKey(const ValueKey('tablet-current-pick')), findsOneWidget);
    // The header row of card numbers: the first row of the chart.
    double x(String n) => tester
        .getCenter(find.descendant(of: find.byType(ExcludeSemantics), matching: find.text(n)).first)
        .dx;
    expect(x('1'), lessThan(x('8')));
    await tester.tap(find.text('Back'));
    await settle();
    expect(c.read(tabletFaceProvider), TabletFaceKind.back);
    expect(x('8'), lessThan(x('1')));
  });

  testWidgets('the checks list every diagnostic with its place, and a tap goes there',
      (tester) async {
    final repo = FakeTabletRepo(
      oracle: band1,
      report: reportWith([
        diagnostic(
          'tablet.long_float',
          TabletSeverityKind.warning,
          'Card 1: the thread in hole B (#f2efe6) floats on the top face for 4 picks (picks 1 to 4).',
          location(TabletLocationKind.run,
              card: 1, hole: TabletHoleKind.b, face: TabletFaceKind.top, firstPick: 3, lastPick: 6),
          remediation: 'Turn the card on these picks.',
        ),
        diagnostic('tablet.reversal', TabletSeverityKind.info, 'Reversal at pick 5, cards 1 to 8.',
            location(TabletLocationKind.pick, pick: 5, cards: [1, 2, 3, 4, 5, 6, 7, 8])),
        diagnostic(
            'tablet.unsupported_turn',
            TabletSeverityKind.unsupported,
            'Pick 2, card 3: "half turn" is not modelled.',
            location(TabletLocationKind.step, segment: 2, step: 1, card: 3)),
      ], picks: 12),
    );
    final c = await pumpEditor(tester, repo);
    await tester.tap(find.byKey(const ValueKey('tablet-checks-tab')));
    await pumpFrames(tester);
    expect(find.text('Warnings (1)'), findsOneWidget);
    expect(find.text('Not modelled (1)'), findsOneWidget);
    expect(find.text('Notes (1)'), findsOneWidget);
    expect(find.textContaining('Card 1, hole B, top face, picks 3 to 6'), findsOneWidget);
    expect(find.byKey(const ValueKey('tablet-review-note')), findsOneWidget);
    // The float: to the Band tab at its first pick, card 1.
    await tester.tap(find.textContaining('floats on the top face'));
    await pumpFrames(tester);
    expect(c.read(tabletTabProvider), TabletEditorTab.band);
    expect(c.read(tabletPickProvider), 3);
    expect(c.read(tabletFocusProvider)?.card, 0);
    // The ? turn: to the Turning tab, segment 2's first written pick.
    await tester.tap(find.byKey(const ValueKey('tablet-checks-tab')));
    await pumpFrames(tester);
    await tester.tap(find.textContaining('is not modelled'));
    await pumpFrames(tester);
    expect(c.read(tabletTabProvider), TabletEditorTab.turning);
    expect(c.read(tabletFocusProvider)?.segment, 1);
    expect(c.read(tabletFocusProvider)?.step, 0);
  });

  testWidgets('a band with errors says so on the Band tab instead of drawing it', (tester) async {
    final repo = FakeTabletRepo(
      oracle: band1,
      report: reportWith([
        diagnostic(
            'tablet.turns_length',
            TabletSeverityKind.error,
            'Segment 1, pick 1 gives 7 turns for a band of 8 cards.',
            location(TabletLocationKind.step, segment: 1, step: 1)),
      ]),
    );
    await pumpEditor(tester, repo);
    await tester.tap(find.text('Band'));
    await pumpFrames(tester);
    expect(find.textContaining('This band has errors'), findsOneWidget);
    expect(repo.windows, isEmpty);
    await tester.tap(find.text('Show the checks'));
    await pumpFrames(tester);
    expect(find.text('Errors (1)'), findsOneWidget);
  });

  testWidgets('a new band saves under the name given, as a tablet weaving band', (tester) async {
    final repo = FakeTabletRepo(oracle: band1);
    final doc = blankTabletDocument(cards: 4);
    final c = await pumpEditor(tester, repo, openId: null, initialDoc: doc);
    await tester.tap(find.byKey(const ValueKey('tablet-threading-0')));
    await tester.pump();
    final edited = c.read(tabletDocProvider);
    await tester.tap(find.byTooltip('Save'));
    await pumpFrames(tester);
    await tester.enterText(find.byType(TextField), 'First band');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await pumpFrames(tester);
    expect(repo.saves, 1);
    expect(repo.savedMeta!.craft, 'TabletWeaving');
    expect(repo.savedMeta!.name, 'First band');
    expect(identical(repo.savedDoc, edited), isTrue);
    expect(c.read(tabletEditorProvider).isDirty, isFalse);
    expect(find.text('First band'), findsOneWidget);
  });

  testWidgets('a band that cannot be opened says why, and nothing can be saved over it',
      (tester) async {
    final repo = FakeTabletRepo(oracle: band1)
      ..readError = const NativeFormatException(NativeFormatProblem.newerVersion,
          document: NativeDocument.tabletBand);
    await pumpEditor(tester, repo);
    expect(find.text('This band was saved by a newer version of Ply. Update the app to open it.'),
        findsOneWidget);
    final save = tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.save_outlined));
    expect(save.onPressed, isNull);
  });

  /// The tab named [name] in the editor's tab bar (not a heading of the same word).
  Finder tab(String name) => find.descendant(of: find.byType(TabBar), matching: find.text(name));

  /// Scroll the tab bar to [name] (it scrolls on a narrow screen) and open that tab.
  Future<void> openTab(WidgetTester tester, String name) async {
    await tester.ensureVisible(tab(name));
    await tester.pump();
    await tester.tap(tab(name));
    await pumpFrames(tester);
  }

  for (final (label, size, scale) in const [
    ('a phone, upright', Size(360, 740), 1.0),
    ('a phone on its side', Size(740, 360), 1.0),
    ('a small phone with larger text', Size(360, 640), 1.3),
  ]) {
    testWidgets('every tab fits $label', (tester) async {
      final repo = FakeTabletRepo(oracle: band1);
      await pumpEditor(tester, repo, size: size, textScale: scale);
      for (final name in ['Turning', 'Band', 'Checks', 'Cards']) {
        await tester.ensureVisible(tab(name));
        await tester.tap(tab(name));
        await pumpFrames(tester);
        expect(tester.takeException(), isNull, reason: '$name on $label');
      }
      // The Band tab scrolls: its card strip can be reached.
      await openTab(tester, 'Band');
      await tester.dragUntilVisible(find.byKey(const ValueKey('tablet-card-strip')),
          find.byKey(const ValueKey('tablet-band-tab')), const Offset(0, -200));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('zoom stays within its bounds', (tester) async {
    final c = await pumpEditor(tester, FakeTabletRepo(oracle: band1));
    await openTab(tester, 'Band');
    for (var i = 0; i < 6; i++) {
      final out = tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.zoom_out));
      if (out.onPressed == null) break;
      await tester.tap(find.byTooltip('Smaller cells'));
      await tester.pump();
    }
    expect(c.read(tabletCellPxProvider), kTabletCellPxMin);
    for (var i = 0; i < 12; i++) {
      final more = tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.zoom_in));
      if (more.onPressed == null) break;
      await tester.tap(find.byTooltip('Larger cells'));
      await tester.pump();
    }
    expect(c.read(tabletCellPxProvider), kTabletCellPxMax);
  });

  testWidgets('a card tile puts the twist before the faces', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpEditor(tester, FakeTabletRepo(oracle: band1));
    await openTab(tester, 'Band');
    expect(
        semantics(RegExp(r'^Card 1 at pick 1: F, forward\. Now: B A D C\. S-threaded\. '
            r'Twist \+1 \(1 quarter turn\)\. Top: A')),
        findsOneWidget);
    handle.dispose();
  });

  testWidgets('undoing an added card on the Band tab shows the cards there are', (tester) async {
    final repo = FakeTabletRepo(oracle: band1);
    final c = await pumpEditor(tester, repo);
    await openTab(tester, 'Band');
    // A ninth card; the oracle still answers for 8, then the undo leaves 8 again while a stale
    // window may still be on screen.
    c.read(tabletEditorProvider.notifier).edit((d) => insertCard(d, 8));
    await pumpFrames(tester);
    c.read(tabletEditorProvider.notifier).undo();
    await tester.pump();
    expect(tester.takeException(), isNull);
    await pumpFrames(tester);
    expect(tester.takeException(), isNull);
    expect(c.read(tabletDocProvider).cards.length, 8);
  });

  testWidgets('while the band is rechecked, a refused pick is not shown as an exception',
      (tester) async {
    final repo = FakeTabletRepo(oracle: band1)
      ..windowError = const TabletRunFailure(
          kind: TabletRunFailureKind.hasErrors, message: 'the band cannot be simulated');
    await pumpEditor(tester, repo);
    await openTab(tester, 'Band');
    expect(find.text('Checking the band...'), findsWidgets);
    expect(find.textContaining('TabletRunFailure'), findsNothing);
  });

  testWidgets('a check\'s focus is followed once and dropped by an edit that moves the cards',
      (tester) async {
    final repo = FakeTabletRepo(
      oracle: band1,
      report: reportWith([
        diagnostic('tablet.start_illegal', TabletSeverityKind.error, 'Card 7 cannot start so.',
            location(TabletLocationKind.card, card: 7)),
      ]),
    );
    final c = await pumpEditor(tester, repo, size: const Size(360, 1400));
    await openTab(tester, 'Checks');
    await tester.tap(find.text('Card 7 cannot start so.'));
    await pumpFrames(tester);
    expect(c.read(tabletTabProvider), TabletEditorTab.cards);
    expect(c.read(tabletFocusProvider)?.card, 6);
    final chart = tester.state<ScrollableState>(find.descendant(
        of: find.byKey(const ValueKey('tablet-threading-chart')),
        matching: find.byType(Scrollable)));
    expect(chart.position.pixels, greaterThan(0), reason: 'scrolled to card 7');
    // The weaver scrolls back and paints a hole: the chart stays where they put it.
    chart.position.jumpTo(0);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('tablet-hole-0-A')));
    await pumpFrames(tester);
    expect(chart.position.pixels, 0);
    expect(c.read(tabletFocusProvider)?.card, 6, reason: 'a hole does not move the cards');
    // Inserting a card moves them: the focus goes.
    c.read(tabletEditorProvider.notifier).edit((d) => insertCard(d, 0));
    await pumpFrames(tester);
    expect(c.read(tabletFocusProvider), isNull);
  });

  testWidgets('times worked and warning levels are kept within Ply\'s limits', (tester) async {
    final repo = FakeTabletRepo(oracle: band1);
    final c = await pumpEditor(tester, repo);
    await openTab(tester, 'Turning');
    await tester.tap(find.byTooltip('Segment 1 actions'));
    await pumpFrames(tester);
    await tester.tap(find.text('Times worked...'));
    await pumpFrames(tester);
    await tester.enterText(find.byKey(const ValueKey('tablet-times-worked')), '4294967297');
    await tester.pump();
    expect(find.textContaining('At most 200,000 times'), findsOneWidget);
    final set = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Set'));
    expect(set.onPressed, isNull);
    await tester.enterText(find.byKey(const ValueKey('tablet-times-worked')), '200000');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Set'));
    await pumpFrames(tester);
    expect(c.read(tabletDocProvider).turning[0].repeat, 200000);
    // The + button stops at the limit.
    final more = tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.add).first);
    expect(more.onPressed, isNull);
    // The warning levels: past the limit is refused with a message.
    await tester.tap(find.byTooltip('More'));
    await pumpFrames(tester);
    await tester.tap(find.text('Band settings'));
    await pumpFrames(tester);
    await tester.enterText(find.byKey(const ValueKey('tablet-twist-threshold')), '4294967296');
    await tester.pump();
    expect(find.textContaining('At most 200,000'), findsOneWidget);
    expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Apply')).onPressed, isNull);
    await tester.enterText(find.byKey(const ValueKey('tablet-twist-threshold')), '40');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
    await pumpFrames(tester);
    expect(c.read(tabletDocProvider).settings.twistWarningQuarters, 40);
  });
}
