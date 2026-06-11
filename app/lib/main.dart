// Ply — minimal Flutter skeleton.
//
// This is the *starting point*, deliberately small. It is plain Flutter and does NOT
// reference generated bridge symbols yet, so it compiles before you run codegen. The
// TODO markers show exactly where the Rust engine plugs in once you run:
//
//   flutter_rust_bridge_codegen generate
//
// At that point, generated bindings appear under lib/src/rust/ and you replace the
// stubbed sections below with real calls (parse_wif, render_preview, suggest_sett, ...).
//
// Real UI/visual design is a later milestone (see ROADMAP.md, milestone M4). Keep this
// lean until the engine integration is proven end to end.

import 'package:flutter/material.dart';

void main() {
  // TODO(bridge): await RustLib.init();  // initialize flutter_rust_bridge
  runApp(const PlyApp());
}

class PlyApp extends StatelessWidget {
  const PlyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ply',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF6B4FA0), useMaterial3: true),
      home: const DraftHomePage(),
    );
  }
}

class DraftHomePage extends StatefulWidget {
  const DraftHomePage({super.key});

  @override
  State<DraftHomePage> createState() => _DraftHomePageState();
}

class _DraftHomePageState extends State<DraftHomePage> {
  // Holds the decoded preview image once the engine renders one.
  // ui.Image? _preview;

  Future<void> _importWif() async {
    // TODO(bridge): pick a .wif with file_picker, read its text, then:
    //   final draft = await parseWif(text: text);
    //   final img   = await renderPreview(draft: draft, cellPx: 12);
    //   decode img.rgba (img.width x img.height, RGBA8) into a ui.Image and setState.
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('WIF import lands here once the bridge is generated.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ply · Weaving')),
      body: Center(
        child: CustomPaint(
          size: const Size(280, 280),
          painter: _DrawdownPlaceholderPainter(),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _importWif,
        icon: const Icon(Icons.file_open_outlined),
        label: const Text('Import WIF'),
      ),
    );
  }
}

/// Placeholder painter — draws a checkerboard so the preview surface is visible before
/// the engine is wired. Replace with a painter that blits the engine's RGBA buffer
/// (or paints from a computed Drawdown) once the bridge is generated.
class _DrawdownPlaceholderPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const cells = 8;
    final cell = size.width / cells;
    final dark = Paint()..color = const Color(0xFF2A2433);
    final light = Paint()..color = const Color(0xFFEDE7F3);
    for (var r = 0; r < cells; r++) {
      for (var c = 0; c < cells; c++) {
        final rect = Rect.fromLTWH(c * cell, r * cell, cell, cell);
        canvas.drawRect(rect, (r + c).isEven ? dark : light);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
