import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/diagnostics/crash_report_url_builder.dart';
import 'package:ply/src/diagnostics/crash_reporter.dart';
import 'package:ply/src/diagnostics/log_buffer.dart';
import 'package:ply/src/diagnostics/log_scrubber.dart';
import 'package:ply/src/diagnostics/platform_log.dart';

/// Install a fake handler for the platform-log channel ([reply] null simulates iOS / unavailable).
void _mockPlatformLog(Future<String?> Function() reply) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(PlatformLog.channel, (call) async => reply());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PlatformLog.channel, null);
  });
  group('LogScrubber', () {
    test('redacts emails, long hex/base64, and the home-dir username', () {
      expect(LogScrubber.scrub('contact me@example.com please'),
          'contact ${LogScrubber.redacted} please');
      expect(LogScrubber.scrub('token deadbeefdeadbeef99 end'),
          'token ${LogScrubber.redacted} end');
      expect(LogScrubber.scrub('/home/janedoe/git/ply/lib/x.dart'),
          '/home/${LogScrubber.redacted}/git/ply/lib/x.dart');
      final b64 = 'A' * 40;
      expect(LogScrubber.scrub('auth $b64 done'), 'auth ${LogScrubber.redacted} done');
    });

    test('leaves benign text and short hex alone', () {
      const benign = 'Generated a 2/2 twill on shaft abc123 at 16:00';
      expect(LogScrubber.scrub(benign), benign);
    });
  });

  group('PlyLog ring buffer', () {
    setUp(() => PlyLog.instance.clear());

    test('records, returns recent, and bounds capacity', () {
      for (var i = 0; i < PlyLog.capacity + 50; i++) {
        PlyLog.instance.info('line $i');
      }
      final all = PlyLog.instance.recent();
      expect(all.length, PlyLog.capacity, reason: 'capacity caps the buffer');
      expect(all.last, contains('line ${PlyLog.capacity + 49}'), reason: 'newest kept');
      expect(all.first, contains('line 50'), reason: 'oldest dropped');
      expect(PlyLog.instance.recent(3), hasLength(3));
    });

    test('clear empties the buffer', () {
      PlyLog.instance.info('x');
      PlyLog.instance.clear();
      expect(PlyLog.instance.dump(), isEmpty);
    });
  });

  group('CrashIssueUrl', () {
    test('embeds a short report and encodes the fields', () {
      final r = CrashIssueUrl.build(device: 'android 14', appVersion: '0.1.0', report: 'boom');
      expect(r.truncated, isFalse);
      expect(r.url, startsWith(CrashIssueUrl.base));
      expect(r.url, contains('device=android+14'));
      expect(r.url, contains('app_version=0.1.0'));
      expect(r.url, contains('report=boom'));
    });

    test('truncates a long report and stays under the URL cap', () {
      final long = 'x' * 50000;
      final r = CrashIssueUrl.build(device: 'd', appVersion: '0.1.0', report: long);
      expect(r.truncated, isTrue);
      expect(r.url.length, lessThanOrEqualTo(CrashIssueUrl.maxUrlLength));
    });
  });

  group('PlatformLog', () {
    test('returns the channel result', () async {
      _mockPlatformLog(() async => 'logcat line A\nlogcat line B');
      expect(await PlatformLog.capture(), contains('logcat line A'));
    });

    test('returns null when the platform has no handler / throws (e.g. iOS)', () async {
      _mockPlatformLog(() async => throw MissingPluginException());
      expect(await PlatformLog.capture(), isNull);
    });
  });

  group('CrashReporter', () {
    late Directory docs;
    setUp(() async {
      docs = await Directory.systemTemp.createTemp('ply_crash');
      CrashReporter.instance.docsOverride = docs;
      PlyLog.instance.clear();
    });
    tearDown(() async {
      CrashReporter.instance.docsOverride = null;
      await docs.delete(recursive: true);
    });

    test('write -> read -> dismiss, with scrubbing applied', () async {
      expect(await CrashReporter.instance.hasReport(), isFalse);
      PlyLog.instance.info('did a thing');
      await CrashReporter.instance.write(
        Exception('failed for user me@example.com'),
        StackTrace.fromString('#0  main (/home/janedoe/ply/main.dart:1)'),
      );
      expect(await CrashReporter.instance.hasReport(), isTrue);

      final report = (await CrashReporter.instance.read())!;
      expect(report, contains('Ply crash report'));
      expect(report, contains('App: Ply $kPlyAppVersion'));
      expect(report, contains('did a thing'), reason: 'recent logs are included');
      expect(report, contains(LogScrubber.redacted), reason: 'the email + username are scrubbed');
      expect(report, isNot(contains('me@example.com')));
      expect(report, isNot(contains('janedoe')));

      await CrashReporter.instance.dismiss();
      expect(await CrashReporter.instance.hasReport(), isFalse);
    });

    test('folds the platform device log into the report when available', () async {
      _mockPlatformLog(() async => 'I/flutter: native warning before the crash');
      await CrashReporter.instance.write(Exception('boom'), StackTrace.fromString('#0  x'));
      final report = (await CrashReporter.instance.read())!;
      expect(report, contains('=== Device log ==='));
      expect(report, contains('native warning before the crash'));
    });
  });
}
