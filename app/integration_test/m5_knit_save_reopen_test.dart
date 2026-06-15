// M5 device proof: the knitting-pattern save round-trip on a real device + filesystem.
//
// Verifies the `<documents>/knits/<id>.{plyknit,json,png}` triplet end to end: a painted chart
// saves, appears in listKnits(), reopens byte-faithfully (the painted cell survives), bumps
// lastOpened on open, and deletes cleanly (drops out of the list).
//
//   flutter test integration_test/m5_knit_save_reopen_test.dart -d emulator-5554

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ply/src/data/knit_repository.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/knit_stitches.dart';
import 'package:ply/src/rust/frb_generated.dart';
import 'package:ply/src/state/knit_editor_state.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('a painted knit chart saves, lists, reopens faithfully, and deletes', (tester) async {
    final repo = KnitRepository();

    // Build a 4x3 chart off the engine blank (carries the builtin legend), then paint a purl at
    // (row 1, col 2) so we have a non-default cell to track through the round-trip.
    final blank = await repo.blank();
    final pattern = KnitEditorState(pattern: blank)
        .resizeChart(4, 3)
        .paintCell(1, 2, KnitStitch.purl, null)
        .pattern;

    final savedAt = DateTime.now();
    final meta = DraftMeta(
      name: 'knit-roundtrip',
      craft: 'Knitting',
      savedAt: savedAt,
      lastOpened: savedAt,
    );

    final id = await repo.saveKnit(pattern: pattern, meta: meta);
    addTearDown(() => repo.deleteKnit(id));

    // listKnits sees the new pattern with its name.
    final listed = await repo.listKnits();
    expect(listed.map((e) => e.id), contains(id));
    expect(listed.firstWhere((e) => e.id == id).meta.name, 'knit-roundtrip');

    // readPattern reopens the chart faithfully: same shape AND the painted cell survives.
    final reopened = await repo.readPattern(id);
    expect((reopened.chart.width, reopened.chart.rows.length), (4, 3));
    expect(reopened.chart.rows[1].cells[2].stitch, KnitStitch.purl,
        reason: 'the painted purl persisted through save -> parse');
    expect(reopened.chart.rows[0].cells[0].stitch, KnitStitch.knit,
        reason: 'an untouched cell stays knit');

    // openKnit bumps lastOpened (never moves it backwards).
    final entry = await repo.openKnit(id);
    expect(entry.meta.lastOpened.isBefore(savedAt), isFalse,
        reason: 'opening bumps lastOpened forward, never back');

    // The reopened pattern still renders (a real, non-empty image).
    final img = await repo.render(reopened, cellPx: 8);
    addTearDown(img.dispose);
    expect(img.width, greaterThan(0));
    expect(img.height, greaterThan(0));

    // delete drops the whole triplet from the listing.
    await repo.deleteKnit(id);
    final afterDelete = await repo.listKnits();
    expect(afterDelete.map((e) => e.id), isNot(contains(id)));
  });
}
