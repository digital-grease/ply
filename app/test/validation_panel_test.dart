import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/draft_issue.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/widgets/validation_panel.dart';

// The inline validation band: zero chrome when clean, a severity-toned summary when not, expandable
// to a bounded list with Errors sorted first. The issue list is fed via a fake validateDto (the
// panel watches validationProvider), so this runs on the host VM with no native lib.

class FakeRepo extends DraftRepository {
  FakeRepo(this.issues, {this.hang = false, this.fail = false});
  final List<DraftIssue> issues;

  /// When true, validateDto never resolves (the panel stays in AsyncLoading).
  final bool hang;

  /// When true, validateDto throws (the panel sees AsyncError).
  final bool fail;

  @override
  Future<List<DraftIssue>> validateDto(DraftDoc doc) {
    if (hang) return Completer<List<DraftIssue>>().future; // never resolves
    if (fail) return Future.error(Exception('validate boom'));
    return Future.value(issues);
  }
}

DraftIssue err(String m) => DraftIssue(severity: IssueSeverity.error, message: m);
DraftIssue warn(String m) => DraftIssue(severity: IssueSeverity.warning, message: m);

Future<ProviderContainer> pumpPanel(WidgetTester tester, List<DraftIssue> issues,
    {bool hang = false, bool fail = false}) async {
  final c = ProviderContainer(
      overrides: [repositoryProvider.overrideWithValue(FakeRepo(issues, hang: hang, fail: fail))]);
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: Scaffold(body: Column(children: [ValidationPanel()]))),
    ),
  );
  // Let the async validation resolve into the panel.
  await tester.pump();
  await tester.pump();
  return c;
}

void main() {
  testWidgets('a clean draft renders zero chrome (no severity icons)', (tester) async {
    await pumpPanel(tester, const []);
    expect(find.byIcon(Icons.error), findsNothing);
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    expect(find.byType(InkWell), findsNothing, reason: 'no summary header when clean');
  });

  testWidgets('one Error shows the red error icon and the engine message', (tester) async {
    await pumpPanel(tester, [err('treadle 1 ties shaft 5 outside 1..=2')]);
    expect(find.byIcon(Icons.error), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    // A single issue shows its engine-formatted message verbatim in the collapsed summary.
    expect(find.text('treadle 1 ties shaft 5 outside 1..=2'), findsOneWidget);
    final colors = Theme.of(tester.element(find.byType(ValidationPanel))).colorScheme;
    expect(tester.widget<Icon>(find.byIcon(Icons.error)).color, colors.error);
  });

  testWidgets('one Warning shows the amber icon and no error icon', (tester) async {
    await pumpPanel(tester, [warn('warp color count (5) != warp ends (4)')]);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.byIcon(Icons.error), findsNothing);
    expect(find.text('warp color count (5) != warp ends (4)'), findsOneWidget);
  });

  testWidgets('a still-loading validation renders zero chrome (no blink)', (tester) async {
    // AsyncLoading collapses to nothing: the advisory band never flashes a spinner.
    await pumpPanel(tester, [err('pending')], hang: true);
    expect(find.byIcon(Icons.error), findsNothing);
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('a thrown validation (AsyncError) renders zero chrome', (tester) async {
    // The panel twin of the Save gate's fail-closed test: a validate throw shows nothing inline
    // (the gate, not the advisory band, is what refuses the save).
    await pumpPanel(tester, const [], fail: true);
    expect(find.byIcon(Icons.error), findsNothing);
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('one error + one warning uses both singular forms in the summary', (tester) async {
    await pumpPanel(tester, [err('E1'), warn('W1')]);
    expect(find.text('1 error, 1 warning'), findsOneWidget);
  });

  testWidgets('mixed issues: collapsed counts, then expand lists all with Errors first',
      (tester) async {
    final c = await pumpPanel(tester, [
      err('E1'),
      warn('W1'),
      err('E2'),
      warn('W2'),
      err('E3'),
    ]);
    // Collapsed: a single pluralized summary row, errors before warnings.
    expect(find.text('3 errors, 2 warnings'), findsOneWidget);
    expect(find.text('E1'), findsNothing, reason: 'collapsed shows the summary, not each issue');

    // Expand via the shared provider (the Save dialog's "Show me" uses the same path).
    c.read(editorIssuesExpandedProvider.notifier).state = true;
    await tester.pump();

    for (final m in ['E1', 'E2', 'E3', 'W1', 'W2']) {
      expect(find.text(m), findsOneWidget);
    }
    // Errors are sorted before warnings: the last error sits above the first warning.
    expect(tester.getTopLeft(find.text('E3')).dy < tester.getTopLeft(find.text('W1')).dy, isTrue,
        reason: 'Errors are listed before Warnings');
    // The list is bounded + scrollable so many issues never eat the drawdown.
    expect(find.byType(Scrollable), findsWidgets);
  });
}
