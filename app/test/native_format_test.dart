import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/knit_repository.dart';
import 'package:ply/src/models/native_format.dart';
import 'package:ply/src/rust/knit_dto.dart';

// The shared version rule for Ply's own formats. The `.plyknit` probe here must classify the shared
// fixtures exactly as the engine does (`ply_knit::native`, tested against the same files in Rust), and
// the engine's typed failure must become the one app-side exception every screen understands.

/// The `.plyknit` migration fixtures in [folder] (repo-root `fixtures/migrations/plyknit/`, shared
/// with the Rust tests), or in every folder when null.
List<File> knitMigrationFixtures([String? folder]) {
  final root = Directory('../fixtures/migrations/plyknit${folder == null ? '' : '/$folder'}');
  final files = root
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.plyknit'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return files;
}

/// Every released (v0.1.x, legacy version 1) `.plyknit` fixture.
List<File> legacyKnitFixtures() =>
    knitMigrationFixtures().where((f) => f.path.contains('/v0.1.')).toList();

String envelope(Object? version, {Object? format = kPlyknitFormat}) =>
    jsonEncode({'format': format, 'schema_version': version, 'document': <String, Object?>{}});

void main() {
  group('plyknitSchemaVersion', () {
    test('every released fixture is legacy version 1', () {
      final files = legacyKnitFixtures();
      expect(files, hasLength(6), reason: 'v0.1.5, v0.1.6, v0.1.7 x sampler, custom-ws-variant');
      for (final f in files) {
        expect(plyknitSchemaVersion(f.readAsStringSync()), 1, reason: f.path);
      }
    });

    test('every schema-v2 fixture is a version 2 envelope (an upgrade on save)', () {
      final files = knitMigrationFixtures('schema-v2');
      expect(files, hasLength(3));
      for (final f in files) {
        expect(plyknitSchemaVersion(f.readAsStringSync()), 2, reason: f.path);
      }
      expect(knitMigrationFixtures(), hasLength(9), reason: 'no migration fixture is unclassified');
    });

    test('every knitting acceptance fixture is a current (version 3) envelope', () {
      // fixtures/knitting/: written by the engine's own writer, so the Dart probe must agree.
      final files = Directory('../fixtures/knitting')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.plyknit'))
          .toList();
      expect(files, isNotEmpty);
      for (final f in files) {
        expect(plyknitSchemaVersion(f.readAsStringSync()), 3, reason: f.path);
      }
    });

    test('an envelope reports its own version', () {
      expect(plyknitSchemaVersion(envelope(2)), 2);
      expect(plyknitSchemaVersion(envelope(3)), 3);
      expect(plyknitSchemaVersion(envelope(4)), 4,
          reason: 'newer versions are reported, not hidden');
    });

    test('anything that is not a .plyknit is null', () {
      expect(plyknitSchemaVersion('{not json'), isNull);
      expect(plyknitSchemaVersion('[1, 2]'), isNull);
      expect(plyknitSchemaVersion(envelope(2, format: 'ply.nalbind')), isNull);
      expect(plyknitSchemaVersion(envelope(0)), isNull);
      expect(plyknitSchemaVersion(envelope('2')), isNull);
      expect(plyknitSchemaVersion(envelope(2.5)), isNull);
    });
  });

  group('NativeFormatException', () {
    test('explains a newer file in plain words, per document kind', () {
      const knit = NativeFormatException(NativeFormatProblem.newerVersion,
          document: NativeDocument.knitPattern, detail: 'schema 3');
      expect(knit.message,
          'This pattern was saved by a newer version of Ply. Update the app to open it.');
      expect('$knit', knit.message, reason: 'the detail is for logs, not the UI');
      const nal = NativeFormatException(NativeFormatProblem.newerVersion,
          document: NativeDocument.nalbindProject);
      expect(nal.message,
          'This project was saved by a newer version of Ply. Update the app to open it.');
    });

    test('a refused save says the original was kept', () {
      const e = NativeFormatException(NativeFormatProblem.newerVersion,
          document: NativeDocument.knitPattern, whileSaving: true);
      expect(e.message,
          'The saved copy of this pattern is from a newer version of Ply, so it was not replaced.');
      const u = NativeFormatException(NativeFormatProblem.unreadable,
          document: NativeDocument.nalbindProject, whileSaving: true);
      expect(
          u.message, 'The saved copy of this project could not be read, so it was not replaced.');
    });

    test('wrong format and unreadable messages', () {
      expect(
        const NativeFormatException(NativeFormatProblem.wrongFormat,
                document: NativeDocument.knitPattern)
            .message,
        'This file is not a Ply knitting pattern.',
      );
      expect(
        const NativeFormatException(NativeFormatProblem.unreadable,
                document: NativeDocument.nalbindProject)
            .message,
        'This project file could not be read.',
      );
    });
  });

  test('the engine failure maps onto the app exception, kind for kind', () {
    for (final (kind, problem) in [
      (KnitFormatFailureKind.newerVersion, NativeFormatProblem.newerVersion),
      (KnitFormatFailureKind.wrongFormat, NativeFormatProblem.wrongFormat),
      (KnitFormatFailureKind.unreadable, NativeFormatProblem.unreadable),
    ]) {
      final e = nativeFormatExceptionFromKnit(KnitFormatFailure(kind: kind, message: 'detail'));
      expect(e.problem, problem);
      expect(e.document, NativeDocument.knitPattern);
      expect(e.whileSaving, isFalse);
      expect(e.detail, 'detail');
    }
  });
}
