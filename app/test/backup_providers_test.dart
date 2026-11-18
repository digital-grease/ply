import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/state/backup_providers.dart';
import 'package:ply/src/state/editor_providers.dart';

// The production backup service checks every craft with the engine: building it calls nothing
// native, so a host test can see that no version probe, value guard or parser is missing (a
// missing one would refuse every pattern, project or band as unreadable).

void main() {
  test('production wires every version probe, value guard and parser', () {
    // The app overrides the draft repository at its root, as main.dart does.
    final container =
        ProviderContainer(overrides: [repositoryProvider.overrideWithValue(DraftRepository())]);
    addTearDown(container.dispose);
    final checks = container.read(libraryBackupProvider).checks;
    expect(checks.wif, isNotNull, reason: 'wif');
    expect(checks.knit, isNotNull, reason: 'knit');
    expect(checks.knitVersion, isNotNull, reason: 'knitVersion');
    expect(checks.knitGuard, isNotNull, reason: 'knitGuard');
    expect(checks.nalbindVersion, isNotNull, reason: 'nalbindVersion');
    expect(checks.nalbindGuard, isNotNull, reason: 'nalbindGuard');
    expect(checks.tablet, isNotNull, reason: 'tablet');
    expect(checks.tabletVersion, isNotNull, reason: 'tabletVersion');
  });
}
