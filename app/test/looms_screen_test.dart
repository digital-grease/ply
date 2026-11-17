import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/app_settings_repository.dart';
import 'package:ply/src/data/loom_repository.dart';
import 'package:ply/src/models/app_settings.dart';
import 'package:ply/src/models/draft_doc.dart' show MeasureUnit;
import 'package:ply/src/models/loom_profile.dart';
import 'package:ply/src/models/loom_type.dart';
import 'package:ply/src/screens/looms_screen.dart';
import 'package:ply/src/screens/settings_screen.dart';
import 'package:ply/src/state/loom_providers.dart';
import 'package:ply/src/state/theme_providers.dart';

import 'loom_test_support.dart';

// My looms (ADR 0014): list, add, edit, duplicate and delete with a confirm; every field optional;
// a newer looms file is read only.

class _Settings extends AppSettingsRepository {
  @override
  Future<AppSettings> load() async => const AppSettings();
  @override
  Future<void> save(AppSettings settings) async {}
}

Future<FakeLoomRepository> pumpLooms(WidgetTester tester,
    {List<LoomProfile> looms = const [], LoomFileStatus status = LoomFileStatus.ok}) async {
  // Tall enough that the whole form is laid out (its list is lazy).
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final repo = FakeLoomRepository(looms: looms, status: status);
  await tester.pumpWidget(ProviderScope(
    overrides: [loomRepositoryProvider.overrideWithValue(repo)],
    child: const MaterialApp(home: LoomsScreen()),
  ));
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  testWidgets('with no looms it explains what they are for', (tester) async {
    await pumpLooms(tester);
    expect(find.textContaining('No looms yet.'), findsOneWidget);
    expect(find.text('Add loom'), findsOneWidget);
  });

  testWidgets('adding a loom saves only what was entered', (tester) async {
    final repo = await pumpLooms(tester);
    await tester.tap(find.text('Add loom'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Every field is optional.'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('loom-name')), 'Floor loom');
    await tester.enterText(find.byKey(const ValueKey('loom-shafts')), '8');
    await tester.enterText(find.byKey(const ValueKey('loom-width')), '36');
    await tester.enterText(find.byKey(const ValueKey('loom-reed-dents')), '12');
    await tester.tap(find.byTooltip('Add this reed'));
    await tester.pump();
    expect(find.text('12 dents per inch'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final saved = repo.looms.single;
    expect(saved.name, 'Floor loom');
    expect(saved.shafts, 8);
    expect(saved.treadles, isNull, reason: 'left blank: unknown, not zero');
    expect(saved.type, isNull);
    expect(saved.treadlesAtOnce, isNull);
    expect(saved.weavingWidth, const LoomLength(36, MeasureUnit.inches));
    expect(saved.reeds, const [Reed(12, DentUnit.perInch)]);
    expect(saved.id, isNotEmpty);
    expect(find.text('Floor loom'), findsOneWidget);
    expect(find.text('8 shafts, 36 in wide, 1 reed'), findsOneWidget);
  });

  testWidgets('a count outside the limits is refused with a plain sentence', (tester) async {
    final repo = await pumpLooms(tester);
    await tester.tap(find.text('Add loom'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('loom-shafts')), '0');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a whole number from 1 to 200, or leave it blank.'), findsOneWidget);
    expect(repo.saves, 0);
  });

  testWidgets('editing changes the loom in place, and the type can be chosen', (tester) async {
    final repo = await pumpLooms(tester, looms: [borrowedLoom]);
    await tester.tap(find.text('Borrowed loom'));
    await tester.pumpAndSettle();
    expect(find.text('Edit loom'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('loom-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(LoomType.countermarch.label).last);
    await tester.pumpAndSettle();
    expect(find.text(LoomType.countermarch.description), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(repo.looms.single.id, borrowedLoom.id);
    expect(repo.looms.single.type, LoomType.countermarch);
    expect(repo.looms.single.shafts, 8);
  });

  testWidgets('duplicate adds a copy after it; delete asks first', (tester) async {
    final repo = await pumpLooms(tester, looms: [floorLoom, borrowedLoom]);
    await tester.tap(find.byTooltip('Loom actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Duplicate'));
    await tester.pumpAndSettle();
    expect(
        [for (final l in repo.looms) l.name], ['Floor loom', 'Floor loom (copy)', 'Borrowed loom']);
    expect(repo.looms[1].id, isNot(floorLoom.id));
    expect(repo.looms[1].shafts, floorLoom.shafts);

    await tester.tap(find.byTooltip('Loom actions').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete "Borrowed loom"?'), findsOneWidget);
    expect(find.textContaining('keep its name'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(repo.looms, hasLength(3), reason: 'Cancel deletes nothing');

    await tester.tap(find.byTooltip('Loom actions').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect([for (final l in repo.looms) l.name], ['Floor loom', 'Floor loom (copy)']);
    expect(find.text('Borrowed loom'), findsNothing);
  });

  testWidgets('leaving the form with changes asks before discarding', (tester) async {
    final repo = await pumpLooms(tester);
    await tester.tap(find.text('Add loom'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('loom-name')), 'Half typed');
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Leave without saving?'), findsOneWidget);
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(repo.looms, isEmpty);
    expect(find.text('My looms'), findsOneWidget);
  });

  testWidgets('a stored width is shown exactly: opening and saving changes nothing else',
      (tester) async {
    const exact = LoomProfile(
        id: 'x', name: 'Exact', weavingWidth: LoomLength(22.25, MeasureUnit.inches), shafts: 4);
    final repo = await pumpLooms(tester, looms: [exact]);
    await tester.tap(find.text('Exact'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, '22.25'), findsOneWidget);
    // Unchanged: back leaves without asking.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Leave without saving?'), findsNothing);
    expect(find.text('My looms'), findsOneWidget);
    // Editing only the notes keeps the width as it was.
    await tester.tap(find.text('Exact'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('loom-notes')), 'New reed on order.');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(repo.looms.single.weavingWidth, const LoomLength(22.25, MeasureUnit.inches));
    expect(repo.looms.single.notes, 'New reed on order.');
  });

  testWidgets('a name too long by the engine\'s count is refused in the form', (tester) async {
    final repo = await pumpLooms(tester);
    await tester.tap(find.text('Add loom'));
    await tester.pumpAndSettle();
    // 60 family emoji: 60 characters on screen, 420 code points (the engine's count).
    await tester.enterText(find.byKey(const ValueKey('loom-name')),
        '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}\u200D\u{1F466}' * 60);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('This is too long: use at most 100'), findsOneWidget);
    expect(repo.saves, 0);
  });

  testWidgets('a looms file too large to open is read only and says so', (tester) async {
    await pumpLooms(tester, status: LoomFileStatus.tooLarge);
    expect(find.textContaining('too large to open'), findsOneWidget);
    expect(find.text('Add loom'), findsNothing);
  });

  testWidgets('a looms file from a newer Ply is read only', (tester) async {
    await pumpLooms(tester, status: LoomFileStatus.newer);
    expect(find.textContaining('saved by a newer version of Ply'), findsOneWidget);
    expect(find.text('Add loom'), findsNothing);
  });

  testWidgets('a file that was set aside is said once, and the list starts empty', (tester) async {
    await pumpLooms(tester, status: LoomFileStatus.setAside);
    expect(find.textContaining('could not be read. The file was kept as looms.json.corrupt'),
        findsOneWidget);
    expect(find.text('Add loom'), findsOneWidget);
  });

  testWidgets('Settings leads to My looms', (tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        appSettingsRepositoryProvider.overrideWithValue(_Settings()),
        loomRepositoryProvider.overrideWithValue(FakeLoomRepository(looms: [floorLoom])),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Equipment'), findsOneWidget);
    await tester.tap(find.text('My looms'));
    await tester.pumpAndSettle();
    expect(find.text('Floor loom'), findsOneWidget);
    expect(find.text(floorLoom.summary), findsOneWidget);
  });
}
