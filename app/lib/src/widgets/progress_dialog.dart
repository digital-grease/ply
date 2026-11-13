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
