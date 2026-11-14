import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../print/knit_print.dart';
import '../print/print_export.dart' show PdfExportText;
import '../state/knit_editor_providers.dart';

/// The knit chart rendered as readable, row-by-row written instructions — the textual companion to
/// the visual chart. Watches [knitWrittenProvider], so it tracks live edits if the chart changes
/// underneath. Rows are listed cast-on edge first (the order a knitter works them), after the cast-on
/// line ("Cast on 26 sts.") when the pattern states one, and each line is [SelectableText] so the
/// pattern can be copied out. The app bar's print action makes the whole printable pattern (key,
/// chart, these instructions, problems) as a PDF to print or share.
class KnitWrittenScreen extends ConsumerWidget {
  const KnitWrittenScreen({this.patternName = 'Knitting pattern', super.key});

  /// The open pattern's name, for the PDF's title.
  final String patternName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncLines = ref.watch(knitWrittenProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Written instructions'),
        actions: [
          IconButton(
            tooltip: PdfExportText.action,
            icon: const Icon(Icons.print_outlined),
            onPressed: () => printOrShareKnitPdf(context, ref, name: patternName),
          ),
        ],
      ),
      body: asyncLines.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text('Could not generate instructions:\n$e', textAlign: TextAlign.center),
          ),
        ),
        data: (lines) => lines.isEmpty ? _empty(context) : _list(context, lines),
      ),
    );
  }

  Widget _empty(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Add some rows to the chart to see written instructions.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.outline),
          ),
        ),
      );

  Widget _list(BuildContext context, List<String> lines) {
    final style = Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.4);
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      itemCount: lines.length,
      separatorBuilder: (_, __) => const Divider(height: 12),
      itemBuilder: (_, i) => SelectableText(lines[i], style: style),
    );
  }
}
