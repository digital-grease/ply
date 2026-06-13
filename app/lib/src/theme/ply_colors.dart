// The semantic color roles Material 3's [ColorScheme] is MISSING. M3 ships error/primary/
// secondary/tertiary and their on-/container- variants, but it has no "warning" role — and Ply
// needs one, because the validation band distinguishes structural ERRORS (which use M3's
// `error`) from WARNINGS (advisory, non-blocking). Until now that warning amber was a lone
// `static const Color(0xFFB26A00)` hardcoded inside the validation panel; this [ThemeExtension]
// is the single place those values live, so the standing M4 theming work can retune the warning
// role (and light/dark it correctly) without touching widget code.
//
// WHY A ThemeExtension AND NOT A BARE const. A const color is brightness-blind: the one amber
// that reads as a warning on a LIGHT surface is muddy and low-contrast on a DARK one. A
// [ThemeExtension] is resolved off the active [ThemeData], so [PlyColors.light] and
// [PlyColors.dark] can carry brightness-appropriate values, and Flutter will [lerp] between them
// during a theme animation. Widgets read it with `Theme.of(context).extension<PlyColors>()`.
//
// Scope is deliberately NARROW: just the warning role (foreground + container background). The
// rest of Ply's theme system is built in parallel; this file owns ONLY what the validation panel
// hardcoded. Resist adding more roles here — extra semantic colors belong in their own extension
// or the M3 ColorScheme proper.

import 'package:flutter/material.dart';

/// The "warning" color role Material 3's [ColorScheme] lacks, supplied to the widget tree as a
/// [ThemeExtension]. The validation panel reads [warning] for its advisory (non-error) tone, with
/// [onWarning] as a legible foreground over it and [warningContainer] as the tinted band
/// background. Register one of the [PlyColors.light] / [PlyColors.dark] factories in the matching
/// [ThemeData.extensions] so `Theme.of(context).extension<PlyColors>()` resolves it.
class PlyColors extends ThemeExtension<PlyColors> {
  const PlyColors({
    required this.warning,
    required this.onWarning,
    required this.warningContainer,
  });

  /// The warning tone itself: used for the warning icon and any warning-severity accent. Brighter
  /// on dark surfaces, deeper on light ones (see the factories) so it stays legible either way.
  final Color warning;

  /// A foreground legible ON TOP of [warning] (text/iconography painted over the warning color),
  /// per the M3 on-/container- pairing convention.
  final Color onWarning;

  /// A low-saturation tinted surface for a warning BAND or container background — a calmer fill
  /// than [warning] itself, so a block of warning text does not vibrate.
  final Color warningContainer;

  /// Light-theme warning palette. [warning] is the amber the validation panel historically
  /// hardcoded (`Color(0xFFB26A00)`), chosen to read as a warning against a light surface; black
  /// is the legible foreground over it, and a low-alpha amber tint serves as the container fill
  /// (the same 12%-alpha wash the band used inline, now named once).
  factory PlyColors.light() => const PlyColors(
        warning: Color(0xFFB26A00),
        onWarning: Color(0xFF000000),
        warningContainer: Color(0x1FB26A00),
      );

  /// Dark-theme warning palette. The deep light-mode amber goes muddy on a dark surface, so
  /// [warning] is LIGHTENED (`Color(0xFFE0A030)`) to keep contrast; near-black is the foreground
  /// over that brighter amber, and the container is a low-alpha wash of the lightened tone.
  factory PlyColors.dark() => const PlyColors(
        warning: Color(0xFFE0A030),
        onWarning: Color(0xFF1A1200),
        warningContainer: Color(0x1FE0A030),
      );

  /// Replace the named roles, defaulting each to the current value (`x ?? this.x`), matching the
  /// repo's [copyWith] house style.
  @override
  PlyColors copyWith({
    Color? warning,
    Color? onWarning,
    Color? warningContainer,
  }) {
    return PlyColors(
      warning: warning ?? this.warning,
      onWarning: onWarning ?? this.onWarning,
      warningContainer: warningContainer ?? this.warningContainer,
    );
  }

  /// Interpolate every role toward [other] for a smooth cross-fade during a theme/brightness
  /// animation. Each field uses [Color.lerp], falling back to `this` field when the result is null
  /// (i.e. when `other` is not a [PlyColors], so there is nothing to blend toward).
  @override
  PlyColors lerp(ThemeExtension<PlyColors>? other, double t) {
    if (other is! PlyColors) return this;
    return PlyColors(
      warning: Color.lerp(warning, other.warning, t) ?? warning,
      onWarning: Color.lerp(onWarning, other.onWarning, t) ?? onWarning,
      warningContainer:
          Color.lerp(warningContainer, other.warningContainer, t) ?? warningContainer,
    );
  }
}
