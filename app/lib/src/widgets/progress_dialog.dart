import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/spacing.dart';

/// Run [work] behind a modal progress dialog labelled [label] that cannot be dismissed, and close it
/// when the work ends, also when it throws (the error is passed on).
Future<T> showProgressWhile<T>(
    BuildContext context, String label, Future<T> Function() work) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: PlySpacing.md),
            Expanded(child: Text(label)),
          ],
        ),
      ),
    ),
  );
  try {
    return await work();
  } finally {
    navigator.pop();
  }
}

/// [showProgressWhile] with a Cancel button: completes with null when the user cancels. A call into
/// the engine that has already started cannot be stopped, only abandoned: its result (or its error)
/// is then ignored, and nothing is done with it.
Future<T?> showCancellableProgressWhile<T>(
    BuildContext context, String label, Future<T> Function() work) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final cancelled = Completer<void>();
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: PlySpacing.md),
            Expanded(child: Text(label)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              if (!cancelled.isCompleted) cancelled.complete();
            },
            child: const Text('Cancel'),
          ),
        ],
      ),
    ),
  );
  final running = work();
  try {
    final first = await Future.any<_Outcome<T>>([
      running.then((value) => _Outcome<T>(value)),
      cancelled.future.then((_) => _Outcome<T>.cancelled()),
    ]);
    if (first.cancelled) {
      running.ignore();
      return null;
    }
    return first.value;
  } finally {
    navigator.pop();
  }
}

class _Outcome<T> {
  _Outcome(this.value) : cancelled = false;
  _Outcome.cancelled()
      : value = null,
        cancelled = true;
  final T? value;
  final bool cancelled;
}
