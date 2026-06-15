import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/knit_repository.dart';
import 'package:ply/src/rust/knit_dto.dart';
import 'package:ply/src/screens/knit_written_screen.dart';
import 'package:ply/src/state/knit_editor_providers.dart';

// Host coverage for the written-instructions view: it renders the repo's lines, an empty hint when
// there are none, and an error message when generation fails. A fake repo stubs written() (no FFI).

class FakeWrittenRepo extends KnitRepository {
  FakeWrittenRepo(this.lines, {this.fail = false});
  final List<String> lines;
  final bool fail;

  @override
  Future<List<String>> written(KnitPatternDto pattern) async {
    if (fail) throw Exception('boom');
    return lines;
  }
}

Future<void> pump(WidgetTester tester, FakeWrittenRepo repo) async {
  final c = ProviderContainer(overrides: [knitRepositoryProvider.overrideWithValue(repo)]);
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: KnitWrittenScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders one selectable line per row', (tester) async {
    await pump(tester, FakeWrittenRepo(['Row 1 (RS): k4', 'Row 2 (WS): p4']));
    expect(find.text('Row 1 (RS): k4'), findsOneWidget);
    expect(find.text('Row 2 (WS): p4'), findsOneWidget);
    expect(find.byType(SelectableText), findsNWidgets(2));
  });

  testWidgets('shows a hint when the chart has no rows', (tester) async {
    await pump(tester, FakeWrittenRepo(const []));
    expect(find.textContaining('Add some rows'), findsOneWidget);
  });

  testWidgets('shows an error message when generation fails', (tester) async {
    await pump(tester, FakeWrittenRepo(const [], fail: true));
    expect(find.textContaining('Could not generate instructions'), findsOneWidget);
  });
}
