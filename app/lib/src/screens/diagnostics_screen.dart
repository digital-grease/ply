import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../diagnostics/crash_report_url_builder.dart';
import '../diagnostics/crash_reporter.dart';
import '../diagnostics/log_buffer.dart';
import '../diagnostics/log_scrubber.dart';
import '../diagnostics/platform_log.dart';

/// Diagnostics: review the on-device activity log and any crash report from a previous run, and copy
/// them (scrubbed) to file a bug report. Nothing is uploaded — it is all local; the user decides what
/// to share. Mirrors the crash-report / log-export flow used elsewhere.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  late Future<String?> _crash;
  String? _deviceLog; // null until captured; '' / "(none)" once captured-but-empty
  bool _capturingDeviceLog = false;

  @override
  void initState() {
    super.initState();
    _crash = CrashReporter.instance.read();
  }

  Future<void> _captureDeviceLog() async {
    setState(() => _capturingDeviceLog = true);
    final log = await PlatformLog.capture();
    if (!mounted) return;
    setState(() {
      _deviceLog = (log == null || log.isEmpty) ? '' : LogScrubber.scrub(log);
      _capturingDeviceLog = false;
    });
    if (log == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Device log is not available on this platform.')));
    }
  }

  String get _device {
    try {
      return '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    } catch (_) {
      return 'unknown';
    }
  }

  Future<void> _copy(String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$what copied.')));
    }
  }

  Future<void> _dismissCrash() async {
    await CrashReporter.instance.dismiss();
    if (mounted) setState(() => _crash = CrashReporter.instance.read());
  }

  /// Show the pre-filled GitHub issue link for [report]; the user copies it and opens it in a browser.
  Future<void> _reportOnGitHub(String report) async {
    final issue = CrashIssueUrl.build(device: _device, appVersion: kPlyAppVersion, report: report);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Report on GitHub'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(issue.truncated
                ? 'The report is long. Copy it, open the link below, and paste it into the issue body.'
                : 'Copy the link, open it in your browser, and submit the pre-filled issue.'),
            const SizedBox(height: 12),
            SelectableText(issue.url, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ],
        ),
        actions: [
          if (issue.truncated)
            TextButton(
              onPressed: () => _copy(report, 'Report'),
              child: const Text('Copy report'),
            ),
          TextButton(
            onPressed: () => _copy(issue.url, 'Link'),
            child: const Text('Copy link'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final logs = LogScrubber.scrub(PlyLog.instance.dump());
    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostics')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          FutureBuilder<String?>(
            future: _crash,
            builder: (context, snap) {
              final report = snap.data;
              if (report == null || report.isEmpty) return const SizedBox.shrink();
              return Card(
                color: cs.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Icon(Icons.warning_amber_rounded, color: cs.onErrorContainer),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text('Ply hit an error since you last opened it',
                              style: text.titleSmall?.copyWith(color: cs.onErrorContainer)),
                        ),
                      ]),
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        constraints: const BoxConstraints(maxHeight: 220),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: cs.surface,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: SingleChildScrollView(
                          child: SelectableText(report,
                              style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          FilledButton.tonal(
                            onPressed: () => _copy(report, 'Report'),
                            child: const Text('Copy report'),
                          ),
                          FilledButton.tonal(
                            onPressed: () => _reportOnGitHub(report),
                            child: const Text('Report on GitHub'),
                          ),
                          TextButton(onPressed: _dismissCrash, child: const Text('Dismiss')),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: Text('Activity log', style: text.titleSmall)),
              TextButton.icon(
                onPressed: logs.isEmpty ? null : () => _copy(logs, 'Logs'),
                icon: const Icon(Icons.copy_all_outlined, size: 18),
                label: const Text('Copy'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text('Stays on your device. Nothing is sent automatically; sensitive details are redacted.',
              style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              logs.isEmpty ? 'No log entries yet.' : logs,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(child: Text('Device log', style: text.titleSmall)),
              if ((_deviceLog ?? '').isNotEmpty)
                TextButton.icon(
                  onPressed: () => _copy(_deviceLog!, 'Device log'),
                  icon: const Icon(Icons.copy_all_outlined, size: 18),
                  label: const Text('Copy'),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            "The app's recent platform log (Android). Useful when a crash didn't leave a report above "
            '— the system keeps it briefly after a native crash.',
            style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          if (_deviceLog == null)
            OutlinedButton.icon(
              onPressed: _capturingDeviceLog ? null : _captureDeviceLog,
              icon: const Icon(Icons.download_outlined),
              label: Text(_capturingDeviceLog ? 'Capturing…' : 'Capture device log'),
            )
          else
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 280),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  _deviceLog!.isEmpty ? 'Not available on this platform/device.' : _deviceLog!,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
