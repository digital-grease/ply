// The "Print or share PDF" flow every craft uses: choose Print or Share, gather the pattern and its
// readiness report, follow the report's verdict (ADR 0021), build the PDF, and hand it to the
// phone's own print dialog (`Printing.layoutPdf`) or share sheet (`Printing.sharePdf`). One entry
// point with both choices keeps each screen's menu short; the two system dialogs serve different
// needs (paper, or a file to send or save).
//
// READY TO MAKE OR SHARE (ADR 0021). A pattern that is ready prints straight away. Warnings and
// things Ply could not check are listed once and acknowledged in one step ("Acknowledge and
// print"). A pattern with errors is never printed as ready: the dialog's default is "Go back", and
// only the separate "Print a draft copy" choice makes a PDF, which then says on EVERY page that it
// is a draft copy, not ready to make or share, with the number of errors (the problems box on the
// first page stays), and whose file name ends in "(draft copy)". Nothing here is remembered between
// exports: each one asks about the pattern as it is now.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:printing/printing.dart';

import '../diagnostics/log_buffer.dart';
import '../models/readiness.dart';
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

/// Whether the flow compresses the PDF it hands to the print and share dialogs. Always true in the
/// app; tests read the exported bytes back uncompressed.
final pdfCompressProvider = Provider<bool>((_) => true);

/// One prepared export: the pattern's readiness report and how to build its document.
class PdfExportJob {
  const PdfExportJob({
    required this.fileStem,
    required this.readiness,
    required this.document,
    this.listNotChecked = false,
  });

  /// The file name before ".pdf" (the pattern or project name).
  final String fileStem;

  /// The engine's readiness report for the pattern as it is now (ADR 0021): its verdict decides
  /// whether the PDF is made straight away, after an acknowledgement, or only as a draft copy.
  final ReadinessReport readiness;

  /// The document, with or without the "has problems" box (a draft copy carries it).
  final PrintDocument Function({required bool withProblemsBox}) document;

  /// Whether the flow ends the PDF with a "Not checked by Ply" table of the readiness report's
  /// unsupported items (ADR 0021). Weaving, knitting and nalbinding set it; a craft whose own
  /// findings table already lists them (tablet weaving) leaves it off.
  final bool listNotChecked;
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
  static const goBack = 'Go back';
  static const printDraftCopy = 'Print a draft copy';
  static const shareDraftCopy = 'Share a draft copy';
  static const acknowledgePrint = 'Acknowledge and print';
  static const acknowledgeShare = 'Acknowledge and share';
  static const warnings = 'Warnings';
  static const notChecked = 'Ply could not check';
  static const notCheckedSection = 'Not checked by Ply';
  static String notCheckedIntro(String noun) => 'Ply could not check these parts of this $noun, '
      'so they are printed as they are. Check them yourself before you rely on them.';

  /// What a draft copy's file name ends with (before ".pdf").
  static const draftCopySuffix = ' (draft copy)';
  static String problemsTitle(String noun) => 'This $noun has problems';
  static String notReadyTitle(String noun) => 'This $noun is not ready to make or share';
  static String checkTitle(String noun, PdfAction action) =>
      'Check this $noun before you ${action == PdfAction.print ? 'print' : 'share'} it';
  static String failed(Object e) => 'Could not make the PDF: $e';
}

/// [name] as a PDF file name every platform accepts: path separators, reserved and control
/// characters become '-', runs of white space one space, no leading or trailing dots or spaces, at
/// most 60 characters; "pattern" when nothing is left. A [draftCopy] ends in "(draft copy)", which
/// is never cut off.
String pdfFileName(String name, {bool draftCopy = false}) {
  final suffix = draftCopy ? PdfExportText.draftCopySuffix : '';
  final room = 60 - suffix.length;
  var s = name
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F\x7F]'), '-')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'^[\s.]+|[\s.]+$'), '');
  if (s.runes.length > room) {
    s = String.fromCharCodes(s.runes.take(room)).replaceAll(RegExp(r'[\s.]+$'), '');
  }
  return '${s.isEmpty ? 'pattern' : s}$suffix.pdf';
}

/// The full flow: ask Print or Share, [prepare] the job (behind a progress dialog), follow its
/// readiness verdict (ready: straight on; warnings or things Ply could not check: one
/// acknowledgement; errors: only an explicitly chosen draft copy, marked on every page), build,
/// output. [noun] names the thing in the dialogs ("pattern", "project", "draft"). [options] is
/// shown in the Print / Share sheet above the two choices (a weaving draft's book layout); it holds
/// its own state, which [prepare] reads after the sheet closes. A failure (the readiness check
/// included) is reported and nothing is exported.
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
  final compress = ref.read(pdfCompressProvider);
  final messenger = ScaffoldMessenger.of(context);

  final action = await choosePdfAction(context, options: options);
  if (action == null || !context.mounted) return;
  try {
    // Gathering and checking a large pattern can take a while: it can be cancelled (an engine call
    // already running is abandoned, never used).
    final job = await showCancellableProgressWhile(context, PdfExportText.preparing, prepare);
    if (job == null || !context.mounted) return;
    final readiness = job.readiness;
    var draftCopy = false;
    switch (readiness.verdict) {
      case ReadinessVerdict.ready:
        break;
      case ReadinessVerdict.needsAcknowledgement:
        final go = await confirmReadyWithWarnings(context,
            noun: noun, readiness: readiness, action: action);
        if (!go || !context.mounted) return;
      case ReadinessVerdict.notReady:
        final copy =
            await chooseDraftCopy(context, noun: noun, readiness: readiness, action: action);
        if (!copy || !context.mounted) return;
        draftCopy = true;
    }
    var doc = job.document(withProblemsBox: draftCopy);
    if (job.listNotChecked) doc = withNotChecked(doc, readiness, noun: noun);
    if (draftCopy) doc = doc.asDraftCopy(readiness.errorCount);
    final loaded = await fonts;
    final file = pdfFileName(job.fileStem, draftCopy: draftCopy);
    if (!context.mounted) return;
    switch (action) {
      case PdfAction.print:
        await output.print(
          name: file,
          format: setup.format,
          build: (format) => buildPrintPdf(doc,
              page: PrintPageSetup.forFormat(format), fonts: loaded, compress: compress),
        );
      case PdfAction.share:
        final bytes = await showProgressWhile(
          context,
          PdfExportText.making,
          () => buildPrintPdf(doc, page: setup, fonts: loaded, compress: compress),
        );
        await output.share(filename: file, bytes: bytes);
    }
  } catch (e) {
    PlyLog.instance.error('PDF export failed: $e');
    messenger.showSnackBar(SnackBar(content: Text(PdfExportText.failed(e))));
  }
}

/// [doc] ending with a "Not checked by Ply" table of [readiness]'s unsupported items (ADR 0021), or
/// [doc] itself when there are none.
PrintDocument withNotChecked(PrintDocument doc, ReadinessReport readiness, {required String noun}) {
  final items = readiness.unsupported;
  if (items.isEmpty) return doc;
  return doc.withSection(PrintSection(PdfExportText.notCheckedSection, [
    PrintParagraph(PdfExportText.notCheckedIntro(noun), style: PrintTextStyle.muted),
    PrintIssues([
      for (final i in items)
        PrintIssue(
          severity: PrintIssueSeverity.notChecked,
          where: i.place ?? 'Whole $noun',
          message: i.message,
        ),
    ], emptyText: ''),
  ]));
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

const int _shownItems = 6;

/// Bullets for [items] (each with its place): every one when [all], else up to [_shownItems], then
/// "and N more." (the draft copy's first page lists them all).
List<Widget> _itemLines(List<ReadinessItem> items, {bool all = false}) {
  final shown = all ? items : items.take(_shownItems).toList();
  final more = [for (final i in items.skip(shown.length)) i.weight].fold(0, (a, b) => a + b);
  return [
    for (final i in shown)
      Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text('• ${i.text}'),
      ),
    if (more > 0) Text('and $more more.'),
  ];
}

String _count(int n, String one, String many) => n == 1 ? '1 $one' : '$n $many';

/// The acknowledgement for a pattern with warnings or things Ply could not check, and no errors:
/// every warning, then what Ply could not check, and one step to go ahead. True to go ahead.
Future<bool> confirmReadyWithWarnings(
  BuildContext context, {
  required String noun,
  required ReadinessReport readiness,
  required PdfAction action,
}) async {
  final warnings = readiness.warnings;
  final unchecked = readiness.unsupported;
  final checked = readiness.checkedWords;
  final theme = Theme.of(context);
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.warning_amber_rounded),
      title: Text(PdfExportText.checkTitle(noun, action)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Every item the acknowledgement covers is shown: nothing is acknowledged unseen. The
            // engine's cap (200 of a kind, the rest counted in one line) keeps the list bounded.
            if (warnings.isNotEmpty) ...[
              Text(PdfExportText.warnings, style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              ..._itemLines(warnings, all: true),
              const SizedBox(height: 8),
            ],
            if (unchecked.isNotEmpty) ...[
              Text(PdfExportText.notChecked, style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              ..._itemLines(unchecked, all: true),
              const SizedBox(height: 8),
            ],
            Text('Ply found no errors${checked == null ? '' : ' in $checked'}. Read these, then '
                'go ahead, or cancel and look at them first.'),
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
          child: Text(action == PdfAction.print
              ? PdfExportText.acknowledgePrint
              : PdfExportText.acknowledgeShare),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// The question for a pattern with errors: it is not ready to make or share. The default is to go
/// back (nothing is exported); a separate text button makes a DRAFT COPY instead, which says so on
/// every page. True for the draft copy.
Future<bool> chooseDraftCopy(
  BuildContext context, {
  required String noun,
  required ReadinessReport readiness,
  required PdfAction action,
}) async {
  final errors = readiness.errors;
  final errorCount = readiness.errorCount;
  final warningCount = readiness.count(ReadinessLevel.warning);
  final uncheckedCount = readiness.count(ReadinessLevel.unsupported);
  final others = [
    if (warningCount > 0) _count(warningCount, 'warning', 'warnings'),
    if (uncheckedCount > 0)
      _count(uncheckedCount, 'thing Ply could not check', 'things Ply could not check'),
  ];
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.error_outline),
      title: Text(PdfExportText.notReadyTitle(noun)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Ply found ${_count(errorCount, 'error', 'errors')} in this $noun:'),
            const SizedBox(height: 8),
            ..._itemLines(errors),
            if (others.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('It also has ${others.join(' and ')}.'),
            ],
            const SizedBox(height: 8),
            Text('Go back and fix ${errorCount == 1 ? 'it' : 'them'}, or make a draft copy: '
                'every page of a draft copy says it is not ready to make or share, with the number '
                'of errors, and its first page lists them.'),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(action == PdfAction.print
              ? PdfExportText.printDraftCopy
              : PdfExportText.shareDraftCopy),
        ),
        FilledButton(
          autofocus: true,
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text(PdfExportText.goBack),
        ),
      ],
    ),
  );
  return result ?? false;
}
