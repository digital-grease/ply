// Ply — weaving first-light: import a WIF draft and render its drawdown.
//
// The Rust engine (ply-weave, via the ply-bridge FFI crate) does all the work: parse_wif
// turns WIF text into a Draft; render_preview returns a flat RGBA8 buffer. This file just
// wires the bridge, picks a file, and blits the engine's pixels.
//
// ORIENTATION CONTRACT: PreviewImage.rgba is RGBA8, row-major, TOP-TO-BOTTOM. render_rgba
// (ply-weave/src/drawdown.rs) already applies the vertical flip so pick 0 is the BOTTOM
// row. So decode width x height as-is and do NOT flip the canvas; alpha is always 255.

import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

import 'src/rust/api.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init(); // load the native engine before any bridge call
  // Temporary round-trip probe: proves Dart<->Rust works on-device (see Phase 2.7).
  final epi = await suggestSett(wpi: 12, structure: 'plain');
  debugPrint('[ply] bridge round-trip OK: suggestSett(12, "plain") = $epi');
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
  /// Render resolution: pixels per intersection in the engine buffer. On-screen size is
  /// decoupled via BoxFit, so this only sets crispness, not layout.
  static const int _cellPx = 12;

  /// The decoded drawdown, once a WIF has been imported and rendered.
  ui.Image? _preview;

  @override
  void dispose() {
    _preview?.dispose();
    super.dispose();
  }

  Future<void> _importWif() async {
    try {
      // `.wif` has no registered MIME type, so Android's file_picker throws on a custom
      // extension filter ("Unsupported filter"). Pick any file and let the engine's parser
      // decide — a non-WIF file just yields a friendly parse error.
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true, // populate .bytes on mobile (default is false off-web)
        allowMultiple: false,
      );
      if (result == null) return; // user cancelled

      final bytes = result.files.single.bytes;
      if (bytes == null) {
        _snack('Could not read the selected file.');
        return;
      }

      final text = utf8.decode(bytes); // WIF is INI-style text
      final draft = await parseWif(text: text); // throws on a malformed WIF
      final image = await renderPreview(draft: draft, cellPx: _cellPx);
      final decoded = await decodePreview(image);
      if (!mounted) {
        decoded.dispose();
        return;
      }
      setState(() {
        _preview?.dispose();
        _preview = decoded;
      });
    } on FormatException {
      _snack("That file isn't a weaving pattern.");
    } catch (e) {
      _snack('Import failed: $e'); // picker or engine error (e.g. "WIF parse error: ...")
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return Scaffold(
      appBar: AppBar(title: const Text('Ply · Weaving')),
      body: Center(
        child: preview == null
            ? const Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Import a weaving pattern to preview it.',
                  textAlign: TextAlign.center,
                ),
              )
            : Padding(
                padding: const EdgeInsets.all(24),
                child: RepaintBoundary(
                  child: AspectRatio(
                    aspectRatio: preview.width / preview.height,
                    // Frame the cloth so its edges read against the background (white weft
                    // would otherwise blend in), and so it's not bled to the screen edges.
                    child: DecoratedBox(
                      position: DecorationPosition.foreground,
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                      ),
                      child: CustomPaint(painter: DrawdownPainter(preview)),
                    ),
                  ),
                ),
              ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _importWif,
        icon: const Icon(Icons.file_open_outlined),
        label: const Text('Import pattern'),
      ),
    );
  }
}

/// Decode the engine's flat RGBA8 buffer into a `ui.Image`. `decodeImageFromPixels` is
/// callback-based, hence the Completer. No rowBytes/flip args: the buffer is tightly
/// packed (stride = width*4) and already top-to-bottom.
Future<ui.Image> decodePreview(PreviewImage p) {
  final completer = Completer<ui.Image>();
  // frb maps the Rust `Vec<u8>` to a Dart Uint8List, exactly what decodeImageFromPixels wants.
  ui.decodeImageFromPixels(p.rgba, p.width, p.height, ui.PixelFormat.rgba8888, completer.complete);
  return completer.future;
}

/// Blits the drawdown image, scaled to fit with nearest-neighbor sampling so weave cells
/// stay crisp squares. No vertical flip — the engine already put pick 0 at the bottom.
class DrawdownPainter extends CustomPainter {
  DrawdownPainter(this.image);

  final ui.Image image;

  @override
  void paint(Canvas canvas, Size size) {
    final imageSize = Size(image.width.toDouble(), image.height.toDouble());
    final src = Offset.zero & imageSize;
    final fitted = applyBoxFit(BoxFit.contain, imageSize, size);
    final dst = Alignment.center.inscribe(fitted.destination, Offset.zero & size);
    canvas.drawImageRect(
      image,
      src,
      dst,
      Paint()
        ..filterQuality = FilterQuality.none
        ..isAntiAlias = false,
    );
  }

  @override
  bool shouldRepaint(covariant DrawdownPainter oldDelegate) => oldDelegate.image != image;
}
