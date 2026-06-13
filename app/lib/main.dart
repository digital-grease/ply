// Ply — local-first pattern tool (weaving first).
//
// This file is just the shell: initialize the native engine, build one
// DraftRepository (the sole owner of the FFI bridge + on-device storage), and
// hand it to the Library home screen. All real work lives in src/.

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/data/draft_repository.dart';
import 'src/screens/library_screen.dart';
import 'src/state/editor_providers.dart';
import 'src/state/theme_providers.dart';
import 'src/theme/ply_colors.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init(); // load the native engine before any bridge call
  final repository = DraftRepository();
  // The Library/Preview screens take the repository by constructor; the editor reads it from
  // Riverpod. One instance, exposed both ways, so there is a single owner of the FFI bridge.
  runApp(
    ProviderScope(
      overrides: [repositoryProvider.overrideWithValue(repository)],
      child: PlyApp(repository: repository),
    ),
  );
}

class PlyApp extends ConsumerWidget {
  const PlyApp({required this.repository, super.key});

  final DraftRepository repository;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    // DynamicColorBuilder supplies the device's Material You palette (Android 12+); we use it ONLY
    // when the user opted in AND the platform provided one, else fall back to a scheme seeded from
    // the chosen accent. The cloth's own palette is draft DATA and is never touched by the theme.
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        final seed = Color(settings.accentSeed);
        final useDynamic = settings.useDynamicColor;
        final lightScheme = (useDynamic && lightDynamic != null)
            ? lightDynamic
            : ColorScheme.fromSeed(seedColor: seed);
        final darkScheme = (useDynamic && darkDynamic != null)
            ? darkDynamic
            : ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark);
        return MaterialApp(
          title: 'Ply',
          theme: _theme(lightScheme, PlyColors.light()),
          darkTheme: _theme(darkScheme, PlyColors.dark()),
          themeMode: settings.themeMode,
          home: LibraryScreen(repository: repository),
        );
      },
    );
  }

  /// One Material 3 theme from a scheme + Ply's extension roles (the semantic `warning` the
  /// ColorScheme lacks).
  static ThemeData _theme(ColorScheme scheme, PlyColors ply) => ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        extensions: [ply],
      );
}
