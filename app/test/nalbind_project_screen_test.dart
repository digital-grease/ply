import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/nalbind_repository.dart';
import 'package:ply/src/models/nalbind_project.dart';
import 'package:ply/src/rust/nalbind_dto.dart';
import 'package:ply/src/screens/nalbind_project_screen.dart';
import 'package:ply/src/state/nalbind_providers.dart';

// Host coverage for the nalbind PROJECT screen's dirty-on-exit guard: a back with unsaved form edits
// prompts Save / Discard / Keep editing, a clean form pops straight through, Save runs the normal
// save flow and leaves only on success, and the in-flight-save races behave. A fake repo stubs the
// stitch FFI and the persistence calls (no disk, no FFI).

const _oslo = NalbindStitchDto(
  name: 'Oslo',
  passes: [
    PassDto(steps: [StepKind.under, StepKind.over]),
    PassDto(steps: [StepKind.under, StepKind.over, StepKind.over]),
  ],
  connections: [ConnectionDto(side: ConnSideKind.front, count: 1)],
  thumbLoops: ThumbLoopsDto(a: 1, b: 1),
  twist: TwistKind.untwisted,
  alsoKnownAs: ['Finnish 1+1'],
  codes: [PublishedCodeDto(code: 'UO/UOO F1', source: 'neulakintaat.fi')],
  note: 'The classic beginner stitch.',
);

final _diagram = DiagramDto(
  width: 6,
  height: 2.6,
  baseline: 1.6,
  loops: const [
    LoopGlyphDto(x: 0.5, kind: LoopKindDto.underEngaged),
    LoopGlyphDto(x: 1.5, kind: LoopKindDto.overEngaged),
  ],
  turns: Float32List.fromList([2.0]),
  connections: const [ConnArrowDto(x: 6, side: ConnSideKind.front, count: 1)],
);

const _stored = NalbindProject(
  name: 'Mittens',
  notation: 'UO/UOO F1',
  stitchName: 'Oslo',
  notes: 'thumb gusset at round 6',
);

class FakeProjectRepo extends NalbindRepository {
  int saveCount = 0;
  NalbindProject? saved;
  String? savedId;
  int listCount = 0;

  /// When set, saveProject suspends on this until completed (holds one save in flight).
  Completer<void>? saveGate;

  /// When true, saveProject throws (a failed write).
  bool saveError = false;

  @override
  Future<List<NalbindStitchDto>> builtins() async => [_oslo];

  @override
  Future<DiagramDto> diagram(NalbindStitchDto dto) async => _diagram;

  @override
  Future<NalbindStitchDto> parse(String notation) async => _oslo;

  @override
  Future<List<NalbindIssueDto>> validate(NalbindStitchDto dto) async => const [];

  @override
  Future<String> saveProject(NalbindProject project, {String? id}) async {
    saveCount++;
    if (saveGate != null) await saveGate!.future;
    if (saveError) throw Exception('disk full');
    saved = project;
    savedId = id;
    return id ?? 'new-id';
  }

  /// When true, readProject throws (a project file that cannot be read or parsed).
  bool readError = false;

  @override
  Future<NalbindProject> readProject(String id) async {
    if (readError) throw const FormatException('corrupt project');
    return _stored;
  }

  @override
  Future<void> touchOpened(String id) async {}

  @override
  Future<List<NalbindProjectEntry>> listProjects() async {
    listCount++;
    return const [];
  }
}

/// Pumps a host that PUSHES the project screen (so a back has somewhere to go), mirroring the
/// Nalbinding tab's `push<void>`. [openId] opens the stored project; null starts a new one.
Future<ProviderContainer> pumpProject(WidgetTester tester, FakeProjectRepo repo,
    {String? openId}) async {
  final c = ProviderContainer(overrides: [nalbindRepositoryProvider.overrideWithValue(repo)]);
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => NalbindProjectScreen(openId: openId)),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(find.byType(NalbindProjectScreen), findsOneWidget);
  return c;
}

Finder get _nameField => find.widgetWithText(TextField, 'Project name');

Future<void> tapBack(WidgetTester tester) async {
  await tester.tap(find.byType(BackButton));
  await tester.pumpAndSettle();
}

const _leaveTitle = 'Leave without saving?';

void main() {
  testWidgets('a project that fails to open is never overwritten by the empty form', (tester) async {
    final repo = FakeProjectRepo()..readError = true;
    await pumpProject(tester, repo, openId: 'p1');
    expect(find.textContaining('Could not open the project'), findsOneWidget);
    expect(find.textContaining('leave the original file untouched'), findsOneWidget);

    await tester.enterText(_nameField, 'Rescued notes');
    await tester.pump();
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    expect(repo.saveCount, 1);
    expect(repo.savedId, isNull, reason: 'saved as a NEW project, not over the unreadable p1');
    expect(repo.saved?.name, 'Rescued notes');
  });

  testWidgets('a fresh, untouched project pops straight back with no prompt', (tester) async {
    final repo = FakeProjectRepo();
    await pumpProject(tester, repo);
    await tapBack(tester);
    expect(find.text(_leaveTitle), findsNothing);
    expect(find.byType(NalbindProjectScreen), findsNothing);
    expect(repo.saveCount, 0);
  });

  testWidgets('an opened project left untouched pops with no prompt', (tester) async {
    final repo = FakeProjectRepo();
    await pumpProject(tester, repo, openId: 'p1');
    expect(find.text('Mittens'), findsOneWidget, reason: 'the stored project loaded');
    await tapBack(tester);
    expect(find.text(_leaveTitle), findsNothing);
    expect(find.byType(NalbindProjectScreen), findsNothing);
  });

  testWidgets('an edit reverted by hand reads clean (value comparison)', (tester) async {
    final repo = FakeProjectRepo();
    await pumpProject(tester, repo, openId: 'p1');
    await tester.enterText(_nameField, 'Mittens, v2');
    await tester.pump();
    await tester.enterText(_nameField, 'Mittens ');
    await tester.pump(); // a trailing space the save would trim away is not an unsaved change
    await tapBack(tester);
    expect(find.text(_leaveTitle), findsNothing);
    expect(find.byType(NalbindProjectScreen), findsNothing);
  });

  testWidgets('back with edits prompts; Keep editing stays with the edit intact', (tester) async {
    final repo = FakeProjectRepo();
    await pumpProject(tester, repo);
    await tester.enterText(_nameField, 'Socks');
    await tester.pump();
    await tapBack(tester);
    expect(find.text(_leaveTitle), findsOneWidget);
    expect(find.textContaining("this project haven't been saved"), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Keep editing'));
    await tester.pumpAndSettle();
    expect(find.byType(NalbindProjectScreen), findsOneWidget, reason: 'still editing');
    expect(find.text('Socks'), findsOneWidget);
    expect(repo.saveCount, 0);
  });

  testWidgets('picking a stitch chip counts as an unsaved change', (tester) async {
    final repo = FakeProjectRepo();
    await pumpProject(tester, repo);
    await tester.tap(find.widgetWithText(ActionChip, 'Oslo'));
    await tester.pumpAndSettle();
    await tapBack(tester);
    expect(find.text(_leaveTitle), findsOneWidget);
  });

  testWidgets('Discard leaves without saving', (tester) async {
    final repo = FakeProjectRepo();
    await pumpProject(tester, repo, openId: 'p1');
    await tester.enterText(find.byType(TextField).last, 'new notes');
    await tester.pump();
    await tapBack(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Discard'));
    await tester.pumpAndSettle();
    expect(find.byType(NalbindProjectScreen), findsNothing, reason: 'discard exits');
    expect(find.text('open'), findsOneWidget, reason: 'exactly one pop: the host survives');
    expect(repo.saveCount, 0, reason: 'nothing persisted on discard');
  });

  testWidgets('Save from the prompt saves the form, then leaves', (tester) async {
    final repo = FakeProjectRepo();
    await pumpProject(tester, repo);
    await tester.enterText(_nameField, '  Socks  ');
    await tester.pump();
    await tapBack(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(repo.saveCount, 1);
    expect(repo.saved, const NalbindProject(name: 'Socks'), reason: 'the normal save flow (trimmed)');
    expect(repo.savedId, isNull, reason: 'a never-saved project gets a new id');
    expect(find.byType(NalbindProjectScreen), findsNothing, reason: 'a successful save exits');
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('Save from the prompt on an opened project overwrites it, then leaves', (tester) async {
    final repo = FakeProjectRepo();
    await pumpProject(tester, repo, openId: 'p1');
    await tester.enterText(_nameField, 'Mittens, v2');
    await tester.pump();
    await tapBack(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(repo.savedId, 'p1');
    expect(repo.saved, _stored.copyWith(name: 'Mittens, v2'));
    expect(find.byType(NalbindProjectScreen), findsNothing);
  });

  testWidgets('a failed save stays on screen, keeps the edits, and still guards the back',
      (tester) async {
    final repo = FakeProjectRepo()..saveError = true;
    await pumpProject(tester, repo);
    await tester.enterText(_nameField, 'Socks');
    await tester.pump();
    await tapBack(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(repo.saveCount, 1);
    expect(find.byType(NalbindProjectScreen), findsOneWidget, reason: 'a failed save never leaves');
    expect(find.textContaining('Could not save'), findsOneWidget);
    expect(find.text('Socks'), findsOneWidget);

    await tapBack(tester);
    expect(find.text(_leaveTitle), findsOneWidget, reason: 'still unsaved, so still guarded');
  });

  testWidgets('an AppBar Save makes the form clean; a later edit guards again', (tester) async {
    final repo = FakeProjectRepo();
    await pumpProject(tester, repo);
    await tester.enterText(_nameField, 'Socks');
    await tester.pump();
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    expect(repo.saveCount, 1);
    expect(find.byType(NalbindProjectScreen), findsOneWidget, reason: 'the project saves in place');

    await tester.enterText(_nameField, 'Socks, v2');
    await tester.pump();
    await tapBack(tester);
    expect(find.text(_leaveTitle), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Keep editing'));
    await tester.pumpAndSettle();

    await tester.enterText(_nameField, 'Socks'); // back to what was saved
    await tester.pump();
    await tapBack(tester);
    expect(find.text(_leaveTitle), findsNothing);
    expect(find.byType(NalbindProjectScreen), findsNothing);
  });

  testWidgets('AppBar Save in flight + back -> Discard pops once; a save landing after the screen '
      'is gone still refreshes the list', (tester) async {
    final repo = FakeProjectRepo();
    final c = await pumpProject(tester, repo);
    await c.read(nalbindProjectsProvider.future); // the library list, built once
    expect(repo.listCount, 1);
    await tester.enterText(_nameField, 'Socks');
    await tester.pump();

    repo.saveGate = Completer<void>(); // park the write
    await tester.tap(find.byTooltip('Save'));
    await tester.pump();
    expect(repo.saveCount, 1);

    await tapBack(tester);
    expect(find.text(_leaveTitle), findsOneWidget, reason: 'a back mid-save still offers the choice');
    await tester.tap(find.widgetWithText(TextButton, 'Discard'));
    await tester.pumpAndSettle(); // the screen is fully gone (disposed) ...
    expect(find.byType(NalbindProjectScreen), findsNothing, reason: 'discarded');
    repo.saveGate!.complete(); // ... before the parked save resumes
    await tester.pumpAndSettle();

    expect(find.text('open'), findsOneWidget, reason: 'the host route survives (no second pop)');
    expect(repo.saveCount, 1, reason: 'the save the user had already started is not repeated');
    expect(tester.takeException(), isNull);
    // The save that finished after the screen closed still invalidated the library list.
    await c.read(nalbindProjectsProvider.future);
    expect(repo.listCount, 2);
  });

  testWidgets('AppBar Save in flight + back -> Save joins that save (one write), then leaves',
      (tester) async {
    final repo = FakeProjectRepo();
    await pumpProject(tester, repo);
    await tester.enterText(_nameField, 'Socks');
    await tester.pump();

    repo.saveGate = Completer<void>();
    await tester.tap(find.byTooltip('Save'));
    await tester.pump();
    await tapBack(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.byType(NalbindProjectScreen), findsOneWidget, reason: 'waits for the save to land');

    repo.saveGate!.complete();
    await tester.pumpAndSettle();
    expect(repo.saveCount, 1, reason: 'joined the in-flight save, no second write');
    expect(find.byType(NalbindProjectScreen), findsNothing, reason: 'left once the save succeeded');
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets("a second back during the leave prompt's own save is dropped", (tester) async {
    final repo = FakeProjectRepo();
    await pumpProject(tester, repo);
    await tester.enterText(_nameField, 'Socks');
    await tester.pump();

    repo.saveGate = Completer<void>();
    await tapBack(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle(); // the write is parked; no dialog is on screen now
    await tapBack(tester);
    expect(find.text(_leaveTitle), findsNothing, reason: 'no second prompt stacked');

    repo.saveGate!.complete();
    await tester.pumpAndSettle();
    expect(repo.saveCount, 1);
    expect(find.byType(NalbindProjectScreen), findsNothing);
    expect(find.text('open'), findsOneWidget, reason: 'one pop only');
  });

  testWidgets("an edit typed during the leave prompt's save keeps the screen open", (tester) async {
    final repo = FakeProjectRepo();
    await pumpProject(tester, repo);
    await tester.enterText(_nameField, 'Socks');
    await tester.pump();

    repo.saveGate = Completer<void>();
    await tapBack(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    await tester.enterText(_nameField, 'Socks, v2'); // lands while the write is in flight
    repo.saveGate!.complete();
    await tester.pumpAndSettle();

    expect(repo.saved, const NalbindProject(name: 'Socks'));
    expect(find.byType(NalbindProjectScreen), findsOneWidget,
        reason: 'the newer edit was not in that save, so leaving would drop it');
    await tapBack(tester);
    expect(find.text(_leaveTitle), findsOneWidget);
  });
}
