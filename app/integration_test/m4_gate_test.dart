// M4 Phase-6.1 milestone gate: the M4-specific claims, end to end on a real device + filesystem.
//
//   1. THEME PERSISTS ACROSS RELAUNCH — AppSettings written by one AppSettingsRepository are read
//      back verbatim by a FRESH instance (the relaunch a user would do), proving the on-device
//      sidecar round-trips theme mode + accent + dynamic-color.
//   2. TABLET / WIDE LAYOUT — the Library renders at a tablet width with both AppBar destinations,
//      and the in-app Glossary (Phase 5) opens and lists terms on the device.
//
// (Thickness variable-cell rendering + WIF round-trip are gated by m4_thickness_render; the full
// editing loop + persistence by m6_e2e. This file adds only the not-yet-device-proven M4 pieces.)
//
//   flutter test integration_test/m4_gate_test.dart -d emulator-5554

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ply/src/data/app_settings_repository.dart';
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/app_settings.dart';
import 'package:ply/src/screens/home_screen.dart';
import 'package:ply/src/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('theme settings survive a relaunch (on-device sidecar round-trip)', (tester) async {
    // A throwaway dir so the gate never clobbers the user's real settings; two repo instances over
    // the same dir model the write-then-relaunch-then-read path.
    final dir = await Directory.systemTemp.createTemp('ply_gate_settings');
    addTearDown(() => dir.delete(recursive: true));

    const custom = AppSettings(
      themeMode: ThemeMode.dark,
      accentSeed: 0xFF2E7D32,
      useDynamicColor: false,
    );
    await (AppSettingsRepository()..dirOverride = dir).save(custom);

    // "Relaunch": a brand-new repository reads the persisted file off disk.
    final reloaded = await (AppSettingsRepository()..dirOverride = dir).load();
    expect(reloaded, custom, reason: 'theme mode + accent + dynamic-color all persist verbatim');
  });

  testWidgets('the Library renders at tablet width and opens the Glossary', (tester) async {
    // Force a tablet-class logical size (1024x768, well past the 600dp wide breakpoint).
    tester.view.physicalSize = const Size(2048, 1536);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final repo = DraftRepository();
    await tester.pumpWidget(
      ProviderScope(
        // The unified home (Weaving | Knitting tabs) owns the shared chrome since the M5 library
        // unification; Glossary + Settings live on its AppBar.
        child: MaterialApp(home: HomeScreen(repository: repo)),
      ),
    );
    await tester.pumpAndSettle();

    // Both AppBar destinations render at tablet width without overflow.
    expect(find.byTooltip('Glossary'), findsOneWidget);
    expect(find.byTooltip('Settings'), findsOneWidget);

    // The in-app glossary opens and lists terms on the device.
    await tester.tap(find.byTooltip('Glossary'));
    await tester.pumpAndSettle();
    expect(find.text('Glossary'), findsOneWidget, reason: 'the Glossary screen is shown');
    expect(find.text('Warp'), findsOneWidget, reason: 'terms are listed on device');
  });
}
