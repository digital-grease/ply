import 'dart:collection';

/// An in-memory ring buffer of recent log lines plus a tiny logging facade. App events and (via the
/// crash reporter's error handlers) uncaught errors append here, so a crash report can carry recent
/// context. LOCAL ONLY — the buffer never leaves the device on its own; it is shown in the Diagnostics
/// screen and folded into a crash report the user may choose to share (scrubbed first).
class PlyLog {
  PlyLog._();
  static final PlyLog instance = PlyLog._();

  /// Bounded so the buffer can never grow without limit during a long session.
  static const int capacity = 400;

  final Queue<String> _lines = Queue<String>();

  /// Append a UTC-timestamped line tagged with a one-letter [level] (I/W/E).
  void add(String message, {String level = 'I'}) {
    final ts = DateTime.now().toUtc().toIso8601String();
    _lines.addLast('$ts $level $message');
    while (_lines.length > capacity) {
      _lines.removeFirst();
    }
  }

  void info(String message) => add(message, level: 'I');
  void warn(String message) => add(message, level: 'W');
  void error(String message) => add(message, level: 'E');

  /// The most recent [count] lines, oldest first.
  List<String> recent([int count = capacity]) {
    final list = _lines.toList();
    return list.length <= count ? list : list.sublist(list.length - count);
  }

  /// All buffered lines joined for display / a crash report.
  String dump() => _lines.join('\n');

  void clear() => _lines.clear();
}
