import 'package:flutter/material.dart';

/// What the user chose when leaving an editor with unsaved edits (see [showLeaveWithoutSavingDialog]).
enum LeaveAction { keepEditing, discard, save }

/// Ask what to do about unsaved edits when leaving an editor. Returns null if the dialog is
/// dismissed (callers treat that as [LeaveAction.keepEditing]). [noun] names the thing being edited
/// in the body text ("pattern" for weaving and knitting, "project" for nalbinding).
///
/// Shared by every craft's editor so the prompt reads and behaves the same everywhere.
Future<LeaveAction?> showLeaveWithoutSavingDialog(BuildContext context, {String noun = 'pattern'}) {
  return showDialog<LeaveAction>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Leave without saving?'),
      content: Text("Your edits to this $noun haven't been saved. Discard will lose them."),
      // Order matters: the destructive Discard is LEFTMOST, separated from the rightmost primary
      // Save by the safe Keep editing, so a mis-tap toward the primary never lands on data loss.
      actions: [
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(ctx).colorScheme.error,
          ),
          onPressed: () => Navigator.pop(ctx, LeaveAction.discard),
          child: const Text('Discard'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, LeaveAction.keepEditing),
          child: const Text('Keep editing'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, LeaveAction.save),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

/// The dirty-on-exit guard for an editor that SAVES IN PLACE (the knit editor, the nalbind project
/// screen): its Save keeps the user on screen, so leaving is only ever the back button / system
/// back. The weaving editor saves-and-exits and keeps its own guard; it shares only the dialog.
///
/// Wire it up by mixing it into the screen's State and wrapping the Scaffold in
///
/// ```dart
/// PopScope<Object?>(canPop: !hasUnsavedChanges, onPopInvokedWithResult: onLeaveRequested, ...)
/// ```
///
/// then routing the screen's own Save button through [guardedSave]. Behavior:
/// - clean: canPop is true, so back pops straight through with no prompt;
/// - dirty: back is blocked and [onLeaveRequested] asks Discard / Keep editing / Save;
/// - Discard pops without saving; Keep editing (or dismissing the dialog) stays;
/// - Save runs the screen's normal [performSave] (including any naming step) and leaves only if it
///   succeeded AND nothing is still unsaved afterwards (an edit that landed during the save's
///   async gap is never dropped by the exit).
///
/// Races (mirroring the weaving editor's guard):
/// - a second back while the prompt or its nested save is open is dropped ([_leaving]);
/// - every exit goes through [popEditorOnce], whose [_exiting] latch makes the first pop win, so no
///   path can pop twice past the parent route;
/// - a back DURING an in-flight Save still opens the prompt; choosing Save there JOINS the save
///   already running (no second write), and choosing Discard pops at once. A save the user already
///   started is not cancelled by Discard: it finishes in the background, and [performSave] must
///   tolerate finishing after the screen is gone (check `mounted`, never touch `ref` after dispose).
mixin UnsavedChangesGuard<T extends StatefulWidget> on State<T> {
  /// True while the leave flow is open (the prompt and, on its Save branch, the nested save).
  bool _leaving = false;

  /// True once something has begun popping the screen; see [popEditorOnce].
  bool _exiting = false;

  /// The save currently running, so a second request joins it instead of writing twice.
  Future<bool>? _saveInFlight;

  /// Whether leaving right now would lose edits. Read synchronously by the PopScope (`canPop`) and
  /// re-checked by the leave flow, so it must be cheap and must report false while the screen is
  /// still loading (nothing has been edited yet).
  bool get hasUnsavedChanges;

  /// The noun the prompt uses for the edited thing ("pattern", "project").
  String get unsavedChangesNoun => 'pattern';

  /// The screen's normal save flow, start to finish (including any naming step for a never-saved
  /// item). Resolves true ONLY when the edits were persisted; a cancelled, refused, or failed save
  /// resolves false. It must not throw, and it must not pop the screen itself.
  Future<bool> performSave();

  /// Run [performSave], or join the one already in flight. Use this for the Save button too, so a
  /// Save chosen from the leave prompt while the button's save is running never writes twice.
  Future<bool> guardedSave() async {
    final inFlight = _saveInFlight;
    if (inFlight != null) return inFlight;
    final save = performSave();
    _saveInFlight = save;
    try {
      return await save;
    } finally {
      if (identical(_saveInFlight, save)) _saveInFlight = null;
    }
  }

  /// Pop the screen exactly once. The canPop() check is belt-and-suspenders for a root-route screen.
  /// The pop is UNCONDITIONAL (`pop`, not `maybePop`), so the PopScope does not re-intercept it.
  void popEditorOnce() {
    if (_exiting || !mounted) return;
    final navigator = Navigator.of(context);
    if (!navigator.canPop()) return;
    _exiting = true;
    navigator.pop();
  }

  /// The PopScope handler. Only does work for a BLOCKED pop (didPop false, i.e. the screen was
  /// dirty when the frame was built). The pop's result is unused: whether to leave is decided by
  /// the user's choice, not by a value the framework carried.
  Future<void> onLeaveRequested(bool didPop, Object? result) async {
    if (didPop) return;
    // Re-entrancy: set synchronously BEFORE the first await so a second back returns at once. Not
    // gated on an in-flight save: a back during a save should still offer the choice.
    if (_leaving) return;
    _leaving = true;
    try {
      // canPop is a frame behind the state: a save can finish (clean) before the rebuild. Nothing
      // to lose, so just leave.
      if (!hasUnsavedChanges) {
        popEditorOnce();
        return;
      }
      final action =
          await showLeaveWithoutSavingDialog(context, noun: unsavedChangesNoun) ?? LeaveAction.keepEditing;
      if (!mounted) return;
      switch (action) {
        case LeaveAction.discard:
          popEditorOnce();
        case LeaveAction.save:
          // An in-flight save may have landed while the prompt was open; only save if still dirty.
          final saved = !hasUnsavedChanges || await guardedSave();
          if (saved && mounted && !hasUnsavedChanges) popEditorOnce();
        case LeaveAction.keepEditing:
          break;
      }
    } finally {
      // A pop unmounts; only reset when we stayed.
      if (mounted) _leaving = false;
    }
  }
}
