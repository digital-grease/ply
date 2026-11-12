import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/loom_type.dart';

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

  group('DraftMeta forward compatibility (sidecars are rewritten on open)', () {
    test('every released sidecar re-serializes byte for byte', () {
      for (final name in ['knit', 'nalbind', 'weaving']) {
        final text = File('../fixtures/migrations/sidecar/v0.1.7/$name.json').readAsStringSync();
        final meta = DraftMeta.fromJson(jsonDecode(text) as Map<String, dynamic>);
        expect(meta.extra, isEmpty, reason: 'this build knows every key a release wrote');
        expect(jsonEncode(meta.toJson()), text, reason: name);
      }
    });

    final newer = <String, dynamic>{
      'name': 'Runner',
      'craft': 'Weaving',
      'author': 'Ada',
      'notes': 'n',
      'loomType': 'RigidHeddle', // a loom type this build does not know
      'overshotTreadling': true,
      'savedAt': '2026-06-01T00:00:00.000Z',
      'lastOpened': '2026-06-02T00:00:00.000Z',
      'schemaVersion': 1,
      'tags': ['gift', 'linen'], // keys this build does not know
      'project': {'yarn': '16/2 linen', 'reed': 12},
    };

    test('unknown keys and unreadable values survive a lastOpened rewrite', () {
      final m = DraftMeta.fromJson(newer);
      expect(m.loomType, LoomType.jack, reason: 'falls back for display');
      expect(m.extra.keys, unorderedEquals(['loomType', 'tags', 'project']));
      final rewritten = m.copyWith(lastOpened: DateTime.utc(2026, 7, 1)).toJson();
      expect(rewritten['loomType'], 'RigidHeddle', reason: 'written back exactly as read');
      expect(rewritten['tags'], ['gift', 'linen']);
      expect(rewritten['project'], {'yarn': '16/2 linen', 'reed': 12});
      expect(rewritten['lastOpened'], '2026-07-01T00:00:00.000Z');
      expect(rewritten['author'], 'Ada');
      // And through a full encode / decode / encode cycle.
      final again = DraftMeta.fromJson(jsonDecode(jsonEncode(rewritten)) as Map<String, dynamic>);
      expect(jsonEncode(again.toJson()), jsonEncode(rewritten));
    });

    test('setting a field replaces the value preserved for it', () {
      final m = DraftMeta.fromJson(newer).copyWith(loomType: LoomType.countermarch);
      expect(m.toJson()['loomType'], 'Countermarch');
      expect(m.extra.containsKey('loomType'), isFalse);
      expect(m.extra.containsKey('tags'), isTrue, reason: 'other preserved keys stay');
    });

    test('a known key with a value of another type is kept, not crashed on', () {
      final m = DraftMeta.fromJson({
        'name': {'en': 'Runner', 'sv': 'Löpare'},
        'author': 42,
        'overshotTreadling': 'yes',
        'savedAt': '2026-06-01T00:00:00.000Z',
      });
      expect(m.name, 'Untitled');
      expect(m.author, isNull);
      final j = m.toJson();
      expect(j['name'], {'en': 'Runner', 'sv': 'Löpare'});
      expect(j['author'], 42);
      expect(j['overshotTreadling'], 'yes');
    });

    test('equality includes the preserved entries', () {
      final a = DraftMeta.fromJson(newer);
      final b = DraftMeta.fromJson({...newer, 'tags': ['other']});
      expect(a, DraftMeta.fromJson(Map.of(newer)));
      expect(a == b, isFalse);
      expect(a.hashCode, DraftMeta.fromJson(Map.of(newer)).hashCode);
    });

    test('the weaving library keeps them when it opens or renames a draft', () async {
      final dir = await Directory.systemTemp.createTemp('ply_weave_sidecar');
      addTearDown(() => dir.delete(recursive: true));
      final repo = DraftRepository(draftsDirOverride: dir);
      File('${dir.path}/d1.wif').writeAsStringSync('[WIF]\nVersion=1.1\n');
      File('${dir.path}/d1.json').writeAsStringSync(jsonEncode(newer));

      final opened = await repo.open('d1');
      expect(opened.meta.lastOpened.isAfter(DateTime.utc(2026, 6, 2)), isTrue);
      await repo.rename('d1', 'Renamed runner');

      final j = jsonDecode(File('${dir.path}/d1.json').readAsStringSync()) as Map<String, dynamic>;
      expect(j['name'], 'Renamed runner');
      expect(j['loomType'], 'RigidHeddle');
      expect(j['tags'], ['gift', 'linen']);
      expect(j['project'], {'yarn': '16/2 linen', 'reed': 12});
      expect(j['author'], 'Ada');
      expect(File('${dir.path}/d1.wif').readAsStringSync(), '[WIF]\nVersion=1.1\n');
    });
  });
}
