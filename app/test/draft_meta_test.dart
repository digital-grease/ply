import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/draft_meta.dart';

void main() {
  group('DraftMeta JSON round-trip', () {
    test('survives jsonEncode/jsonDecode unchanged (UTC dates)', () {
      final original = DraftMeta(
        name: 'Plain weave sampler',
        craft: 'Weaving',
        author: 'Ada',
        notes: 'A 2x2 test cloth.',
        savedAt: DateTime.utc(2026, 6, 10, 12, 30, 45, 123),
        lastOpened: DateTime.utc(2026, 6, 10, 18, 5),
        schemaVersion: 1,
      );

      final restored =
          DraftMeta.fromJson(jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>);

      expect(restored, equals(original));
    });

    test('overshotTreadling survives the round-trip', () {
      final original = DraftMeta(
        name: 'Overshot star',
        overshotTreadling: true,
        savedAt: DateTime.utc(2026, 6, 26, 12, 0),
        lastOpened: DateTime.utc(2026, 6, 26, 12, 0),
      );
      final restored =
          DraftMeta.fromJson(jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>);
      expect(restored.overshotTreadling, isTrue);
      expect(restored, equals(original));
    });

    test('an older sidecar without overshotTreadling defaults to false', () {
      final m = DraftMeta.fromJson({
        'name': 'Legacy',
        'savedAt': '2026-06-01T00:00:00.000Z',
      });
      expect(m.overshotTreadling, isFalse);
    });

    test('normalizes local input to UTC and still round-trips', () {
      final original = DraftMeta(
        name: 'Twill 2/2',
        author: null,
        notes: '',
        // Local inputs — the constructor normalizes them to UTC so the sidecar is
        // timezone-stable (serializes with a 'Z', not an offset-less wall-clock).
        savedAt: DateTime(2026, 6, 9, 9, 15, 0, 500),
        lastOpened: DateTime(2026, 6, 10, 10, 0),
      );
      expect(original.savedAt.isUtc, isTrue, reason: 'normalized at construction');

      final restored =
          DraftMeta.fromJson(jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>);

      expect(restored, equals(original));
      expect(restored.savedAt.isUtc, isTrue);
    });
  });

  group('DraftMeta defaults & tolerance', () {
    test('craft defaults to the serde representation "Weaving"', () {
      final m = DraftMeta(
        name: 'x',
        savedAt: DateTime.utc(2026, 1, 1),
        lastOpened: DateTime.utc(2026, 1, 1),
      );
      expect(m.craft, 'Weaving');
      expect(m.notes, '');
      expect(m.schemaVersion, 1);
    });

    test('omits author from JSON when null', () {
      final json = DraftMeta(
        name: 'x',
        author: null,
        savedAt: DateTime.utc(2026, 1, 1),
        lastOpened: DateTime.utc(2026, 1, 1),
      ).toJson();
      expect(json.containsKey('author'), isFalse);
    });

    test('tolerates a minimal/older sidecar (missing optionals)', () {
      // Only the bare-minimum keys a future or partial writer might leave.
      final m = DraftMeta.fromJson({
        'name': 'Salvaged',
        'savedAt': '2026-06-01T08:00:00.000Z',
        // craft, author, notes, lastOpened, schemaVersion all absent
      });
      expect(m.name, 'Salvaged');
      expect(m.craft, 'Weaving');
      expect(m.author, isNull);
      expect(m.notes, '');
      expect(m.schemaVersion, 1);
      // lastOpened falls back to savedAt when absent.
      expect(m.lastOpened, equals(m.savedAt));
    });

    test('does not throw on a malformed date', () {
      final m = DraftMeta.fromJson({
        'name': 'Corrupt',
        'savedAt': 'not-a-date',
        'lastOpened': 42,
      });
      // Falls back to the epoch rather than crashing the Library scan.
      expect(m.savedAt.millisecondsSinceEpoch, 0);
      expect(m.lastOpened, equals(m.savedAt));
    });
  });
}
