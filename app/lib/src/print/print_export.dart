// The "Print or share PDF" flow every craft uses: choose Print or Share, gather the pattern, ask
// before exporting a pattern with errors (roadmap M7-05: blocking problems are never ignored
// silently), build the PDF, and hand it to the phone's own print dialog (`Printing.layoutPdf`) or
// share sheet (`Printing.sharePdf`). One entry point with both choices keeps each screen's menu
// short; the two system dialogs serve different needs (paper, or a file to send or save).

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:printing/printing.dart';

import '../diagnostics/log_buffer.dart';
import '../state/theme_providers.dart';
import '../widgets/progress_dialog.dart';
import 'pdf_builder.dart';
import 'pdf_fonts.dart';
import 'print_document.dart';
import 'print_layout.dart';

/// What the user asked for.
enum PdfAction { print, share }

/// Where a finished PDF goes: the platform print and share dialogs. Tests substitute a recorder.
abstract class PdfOutput {
  /// Open the print dialog. [build] lays the document out for the paper the dialog picks (it is
  /// called again when the user changes the paper). Resolves false when the user cancelled.
  Future<bool> print({
    required String name,
    required PdfPageFormat format,
    required Future<Uint8List> Function(PdfPageFormat format) build,
  });

  /// Open the share sheet with the PDF as [filename].
  Future<bool> share({required String filename, required Uint8List bytes});
}

/// The real output, through the `printing` plugin.
class SystemPdfOutput implements PdfOutput {
  const SystemPdfOutput();

  @override
  Future<bool> print({
    required String name,
    required PdfPageFormat format,
    required Future<Uint8List> Function(PdfPageFormat format) build,
  }) =>
      Printing.layoutPdf(onLayout: build, name: name, format: format);

  @override
  Future<bool> share({required String filename, required Uint8List bytes}) =>
      Printing.sharePdf(bytes: bytes, filename: filename);
}

final pdfOutputProvider = Provider<PdfOutput>((_) => const SystemPdfOutput());

/// One prepared export: the pattern's blocking errors and how to build its document.
class PdfExportJob {
  const PdfExportJob({required this.fileStem, required this.errors, required this.document});

  /// The file name before ".pdf" (the pattern or project name).
  final String fileStem;

  /// Errors that make the export ask first. Warnings are not here: they never block.
  final List<String> errors;

  /// The document, with or without the "has problems" box.
  final PrintDocument Function({required bool withProblemsBox}) document;
}

/// The user-visible labels of the flow.
class PdfExportText {
  const PdfExportText._();
  static const action = 'Print or share PDF';
  static const print = 'Print';
  static const printHint = 'Send it to a printer, or save it as a PDF from the print dialog.';
  static const share = 'Share PDF';
  static const shareHint = 'Send the PDF to another app, or save it to your files.';
  static const preparing = 'Preparing the PDF...';
  static const making = 'Making the PDF...';
  static const cancel = 'Cancel';
  static const printAnyway = 'Print anyway';
  static const shareAnyway = 'Share anyway';
  static String problemsTitle(String noun) => 'This $noun has problems';
  static String failed(Object e) => 'Could not make the PDF: $e';
}

/// [name] as a PDF file name every platform accepts: path separators, reserved and control
/// characters become '-', runs of white space one space, no leading or trailing dots or spaces, at
/// most 60 characters; "pattern" when nothing is left.
String pdfFileName(String name) {
  var s = name
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F\x7F]'), '-')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'^[\s.]+|[\s.]+$'), '');
  if (s.runes.length > 60) {
    s = String.fromCharCodes(s.runes.take(60)).replaceAll(RegExp(r'[\s.]+$'), '');
  }
  return '${s.isEmpty ? 'pattern' : s}.pdf';
}

/// The full flow: ask Print or Share, [prepare] the job (behind a progress dialog), confirm a
/// pattern with errors (cancel exports nothing; "anyway" prints the problems box), build, output.
/// [noun] names the thing in the dialog ("pattern", "project", "draft"). [options] is shown in the
/// Print / Share sheet above the two choices (a weaving draft's book layout); it holds its own state,
/// which [prepare] reads after the sheet closes.
Future<void> printOrSharePdf(
  BuildContext context,
  WidgetRef ref, {
  required String noun,
  required Future<PdfExportJob> Function() prepare,
  Widget? options,
}) async {
  // Everything that needs the widget or a provider is read before the first gap.
  final output = ref.read(pdfOutputProvider);
  final setup = PrintPageSetup.forUnit(ref.read(appSettingsProvider).unit);
  final fonts = ref.read(plyPdfFontsProvider.future);
  final messenger = ScaffoldMessenger.of(context);

  final action = await choosePdfAction(context, options: options);
  if (action == null || !context.mounted) return;
  try {
    final job = await showProgressWhile(context, PdfExportText.preparing, prepare);
    if (!context.mounted) return;
    if (job.errors.isNotEmpty) {
      final go =
          await confirmExportWithProblems(context, noun: noun, errors: job.errors, action: action);
      if (!go || !context.mounted) return;
    }
    final doc = job.document(withProblemsBox: job.errors.isNotEmpty);
    final loaded = await fonts;
    final file = pdfFileName(job.fileStem);
    if (!context.mounted) return;
    switch (action) {
      case PdfAction.print:
        await output.print(
          name: file,
          format: setup.format,
          build: (format) =>
              buildPrintPdf(doc, page: PrintPageSetup.forFormat(format), fonts: loaded),
        );
      case PdfAction.share:
        final bytes = await showProgressWhile(
          context,
          PdfExportText.making,
          () => buildPrintPdf(doc, page: setup, fonts: loaded),
        );
        await output.share(filename: file, bytes: bytes);
    }
  } catch (e) {
    PlyLog.instance.error('PDF export failed: $e');
    messenger.showSnackBar(SnackBar(content: Text(PdfExportText.failed(e))));
  }
}

/// The Print / Share choice, as a bottom sheet, with [options] (if any) under its title. Null when
/// dismissed.
Future<PdfAction?> choosePdfAction(BuildContext context, {Widget? options}) =>
    showModalBottomSheet<PdfAction>(
      context: context,
      isScrollControlled: options != null,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(PdfExportText.action, style: Theme.of(ctx).textTheme.titleMedium),
            ),
            if (options != null) options,
            ListTile(
              leading: const Icon(Icons.print_outlined),
              title: const Text(PdfExportText.print),
              subtitle: const Text(PdfExportText.printHint),
              onTap: () => Navigator.pop(ctx, PdfAction.print),
            ),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text(PdfExportText.share),
              subtitle: const Text(PdfExportText.shareHint),
              onTap: () => Navigator.pop(ctx, PdfAction.share),
            ),
          ],
        ),
      ),
    );

/// The export-readiness question for a pattern with [errors]: export anyway (the PDF then carries a
/// box listing them) or cancel. True to go ahead.
Future<bool> confirmExportWithProblems(
  BuildContext context, {
  required String noun,
  required List<String> errors,
  required PdfAction action,
}) async {
  const shown = 5;
  final verb = action == PdfAction.print ? 'Print' : 'Share';
  final n = errors.length;
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.error_outline),
      title: Text(PdfExportText.problemsTitle(noun)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Ply found $n ${n == 1 ? 'error' : 'errors'} in this $noun:'),
            const SizedBox(height: 8),
            for (final e in errors.take(shown))
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('• $e'),
              ),
            if (n > shown) Text('and ${n - shown} more.'),
            const SizedBox(height: 8),
            Text('$verb it anyway and the PDF lists the problems in a box at the top, or cancel '
                'and fix them first.'),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text(PdfExportText.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(
              action == PdfAction.print ? PdfExportText.printAnyway : PdfExportText.shareAnyway),
        ),
      ],
    ),
  );
  return result ?? false;
}
